-- The verbs on threads, in one place: every UI (the code buffer keys, the
-- finder, the sidebar) calls these. A thread is named by its review and key;
-- the change is local until `publish`. The `*_items`
-- variants take finder / list items and tell when there is nothing to do.
local store = require("review_notes.store")
local merge = require("review_notes.merge")
local review = require("review_notes.review")
local compose = require("review_notes.compose")

local M = {}

local notify = review.notify

--- Resolve or reopen. Resolving something someone else resolved only
--- accepts it.
---@param ctx review_notes.Context
---@param key string
function M.resolve(ctx, key)
  review.edit_thread(ctx, key, function(t, _, side)
    if merge.resolved_unseen(t, t.id and side.threads[t.id]) then
      merge.mark_seen(t, side)
    else
      t.status = t.status == "resolved" and "open" or "resolved"
    end
  end)
end

---@param ctx review_notes.Context
---@param key string
function M.read(ctx, key)
  review.edit_thread(ctx, key, function(t, _, side) merge.mark_seen(t, side) end)
end

--- Whether the review is private: a document, or a branch with no MR yet.
--- Then my new threads start as notes, and approving a finding means "agreed".
---@param ctx review_notes.Context
---@param side review_notes.Sidecar
---@return boolean
function M.private(ctx, side)
  return ctx.kind ~= "git" or not side.mr
end

--- Approve what a tool proposed: on a thread that publishes, so `publish`
--- sends it; on a local-only one (or any finding while the review is
--- private), as agreed.
---@param ctx review_notes.Context
---@param key string
function M.approve(ctx, key)
  review.edit_thread(ctx, key, function(t, _, side) merge.approve(t, M.private(ctx, side)) end)
end

--- Approve every proposed comment of the review.
---@param ctx review_notes.Context
---@return integer approved
function M.approve_all(ctx)
  return review.edit(ctx, function(doc, side)
    local total = 0
    local private = M.private(ctx, side)
    for _, t in ipairs(doc.threads) do total = total + merge.approve(t, private) end
    return total
  end) or 0
end

--- Mark every thread of the review as seen.
---@param ctx review_notes.Context
function M.read_all(ctx)
  review.edit(ctx, function(doc, side)
    for _, t in ipairs(doc.threads) do merge.mark_seen(t, side) end
  end)
end

--- Remove everything unpublished from a thread: my text, proposed comments,
--- and a resolve or reopen not sent yet. A thread that was never published
--- goes entirely, as if it never existed.
local function drop_unpublished(t, doc, side)
  t.comments = vim.tbl_filter(function(c) return c.source == "remote" end, t.comments)
  if not t.id then
    doc.threads = vim.tbl_filter(function(x) return x ~= t end, doc.threads)
  elseif side.threads[t.id] then
    t.status = side.threads[t.id].status
  end
end

--- Whether *item* has anything `discard` would remove.
---@param item review_notes.Item
---@return boolean
function M.can_discard(item)
  local e = item.entry
  local f = merge.flags(e.thread, e.state)
  return merge.has_unpublished(e.thread) or (f.unsent and e.thread.id ~= nil)
end

--- Whether *item* has a proposed comment to approve.
---@param item review_notes.Item
---@return boolean
function M.can_approve(item)
  return merge.flags(item.entry.thread, item.entry.state).proposed
end

