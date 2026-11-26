-- Keys of the sidebar modes, declared once: each mode binds them, draws its
-- hint bar from them (only those that apply to the thread at hand, like
-- lazygit's options bar) and lists them in the `?` menu, where pressing a
-- key or <CR> on a row runs it.
local M = {}

---@class review_notes.Key
---@field lhs string
---@field desc string
---@field group string heading in the menu
---@field fn fun()
---@field hint (string|fun(): string?)? the label in the hint bar; a function
---  decides from the current thread (nil hides it); unset: menu only
---@field modes string[]? default { "n" }

local ns = vim.api.nvim_create_namespace("review_notes_keys")

--- Bind *keys* in *buf*, plus `?` and `g?` for the menu.
---@param buf integer
---@param title string the menu's title
---@param keys review_notes.Key[]
function M.bind(buf, title, keys)
  for _, k in ipairs(keys) do
    vim.keymap.set(k.modes or "n", k.lhs, k.fn, { buffer = buf, nowait = true, desc = k.desc })
  end
  local function menu() M.menu(title, keys) end
  vim.keymap.set("n", "?", menu, { buffer = buf, nowait = true, desc = "keys" })
  vim.keymap.set("n", "g?", menu, { buffer = buf, nowait = true, desc = "keys" })
end

--- A hint for the thread at hand, as returned by *get*: *label* (or what it
--- returns for the item), only when *test* holds. Nothing without a thread.
---@param get fun(): review_notes.Item?
---@param label string|fun(item: review_notes.Item): string
---@param test (fun(item: review_notes.Item): boolean)?
---@return fun(): string?
function M.when(get, label, test)
  return function()
    local item = get()
    if not item or (test and not test(item)) then return nil end
    return type(label) == "function" and label(item) or label
  end
end

--- The hint bar: `lhs label` for each key that applies now, in order, as
--- many as fit in *width*; `? keys` always ends it.
---@param keys review_notes.Key[]
---@param width integer
---@param prefix string? shown first (the place in the list)
---@return string
function M.hints(keys, width, prefix)
  local head = " " .. (prefix and (prefix .. "   ") or "")
  local tail = "? keys"
  local used = #head + #tail
  local parts = {}
  for _, k in ipairs(keys) do
    local label = k.hint
    if type(label) == "function" then label = label() end
    if label then
      local part = k.lhs .. " " .. label
      if used + #part + 2 > width then break end
      used = used + #part + 2
      table.insert(parts, part)
    end
  end
  table.insert(parts, tail)
  local bar = (head .. table.concat(parts, "  ")):gsub("%%", "%%%%")
  return bar
end

--- The `?` menu: a float over the current window listing *keys* by group.
--- A key or <CR> on its row closes it and runs it; `/` filters; q, <Esc>
--- or ? close it.
---@param title string
---@param keys review_notes.Key[]
function M.menu(title, keys)
  local host = vim.api.nvim_get_current_win()
  local groups, order = {}, {}
  for _, k in ipairs(keys) do
    if not groups[k.group] then
      groups[k.group] = {}
      table.insert(order, k.group)
    end
    table.insert(groups[k.group], k)
  end
  local width = 0
  for _, k in ipairs(keys) do width = math.max(width, #k.lhs) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local rows ---@type table<integer, review_notes.Key>
  local filter = ""
  local function draw()
    local lines, hls = {}, {}
    rows = {}
    for _, g in ipairs(order) do
      local shown = vim.tbl_filter(function(k)
        return filter == "" or (k.lhs .. " " .. k.desc):lower():find(filter:lower(), 1, true) ~= nil
      end, groups[g])
      if #shown > 0 then
        if #lines > 0 then table.insert(lines, "") end
        table.insert(lines, g)
        table.insert(hls, { #lines, 0, #g, "Title" })
        for _, k in ipairs(shown) do
          table.insert(lines, ("  %s%s  %s"):format(k.lhs, (" "):rep(width - #k.lhs), k.desc))
          rows[#lines] = k
          table.insert(hls, { #lines, 2, 2 + #k.lhs, "Special" })
        end
      end
    end
    if #lines == 0 then lines = { "no key matches " .. filter } end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for _, h in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(buf, ns, h[1] - 1, h[2], { end_col = h[3], hl_group = h[4] })
    end
    return lines
  end
  local lines = draw()

  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, #l) end
  local hw, hh = vim.api.nvim_win_get_width(host), vim.api.nvim_win_get_height(host)
  w = math.min(math.max(w + 2, 30), math.max(20, hw - 4))
  local h = math.min(#lines, math.max(3, hh - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "win",
    win = host,
    row = math.max(0, math.floor((hh - h) / 2) - 1),
    col = math.max(0, math.floor((hw - w) / 2) - 1),
    width = w,
    height = h,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    footer = " <CR>/key run  / filter  q close ",
    footer_pos = "right",
  })
  vim.wo[win].cursorline = true

  local function first_row()
    local l = math.huge
    for n in pairs(rows) do l = math.min(l, n) end
    return l ~= math.huge and l or 1
  end
  vim.api.nvim_win_set_cursor(win, { first_row(), 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(host) then vim.api.nvim_set_current_win(host) end
  end
  local function run(k)
    close()
    -- After the float is gone, so the key acts on the host's cursor.
    vim.schedule(k.fn)
  end
  local function map(lhs, fn) vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true }) end
  for _, k in ipairs(keys) do
    if k.lhs ~= "q" and k.lhs ~= "?" then map(k.lhs, function() run(k) end) end
  end
  map("<CR>", function()
    local k = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if k then run(k) end
  end)
  map("q", close)
  map("<Esc>", close)
  map("?", close)
  map("/", function()
    -- The command line, not vim.ui.input: a floating input would take the
    -- focus and close the menu (WinLeave).
    -- pcall: <C-c> at the prompt raises Keyboard interrupt.
    local ok, text = pcall(vim.fn.input, { prompt = "filter keys: ", default = filter, cancelreturn = filter })
    if not ok or not vim.api.nvim_win_is_valid(win) then return end
    filter = text
    local shown = draw()
    vim.api.nvim_win_set_height(win, math.min(#shown, math.max(3, hh - 4)))
    vim.api.nvim_win_set_cursor(win, { first_row(), 0 })
  end)
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function()
    vim.schedule(function()
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end)
  end })
end

return M
