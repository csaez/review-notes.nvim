-- The note float: one buffer per note, shown in a single float centered on
-- the editor. The conversation is on top and my turn below a `---`
-- line; `:w` saves my turn into the notes file (through *on_write*), `q`
-- closes. A closed note with unsaved text stays as a hidden buffer, like any
-- modified buffer, and comes back when the note is opened again.
local M = {}

local ns = vim.api.nvim_create_namespace("review_notes_note")
local SEP = "---"

---@class review_notes.NoteAction
---@field key string normal mode key, buffer-local
---@field desc string shown in the footer
---@field run fun(buf: integer)

---@class review_notes.NoteState
---@field sep integer? extmark on the `---` line (no conversation: none)
---@field title fun(): string
---@field on_write fun(text: string[], buf: integer): boolean
---@field on_wipe fun(buf: integer)?

local state = {} ---@type table<integer, review_notes.NoteState>
local win ---@type integer?

--- Share of the editor the float takes, each way.
M.size = 0.8

--- Window config of the float: centered, `M.size` of the editor. Override to
--- place it elsewhere.
---@param title string
---@param footer string
---@return vim.api.keyset.win_config
function M.float(title, footer)
  local lines = vim.o.lines - vim.o.cmdheight
  local width = math.max(40, math.floor(vim.o.columns * M.size))
  local height = math.max(5, math.floor(lines * M.size))
  return {
    relative = "editor",
    -- The border takes a cell on each side.
    row = math.max(0, math.floor((lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
    width = width,
    height = height,
    border = "rounded",
    title = title,
    title_pos = "left",
    footer = footer,
    footer_pos = "right",
    style = "minimal",
  }
end

M.close_key = "q"

local function strip(lines)
  local first, last = 1, #lines
  while first <= last and not lines[first]:match("%S") do first = first + 1 end
  while last >= first and not lines[last]:match("%S") do last = last - 1 end
  return vim.list_slice(lines, first, last)
end

local function shown() return win and vim.api.nvim_win_is_valid(win) and win or nil end

--- The note buffer shown in the float, if any.
---@return integer?
function M.current()
  local w = shown()
  local buf = w and vim.api.nvim_win_get_buf(w)
  return buf and state[buf] and buf or nil
end

function M.close()
  local w = shown()
  if w then vim.api.nvim_win_close(w, true) end
  win = nil
end

-- Fill *buf*: the conversation, then my turn. Returns the 0-based row where
-- my turn starts.
local function render(buf, conversation, reply)
  local lines = vim.list_extend({}, conversation)
  local sep
  if #conversation > 0 then
    vim.list_extend(lines, { "", SEP })
    sep = #lines - 1
  end
  local first = #lines
  vim.list_extend(lines, #reply > 0 and reply or { "" })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  require("review_notes.thread").decorate(buf, conversation)
  state[buf].sep = sep
    and vim.api.nvim_buf_set_extmark(buf, ns, sep, 0, {
      virt_text = { { " my turn, :w saves", "ReviewText" } },
      virt_text_pos = "eol",
    })
  vim.bo[buf].modified = false
  return first
end

--- My turn as written in *buf*: the lines below the `---` line, without blank
--- edges.
---@return string[]
function M.reply(buf)
  local from = 0
  local mark = state[buf] and state[buf].sep
  if mark then
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, mark, {})
    if pos[1] then from = pos[1] + 1 end
  end
  return strip(vim.api.nvim_buf_get_lines(buf, from, -1, false))
end

local function footer(actions)
  local parts = { ":w save", M.close_key .. " close" }
  for _, a in ipairs(actions) do
    table.insert(parts, vim.fn.keytrans(vim.keycode(a.key)) .. " " .. a.desc)
  end
  return " " .. table.concat(parts, "  ") .. " "
end

local function create(name)
  local buf = vim.api.nvim_create_buf(false, false)
  if not pcall(vim.api.nvim_buf_set_name, buf, "review://" .. name) then
    vim.api.nvim_buf_set_name(buf, "review://" .. name .. "#" .. buf)
  end
  -- acwrite: `:w` saves through BufWriteCmd into the notes file.
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  -- Wrap on screen only: hard breaks while typing would end up in the
  -- comment sent to the remote.
  vim.bo[buf].textwidth = 0
  vim.bo[buf].formatoptions = vim.bo[buf].formatoptions:gsub("[tca]", "")
  local group = vim.api.nvim_create_augroup("review_notes_note_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function()
      local st = state[buf]
      if st and st.on_write(M.reply(buf), buf) then vim.bo[buf].modified = false end
    end,
  })
  -- Only unsaved text is worth keeping around.
  vim.api.nvim_create_autocmd("BufHidden", {
    group = group,
    buffer = buf,
    callback = function()
      if not vim.bo[buf].modified then
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) == -1 and not vim.bo[buf].modified then
            vim.api.nvim_buf_delete(buf, { force = true })
          end
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = buf,
    callback = function()
      local st = state[buf]
      state[buf] = nil
      if st and st.on_wipe then st.on_wipe(buf) end
    end,
  })
  -- Leaving the float for another window closes it, as other floats do.
  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if shown() and vim.api.nvim_get_current_win() ~= win then M.close() end
      end)
    end,
  })
  return buf
