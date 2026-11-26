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

--- When each review (by notes path) was last pulled, this session.
---@type table<string, integer>
M.pulled_at = {}

---@class review_notes.PullState
---@field tried integer? last attempt, failed or not
---@field failing boolean? the last attempt failed
---@field since integer? when it started failing
---@field error string? why the last attempt failed
---@field kind review_notes.FailKind? what kind of failure
---@field running boolean? a pull is under way
---@field paused boolean? automatic pulls wait for a manual one: retrying
---  cannot help (no access, no MR, the MR merged or closed)
---@field mr review_notes.MrRecord|false|nil the MR the review is on, from
---  the sidecar (false: none recorded)
---@field declined string? the successor MR I chose not to move to, this session

---@type table<string, review_notes.PullState> by notes path
local pulls = {}

local function pull_state(ctx)
  local s = pulls[ctx.path]
  if not s then
    s = { mr = store.read_sidecar(store.sidecar_path(ctx.path)).mr or false }
    pulls[ctx.path] = s
  end
  return s
end

local status_listeners = {} ---@type fun()[]

--- Call *fn* when a pull starts or ends, or the MR changes.
---@param fn fun()
function M.on_status(fn) table.insert(status_listeners, fn) end

local function status_changed()
  for _, fn in ipairs(status_listeners) do fn() end
end

--- How syncing *ctx* goes: running, failing and why, the MR it is on.
---@param ctx review_notes.Context
---@return review_notes.PullState
function M.state(ctx) return pull_state(ctx) end

local function ended(mr) return mr and (mr.state == "merged" or mr.state == "closed") or false end
M.ended = ended

--- Who approved *mr*, other than me.
---@param mr review_notes.MrRecord|false|nil
---@return string[]
local function peer_approvals(mr)
  if not mr then return {} end
  return vim.tbl_filter(function(u) return u ~= mr.me end, mr.approved_by or {})
end
M.peer_approvals = peer_approvals

--- The backend variables of *ctx*: `{mr}` once the review knows its MR.
---@param ctx review_notes.Context
function M.vars(ctx, vars)
  local mr = pull_state(ctx).mr
  return vim.tbl_extend("keep", vars or {}, { mr = mr and mr.iid and tostring(mr.iid) or "" })
end

local function record_mr(ctx, mr)
  local s = pull_state(ctx)
  s.mr = mr or false
  review.edit(ctx, function(_, side) side.mr = mr end)
end

--- Turn the review of *ctx* to the branch's new MR *successor*, after a
--- confirm that says what happens to the threads of the old one.
---@return boolean moved
local function offer_successor(ctx, mr, mode)
  local succ = mr.successor
  if pull_state(ctx).declined == tostring(succ.iid) then return false end
  if mode == "auto" then
    notify(("MR %s is %s; the branch has a new MR %s: pull to move this review to it")
      :format(mr.ref, mr.state, succ.ref), vim.log.levels.WARN)
    return false
  end
  local doc = review.read(ctx)
  local remote, mine = 0, 0
  for _, t in ipairs(doc.threads) do
    if t.id and not t.orphan then
      if merge.has_unpublished(t) then mine = mine + 1 else remote = remote + 1 end
    end
  end
  local prompt = ("MR %s is %s; the branch has a new MR %s. Move this review to %s?"):format(
    mr.ref, mr.state, succ.ref, succ.ref)
  if remote > 0 then
    prompt = prompt .. ("\n  %d thread(s) of %s leave the notes (they stay on GitLab)"):format(remote, mr.ref)
  end
  if mine > 0 then
    prompt = prompt .. ("\n  %d thread(s) with your unpublished text stay, and publish as new threads on %s")
      :format(mine, succ.ref)
  end
  local move = "Move to " .. succ.ref
  local choice = choose(prompt, { move, "Stay on " .. mr.ref })
  if choice ~= move then
    pull_state(ctx).declined = tostring(succ.iid)
    return false
  end
  local next_mr = vim.deepcopy(succ)
  next_mr.successor = nil
  record_mr(ctx, next_mr)
  return true
end

