-- The verbs on threads, in one place: every UI (the code buffer keys, the
-- picker, the home and the thread panel) calls these. A thread is named by
-- its review and key; the change is local until `publish`. The `*_items`
-- variants take picker / home items and tell when there is nothing to do.
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

--- Approve what a tool proposed, so `publish` sends it.
---@param ctx review_notes.Context
---@param key string
function M.approve(ctx, key)
  review.edit_thread(ctx, key, function(t) merge.approve(t) end)
end

--- Approve every proposed comment of the review.
---@param ctx review_notes.Context
---@return integer approved
function M.approve_all(ctx)
  return review.edit(ctx, function(doc)
    local total = 0
    for _, t in ipairs(doc.threads) do total = total + merge.approve(t) end
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

--- Whether *entry* has anything `discard` would remove.
---@param entry review_notes.Entry
---@return boolean
local function can_discard(entry)
  local f = merge.flags(entry.thread, entry.state)
  return merge.has_unpublished(entry.thread) or (f.unsent and entry.thread.id ~= nil)
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
  local list = vim.tbl_filter(function(i) return merge.flags(i.entry.thread, i.entry.state).proposed end, items)
  if #list == 0 then return notify("nothing proposed here") end
  for _, i in ipairs(list) do M.approve(i.ctx, i.key) end
end

--- Discard the unpublished part of *items*. Only deleting a thread that was
--- never published asks first; the rest is local text. *done* runs after.
---@param items review_notes.Item[]
---@param done fun()?
function M.discard_items(items, done)
  if #items == 0 then return end
  local list = vim.tbl_filter(function(i) return can_discard(i.entry) end, items)
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

--- Save my comment of a thread (the one not published yet); an empty text
--- removes it, and a new thread with nothing left.
---@param ctx review_notes.Context
---@param target review_notes.Target
---@param text string
function M.save_comment(ctx, target, text)
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
    local mine
    for _, c in ipairs(thread.comments) do
      if c.source == "local" then mine = c end
    end
    if text == "" then
      if mine then
        thread.comments = vim.tbl_filter(function(c) return c ~= mine end, thread.comments)
      end
      if not thread.id and #thread.comments == 0 then
        doc.threads = vim.tbl_filter(function(t) return t ~= thread end, doc.threads)
      end
    elseif mine then
      mine.body = text
    else
      table.insert(thread.comments, { source = "local", body = text })
    end
    merge.sort(doc.threads)
  end)
end

local function open_composer(ctx, target, title, thread, win)
  local existing
  for _, c in ipairs(thread and thread.comments or {}) do
    if c.source == "local" then existing = c.body end
  end
  compose.open({
    title = title,
    text = existing,
    win = win,
    on_save = function(text) M.save_comment(ctx, target, text) end,
  })
end

--- Reply to a thread, or edit my reply not published yet.
---@param ctx review_notes.Context
---@param entry review_notes.Entry
---@param win integer? open the composer inside this window (the panel)
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
