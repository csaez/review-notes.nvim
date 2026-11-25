-- Talking to the remote: `pull` brings threads in and never sends,
-- `publish` shows the plan, confirms, then sends exactly that. See the
-- "Safe pull" and "Safe publish" rules in DESIGN.md.
local merge = require("review_notes.merge")
local backend = require("review_notes.backend")
local config = require("review_notes.config")
local review = require("review_notes.review")
local store = require("review_notes.store")

local M = {}

local notify = review.notify

local function choose(prompt, choices)
  local co = assert(coroutine.running())
  vim.ui.select(choices, { prompt = prompt }, function(choice)
    vim.schedule(function() backend.resume(co, choice) end)
  end)
  return coroutine.yield()
end

--- Bring the remote threads in, inside an async function. Never sends.
---@return boolean ok
local function pull(ctx, opts)
  local r = backend.run(config.values.backend, "threads", { root = ctx.root })
  if not r.ok or type(r.json) ~= "table" then
    notify("pull failed: " .. (r.ok and "the backend printed no thread list" or backend.message(r)), vim.log.levels.ERROR)
    return false
  end
  local report
  M.pulled_at[ctx.path] = os.time()
  review.edit(ctx, function(doc, side)
    report = merge.pull(doc, side, r.json)
  end)
  if not (opts and opts.quiet) then
    local unread = 0
    for _, item in ipairs(review.items(ctx)) do
      if item.state == "unread" then unread = unread + 1 end
    end
    local msg = ("pulled: %d new threads, %d updated, %d unread"):format(report.added, report.changed, unread)
    if #report.orphaned > 0 then
      msg = msg .. "\ndeleted on the remote, kept because they hold your text: " .. table.concat(report.orphaned, ", ")
    end
    notify(msg, #report.orphaned > 0 and vim.log.levels.WARN or nil)
  end
  return true
end

--- When each review (by notes path) was last pulled, this session.
---@type table<string, integer>
M.pulled_at = {}

local function git_review(ctx)
  if ctx and ctx.kind == "git" then return ctx end
  return review.remote_context()
end

--- Bring the remote threads in. Never sends anything.
---@param ctx review_notes.Context? default: the current buffer's review
function M.pull(ctx)
  ctx = git_review(ctx)
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function() pull(ctx) end)
end

local function label(item)
  local t = item.thread
  return t.anchor.path and store.anchor_string(t.anchor) or "the change"
end