--- Bring the remote threads in, inside an async function. Never sends.
--- *mode* `quiet` reports nothing; `auto` reports only when something came
--- in, and a failure only when the previous attempt worked.
---@param mode "quiet"|"auto"|nil
---@return boolean ok
local function pull(ctx, mode)
  local s = pull_state(ctx)
  s.tried = os.time()
  s.running = true
  status_changed()
  local ok, r = pcall(backend.run, config.values.backend, "threads", { root = ctx.root, vars = M.vars(ctx) })
  s.running = false
  if not ok then
    status_changed()
    error(r, 0)
  end
  -- {mr, threads} or the bare list of threads.
  local list, mr = r.json, nil
  if type(r.json) == "table" and type(r.json.threads) == "table" then
    list, mr = r.json.threads, type(r.json.mr) == "table" and r.json.mr or nil
  end
  if not r.ok or type(list) ~= "table" then
    local was = s.kind
    s.kind = r.ok and "error" or r.kind
    s.error = r.ok and "the backend printed no thread list" or backend.message(r)
    s.since = s.failing and s.since or os.time()
    -- Retrying cannot fix these; a manual pull checks again.
    s.paused = s.kind == "no_access" or s.kind == "no_mr" or s.kind == "no_remote"
    -- Automatic pulls report a failure once, and again when its kind changes.
    if not (mode == "auto" and s.failing and was == s.kind) then
      local msg = (mode == "auto" and "automatic pull failed: " or "pull failed: ") .. s.error
      if mode == "auto" and s.paused then msg = msg .. "\nautomatic pulls paused: pull to check again" end
      notify(msg, mode == "auto" and vim.log.levels.WARN or vim.log.levels.ERROR)
    end
    s.failing = true
    status_changed()
    return false
  end
  local was_ended = ended(s.mr)
  s.failing, s.error, s.kind, s.since = false, nil, nil, nil
  if mr and mr.successor and ended(mr) and offer_successor(ctx, mr, mode) then
    return pull(ctx, mode)
  end
  M.pulled_at[ctx.path] = os.time()
  if mr then
    local recorded = vim.deepcopy(mr)
    recorded.successor = nil
    -- A peer approving may make my review moot: say so once per approver,
    -- the first pull of an MR approved before I came included, and even in
    -- a quiet pull (the one publish runs first).
    local known = {}
    if s.mr and s.mr.iid == recorded.iid then
      for _, u in ipairs(peer_approvals(s.mr)) do known[u] = true end
    end
    local fresh = vim.tbl_filter(function(u) return not known[u] end, peer_approvals(recorded))
    if #fresh > 0 then
      notify(("MR %s approved by %s"):format(recorded.ref or "",
        table.concat(vim.tbl_map(function(u) return "@" .. u end, fresh), ", ")), vim.log.levels.WARN)
    end
    s.mr = recorded
  end
  s.paused = ended(s.mr)
  if s.paused and not was_ended and not (mr and mr.successor) then
    notify(("MR %s is %s: automatic pulls stopped; threads still pull and publish to it")
      :format(s.mr.ref or "", s.mr.state), vim.log.levels.WARN)
  end
  status_changed()
  local report = review.edit(ctx, function(doc, side)
    if mr then side.mr = s.mr end
    return merge.pull(doc, side, list)
  end)
  local news = report.added + report.changed + #report.orphaned > 0
  if mode ~= "quiet" and (news or mode ~= "auto") then
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

--- Pull *ctx* in the background when the last attempt is older than
--- `auto_pull` seconds (failed ones count, so an offline remote is not hit
--- on every focus). Quiet unless threads came in or it starts failing.
--- Skipped while the notes file has unsaved edits in a buffer: the write
--- would conflict with them; and while paused: no access, no MR, or the MR
--- merged or closed (a manual pull checks again).
---@param ctx review_notes.Context?
function M.auto_pull(ctx)
  local every = config.values.auto_pull
  if not every or not ctx or ctx.kind ~= "git" or not config.values.backend.threads then return end
  local s = pull_state(ctx)
  if s.running or s.paused or ended(s.mr) or os.time() - (s.tried or 0) < every then return end
  local buf = vim.fn.bufnr(ctx.path)
  if buf ~= -1 and vim.bo[buf].modified then return end
  -- Set before the coroutine starts: a second focus must not start another.
  s.running = true
  backend.async(function() pull(ctx, "auto") end)
end

--- Pull *ctx* now, quietly (after an MR action: who reviews it changed).
---@param ctx review_notes.Context
function M.refresh(ctx)
  if ctx.kind ~= "git" or not config.values.backend.threads then return end
  local s = pull_state(ctx)
  if s.running then return end
  s.running = true
  backend.async(function() pull(ctx, "quiet") end)
end

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
  if pull_state(ctx).running then return notify("a pull is under way") end
  notify("pulling...")
  backend.async(function() pull(ctx) end)
