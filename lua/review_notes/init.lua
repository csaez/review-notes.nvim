-- Code review notes kept outside the code, synced on demand. See DESIGN.md.
-- The notes of a branch live in `.git/review/<branch>.md` (a file outside
-- git gets a sibling `<file>.review.md`).
--
--   review   which review a buffer is in, reading and changing it
--   actions  the verbs on threads, shared by every UI
--   home     the review's buffer (:Review); panel: one thread
--   signs    anchors and signs in code buffers
--   sync     pull and publish
--   store, merge, backend, compose: the file, the rules, the remote, the editor
--
-- This module is the glue: code buffers, commands, autocmds and the API.
local store = require("review_notes.store")
local merge = require("review_notes.merge")
local signs = require("review_notes.signs")
local config = require("review_notes.config")
local review = require("review_notes.review")
local actions = require("review_notes.actions")
local sync = require("review_notes.sync")
local panel = require("review_notes.panel")
local home = require("review_notes.home")

local M = {}

--- The options (see `review_notes.Config`); `setup` merges into them.
M.config = config.values

--- Icons and highlight groups per state.
M.style = review.style

local contexts = {} ---@type table<integer, review_notes.Context>
local last_ctx ---@type review_notes.Context?
local counts = {} ---@type table<string, table<string, integer>> by notes path

local notify = review.notify

-- Code buffers --------------------------------------------------------------

local function tally(entries)
  local n = { unread = 0, proposed = 0, unsent = 0, open = 0 }
  for _, e in ipairs(entries) do
    local f = merge.flags(e.thread, e.state)
    if f.unread then n.unread = n.unread + 1 end
    if f.proposed then n.proposed = n.proposed + 1 end
    if f.unsent then n.unsent = n.unsent + 1 end
    if not f.resolved then n.open = n.open + 1 end
  end
  return n
end

---@param buf integer
---@param memo table?
local function redraw_buffer(buf, memo)
  if not review.is_reviewed(buf) then return end
  local ctx = review.context(buf, memo)
  if not ctx then return end
  contexts[buf], last_ctx = ctx, ctx
  local doc, side = review.read(ctx)
  local entries = review.entries_of(doc, side)
  counts[ctx.path] = tally(entries)
  signs.render(buf, entries, review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root), {
    signs = config.values.signs,
    -- Unsaved edits: the file's lines are stale, keep where the threads are.
    buf_rows = vim.bo[buf].modified and signs.live_rows(buf) or nil,
  })
  review.watch(ctx.path)
end

--- Redraw every shown file.
function M.refresh()
  local memo = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    redraw_buffer(buf, memo)
  end
end

-- Anchors follow edits through extmarks; saving the file writes the new
-- lines back to the notes.
local function sync_anchors(buf)
  local anchored = signs.anchored(buf)
  local ctx = contexts[buf]
  if not ctx or #anchored == 0 then return end
  local rel = review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root)
  local live = {}
  for _, a in ipairs(anchored) do live[a.entry.key] = a end
  pcall(store.update, ctx.path, function(doc)
    local keys = review.keys_of(doc)
    for i, t in ipairs(doc.threads) do
      local a = live[keys[i]]
      if a and t.anchor.path == rel and t.anchor.line then
        t.anchor.line = a.row + 1
        t.anchor.end_line = a.end_row > a.row and (a.end_row + 1) or nil
        t.moved = a.moved or nil
      end
    end
  end)
end

local function current_review(buf)
  local ctx = contexts[buf] or review.context(buf)
  if not ctx then notify("not in a reviewable file") end
  return ctx
end

-- In code buffers ------------------------------------------------------------

