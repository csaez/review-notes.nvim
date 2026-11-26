-- Runs the configured backend command lines. This is the only code that spawns
-- the remote tool. Each operation is an argv list with `{placeholders}`; text
-- goes on stdin, structured output comes back as JSON on stdout.
local M = {}

---@class review_notes.Result
---@field ok boolean
---@field stdout string
---@field stderr string
---@field json any? decoded stdout, when it is JSON (also on failure: a partial result)
---@field kind review_notes.FailKind? why it failed

---@alias review_notes.FailKind
---| "offline" the remote is unreachable, or the command timed out
---| "no_access" no permission
---| "no_mr" no such merge request
---| "error" anything else

--- Exit statuses a backend uses to say why it failed (git-lab's); 124 is a
--- timeout, as `vim.system` and timeout(1) report it.
local KINDS = { [3] = "offline", [4] = "no_access", [5] = "no_mr", [124] = "offline" }

--- Resume *co*, reporting an error instead of losing it: a coroutine that
--- fails after its first yield has no caller to raise to.
---@param co thread
function M.resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then vim.notify("review: " .. tostring(err), vim.log.levels.ERROR) end
end

--- An unknown placeholder stays as it is. An argument holding an empty
--- `{mr}` is dropped: `--mr={mr}` before the review knows its MR.
local function substitute(argv, vars)
  local out = {}
  for _, arg in ipairs(argv) do
    local empty = false
    local s = arg:gsub("{(%w+)}", function(k)
      if k == "mr" and vars.mr == "" then empty = true end
      return vars[k] and tostring(vars[k]) or "{" .. k .. "}"
    end)
    if not empty then table.insert(out, s) end
  end
  return out
end

--- Run operation *name* of *cmds*. Must be called inside `M.async`; it yields
--- until the process exits.
---@param cmds table<string, string[]>
---@param name string
---@param opts { root: string, vars: table?, stdin: string? }
---@return review_notes.Result
function M.run(cmds, name, opts)
  local argv = cmds[name]
  if not argv then
    return { ok = false, stdout = "", stderr = "no backend command configured for '" .. name .. "'" }
  end
  local co = assert(coroutine.running(), "backend.run needs M.async")
  local limit = require("review_notes.config").values.timeout
  local started, err = pcall(vim.system, substitute(argv, opts.vars or {}), {
    cwd = opts.root,
    text = true,
    stdin = opts.stdin or false,
    -- A remote that drops packets must not hold the review forever.
    timeout = limit and limit * 1000 or nil,
  }, function(out)
    vim.schedule(function() M.resume(co, out) end)
  end)
  if not started then
    return { ok = false, stdout = "", stderr = tostring(err), kind = "error" }
  end
  local out = coroutine.yield()
  local result = { ok = out.code == 0, stdout = out.stdout or "", stderr = vim.trim(out.stderr or "") }
  if not result.ok then
    result.kind = KINDS[out.code] or "error"
    if out.code == 124 and result.stderr == "" then
      result.stderr = ("%s timed out after %ss"):format(argv[1], limit)
    end
  end
  if vim.trim(result.stdout) ~= "" then
    -- JSON null is nil, not vim.NIL, so callers can test fields with `or`.
    local decoded, json = pcall(vim.json.decode, result.stdout, { luanil = { object = true, array = true } })
    if decoded then result.json = json end
  end
  return result
end

--- Whether operation *name* takes placeholder *var*.
---@param cmds table<string, string[]>
---@return boolean
function M.uses(cmds, name, var)
  for _, arg in ipairs(cmds[name] or {}) do
    if arg:find("{" .. var .. "}", 1, true) then return true end
  end
  return false
end

--- Run *fn* as a coroutine so `run` calls read like blocking code while the UI
--- stays responsive.
---@param fn fun()
function M.async(fn)
  M.resume(coroutine.create(fn))
end

--- First line of an error, for notifications.
---@param r review_notes.Result
function M.message(r)
  local text = r.stderr ~= "" and r.stderr or vim.trim(r.stdout)
  return text ~= "" and text or "failed"
end

return M
