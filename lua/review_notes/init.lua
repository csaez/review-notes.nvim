-- Code review notes kept outside the code, shown inline, synced on demand.
-- See DESIGN.md. The notes of a branch live in `.git/review/<branch>.md` (a
-- file outside git gets a sibling `<file>.review.md`).
--
--   review   which review a buffer is in, reading and changing it
--   actions  the verbs on threads, shared by every UI
--   sync     pull and publish
--   view     signs and virtual lines in code buffers
--   store, merge, backend, compose: the file, the rules, the remote, the editor
--
-- This module is the glue: drawing code buffers, finding the thread at the
-- cursor, commands, autocmds and the public API.
local store = require("review_notes.store")
local merge = require("review_notes.merge")
local view = require("review_notes.view")
local config = require("review_notes.config")
local review = require("review_notes.review")
local actions = require("review_notes.actions")
local sync = require("review_notes.sync")
local panel = require("review_notes.panel")

local M = {}

--- The options (see `review_notes.Config`); `setup` merges into them.
M.config = config.values

--- Icons and highlight groups per state.
M.style = review.style

local visible = true
local contexts = {} ---@type table<integer, review_notes.Context>
local last_ctx ---@type review_notes.Context?
local expanded = {} ---@type table<string, table<string, boolean>> by notes path, then thread key
local counts = {} ---@type table<string, table<string, integer>> by notes path

local notify = review.notify

-- Drawing ---------------------------------------------------------------

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
  view.render(buf, entries, review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root), visible, {
    expanded = expanded[ctx.path] or {},
    signs = config.values.signs,
    -- Unsaved edits: the file's lines are stale, keep where the threads are.
    buf_rows = vim.bo[buf].modified and view.live_rows(buf) or nil,
  })
  view.show_header(buf)
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
  local anchored = view.anchored(buf)
  local ctx = contexts[buf]
  if not ctx or #anchored == 0 then return end
  local rel = review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root)
  local live = {}
  for _, a in ipairs(anchored) do
    if not a.header then live[a.entry.key] = a end
  end
  if vim.tbl_isempty(live) then return end
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

-- Threads at the cursor ---------------------------------------------------

---@param buf integer
---@param header boolean? threads of the header (change and file) instead
---@return review_notes.Anchored[]
local function threads_here(buf, header)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if header then
    return vim.tbl_filter(function(a) return a.header end, view.anchored(buf))
  end
  local here = view.at(buf, row, false)
  if #here > 0 then return here end
  return view.at(buf, row, true)
end

local function describe_thread(entry)
  local t = entry.thread
  local last = t.comments[#t.comments]
  local text = last and vim.split(last.body, "\n", { plain = true })[1] or ""
  return ("%s  %s"):format(store.anchor_string(t.anchor), text)
end

---@param list review_notes.Anchored[]
---@param prompt string
---@param cb fun(a: review_notes.Anchored)
local function choose_thread(list, prompt, cb)
  if #list == 0 then return notify("no thread here") end
  if #list == 1 then return cb(list[1]) end
  vim.ui.select(list, {
    prompt = prompt,
    format_item = function(a) return describe_thread(a.entry) end,
  }, function(choice) if choice then cb(choice) end end)
end

--- Run *fn* on the thread at the cursor (a menu when there are several).
---@param prompt string
---@param fn fun(ctx: review_notes.Context, entry: review_notes.Entry)
local function with_target(prompt, fn)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = contexts[buf]
  if not ctx then return notify("no review in this buffer") end
  choose_thread(threads_here(buf), prompt, function(a) fn(ctx, a.entry) end)
end

local function current_review(buf)
  local ctx = contexts[buf] or review.context(buf)
  if not ctx then notify("not in a reviewable file") end
  return ctx
end

-- Writing -------------------------------------------------------------------

--- Visual range as 1-based lines, leaving visual mode.
local function visual_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then return nil end
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return math.min(a, b), math.max(a, b)
end

--- Reply to the thread at the cursor, or start one on the line (or the
--- selected lines). Writes into the notes only; `publish` sends it.
function M.add()
  local buf = vim.api.nvim_get_current_buf()
  local first, last = visual_range()
  local ctx = current_review(buf)
  if not ctx then return end
  if not first then
    local here = threads_here(buf)
    if #here > 0 then
      return choose_thread(here, "Reply to", function(a) actions.reply(ctx, a.entry) end)
    end
    first = vim.api.nvim_win_get_cursor(0)[1]
    last = first
  end
  actions.new_thread(ctx, {
    path = review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root),
    line = first,
    end_line = last > first and last or nil,
  })
end

