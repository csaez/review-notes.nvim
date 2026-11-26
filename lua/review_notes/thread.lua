-- Thread mode of the sidebar: one thread at a time. Showing a thread marks
-- it seen and shows its code in the code window; the thread keys (reply,
-- resolve, approve, discard, next / previous) act on the thread shown. It
-- redraws on every change of the notes, so a pull or pi writing shows up.
local review = require("review_notes.review")
local actions = require("review_notes.actions")
local sidebar = require("review_notes.sidebar")
local keys = require("review_notes.keys")

local M = {}

local ns = vim.api.nvim_create_namespace("review_notes_thread")

---@class review_notes.ThreadMode
---@field buf integer?
---@field ctx review_notes.Context?
---@field key string?
---@field order string[] keys in the order of `]t`, kept while moving so a
---  thread read on the way does not jump to another section
local state = { order = {} }

local KEYS ---@type review_notes.Key[] set below, they need the functions

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

--- The thread as thread mode shows it: a heading, the status line (line 2,
--- highlighted with `item.hl`), the conversation. A picker's preview too.
---@param item review_notes.Item
---@return string[]
function M.lines(item)
  local t = item.entry.thread
  local n = #t.comments
  local bits = { item.state }
  vim.list_extend(bits, item.tags)
  local by = item.entry.state and item.entry.state.resolved_by
  if by and t.status == "resolved" then table.insert(bits, "by @" .. by) end
  table.insert(bits, n == 1 and "1 comment" or (n .. " comments"))
  if t.moved then table.insert(bits, "its lines were deleted") end
  local lines = {
    "# " .. (item.kind == "change" and "change (the whole merge request)" or item.anchor),
    item.icon .. " " .. table.concat(bits, ", "),
    "",
  }
  vim.list_extend(lines, item.thread)
  while #lines > 0 and lines[#lines] == "" do table.remove(lines) end
  return lines
end

local function render()
  if not (state.buf and sidebar.shows(state.buf)) then return end
  local win = sidebar.win() --[[@as integer]]
  local items = state.ctx and review.items(state.ctx) or {}
  local item = current()
  local lines = item and M.lines(item) or { "This thread is gone: deleted, or published under a new id." }
  local status_hl = item and item.hl
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
  local place = at > 0 and ("%d of %d"):format(at, #order) or ("%d threads"):format(#order)
  if unread > 0 then place = ("%d unread  "):format(unread) .. place end
  vim.wo[win][0].statusline = keys.hints(KEYS, keys.bar_width(win), place)
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

-- Required late: list mode requires this module.
local function back_to_list()
  if state.ctx then require("review_notes.list").open(state.ctx, { key = state.key }) end
end

local function when(label, test) return keys.when(current, label, test) end

KEYS = {
  { lhs = "r", group = "Thread", desc = "reply, or edit my reply not published yet", hint = when("reply"),
    fn = function() with_item(function(i) actions.reply(i.ctx, i.entry, sidebar.win()) end) end },
  { lhs = "x", group = "Thread", desc = "resolve / reopen (accepts a resolve by someone else)", hint = when(actions.resolve_verb),
    fn = function() with_item(function(i) actions.resolve(i.ctx, i.key) end) end },
  { lhs = "a", group = "Thread", desc = "approve the proposed comment", hint = when("approve", actions.can_approve),
    fn = function() with_item(function(i) actions.approve_items({ i }) end) end },
  { lhs = "d", group = "Thread", desc = "discard my unpublished text (a new thread goes entirely)", hint = when("discard", actions.can_discard),
    fn = function() with_item(function(i) actions.discard_items({ i }) end) end },
  { lhs = "t", group = "Thread", desc = "make private (never published) / public",
    hint = when(function(i) return "make " .. actions.private_verb(i) end, actions.can_toggle_private),
    fn = function() with_item(function(i) actions.toggle_private(i.ctx, i.key) end) end },
  { lhs = "o", group = "Thread", desc = "go to the code", hint = when("code", function(i) return i.has_code end),
    fn = function() with_item(function(i) sidebar.show_code(i, true) end) end },
  { lhs = "]t", group = "Move", desc = "next thread", hint = "next", fn = function() step(1) end },
  { lhs = "[t", group = "Move", desc = "previous thread", fn = function() step(-1) end },
  { lhs = "]u", group = "Move", desc = "next unread", fn = function() step(1, true) end },
  { lhs = "[u", group = "Move", desc = "previous unread", fn = function() step(-1, true) end },
  -- The list is home: q steps back to it, and q there closes the sidebar.
  { lhs = "q", group = "Move", desc = "back to the list, on this thread", hint = "list", fn = back_to_list },
}

---@return integer
local function ensure_buf()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then return state.buf end
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "reviewnotes://thread")
  -- Its own filetype, so statusline plugins can leave its hint bar alone;
  -- markdown highlighting through treesitter, else the syntax file.
  vim.bo[buf].filetype = "reviewthread"
  if not pcall(vim.treesitter.start, buf, "markdown") then vim.bo[buf].syntax = "markdown" end
  vim.bo[buf].modifiable = false
  sidebar.register(buf)
  keys.bind(buf, "Thread", KEYS)
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
  require("review_notes.list").follow(ctx, key)
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
