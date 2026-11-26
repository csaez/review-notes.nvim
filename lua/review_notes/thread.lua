-- Thread mode of the sidebar: one thread at a time. Showing a thread marks
-- it seen and shows its code in the code window; the thread keys (reply,
-- resolve, approve, discard, next / previous) act on the thread shown. It
-- redraws on every change of the notes, so a pull or pi writing shows up.
local review = require("review_notes.review")
local actions = require("review_notes.actions")
local sidebar = require("review_notes.sidebar")

local M = {}

local ns = vim.api.nvim_create_namespace("review_notes_thread")

---@class review_notes.ThreadMode
---@field buf integer?
---@field ctx review_notes.Context?
---@field key string?
---@field order string[] keys in the order of `]t`, kept while moving so a
---  thread read on the way does not jump to another section
local state = { order = {} }

local HELP = {
  "r   reply, or edit my reply not published yet",
  "x   resolve / reopen (accepts a resolve by someone else)",
  "a   approve the proposed comment",
  "d   discard my unpublished text (a new thread goes entirely)",
  "]t  next thread, [t previous",
  "]u  next unread, [u previous",
  "o   go to the code",
  "-   back to the list",
  "q   close the sidebar",
}

local function notify(msg, level) review.notify(msg, level) end

--- The thread shown, read now.
---@return review_notes.Item?
local function current()
  if not (state.ctx and state.key) then return nil end
  for _, item in ipairs(review.items(state.ctx)) do
    if item.key == state.key then return item end
  end
end

--- The `]t` order, refreshed when threads came or went.
---@param items review_notes.Item[]
---@return string[]
local function order_of(items)
  local by_key = {}
  for _, item in ipairs(items) do by_key[item.key] = true end
  local order = vim.tbl_filter(function(k) return by_key[k] ~= nil end, state.order)
  if #order ~= #items then order = vim.tbl_map(function(item) return item.key end, items) end
  state.order = order
  return order
end

-- Drawing ---------------------------------------------------------------------

local function render()
  if not (state.buf and sidebar.shows(state.buf)) then return end
  local win = sidebar.win() --[[@as integer]]
  local items = state.ctx and review.items(state.ctx) or {}
  local item = current()
  local lines, status_hl = {}, nil
  if not item then
    lines = { "This thread is gone: deleted, or published under a new id." }
  else
    local entry = item.entry
    local t = entry.thread
    local n = #t.comments
    local bits = { item.state }
    vim.list_extend(bits, item.tags)
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
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if status_hl then vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { line_hl_group = status_hl }) end

  local order, at, unread = order_of(items), 0, 0
  for i, k in ipairs(order) do
    if k == state.key then at = i end
  end
  for _, i in ipairs(items) do
    if i.state == "unread" then unread = unread + 1 end
  end
  local place = at > 0 and ("%d/%d"):format(at, #order) or ("-/%d"):format(#order)
  if unread > 0 then place = place .. ("  %d unread"):format(unread) end
  vim.wo[win][0].winbar = " " .. place .. "   r reply  x resolve  a approve  d discard  - list  g? help"
end

-- Acting ------------------------------------------------------------------------

local function with_item(fn)
  local item = current()
  if not item then return notify("no thread shown") end
  fn(item)
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
  local order = order_of(items)
  if #order == 0 then return notify("no threads") end
  local at = 0
  for i, k in ipairs(order) do
    if k == state.key then at = i end
  end
  if at == 0 then at = dir > 0 and 0 or #order + 1 end
  for n = 1, #order do
    local k = order[((at - 1 + dir * n) % #order) + 1] --[[@as string]]
    if not unread or by_key[k].state == "unread" then
      return M.show(ctx, k)
    end
  end
  notify("nothing unread")
end

local function back_to_list()
  local ok, list = pcall(require, "review_notes.list")
  if ok and state.ctx then list.open(state.ctx, { key = state.key }) end
end

local function map(lhs, fn, desc)
  vim.keymap.set("n", lhs, fn, { buffer = state.buf, nowait = true, desc = desc })
end

local function set_keys()
  map("r", function() with_item(function(i) actions.reply(i.ctx, i.entry, sidebar.win()) end) end, "reply")
  map("x", function() with_item(function(i) actions.resolve(i.ctx, i.key) end) end, "resolve / reopen")
  map("a", function() with_item(function(i) actions.approve_items({ i }) end) end, "approve proposed")
  map("d", function() with_item(function(i) actions.discard_items({ i }) end) end, "discard unpublished")
  map("]t", function() step(1) end, "next thread")
  map("[t", function() step(-1) end, "previous thread")
  map("]u", function() step(1, true) end, "next unread")
  map("[u", function() step(-1, true) end, "previous unread")
  map("o", function() with_item(function(i) sidebar.show_code(i, true) end) end, "go to the code")
  map("-", back_to_list, "back to the list")
  map("<BS>", back_to_list, "back to the list")
  map("q", sidebar.close, "close the sidebar")
  map("g?", function() notify(table.concat(HELP, "\n")) end, "help")
end

---@return integer
local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "reviewnotes://thread")
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  sidebar.register(buf)
  set_keys()
  return buf
end

---@class review_notes.ThreadOpts
---@field follow boolean? show the code (default true)
---@field focus "code"|"sidebar"|nil move the cursor there (default: stay)
---@field reorder boolean? take the `]t` order from the review again

--- Show the thread *key* of *ctx* in the sidebar, opening it when needed.
---@param ctx review_notes.Context
---@param key string
---@param opts review_notes.ThreadOpts?
function M.show(ctx, key, opts)
  opts = opts or {}
  if state.ctx ~= ctx or opts.reorder then state.order = {} end
  state.ctx, state.key = ctx, key
  local buf = ensure_buf()
  sidebar.show(buf, {
    focus = opts.focus == "sidebar",
    wo = { wrap = true, linebreak = true, cursorline = false },
  })
  render()
  local item = current()
  if not item then return end
  if opts.follow ~= false then sidebar.show_code(item, opts.focus == "code") end
  if item.state == "unread" then actions.read(ctx, key) end
  local ok, list = pcall(require, "review_notes.list")
  if ok then list.follow(ctx, key) end
end

--- Go to the code of *item* and show the thread in the sidebar. A thread
--- with no code (the change, a directory) only shows in the sidebar.
---@param item review_notes.Item
function M.go_to(item)
  M.show(item.ctx, item.key, { reorder = true, focus = item.has_code and "code" or nil })
end

--- The thread shown last: its review and key.
---@return review_notes.Context?, string?
function M.shown() return state.ctx, state.key end

--- Whether thread mode is in the sidebar.
---@return boolean
function M.is_shown() return state.buf ~= nil and sidebar.shows(state.buf) end

review.on_change(render)

return M