--- Start a thread on the whole change, or on the current file.
---@param file boolean? the whole current file instead
function M.add_general(file)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = current_review(buf)
  if not ctx then return end
  actions.new_thread(ctx, file and { path = review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root) } or {})
end

--- Reply to a thread of the header (the change or the file).
function M.reply_general()
  local buf = vim.api.nvim_get_current_buf()
  local ctx = current_review(buf)
  if not ctx then return end
  choose_thread(threads_here(buf, true), "Reply to", function(a) actions.reply(ctx, a.entry) end)
end

-- Showing -------------------------------------------------------------------

local function set_expanded(ctx, key, value)
  expanded[ctx.path] = expanded[ctx.path] or {}
  expanded[ctx.path][key] = value or nil
end

--- Expand or collapse the thread at the cursor (or those of the header).
--- Expanding marks it as seen.
---@param header boolean? the change and file threads
function M.toggle_expand(header)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = contexts[buf]
  if not ctx then return end
  local list = threads_here(buf, header)
  if #list == 0 then return notify("no thread here") end
  local function toggle(a)
    local open = not (expanded[ctx.path] or {})[a.entry.key]
    set_expanded(ctx, a.entry.key, open)
    if open and merge.is_unread(a.entry.thread, a.entry.state) then
      actions.read(ctx, a.entry.key)
    else
      M.refresh()
    end
  end
  -- The header can hold many threads: open one at a time, it would fill the window.
  if header then return choose_thread(list, "Expand", toggle) end
  for _, a in ipairs(list) do toggle(a) end
end

--- Expand every thread, or collapse them all when all are expanded.
function M.toggle_expand_all()
  local buf = vim.api.nvim_get_current_buf()
  local ctx = contexts[buf]
  if not ctx then return end
  local doc, side = review.read(ctx)
  local entries = review.entries_of(doc, side)
  local all = true
  for _, e in ipairs(entries) do
    if not (expanded[ctx.path] or {})[e.key] then all = false end
  end
  expanded[ctx.path] = {}
  if all then return M.refresh() end
  for _, e in ipairs(entries) do expanded[ctx.path][e.key] = true end
  actions.read_all(ctx)
end

--- Toggle review mode: threads as text under the code, or just the signs.
function M.toggle()
  visible = not visible
  M.refresh()
  notify("review mode " .. (visible and "on" or "off"))
end

-- Acting on the thread at the cursor ----------------------------------------

--- Resolve or reopen the thread at the cursor. Resolving something someone
--- else resolved only accepts it. Sent by `publish`.
function M.toggle_resolved()
  with_target("Resolve", function(ctx, entry) actions.resolve(ctx, entry.key) end)
end

--- Mark the thread at the cursor as seen.
function M.mark_read()
  with_target("Mark read", function(ctx, entry) actions.read(ctx, entry.key) end)
end

--- Approve what a tool proposed on the thread at the cursor, so `publish`
--- sends it. With *all*, on every thread.
---@param all boolean?
function M.approve(all)
  if all then
    local ctx = current_review(vim.api.nvim_get_current_buf())
    if not ctx then return end
    return notify(("approved %d proposed comments"):format(actions.approve_all(ctx)))
  end
  with_target("Approve", function(ctx, entry) actions.approve(ctx, entry.key) end)
end

--- Delete the unpublished part of the thread at the cursor (mine and
--- proposed). Remote comments are never touched.
function M.discard()
  with_target("Discard", function(ctx, entry)
    if not actions.can_discard(entry) then return notify("nothing unpublished here") end
    actions.confirm_discard(entry, function() actions.discard(ctx, entry.key) end)
  end)
end

--- Delete every proposed comment (a tool's), threads it started included.
--- Mine and the remote's stay.
function M.discard_proposed()
  local ctx = current_review(vim.api.nvim_get_current_buf())
  if ctx then actions.discard_proposed(ctx) end
end

--- Open the notes file in a split, to edit by hand.
function M.open()
  local ctx = current_review(vim.api.nvim_get_current_buf())
  if not ctx then return end
  vim.cmd("split " .. vim.fn.fnameescape(ctx.path))
end

-- Moving ------------------------------------------------------------------

--- Next or previous thread in the buffer.
---@param dir integer 1 or -1
function M.jump(dir)
  local buf = vim.api.nvim_get_current_buf()
  local list = vim.tbl_filter(function(a) return not a.header end, view.anchored(buf))
  if #list == 0 then return notify("no threads in this buffer") end
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

--- Go to the code of *item*; for a change thread, the top of the current
--- buffer (where its header is), or the notes file outside a reviewed buffer.
---@param item review_notes.Item
function M.goto_item(item)
  if item.kind == "change" and review.is_reviewed(vim.api.nvim_get_current_buf()) then
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    view.show_header(vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win())
    return
  end
  vim.cmd("edit " .. vim.fn.fnameescape(item.file))
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(item.line, last), 0 })
end

