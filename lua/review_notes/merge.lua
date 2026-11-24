-- The rules for pull and publish, as pure functions on a document, the
-- sidecar and the backend's thread list. See DESIGN.md ("Safe pull", "Safe
-- publish"). Nothing here touches files, buffers or processes.
local store = require("review_notes.store")

local M = {}

---@class review_notes.RemoteComment
---@field id string?
---@field author string?
---@field body string
---@field mine boolean?

---@class review_notes.RemoteThread
---@field id string
---@field path string? nil for a thread on the whole change
---@field line integer? 0 or nil for the whole file
---@field start_line integer?
---@field resolved boolean
---@field resolved_by string?
---@field resolved_by_me boolean?
---@field comments review_notes.RemoteComment[]

-- Helpers ---------------------------------------------------------------

local function state_of(side, id)
  side.threads[id] = side.threads[id] or { status = "open", seen = {}, seen_status = true }
  return side.threads[id]
end

local function has_source(thread, source)
  for _, c in ipairs(thread.comments) do
    if c.source == source then return true end
  end
  return false
end

--- Whether the thread holds text of mine that only exists here.
---@param thread review_notes.Thread
---@return boolean
function M.has_unpublished(thread)
  return has_source(thread, "local") or has_source(thread, "proposed")
end

---@param remote review_notes.RemoteThread
---@return review_notes.Anchor
local function anchor_of(remote)
  if not remote.path then return {} end
  if not remote.line or remote.line == 0 then return { path = remote.path } end
  local first = remote.start_line
  if first and first > 0 and first < remote.line then
    return { path = remote.path, line = first, end_line = remote.line }
  end
  return { path = remote.path, line = remote.line }
end

-- A local anchor follows my edits, so the remote's wins only when mine is
-- plainly wrong: another file, or a different kind of anchor.
local function keep_anchor(mine, theirs)
  if mine.path ~= theirs.path then return theirs end
  if (mine.line == nil) ~= (theirs.line == nil) then return theirs end
  return mine
end

-- Unread ----------------------------------------------------------------

--- Remote comments of someone else that I have not seen yet.
---@param thread review_notes.Thread
---@param state review_notes.ThreadState?
---@return integer
function M.unread_count(thread, state)
  local seen = state and state.seen or {}
  local n = 0
  for _, c in ipairs(thread.comments) do
    if c.source == "remote" and not c.mine and not (c.id and seen[c.id]) then n = n + 1 end
  end
  return n
end

--- Resolved by someone else, and not looked at yet.
---@param thread review_notes.Thread
---@param state review_notes.ThreadState?
---@return boolean
function M.resolved_unseen(thread, state)
  return thread.status == "resolved" and state ~= nil and state.resolved_by ~= nil and not state.seen_status
end

---@param thread review_notes.Thread
---@param state review_notes.ThreadState?
---@return boolean
function M.is_unread(thread, state)
  return M.unread_count(thread, state) > 0 or M.resolved_unseen(thread, state)
end

--- Mark everything in the thread as seen.
---@param thread review_notes.Thread
---@param side review_notes.Sidecar
function M.mark_seen(thread, side)
  if not thread.id then return end
  local state = state_of(side, thread.id)
  for _, c in ipairs(thread.comments) do
    if c.source == "remote" and c.id then state.seen[c.id] = true end
  end
  state.seen_status = true
end

---@class review_notes.Flags
---@field unread boolean
---@field proposed boolean a tool's comment waits for my approval
---@field unsent boolean text of mine, or a status change, not published yet
---@field resolved boolean
---@field resolved_by string? set while someone else's resolve is unseen
---@field new boolean the thread does not exist on the remote yet
---@field orphan boolean

--- Everything a view needs to know about a thread's state.
---@param thread review_notes.Thread
---@param state review_notes.ThreadState?
---@return review_notes.Flags
function M.flags(thread, state)
  local unseen = M.resolved_unseen(thread, state)
  return {
    unread = M.is_unread(thread, state),
    proposed = has_source(thread, "proposed"),
    unsent = has_source(thread, "local")
      or (thread.id ~= nil and state ~= nil and thread.status ~= state.status),
    resolved = thread.status == "resolved",
    resolved_by = unseen and state and state.resolved_by or nil,
    new = thread.id == nil or thread.orphan == true,
    orphan = thread.orphan == true,
  }
