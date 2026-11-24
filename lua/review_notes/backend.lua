-- Runs the configured backend command lines. This is the only code that spawns
-- the remote tool. Each operation is an argv list with `{placeholders}`; text
-- goes on stdin, structured output comes back as JSON on stdout.
local M = {}

---@class review_notes.Result
---@field ok boolean
---@field stdout string
---@field stderr string
---@field json any? decoded stdout, when it is JSON (also on failure: a partial result)

--- Resume *co*, reporting an error instead of losing it: a coroutine that
--- fails after its first yield has no caller to raise to.
---@param co thread
function M.resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then vim.notify("review: " .. tostring(err), vim.log.levels.ERROR) end
end

local function substitute(argv, vars)
  local out = {}
  for i, arg in ipairs(argv) do
    out[i] = (arg:gsub("{(%w+)}", function(k) return vars[k] and tostring(vars[k]) or "{" .. k .. "}" end))
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
  local started, err = pcall(vim.system, substitute(argv, opts.vars or {}), {
    cwd = opts.root,
    text = true,
    stdin = opts.stdin or false,
  }, function(out)
    vim.schedule(function() M.resume(co, out) end)
  end)
  if not started then
    return { ok = false, stdout = "", stderr = tostring(err) }
  end
  local out = coroutine.yield()
  local result = { ok = out.code == 0, stdout = out.stdout or "", stderr = vim.trim(out.stderr or "") }
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
  local co = coroutine.create(fn)
  local function step(...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then vim.notify("review: " .. tostring(err), vim.log.levels.ERROR) end
  end
  step()
end

--- First line of an error, for notifications.
---@param r review_notes.Result
function M.message(r)
  local text = r.stderr ~= "" and r.stderr or vim.trim(r.stdout)
  return text ~= "" and text or "failed"
end

return M
