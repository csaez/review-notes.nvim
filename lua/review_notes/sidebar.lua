-- The sidebar: one window on the right of the tabpage, owned by the plugin.
-- It shows one of the mode buffers (the list of a review, or one thread),
-- registered by their modules. It never takes a code window's place: code
-- goes to the code window, the last normal window the cursor was in.
local M = {}

M.width = 72

local range_ns = vim.api.nvim_create_namespace("review_notes_range")

local wins = {} ---@type table<integer, integer> sidebar window by tabpage
local code_wins = {} ---@type table<integer, integer> code window by tabpage
local mode_bufs = {} ---@type table<integer, boolean>

--- Make *buf* a buffer the sidebar can show.
---@param buf integer
function M.register(buf)
  mode_bufs[buf] = true
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function() mode_bufs[buf] = nil end })
end

--- The sidebar window of the current tabpage.
---@return integer?
function M.win()
  local tab = vim.api.nvim_get_current_tabpage()
  local w = wins[tab]
  if w and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_tabpage(w) == tab
    and mode_bufs[vim.api.nvim_win_get_buf(w)] then
    return w
  end
  wins[tab] = nil
end

---@return boolean
function M.is_open() return M.win() ~= nil end

--- Whether *buf* is shown in the sidebar.
---@param buf integer
---@return boolean
function M.shows(buf)
  local w = M.win()
  return w ~= nil and vim.api.nvim_win_get_buf(w) == buf
end

local function is_code(win)
  if win == M.win() or vim.api.nvim_win_get_config(win).relative ~= "" then return false end
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

-- Code window -------------------------------------------------------------------

--- The window for the code: the last normal window the cursor was in, else
--- any. With none and a *file*, a split left of the sidebar opens on it.
---@param file string?
---@return integer?
function M.code_win(file)
  local tab = vim.api.nvim_get_current_tabpage()
  local w = code_wins[tab]
  if w and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_tabpage(w) == tab and is_code(w) then
    return w
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if is_code(win) then
      code_wins[tab] = win
      return win
    end
  end
  local side = M.win()
  if not (file and side) then return nil end
  local buf = vim.fn.bufadd(file)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  w = vim.api.nvim_open_win(buf, false, { split = "left", win = side })
  vim.api.nvim_win_set_width(side, M.width)
  code_wins[tab] = w
  return w
end

--- Use *win* for the code from now on.
---@param win integer
function M.set_code_win(win)
  if vim.api.nvim_win_is_valid(win) and is_code(win) then code_wins[vim.api.nvim_win_get_tabpage(win)] = win end
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
function M.show_code(item, focus)
  local notify = require("review_notes.review").notify
  if not item.has_code then
    if focus then notify("this thread has no code") end
    return
  end
  local win = M.code_win(item.file)
  if not win then
    if focus then notify("no window for the code") end
    return
  end
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

--- Edit *file* in the code window and go there.
---@param file string
function M.edit(file)
  local win = M.code_win(file)
  if not win then return end
  vim.api.nvim_set_current_win(win)
  if vim.api.nvim_buf_get_name(0) ~= file then vim.cmd("edit " .. vim.fn.fnameescape(file)) end
end

-- Window --------------------------------------------------------------------------

-- Local to the mode buffer in the sidebar window ([0]), so nothing leaks
-- into windows split from it or into other buffers.
local BASE = {
  winfixwidth = true,
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  statuscolumn = "",
  colorcolumn = "",
  spell = false,
  list = false,
}

---@class review_notes.ShowOpts
---@field focus boolean? move the cursor into the sidebar
---@field wo table<string, any>? window options for this mode

--- Show the mode buffer *buf* in the sidebar, opening it when needed.
---@param buf integer
---@param opts review_notes.ShowOpts?
---@return integer win
function M.show(buf, opts)
  opts = opts or {}
  local tab = vim.api.nvim_get_current_tabpage()
  local cur = vim.api.nvim_get_current_win()
  if is_code(cur) then code_wins[tab] = cur end
  local win = M.win()
  if not win then
    win = vim.api.nvim_open_win(buf, false, { split = "right", win = -1, width = M.width })
    wins[tab] = win
  elseif vim.api.nvim_win_get_buf(win) ~= buf then
    vim.wo[win][0].winfixbuf = false
    vim.api.nvim_win_set_buf(win, buf)
  end
  local wo = vim.wo[win][0]
  for k, v in pairs(vim.tbl_extend("force", BASE, opts.wo or {})) do wo[k] = v end
  wo.winfixbuf = true
  if opts.focus then vim.api.nvim_set_current_win(win) end
  return win
end

--- Close the sidebar. As the last window it shows an empty buffer instead.
function M.close()
  local win = M.win()
  clear_range()
  if not win then return end
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(win, true)
  else
    vim.wo[win][0].winfixbuf = false
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
  end
end

vim.api.nvim_create_autocmd("WinEnter", {
  group = vim.api.nvim_create_augroup("ReviewNotesSidebar", { clear = true }),
  callback = function()
    local win = vim.api.nvim_get_current_win()
    if is_code(win) then code_wins[vim.api.nvim_get_current_tabpage()] = win end
  end,
})

return M
