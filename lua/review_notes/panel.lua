-- The thread panel: one thread at a time in a split on the right, reused
-- across threads. Showing a thread marks it seen and shows its code in the
-- code window next to it; the thread keys (reply, resolve, approve, discard,
-- next / previous) act on the thread shown. It redraws on every change of
-- the notes, so a pull or pi writing shows up while it is open.
local merge = require("review_notes.merge")
local review = require("review_notes.review")
local actions = require("review_notes.actions")

local M = {}

M.width = 72

local range_ns = vim.api.nvim_create_namespace("review_notes_range")
local panel_ns = vim.api.nvim_create_namespace("review_notes_panel")

---@class review_notes.PanelState
---@field buf integer?
---@field ctx review_notes.Context?
---@field key string?
---@field order string[] keys in the order of `]t`, kept while moving so a
---  thread read on the way does not jump to another section
---@field code_win integer?
local state = { order = {} }

local HELP = {
  "r   reply, or edit my reply not published yet",
  "x   resolve / reopen (accepts a resolve by someone else)",
  "a   approve the proposed comment",
  "d   discard my unpublished text (a new thread goes entirely)",
  "]t  next thread, [t previous",
  "]u  next unread, [u previous",
  "o   go to the code",
  "q   close",
}

local function notify(msg, level) review.notify(msg, level) end

--- The panel window in the current tabpage.
---@return integer?
local function panel_win()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then return nil end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(w) == state.buf then return w end
  end
end

--- The item and the entry of the thread shown, read now.
---@return review_notes.Item?, review_notes.Entry?
local function current()
  if not (state.ctx and state.key) then return nil end
  for _, item in ipairs(review.items(state.ctx)) do
    if item.key == state.key then return item, review.entry(state.ctx, state.key) end
  end
end

-- Code window -----------------------------------------------------------------

--- A window of the current tabpage for the code: the one the panel was
--- opened from, else any window on a file.
---@return integer?
local function code_win()
  local tab = vim.api.nvim_get_current_tabpage()
  local w = state.code_win
  if w and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_tabpage(w) == tab and w ~= panel_win() then
    return w
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if win ~= panel_win() and cfg.relative == "" and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == "" then
      state.code_win = win
      return win
    end
  end
end

local function clear_range()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then vim.api.nvim_buf_clear_namespace(b, range_ns, 0, -1) end
  end
end

--- Highlight rows *first*..*last* (1-based) of *buf* until the cursor leaves them.
local function highlight_range(buf, first, last)
  clear_range()
  for row = first, last do
    vim.api.nvim_buf_set_extmark(buf, range_ns, row - 1, 0, { line_hl_group = "ReviewRange", priority = 5 })
  end
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(0)[1]
      if row >= first and row <= last then return end
      vim.api.nvim_buf_clear_namespace(buf, range_ns, 0, -1)
      return true
    end,
  })
end

--- Show the code of *item* in the code window. Threads with no code (the
--- whole change, a directory) leave it alone.
---@param item review_notes.Item
---@param focus boolean move the cursor there
local function show_code(item, focus)
  if item.kind == "change" or item.file == item.ctx.path then
    if focus then notify("this thread has no code") end
    return
  end
  local win = code_win()
  if not win then return notify("no window for the code") end
  vim.api.nvim_win_call(win, function()
    if vim.api.nvim_buf_get_name(0) ~= item.file then vim.cmd("edit " .. vim.fn.fnameescape(item.file)) end
    local last = vim.api.nvim_buf_line_count(0)
    local first = math.min(item.line, last)
    vim.api.nvim_win_set_cursor(0, { first, 0 })
    vim.cmd("normal! zz")
    if item.kind == "line" then highlight_range(0, first, math.min(item.end_line, last)) end
  end)
  if focus then vim.api.nvim_set_current_win(win) end
end

-- Drawing ---------------------------------------------------------------------

local function render()
  local win = panel_win()
  if not win then return end
  local item, entry = current()
  local lines, status_hl = {}, nil
  if not (item and entry) then
    lines = { "This thread is gone: deleted, or published under a new id." }
  else
    local t = entry.thread
    local n = #t.comments
    local bits = { item.state }
    vim.list_extend(bits, item.tags)
    if t.status == "resolved" and item.state ~= "resolved" and not vim.tbl_contains(item.tags, "resolved") then
      table.insert(bits, "resolved")
    end
    local by = entry.state and entry.state.resolved_by
    if by and t.status == "resolved" then table.insert(bits, "by @" .. by) end
    table.insert(bits, n == 1 and "1 comment" or (n .. " comments"))
    if t.moved then table.insert(bits, "its lines were deleted") end
    lines = { "# " .. (item.kind == "change" and "change (the whole merge request)" or item.anchor), item.icon .. " " .. table.concat(bits, ", "), "" }
    status_hl = item.hl
    vim.list_extend(lines, item.thread)
    while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  end
  local buf = state.buf --[[@as integer]]
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, panel_ns, 0, -1)
  if status_hl then vim.api.nvim_buf_set_extmark(buf, panel_ns, 1, 0, { line_hl_group = status_hl }) end
  vim.wo[win].winbar = " r reply  x resolve  a approve  d discard  ]t next  o code  g? help"