end

--- The most urgent state, for an icon and for sorting: lower is more urgent.
---@param f review_notes.Flags
---@return "unread"|"proposed"|"unsent"|"resolved"|"open", integer
function M.urgency(f)
  if f.unread then return "unread", 1 end
  if f.proposed then return "proposed", 2 end
  if f.unsent then return "unsent", 3 end
  if f.resolved then return "resolved", 5 end
  return "open", 4
end

-- Pull ------------------------------------------------------------------

local function sort_key(thread)
  local a = thread.anchor
  return a.path and 1 or 0, a.path or "", a.line or 0
end

function M.sort(threads)
  local indexed = {}
  for i, t in ipairs(threads) do indexed[i] = { t = t, i = i } end
  table.sort(indexed, function(x, y)
    local xg, xp, xl = sort_key(x.t)
    local yg, yp, yl = sort_key(y.t)
    if xg ~= yg then return xg < yg end
    if xp ~= yp then return xp < yp end
    if xl ~= yl then return xl < yl end
    return x.i < y.i
  end)
  for i, e in ipairs(indexed) do threads[i] = e.t end
end

---@class review_notes.PullReport
---@field added integer threads new from the remote
---@field changed integer threads whose remote comments changed
---@field orphaned string[] anchors of threads deleted remotely that I keep

--- Merge the remote threads into the document and the sidecar, in place.
--- Remote comments are replaced. Local and proposed comments, and a status
--- change I have not published, are never touched.
---@param doc review_notes.Doc
---@param side review_notes.Sidecar
---@param remote review_notes.RemoteThread[]
---@return review_notes.PullReport
function M.pull(doc, side, remote)
  local report = { added = 0, changed = 0, orphaned = {} }
  local by_id = {}
  for _, t in ipairs(doc.threads) do
    if t.id then by_id[t.id] = t end
  end
  local remote_ids = {}

  for _, r in ipairs(remote) do
    remote_ids[r.id] = true
    local before = side.threads[r.id]
    local prev = before and { status = before.status, seen_status = before.seen_status }
    local thread = by_id[r.id]
    local theirs = anchor_of(r)
    local comments = {}
    for _, c in ipairs(r.comments) do
      table.insert(comments, {
        source = "remote",
        author = c.author,
        id = c.id,
        mine = c.mine or nil,
        body = c.body,
      })
    end

    local old_remote = {}
    if thread then
      for _, c in ipairs(thread.comments) do
        if c.source == "remote" then table.insert(old_remote, c.body) end
      end
    end

    local status = r.resolved and "resolved" or "open"
    if thread then
      local pending = prev and thread.status ~= prev.status
      local mine = {}
      for _, c in ipairs(thread.comments) do
        if c.source ~= "remote" then table.insert(mine, c) end
      end
      vim.list_extend(comments, mine)
      thread.comments = comments
      thread.anchor = keep_anchor(thread.anchor, theirs)
      thread.orphan = nil
      if not pending then thread.status = status end

      local same = #old_remote == #r.comments
      for i, body in ipairs(old_remote) do
        if r.comments[i] and r.comments[i].body ~= body then same = false end
      end
      if not same then report.changed = report.changed + 1 end
    else
      thread = { anchor = theirs, status = status, id = r.id, comments = comments }
      table.insert(doc.threads, thread)
      by_id[r.id] = thread
      report.added = report.added + 1
    end

    local state = state_of(side, r.id)
    state.status = status
    if r.resolved and not r.resolved_by_me then
      local newly = prev == nil or prev.status ~= "resolved"
      state.resolved_by = r.resolved_by or "someone"
      state.seen_status = not newly and prev.seen_status ~= false
    else
      state.resolved_by, state.seen_status = nil, true
    end
  end

  local kept = {}
  for _, t in ipairs(doc.threads) do
    if not t.id or remote_ids[t.id] then
      table.insert(kept, t)
    elseif M.has_unpublished(t) then
      t.orphan = true
      table.insert(kept, t)
      table.insert(report.orphaned, store.anchor_string(t.anchor))
    else
      side.threads[t.id] = nil
    end
  end
  doc.threads = kept
  M.sort(doc.threads)
  return report
