-- The note editor: a small markdown float anchored at the code it is about,
-- like GitLab's inline reply box. <CR> (normal mode) or :w sends, q closes.
-- Closing without sending keeps the text as a draft for the same location, so
-- an accidental q loses nothing; empty the buffer and close to drop it.
local M = {}

local drafts = {} ---@type table<string, string[]>

M.keys = { submit = "<CR>", close = "q" }

-- Lines of *lines* without leading and trailing blank lines.
local function strip(lines)
  local first, last = 1, #lines
  while first <= last and not lines[first]:match("%S") do first = first + 1 end
  while last >= first and not lines[last]:match("%S") do last = last - 1 end
  return vim.list_slice(lines, first, last)
end

---@class review_notes.ComposeOpts
---@field key string identifies the location, for drafts
---@field title string
---@field initial string[]? text to start with (editing); a draft wins
---@field row integer 0-based first row of the code the note is about
---@field end_row integer 0-based last row (the float opens under it)
---@field skip integer? virtual lines under end_row to open below (the shown thread)
---@field on_submit fun(lines: string[])

--- Open the editor. *on_submit* gets the text without blank edges; it is not
--- called for an empty text.
---@param opts review_notes.ComposeOpts
---@return integer win
function M.open(opts)
  local src_win = vim.api.nvim_get_current_win()
  local info = assert(vim.fn.getwininfo(src_win)[1])
  local text_width = info.width - info.textoff
  local indent = math.min(vim.fn.indent(opts.end_row + 1), math.max(0, text_width - 50))
  local width = math.max(20, math.min(90, text_width - indent - 2))
  local height = 8

  local buf = vim.api.nvim_create_buf(false, true)
  local initial = drafts[opts.key] or opts.initial or {}
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
  vim.bo[buf].modified = false
  -- acwrite: `:w` submits through BufWriteCmd instead of writing a file.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "review://" .. opts.key .. "#" .. buf)
  vim.bo[buf].filetype = "markdown"

  -- Below the code (and the thread shown under it); above it when that would
  -- run off the window, so the float never covers the line it is about.
  local skip = opts.skip or 0
  local below = vim.fn.screenpos(src_win, opts.end_row + 1, 1).row
  local room = (info.winrow + info.height - 1) - (below + skip)
  local config = {
    relative = "win",
    win = src_win,
    width = width,
    height = height,
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "left",
    footer = " " .. M.keys.submit .. " send  :w send  " .. M.keys.close .. " close (keeps draft) ",
    footer_pos = "right",
    style = "minimal",
  }
  if below == 0 or room >= height + 2 then
    config.bufpos, config.anchor, config.row, config.col = { opts.end_row, indent }, "NW", 1 + skip, 0
  else
    config.bufpos, config.anchor, config.row, config.col = { opts.row, indent }, "SW", 0, 0
  end
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].spell = true
  vim.wo[win].winfixbuf = true

  local done = false
  local function close()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_win_is_valid(src_win) then vim.api.nvim_set_current_win(src_win) end
  end
  local function submit()
    local lines = strip(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    done = true
    drafts[opts.key] = nil
    vim.cmd.stopinsert()
    close()
    if #lines > 0 then opts.on_submit(lines) end
  end

  local group = vim.api.nvim_create_augroup("review_notes_compose_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, buffer = buf, callback = submit })
  -- Unsent text is kept as a draft, so :q must not refuse with E37.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = buf,
    callback = function() vim.bo[buf].modified = false end,
  })
  -- However the float goes away (q, :q, <C-w>c), unsent text is kept.
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      if not done then
        local lines = strip(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
        drafts[opts.key] = #lines > 0 and vim.api.nvim_buf_get_lines(buf, 0, -1, false) or nil
        if drafts[opts.key] then
          vim.notify("review: note kept as a draft, reopen it at the same place", vim.log.levels.INFO)
        end
      end
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  -- Leaving the float for another window closes it, as other floats do.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function() vim.schedule(close) end,
  })
  vim.keymap.set("n", M.keys.submit, submit, { buffer = buf, desc = "Review: send note" })
  vim.keymap.set("n", M.keys.close, close, { buffer = buf, desc = "Review: close (keeps draft)" })
  if #initial == 0 then vim.cmd.startinsert() end
  return win
end

--- Test hook: the draft kept for *key*.
function M.draft(key) return drafts[key] end

return M
