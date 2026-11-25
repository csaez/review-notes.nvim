-- The composer: a small markdown float next to the cursor for writing or
-- editing one comment of mine. It only collects text; the caller decides what
-- to do with it.
local M = {}

---@class review_notes.ComposeOpts
---@field title string
---@field text string? initial text
---@field on_save fun(text: string) called on every save with the trimmed text
---@field win integer? open at the bottom of this window, at its width (default: under the cursor)

--- Open the composer. `:w` or `<C-s>` saves and closes, `q` closes (`:q!`
--- when there are unsaved changes).
---@param opts review_notes.ComposeOpts
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_name(buf, "review-note://" .. buf)
  local lines = vim.split(opts.text or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  local width = math.min(80, math.max(40, vim.o.columns - 10))
  local height = math.min(math.max(#lines + 2, 6), math.max(6, math.floor(vim.o.lines / 2)))
  local place = { relative = "cursor", row = 1, col = 0 }
  local host = opts.win
  if host and vim.api.nvim_win_is_valid(host) then
    -- Inside the window, borders included.
    width = math.max(20, vim.api.nvim_win_get_width(host) - 2)
    height = math.min(height, math.max(3, vim.api.nvim_win_get_height(host) - 4))
    place = { relative = "win", win = host, row = vim.api.nvim_win_get_height(host) - height - 2, col = 0 }
  end
  local win = vim.api.nvim_open_win(buf, true, vim.tbl_extend("force", place, {
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    footer = " <C-s> save  q close ",
    footer_pos = "right",
  }))
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.bo[buf].textwidth = 0

  local function save()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    vim.bo[buf].modified = false
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    opts.on_save(text)
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = save })
  local function map(mode, lhs, fn) vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true }) end
  map({ "n", "i" }, "<C-s>", save)
  map("n", "q", function()
    if vim.bo[buf].modified then
      vim.notify("unsaved text: <C-s> saves, :q! discards", vim.log.levels.WARN, { title = "review" })
    else
      vim.api.nvim_win_close(win, true)
    end
  end)
  vim.cmd("startinsert!")
end

return M