--- Show the thread at the cursor in the thread panel (a menu when there are
--- several).
function M.thread()
  local buf = vim.api.nvim_get_current_buf()
  local ctx = contexts[buf]
  if not ctx then return notify("no review in this buffer") end
  local here = signs.at(buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if #here == 0 then return notify("no thread here") end
  local function show(a) panel.show(ctx, a.entry.key, { follow = false }) end
  if #here == 1 then return show(here[1]) end
  vim.ui.select(here, {
    prompt = "Show",
    format_item = function(a)
      local last = a.entry.thread.comments[#a.entry.thread.comments]
      return store.anchor_string(a.entry.thread.anchor) .. "  " .. (last and vim.split(last.body, "\n")[1] or "")
    end,
  }, function(a) if a then show(a) end end)
end

--- Visual range as 1-based lines, leaving visual mode.
local function visual_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then return nil end
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return math.min(a, b), math.max(a, b)
end

--- Start a thread on the line, or the selected lines, even where one is
--- already (replies are `r` in the panel). Writes into the notes only;
--- `publish` sends it.
function M.new()
  local buf = vim.api.nvim_get_current_buf()
  local first, last = visual_range()
  local ctx = current_review(buf)
  if not ctx then return end
  if not review.is_reviewed(buf) then return notify("not a file under review") end
  first = first or vim.api.nvim_win_get_cursor(0)[1]
  last = last or first
  actions.new_thread(ctx, {
    path = review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root),
    line = first,
    end_line = last > first and last or nil,
  })
end

--- Start a thread on the whole change.
function M.new_change()
  local ctx = current_review(vim.api.nvim_get_current_buf())
  if ctx then actions.new_thread(ctx, {}) end
end

--- Next or previous thread: the unread ones across the review while there
--- are any, else the threads of this buffer. The panel follows when open.
---@param dir integer 1 or -1
function M.next(dir)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = current_review(buf)
  if not ctx then return end
  local unread = vim.tbl_filter(function(i) return i.state == "unread" end, review.items(ctx))
  if #unread > 0 then
    table.sort(unread, function(a, b) return a.order < b.order end)
    local rel = review.is_reviewed(buf) and review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root) or ""
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local function pos(i) return i.kind == "change" and "" or review.note_path(i.file, ctx.root), i.kind == "line" and i.line or 0 end
    local function after(i)
      local p, l = pos(i)
      if p ~= rel then return p > rel end
      return l > row
    end
    local function before(i)
      local p, l = pos(i)
      if p ~= rel then return p < rel end
      return l < row
    end
    local target
    if dir > 0 then
      for _, i in ipairs(unread) do
        if after(i) then target = i break end
      end
      target = target or unread[1]
    else
      for k = #unread, 1, -1 do
        if before(unread[k]) then target = unread[k] break end
      end
      target = target or unread[#unread]
    end
    return panel.show(ctx, target.key, { focus = true })
  end
  local list = signs.anchored(buf)
  if #list == 0 then return notify("nothing unread, no threads in this buffer") end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  if dir > 0 then
    for _, a in ipairs(list) do
      if a.row > row then target = a break end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      if list[i].row < row then target = list[i] break end
    end
    target = target or list[#list]
  end
  vim.api.nvim_win_set_cursor(0, { target.row + 1, 0 })
  if panel.is_open() then panel.show(ctx, target.entry.key, { follow = false }) end
end

--- The home of the current review: every thread, the review-wide actions.
function M.home() home.open() end

--- Open the notes file, to edit by hand.
function M.edit()
  local ctx = current_review(vim.api.nvim_get_current_buf())
  if ctx then vim.cmd("edit " .. vim.fn.fnameescape(ctx.path)) end
end

-- Items (for pickers) -----------------------------------------------------

--- Every thread of the review of *buf*, urgent first: unread, proposed, not
--- published, open, resolved; each by position. One kind of row for all, the
--- change threads included.
---@param buf integer?
---@return review_notes.Item[]
function M.items(buf)
  local ctx = review.context(buf)
  return ctx and review.items(ctx) or {}
end

--- Show *item* in the thread panel, and its code in the current window.
---@param item review_notes.Item
function M.open_item(item)
  panel.show(item.ctx, item.key)
end

--- Go to the code of *item* in the current window; a thread with no code
--- (the change, a directory) opens in the panel instead.
---@param item review_notes.Item
function M.goto_item(item)
  if item.kind == "change" or item.file == item.ctx.path then return M.open_item(item) end
  vim.cmd("edit " .. vim.fn.fnameescape(item.file))
  vim.api.nvim_win_set_cursor(0, { math.min(item.line, vim.api.nvim_buf_line_count(0)), 0 })
end

---@param item review_notes.Item
---@param action "resolve"|"read"|"approve"|"discard"
function M.item_action(item, action)
  actions[action](item.ctx, item.key)
end

--- A statusline component: what waits for me in the current review.
---@return string
function M.status()
  local ctx = contexts[vim.api.nvim_get_current_buf()] or last_ctx
  local n = ctx and counts[ctx.path]
  if not n then return "" end
  local parts = {}
  for _, k in ipairs({ "unread", "proposed", "unsent" }) do
    if n[k] > 0 then table.insert(parts, review.style[k].icon .. " " .. n[k]) end
  end
  return table.concat(parts, " ")
end

-- Sync --------------------------------------------------------------------

--- Bring the remote threads in. Never sends anything.
function M.pull() sync.pull() end

--- Pull, show what would be sent, and send it after a confirm.
function M.publish() sync.publish() end

-- Setup -------------------------------------------------------------------

local commands = {
  home = M.home,
  pull = M.pull,
  publish = M.publish,
  edit = M.edit,
  thread = M.thread,
}

local listening = false

function M.setup(opts)
  M.config = config.set(opts)
  signs.set_highlights()
  if not listening then
    listening = true
    review.on_change(M.refresh)
  end
  local group = vim.api.nvim_create_augroup("ReviewNotes", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "FocusGained" }, {
    group = group,
    callback = function(ev) redraw_buffer(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if review.is_reviewed(ev.buf) then sync_anchors(ev.buf) redraw_buffer(ev.buf) end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = signs.set_highlights })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev) contexts[ev.buf] = nil end,
  })
  vim.api.nvim_create_user_command("Review", function(a)
    local name = a.args:match("^(%S*)")
    if name == "" then name = "home" end
    local fn = commands[name]
    if not fn then return notify("unknown subcommand: " .. name, vim.log.levels.ERROR) end
    fn()
  end, {
    nargs = "?",
    complete = function(lead)
      return vim.tbl_filter(function(c) return c:find(lead, 1, true) == 1 end, vim.tbl_keys(commands))
    end,
  })
  M.refresh()
end

return M