end

---@class review_notes.NoteOpts
---@field buf integer? the note's buffer, if it has one already
---@field name string buffer name after `review://`
---@field title fun(): string
---@field conversation string[]
---@field reply string[] my turn as saved
---@field insert boolean? start typing (a new note)
---@field actions review_notes.NoteAction[]
---@field on_write fun(text: string[], buf: integer): boolean true when saved
---@field on_wipe fun(buf: integer)?

--- Show a note in the float (opening it if needed) and enter it. A buffer with
--- unsaved text is shown as it is.
---@param opts review_notes.NoteOpts
---@return integer buf
function M.show(opts)
  local buf = opts.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf) and state[buf]) then
    buf = create(opts.name)
    state[buf] = { title = opts.title, on_write = opts.on_write, on_wipe = opts.on_wipe }
    render(buf, opts.conversation, opts.reply)
  elseif not vim.bo[buf].modified then
    render(buf, opts.conversation, opts.reply)
  end
  local st = state[buf]
  st.title, st.on_write, st.on_wipe = opts.title, opts.on_write, opts.on_wipe
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "Review: " .. desc })
  end
  map(M.close_key, M.close, "close the note")
  for _, a in ipairs(opts.actions) do
    map(a.key, function() a.run(buf) end, a.desc)
  end

  local config = M.float(" " .. opts.title() .. " ", footer(opts.actions))
  local w = shown()
  if w then
    vim.wo[w].winfixbuf = false
    vim.api.nvim_win_set_buf(w, buf)
    vim.api.nvim_win_set_config(w, config)
    vim.api.nvim_set_current_win(w)
  else
    w = vim.api.nvim_open_win(buf, true, config)
    win = w
  end
  vim.wo[w].winfixbuf = true
  vim.wo[w].wrap = true
  vim.wo[w].linebreak = true
  vim.wo[w].spell = true
  vim.wo[w].conceallevel = 2
  vim.wo[w].concealcursor = "nc"
  -- Land on my turn, with the latest comments right above it.
  local from = 0
  local pos = st.sep and vim.api.nvim_buf_get_extmark_by_id(buf, ns, st.sep, {})
  if pos and pos[1] then from = pos[1] + 1 end
  vim.api.nvim_win_set_cursor(w, { math.min(from + 1, vim.api.nvim_buf_line_count(buf)), 0 })
  if opts.insert then vim.cmd.startinsert({ bang = true }) end
  return buf
end

--- Re-render *buf* from the notes file unless it has unsaved text, and redraw
--- the title. The cursor stays where it was.
---@param conversation string[]
---@param reply string[]
function M.update(buf, conversation, reply)
  if not state[buf] then return end
  if not vim.bo[buf].modified then
    local w = vim.fn.bufwinid(buf)
    local cursor = w ~= -1 and vim.api.nvim_win_get_cursor(w)
    render(buf, conversation, reply)
    if cursor then
      vim.api.nvim_win_set_cursor(w, { math.min(cursor[1], vim.api.nvim_buf_line_count(buf)), cursor[2] })
    end
  end
  M.retitle(buf)
end

function M.retitle(buf)
  local w = shown()
  if w and vim.api.nvim_win_get_buf(w) == buf and state[buf] then
    vim.api.nvim_win_set_config(w, { title = " " .. state[buf].title() .. " ", title_pos = "left" })
  end
end

return M
