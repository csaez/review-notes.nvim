-- The note editor: a small markdown float anchored at the code it is about,
-- like GitLab's inline reply box. <CR> (normal mode) or :w sends, q or <Esc>
-- (normal mode) closes.
-- Closing without sending keeps the text as a draft for the same location, so
-- an accidental q loses nothing; empty the buffer and close to drop it.
--
-- On a thread, a read-only float with the conversation sits right above the
-- editor (<C-k> / <C-j> move between the two), and *actions* (resolve, pending)
-- run on keys inside the floats without closing them.
local M = {}

--- Filetype of the read-only thread buffers: markdown to treesitter (registered
--- in ftdetect/), but its own name so a markdown renderer can be enabled for
--- threads alone.
M.thread_ft = "reviewthread"

local drafts = {} ---@type table<string, string[]>

M.keys = {
  submit = "<CR>",
  close = { "q", "<Esc>" },
  thread = "<C-k>", -- editor -> thread
  editor = "<C-j>", -- thread -> editor
}

-- Lines of *lines* without leading and trailing blank lines.
local function strip(lines)
  local first, last = 1, #lines
  while first <= last and not lines[first]:match("%S") do first = first + 1 end
  while last >= first and not lines[last]:match("%S") do last = last - 1 end
  return vim.list_slice(lines, first, last)
end

-- Screen rows *lines* take when wrapped to *width* cells.
local function screen_rows(lines, width)
  local n = 0
  for _, l in ipairs(lines) do
    n = n + math.max(1, math.ceil(vim.fn.strdisplaywidth(l) / width))
  end
  return n
end

---@class review_notes.ComposeAction
---@field key string normal and insert mode key
---@field desc string shown in the footer
---@field run fun() the floats stay open; the title is redrawn afterwards

---@class review_notes.ComposeOpts
---@field key string identifies the location, for drafts
---@field title string|fun(): string
---@field initial string[]? text to start with (editing); a draft wins
---@field row integer 0-based first row of the code the note is about
---@field end_row integer 0-based last row (the float opens under it)
---@field skip integer? virtual lines under end_row to open below (the shown thread)
---@field thread string[]? the conversation so far, shown read-only above the editor
---@field actions review_notes.ComposeAction[]?
---@field on_submit fun(lines: string[])