local function describe_plan(items, held)
  local lines, n = {}, { thread = 0, reply = 0, resolve = 0, unresolve = 0 }
  for _, item in ipairs(items) do
    n[item.kind] = n[item.kind] + 1
    local what = ({
      thread = "new thread on ", reply = "reply on ", resolve = "resolve ", unresolve = "reopen ",
    })[item.kind]
    table.insert(lines, ("  %s%s%s"):format(what, label(item), item.stale and "  (new comments since you wrote this)" or ""))
  end
  if #lines > 8 then
    local extra = #lines - 7
    lines = vim.list_slice(lines, 1, 7)
    table.insert(lines, ("  ... and %d more"):format(extra))
  end
  if #held > 0 then
    table.insert(lines, ("  %d thread(s) with proposed comments not approved: skipped"):format(#held))
  end
  return table.concat(lines, "\n")
end

local function submit(ctx, ids)
  local cmds = config.values.backend
  local r = backend.run(cmds, "submit", { root = ctx.root, vars = { ids = table.concat(ids, ",") } })
  local published = {}
  local listed = type(r.json) == "table" and type(r.json.published) == "table"
  for _, id in ipairs(listed and r.json.published or (r.ok and ids or {})) do
    published[tostring(id)] = true
  end
  local left = vim.tbl_filter(function(id) return not published[id] end, ids)
  if #left > 0 and cmds.discard then
    backend.run(cmds, "discard", { root = ctx.root, vars = { ids = table.concat(left, ",") } })
  end
  return published, not r.ok and r or nil
end

--- Pull, show what would be sent, and send it after a confirm. Everything is
--- queued as drafts and published together (one notification), only the
--- drafts created here.
---@param ctx review_notes.Context? default: the current buffer's review
function M.publish(ctx)
  ctx = git_review(ctx)
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function()
    local cmds = config.values.backend
    if not pull(ctx, { quiet = true }) then return end
    local doc, side = review.read(ctx)
    local plan = merge.plan(doc, side)
    if #plan.items == 0 then
      return notify("nothing to publish" .. (#plan.held > 0 and (" (%d proposed, not approved)"):format(#plan.held) or ""))
    end
    local stale = vim.tbl_filter(function(i) return i.stale end, plan.items)
    local choices = #stale > 0 and { "Publish all", "Skip the ones with new comments", "Cancel" } or { "Publish", "Cancel" }
    local choice = choose("Publish?\n" .. describe_plan(plan.items, plan.held), choices)
    if not choice or choice == "Cancel" then return end
    local items = plan.items
    if choice:match("^Skip") then
      items = vim.tbl_filter(function(i) return not i.stale end, items)
    end

    local failures, done = {}, {}
    local function fail(what, r) table.insert(failures, what .. ": " .. backend.message(r)) end
    local by_id = cmds.submit and backend.uses(cmds, "submit", "ids")
    local queued, ids = {}, {}
    local function sent(item, r)
      if not r.ok then return fail(label(item), r) end
      local id = type(r.json) == "table" and r.json.id
      if by_id and not id then
        return fail(label(item), { stderr = "queued, but the backend printed no id: left pending on the remote" })
      end
      if by_id then
        queued[item] = tostring(id)
        table.insert(ids, tostring(id))
      end
      done[item] = true
    end

    for _, item in ipairs(items) do
      local t, text = item.thread, item.comment and item.comment.body
      if item.kind == "thread" then
        local a = t.anchor
        if a.path then
          -- A range is anchored at its last line, as on the remote.
          local vars = { path = a.path, line = a.end_line or a.line or 0 }
          sent(item, backend.run(cmds, "add", { root = ctx.root, vars = vars, stdin = text }))
        else
          sent(item, backend.run(cmds, "general", { root = ctx.root, stdin = text }))
        end
      elseif item.kind == "reply" then
        sent(item, backend.run(cmds, "reply", { root = ctx.root, vars = { thread = t.id }, stdin = text }))
      end
    end
    if by_id and #ids > 0 then
      local published, err = submit(ctx, ids)
      if err then fail("submit", err) end
      for item in pairs(queued) do
        if not published[queued[item]] then done[item] = nil end
      end
    elseif cmds.submit and not by_id then
      local r = backend.run(cmds, "submit", { root = ctx.root })
      if not r.ok then
        fail("submit", r)
        if cmds.discard then backend.run(cmds, "discard", { root = ctx.root }) end
        for item in pairs(queued) do done[item] = nil end
        for item in pairs(done) do
          if item.kind ~= "resolve" and item.kind ~= "unresolve" then done[item] = nil end
        end
      end
    end
    -- After submit: publishing a queued reply reopens a resolved thread.
    for _, item in ipairs(items) do
      if item.kind == "resolve" or item.kind == "unresolve" then
        local r = backend.run(cmds, item.kind, { root = ctx.root, vars = { thread = item.thread.id } })
        if r.ok then done[item] = true else fail(item.kind .. " " .. label(item), r) end
      end
    end

    review.edit(ctx, function(d, s)
      for _, item in ipairs(items) do
        local found = done[item] and merge.relocate(d, item)
        if found then merge.published(d, s, found) end
      end
    end)
    -- What was sent comes back as remote comments, mine, so not unread.
    pull(ctx, { quiet = true })
    if #failures > 0 then
      notify("published with problems:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
    else
      local sent_count = vim.tbl_count(done)
      notify(("published %d item%s"):format(sent_count, sent_count == 1 and "" or "s"))
    end
  end)
end

return M