--- What `resolve` does to *item*: "accept" (someone else's resolve),
--- "reopen" or "resolve".
---@param item review_notes.Item
---@return string
function M.resolve_verb(item)
  local t = item.entry.thread
  if merge.resolved_unseen(t, item.entry.state) then return "accept" end
  return t.status == "resolved" and "reopen" or "resolve"
end

--- Delete the unpublished part of a thread (mine and proposed). Remote
--- comments are never touched.
---@param ctx review_notes.Context
---@param key string
function M.discard(ctx, key)
  review.edit_thread(ctx, key, drop_unpublished)
end

--- Approve the proposed comments of *items*.
---@param items review_notes.Item[]
function M.approve_items(items)
  if #items == 0 then return end
  local list = vim.tbl_filter(M.can_approve, items)
  if #list == 0 then return notify("nothing proposed here") end
  for _, i in ipairs(list) do M.approve(i.ctx, i.key) end
end

--- Discard the unpublished part of *items*. Only deleting a thread that was
--- never published asks first; the rest is local text. *done* runs after.
---@param items review_notes.Item[]
---@param done fun()?
function M.discard_items(items, done)
  if #items == 0 then return end
  local list = vim.tbl_filter(M.can_discard, items)
  if #list == 0 then return notify("nothing unpublished here") end
  local new = #vim.tbl_filter(function(i) return not i.entry.thread.id end, list)
  local function go()
    for _, i in ipairs(list) do M.discard(i.ctx, i.key) end
    if done then done() end
  end
  if new == 0 then return go() end
  local prompt = #list == 1 and "Delete this thread (never published)?"
    or ("Discard %d threads; %d never published will be deleted?"):format(#list, new)
  vim.ui.select({ "Discard", "Keep" }, { prompt = prompt }, function(choice)
    if choice == "Discard" then go() end
  end)
end

--- Delete every proposed comment (a tool's), threads it started included,
--- after a confirm. Mine and the remote's stay.
---@param ctx review_notes.Context
function M.discard_proposed(ctx)
  local doc = review.read(ctx)
  local n = 0
  for _, t in ipairs(doc.threads) do
    for _, c in ipairs(t.comments) do
      if c.source == "proposed" then n = n + 1 end
    end
  end
  if n == 0 then return notify("no proposed comments") end
  vim.ui.select({ "Discard", "Keep" }, { prompt = ("Delete all %d proposed comments?"):format(n) }, function(choice)
    if choice ~= "Discard" then return end
    review.edit(ctx, function(d, side)
      local keep = {}
      for _, t in ipairs(d.threads) do
        local had = merge.has_unpublished(t)
        t.comments = vim.tbl_filter(function(c) return c.source ~= "proposed" end, t.comments)
        if t.id then
          if had and side.threads[t.id] and not merge.has_unpublished(t) then t.status = side.threads[t.id].status end
          table.insert(keep, t)
        elseif #t.comments > 0 then
          table.insert(keep, t)
        end
      end
      d.threads = keep
    end)
  end)
end

-- Writing -------------------------------------------------------------------

---@class review_notes.Target
---@field key string? an existing thread
---@field anchor review_notes.Anchor? where to start a new one

--- Mine and not published: a local comment or a note.
local function is_mine(c) return c.source == "local" or c.source == "note" end

--- Save my comment of a thread (the one not published yet); an empty text
--- removes it, and a new thread with nothing left. *note* writes it as a
--- note for the agent, never published; a reply on a local-only thread is
--- always one.
---@param ctx review_notes.Context
---@param target review_notes.Target
---@param text string
---@param note boolean?
function M.save_comment(ctx, target, text, note)
  review.edit(ctx, function(doc)
    local thread
    if target.key then
      for i, k in ipairs(review.keys_of(doc)) do
        if k == target.key then thread = doc.threads[i] end
      end
    end
    if not thread then
      if text == "" or not target.anchor then return end
      thread = { anchor = target.anchor, status = "open", comments = {} }
      table.insert(doc.threads, thread)
    end
    local source = (note or merge.local_only(thread)) and "note" or "local"
    local mine
    for _, c in ipairs(thread.comments) do
      if is_mine(c) then mine = c end
    end
    if text == "" then
      if mine then
        thread.comments = vim.tbl_filter(function(c) return c ~= mine end, thread.comments)
      end
      if not thread.id and #thread.comments == 0 then
        doc.threads = vim.tbl_filter(function(t) return t ~= thread end, doc.threads)
      end
    elseif mine then
      mine.body, mine.source = text, source
    else
      table.insert(thread.comments, { source = source, body = text })
    end
    merge.sort(doc.threads)
  end)
end

--- The composer starts as a note on a local-only thread (and stays one),
--- on my existing note, and on a thread not published yet while the review
--- is private; as a comment for the remote otherwise. `<C-t>` switches.
local function open_composer(ctx, target, title, thread, win)
  local existing
  for _, c in ipairs(thread and thread.comments or {}) do
    if is_mine(c) then existing = c end
  end
  -- A document's review never publishes: plain comments, nothing to switch.
  local fixed = ctx.kind ~= "git" or (thread ~= nil and merge.local_only(thread))
  local note = false
  if ctx.kind ~= "git" then
    note = false
  elseif fixed then
    note = true
  elseif existing then
    note = existing.source == "note"
  elseif not (thread and thread.id) then
    local _, side = review.read(ctx)
    note = M.private(ctx, side)
  end
  compose.open({
    title = title,
    text = existing and existing.body,
    win = win,
    note = note,
    fixed = fixed,
    on_save = function(text, as_note) M.save_comment(ctx, target, text, as_note) end,
  })
end

--- Reply to a thread, or edit my reply not published yet.
---@param ctx review_notes.Context
---@param entry review_notes.Entry
---@param win integer? open the composer inside this window (the sidebar)
function M.reply(ctx, entry, win)
  open_composer(ctx, { key = entry.key }, "reply to " .. store.anchor_string(entry.thread.anchor), entry.thread, win)
end

--- Start a thread on *anchor* (`{}` is the whole change).
---@param ctx review_notes.Context
---@param anchor review_notes.Anchor
function M.new_thread(ctx, anchor)
  local where = anchor.path and store.anchor_string(anchor) or "the change"
  open_composer(ctx, { anchor = anchor }, "new thread on " .. where)
end

return M