--- Show *item* in the thread panel, and its code in the current window.
---@param item review_notes.Item
function M.open_item(item)
  panel.show(item.ctx, item.key)
end

--- Show the thread at the cursor in the thread panel (a menu when there are
--- several; on line 1 the change threads count too).
function M.thread()
  with_target("Show", function(ctx, entry) panel.show(ctx, entry.key, { follow = false }) end)
end

---@param item review_notes.Item
---@param action "resolve"|"read"|"approve"|"discard"
function M.item_action(item, action)
  actions[action](item.ctx, item.key)
end

--- Next or previous unread thread, across the files of the review.
---@param dir integer 1 or -1
function M.jump_unread(dir)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = current_review(buf)
  if not ctx then return end
  local unread = vim.tbl_filter(function(i) return i.state == "unread" end, review.items(ctx))
  if #unread == 0 then return notify("nothing unread") end
  table.sort(unread, function(a, b) return a.order < b.order end)
  local rel = review.note_path(vim.api.nvim_buf_get_name(buf), ctx.root)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local function ahead(item)
    local path = item.kind == "change" and "" or review.note_path(item.file, ctx.root)
    if path ~= rel then return path > rel end
    return item.kind ~= "change" and item.line > row
  end
  local target
  if dir > 0 then
    for _, item in ipairs(unread) do
      if ahead(item) then target = item break end
    end
    target = target or unread[1]
  else
    for i = #unread, 1, -1 do
      if not ahead(unread[i]) and not (unread[i].kind ~= "change" and unread[i].line == row and
        review.note_path(unread[i].file, ctx.root) == rel) then
        target = unread[i]
        break
      end
    end
    target = target or unread[#unread]
  end
  M.open_item(target)
end

--- The list of threads in the quickfix window.
function M.list()
  local items = M.items()
  if #items == 0 then return notify("no threads") end
  local qf = {}
  for _, item in ipairs(items) do
    table.insert(qf, {
      filename = item.file,
      lnum = item.line,
      text = ("%s [%s] %s %s"):format(item.icon, item.state, item.anchor, item.summary),
    })
  end
  vim.fn.setqflist({}, " ", { title = "Review threads", items = qf })
  vim.cmd("copen")
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
M.pull = sync.pull

--- Pull, show what would be sent, and send it after a confirm.
M.publish = sync.publish

-- Setup -------------------------------------------------------------------

local commands = {
  pull = M.pull,
  publish = M.publish,
  list = M.list,
  open = M.open,
  approve = function(args) M.approve(args == "all") end,
  discard = function(args) if args == "proposed" then M.discard_proposed() else M.discard() end end,
  toggle = M.toggle,
  thread = M.thread,
  expand = function() M.toggle_expand_all() end,
}

local listening = false

function M.setup(opts)
  M.config = config.set(opts)
  visible = M.config.visible
  view.set_highlights()
  if not listening then
    listening = true
    review.on_change(M.refresh)
  end
  local group = vim.api.nvim_create_augroup("ReviewNotes", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "FocusGained" }, {
    group = group,
    callback = function(ev) redraw_buffer(ev.buf) end,
  })
  -- Keyboard motions to line 1 (gg, k) hide the header above it: scroll it
  -- back in when the cursor arrives there, not on moves along line 1, so
  -- <C-e> can still hide it.
  local last_row = {} ---@type table<integer, integer> by window
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function(ev)
      local win = vim.api.nvim_get_current_win()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      if row == 1 and last_row[win] ~= 1 then view.show_header(ev.buf, win) end
      last_row[win] = row
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev) last_row[tonumber(ev.match)] = nil end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if review.is_reviewed(ev.buf) then sync_anchors(ev.buf) redraw_buffer(ev.buf) end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function() if visible then M.refresh() end end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = view.set_highlights })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev) contexts[ev.buf] = nil end,
  })
  vim.api.nvim_create_user_command("Review", function(a)
    local name, rest = a.args:match("^(%S*)%s*(.*)$")
    if name == "" then name = "toggle" end
    local fn = commands[name]
    if not fn then return notify("unknown subcommand: " .. name, vim.log.levels.ERROR) end
    fn(rest)
  end, {
    nargs = "*",
    complete = function(lead, line)
      if line:match("^%S+%s+approve%s") then return { "all" } end
      if line:match("^%S+%s+discard%s") then return { "proposed" } end
      return vim.tbl_filter(function(c) return c:find(lead, 1, true) == 1 end, vim.tbl_keys(commands))
    end,
  })
  M.refresh()
end

return M