end

-- Publish ---------------------------------------------------------------

---@class review_notes.PlanItem
---@field kind "thread"|"reply"|"resolve"|"unresolve"
---@field thread review_notes.Thread
---@field comment review_notes.Comment? the local comment sent, for "thread" and "reply"
---@field stale boolean? the thread got remote comments I have not seen since I wrote this

---@class review_notes.Plan
---@field items review_notes.PlanItem[]
---@field held review_notes.Thread[] threads with proposed comments, not sent

--- What publish would send. A proposed comment is never sent, and while a
--- thread has one its status change is held too, so approving takes one step.
--- Unread never blocks: it only marks the item stale, for a per-thread
--- confirm in the summary.
---@param doc review_notes.Doc
---@param side review_notes.Sidecar
---@return review_notes.Plan
function M.plan(doc, side)
  local plan = { items = {}, held = {} }
  for _, t in ipairs(doc.threads) do
    local id = not t.orphan and t.id or nil
    local state = id and side.threads[id] or nil
    local stale = state ~= nil and M.unread_count(t, state) > 0
    local proposed = has_source(t, "proposed")
    if proposed then table.insert(plan.held, t) end

    for _, c in ipairs(t.comments) do
      if c.source == "local" and c.body ~= "" then
        table.insert(plan.items, {
          kind = id and "reply" or "thread",
          thread = t,
          comment = c,
          stale = stale or nil,
        })
        if not id then break end
      end
    end

    if id and state and not proposed and t.status ~= state.status then
      table.insert(plan.items, { kind = t.status == "resolved" and "resolve" or "unresolve", thread = t })
    end
  end
  return plan
end

--- Record that *item* was published: the sent text leaves the document and
--- the next pull brings it back as a remote comment. A thread that does not
--- exist remotely (new, or orphaned) goes away with its text: the pull
--- re-adds it under its real id.
---@param doc review_notes.Doc
---@param side review_notes.Sidecar
---@param item review_notes.PlanItem
function M.published(doc, side, item)
  local t = item.thread
  if item.comment then
    for i, c in ipairs(t.comments) do
      if c == item.comment then
        table.remove(t.comments, i)
        break
      end
    end
  end
  if item.kind == "thread" and not M.has_unpublished(t) then
    for i, other in ipairs(doc.threads) do
      if other == t then
        table.remove(doc.threads, i)
        break
      end
    end
  elseif item.kind == "resolve" or item.kind == "unresolve" then
    state_of(side, t.id).status = t.status
  end
end

--- The thread and comment of *item* in a freshly read *doc*, as an item that
--- `published` can act on, or nil when it is gone or changed meanwhile.
---@param doc review_notes.Doc
---@param item review_notes.PlanItem
---@return review_notes.PlanItem?
function M.relocate(doc, item)
  local old = item.thread
  local anchor = store.anchor_string(old.anchor)
  local keyed = old.id ~= nil and not old.orphan
  for _, t in ipairs(doc.threads) do
    local same
    if keyed then
      same = t.id == old.id
    else
      same = (t.id == nil or t.orphan) and t.id == old.id and store.anchor_string(t.anchor) == anchor
    end
    if same then
      if not item.comment then
        if t.status == old.status then return { kind = item.kind, thread = t } end
      else
        for _, c in ipairs(t.comments) do
          if c.source == "local" and c.body == item.comment.body then
            return { kind = item.kind, thread = t, comment = c }
          end
        end
      end
    end
  end
end

-- Approve ---------------------------------------------------------------

--- Turn the proposed comments of a thread into mine, so publish sends them.
---@param thread review_notes.Thread
---@return integer approved
function M.approve(thread)
  local n = 0
  for _, c in ipairs(thread.comments) do
    if c.source == "proposed" then
      c.source = "local"
      n = n + 1
    end
  end
  return n
end

return M