end

local function label(item)
  local t = item.thread
  return t.anchor.path and store.anchor_string(t.anchor) or "the change"
end

local function describe_plan(items, held)
  local lines = {}
  for _, item in ipairs(items) do
    local what = ({
      thread = "new thread on ", reply = "reply on ", resolve = "resolve ", unresolve = "reopen ",
    })[item.kind]
    local note = item.stale and "  (new comments since you wrote this)"
      or item.thread.orphan and "  (gone from the MR: posted again as a new thread)"
      or ""
    table.insert(lines, ("  %s%s%s"):format(what, label(item), note))
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
  local r = backend.run(cmds, "submit", { root = ctx.root, vars = M.vars(ctx, { ids = table.concat(ids, ",") }) })
  local published = {}
  local listed = type(r.json) == "table" and type(r.json.published) == "table"
  for _, id in ipairs(listed and r.json.published or (r.ok and ids or {})) do
    published[tostring(id)] = true
  end
  local left = vim.tbl_filter(function(id) return not published[id] end, ids)
  local stuck
  if #left > 0 then
    local d = cmds.discard
      and backend.run(cmds, "discard", { root = ctx.root, vars = M.vars(ctx, { ids = table.concat(left, ",") }) })
    if not (d and d.ok) then stuck = left end
  end
  return published, not r.ok and r or nil, stuck
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
    if pull_state(ctx).running then return notify("a pull is under way, publish again when it is done") end
    if not pull(ctx, "quiet") then return end
    local doc, side = review.read(ctx)
    local plan = merge.plan(doc, side)
    if #plan.items == 0 then
      return notify("nothing to publish" .. (#plan.held > 0 and (" (%d proposed, not approved)"):format(#plan.held) or ""))
    end
    local stale = vim.tbl_filter(function(i) return i.stale end, plan.items)
    local choices = #stale > 0 and { "Publish all", "Skip the ones with new comments", "Cancel" } or { "Publish", "Cancel" }
    local mr = pull_state(ctx).mr
    local header = ended(mr) and ("MR %s is %s. Publish to it anyway?\n"):format(mr.ref or "", mr.state) or "Publish?\n"
    local peers = peer_approvals(mr)
    if #peers > 0 and not ended(mr) then
      header = ("MR %s is already approved by %s. Publish?\n"):format(mr.ref or "",
        table.concat(vim.tbl_map(function(u) return "@" .. u end, peers), ", "))
    end
    local choice = choose(header .. describe_plan(plan.items, plan.held), choices)
    if not choice or choice == "Cancel" then return end
    local items = plan.items
    if choice:match("^Skip") then
      items = vim.tbl_filter(function(i) return not i.stale end, items)
    end

    local failures, done = {}, {}
    local function fail(what, r) table.insert(failures, what .. ": " .. backend.message(r)) end
    local function run(name, vars, stdin)
      return backend.run(cmds, name, { root = ctx.root, vars = M.vars(ctx, vars), stdin = stdin })
    end
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
          sent(item, run("add", { path = a.path, line = a.end_line or a.line or 0 }, text))
        else
          sent(item, run("general", nil, text))
        end
      elseif item.kind == "reply" then
        sent(item, run("reply", { thread = t.id }, text))
      end
    end
    if by_id and #ids > 0 then
      local published, err, stuck = submit(ctx, ids)
      if err then fail("submit", err) end
      if stuck then
        fail("cleanup", { stderr = "drafts may still be pending on the remote, unpublished: " .. table.concat(stuck, ", ") })
      end
      for item in pairs(queued) do
        if not published[queued[item]] then done[item] = nil end
      end
    elseif cmds.submit and not by_id then
      local r = run("submit")
      if not r.ok then
        fail("submit", r)
        local d = cmds.discard and run("discard")
        if not (d and d.ok) then
          fail("cleanup", { stderr = "drafts may still be pending on the remote, unpublished" })
        end
        done = {}
      end
    end
    -- After submit: publishing a queued reply reopens a resolved thread.
    for _, item in ipairs(items) do
      if item.kind == "resolve" or item.kind == "unresolve" then
        local r = run(item.kind, { thread = item.thread.id })
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
    pull(ctx, "quiet")
    if #failures > 0 then
      notify("published with problems:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
    else
      local sent_count = vim.tbl_count(done)
      notify(("published %d item%s"):format(sent_count, sent_count == 1 and "" or "s"))
    end
  end)
end

return M