--- Open the editor. *on_submit* gets the text without blank edges; it is not
--- called for an empty text.
---@param opts review_notes.ComposeOpts
---@return integer win
function M.open(opts)
  local src_win = vim.api.nvim_get_current_win()
  local win_width = vim.api.nvim_win_get_width(src_win)
  local text_width = win_width - (vim.fn.getwininfo(src_win)[1] or { textoff = 0 }).textoff
  local indent = math.floor(math.min(vim.fn.indent(opts.end_row + 1), math.max(0, text_width - 50)))
  local width = math.floor(math.max(20, math.min(90, text_width - indent - 2)))
  local has_thread = opts.thread ~= nil and #opts.thread > 0
  local height = has_thread and 6 or 8
  -- Inner height of the thread float; its border adds 2.
  local thread_h = has_thread and math.max(3, math.min(14, screen_rows(opts.thread, width))) or 0
  local thread_total = has_thread and thread_h + 2 or 0
  local actions = opts.actions or {}

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
  -- Wrap on screen only: a global textwidth wider than the float would hard
  -- break lines while typing, reflowing the text mid-sentence, and those
  -- breaks would end up in the note (and in the comment sent to GitLab).
  vim.bo[buf].textwidth = 0
  vim.bo[buf].formatoptions = vim.bo[buf].formatoptions:gsub("[tca]", "")

  local function title()
    return " " .. (type(opts.title) == "function" and opts.title() or opts.title) .. " "
  end
  local footer = { M.keys.submit .. " send", ":w send", table.concat(M.keys.close, "/") .. " close (keeps draft)" }
  for _, a in ipairs(actions) do table.insert(footer, a.key .. " " .. a.desc) end
  if has_thread then table.insert(footer, M.keys.thread .. " thread") end

  -- Below the code (and the thread shown under it); above it when that would
  -- run off the window, so the float never covers the line it is about.
  local skip = opts.skip or 0
  local below = vim.fn.screenpos(src_win, opts.end_row + 1, 1).row
  local bottom = vim.fn.win_screenpos(src_win)[1] + vim.api.nvim_win_get_height(src_win) - 1
  local room = bottom - (below + skip)
  local config = {
    relative = "win",
    win = src_win,
    width = width,
    height = height,
    border = "rounded",
    title = title(),
    title_pos = "left",
    footer = " " .. table.concat(footer, "  ") .. " ",
    footer_pos = "right",
    style = "minimal",
  }
  local thread_config = {
    relative = "win",
    win = src_win,
    width = width,
    height = thread_h,
    border = "rounded",
    title = " Thread ",
    title_pos = "left",
    footer = " " .. M.keys.editor .. " / <CR> / i reply  q close ",
    footer_pos = "right",
    style = "minimal",
  }
  if below == 0 or room >= thread_total + height + 2 then
    config.bufpos, config.anchor, config.row, config.col = { opts.end_row, indent }, "NW", 1 + skip + thread_total, 0
    thread_config.bufpos, thread_config.anchor, thread_config.row, thread_config.col =
      { opts.end_row, indent }, "NW", 1 + skip, 0
  else
    config.bufpos, config.anchor, config.row, config.col = { opts.row, indent }, "SW", 0, 0
    thread_config.bufpos, thread_config.anchor, thread_config.row, thread_config.col =
      { opts.row, indent }, "SW", -(height + 2), 0
  end

  local tbuf, twin
  if has_thread then
    tbuf = vim.api.nvim_create_buf(false, true)
    vim.bo[tbuf].filetype = M.thread_ft
    vim.bo[tbuf].bufhidden = "wipe"
    vim.bo[tbuf].swapfile = false
    twin = vim.api.nvim_open_win(tbuf, false, thread_config)
    require("review_notes.thread").set(tbuf, opts.thread)
    require("review_notes.thread").style(twin)
    vim.wo[twin].winfixbuf = true
    -- The latest comments are the ones to answer.
    vim.api.nvim_win_set_cursor(twin, { vim.api.nvim_buf_line_count(tbuf), 0 })
  end

  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].spell = true
  vim.wo[win].winfixbuf = true

  local done = false
  local function close()
    for _, w in pairs({ twin = twin, win = win }) do
      if vim.api.nvim_win_is_valid(w) then vim.api.nvim_win_close(w, true) end
    end
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
      -- Take the thread float along when the editor is wiped (:bwipeout).
      if twin and vim.api.nvim_win_is_valid(twin) then vim.schedule(close) end
    end,
  })
  -- Leaving the floats for another window closes them, as other floats do;
  -- moving between the thread and the editor does not.
  local function leave_check()
    vim.schedule(function()
      local cur = vim.api.nvim_get_current_win()
      if cur ~= win and cur ~= twin then close() end
    end)
  end
  for _, b in pairs({ buf = buf, tbuf = tbuf }) do
    vim.api.nvim_create_autocmd("WinLeave", { group = group, buffer = b, callback = leave_check })
  end

  local function focus(w, insert)
    if w and vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_set_current_win(w)
      if insert then vim.cmd.startinsert() end
    end
  end
  local function map(b, modes, lhs, fn, desc)
    vim.keymap.set(modes, lhs, fn, { buffer = b, desc = "Review: " .. desc, nowait = true })
  end
  map(buf, "n", M.keys.submit, submit, "send note")
  for _, key in ipairs(M.keys.close) do
    map(buf, "n", key, close, "close (keeps draft)")
  end
  for _, a in ipairs(actions) do
    local function run()
      a.run()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_config(win, { title = title(), title_pos = "left" })
      end
    end
    for _, b in pairs({ buf = buf, tbuf = tbuf }) do
      map(b, { "n", "i" }, a.key, run, a.desc)
    end
  end
  if tbuf then
    map(buf, { "n", "i" }, M.keys.thread, function()
      vim.cmd.stopinsert()
      focus(twin)
    end, "read the thread")
    for _, key in ipairs(M.keys.close) do
      map(tbuf, "n", key, close, "close")
    end
    for _, key in ipairs({ M.keys.editor, M.keys.submit }) do
      map(tbuf, "n", key, function() focus(win) end, "back to the editor")
    end
    for _, key in ipairs({ "i", "a", "A", "o" }) do
      map(tbuf, "n", key, function() focus(win, true) end, "reply")
    end
  end
  if #initial == 0 then vim.cmd.startinsert() end
  return win
end

--- Test hook: the draft kept for *key*.
function M.draft(key) return drafts[key] end

return M