end

-- Acting ------------------------------------------------------------------------

local function with_entry(fn)
  local item, entry = current()
  if not (item and entry and state.ctx) then return notify("no thread in the panel") end
  fn(state.ctx, entry, item)
end

--- Move to the next or previous thread, or unread thread.
---@param dir integer 1 or -1
---@param unread boolean?
local function step(dir, unread)
  local ctx = state.ctx
  if not ctx then return end
  local items = review.items(ctx)
  local by_key = {}
  for _, item in ipairs(items) do by_key[item.key] = item end
  local order = vim.tbl_filter(function(k) return by_key[k] ~= nil end, state.order)
  if #order ~= #items then
    order = vim.tbl_map(function(item) return item.key end, items)
  end
  state.order = order
  if #order == 0 then return notify("no threads") end
  local at = 0
  for i, k in ipairs(order) do
    if k == state.key then at = i end
  end
  if at == 0 then at = dir > 0 and 0 or #order + 1 end
  for n = 1, #order do
    local k = order[((at - 1 + dir * n) % #order) + 1]
    if not unread or by_key[k].state == "unread" then
      return M.show(ctx, k)
    end
  end
  notify("nothing unread")
end

local function map(lhs, fn, desc)
  vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, desc = desc })
end

local function set_keys()
  map("r", function()
    with_entry(function(ctx, entry) actions.reply(ctx, entry, panel_win()) end)
  end, "reply")
  map("x", function() with_entry(function(ctx, entry) actions.resolve(ctx, entry.key) end) end, "resolve / reopen")
  map("a", function()
    with_entry(function(ctx, entry)
      if not merge.has_unpublished(entry.thread) then return notify("nothing proposed here") end
      actions.approve(ctx, entry.key)
    end)
  end, "approve proposed")
  map("d", function()
    with_entry(function(ctx, entry)
      if not actions.can_discard(entry) then return notify("nothing unpublished here") end
      -- Only a whole new thread is worth a question; the rest is local text.
      if entry.thread.id then return actions.discard(ctx, entry.key) end
      actions.confirm_discard(entry, function() actions.discard(ctx, entry.key) end)
    end)
  end, "discard unpublished")
  map("]t", function() step(1) end, "next thread")
  map("[t", function() step(-1) end, "previous thread")
  map("]u", function() step(1, true) end, "next unread")
  map("[u", function() step(-1, true) end, "previous unread")
  map("o", function() with_entry(function(_, _, item) show_code(item, true) end) end, "go to the code")
  map("q", M.close, "close")
  map("g?", function() notify(table.concat(HELP, "\n")) end, "help")
end

-- Window ------------------------------------------------------------------------

local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return end
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "reviewnotes://thread")
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  set_keys()
end

---@return integer win
local function ensure_win()
  local win = panel_win()
  if win then return win end
  local back = vim.api.nvim_get_current_win()
  vim.cmd(("botright vertical %dsplit"):format(M.width))
  win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  local wo = vim.wo[win]
  wo.winfixwidth = true
  wo.wrap = true
  wo.linebreak = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.cursorline = false
  wo.spell = false
  if vim.api.nvim_win_is_valid(back) then vim.api.nvim_set_current_win(back) end
  return win
end

---@class review_notes.PanelOpts
---@field code_win integer? the window for the code (default: the current one, unless it is the panel)
---@field follow boolean? show the code (default true)
---@field reorder boolean? take the `]t` order from the review again

--- Show the thread *key* of *ctx* in the panel, opening it when needed.
---@param ctx review_notes.Context
---@param key string
---@param opts review_notes.PanelOpts?
function M.show(ctx, key, opts)
  opts = opts or {}
  local cur = vim.api.nvim_get_current_win()
  if opts.code_win then
    state.code_win = opts.code_win
  elseif cur ~= panel_win() and vim.api.nvim_win_get_config(cur).relative == "" then
    state.code_win = cur
  end
  if state.ctx ~= ctx or opts.reorder then state.order = {} end
  state.ctx, state.key = ctx, key
  ensure_buf()
  ensure_win()
  render()
  local item, entry = current()
  if not (item and entry) then return end
  if opts.follow ~= false then show_code(item, false) end
  if merge.is_unread(entry.thread, entry.state) then actions.read(ctx, key) end
end

function M.close()
  local win = panel_win()
  clear_range()
  if win and #vim.api.nvim_tabpage_list_wins(0) > 1 then vim.api.nvim_win_close(win, true) end
end

---@return boolean
function M.is_open() return panel_win() ~= nil end

--- The thread shown: its review and key.
---@return review_notes.Context?, string?
function M.shown() return state.ctx, state.key end

review.on_change(render)

return M
