-- Shows threads inside code buffers: a sign on the anchor and the thread as
-- virtual lines under it, collapsed to one line or expanded to the whole
-- conversation. Threads on the whole change or on a whole file have no line:
-- they sit in a header above line 1 (virtual lines above), with a label so
-- they cannot be mistaken for a thread anchored on line 1.
--
-- Everything is extmarks, so it does not touch the buffer, gitsigns or diff
-- views. `render` draws a list of entries; anchors follow edits and
-- `anchors` reads where they ended up.
local merge = require("review_notes.merge")
local store = require("review_notes.store")

local M = {}

local ns = vim.api.nvim_create_namespace("review_notes_view")

-- Nerd Font icons by state.
---@type table<string, { icon: string, hl: string }>
M.style = {
  unread = { icon = "\u{f0f3}", hl = "ReviewUnread" },
  proposed = { icon = "\u{ea73}", hl = "ReviewProposed" },
  unsent = { icon = "\u{f093}", hl = "ReviewUnsent" },
  open = { icon = "\u{eac7}", hl = "ReviewOpen" },
  resolved = { icon = "\u{f00c}", hl = "ReviewResolved" },
}

---@class review_notes.Entry
---@field key string stable across re-reads, to remember what is expanded
---@field thread review_notes.Thread
---@field state review_notes.ThreadState?

--- A key for *thread*: its remote id, or its place among new threads.
---@param thread review_notes.Thread
---@param ordinal integer
---@return string
function M.key(thread, ordinal)
  return thread.id or ("new:" .. store.anchor_string(thread.anchor) .. "#" .. ordinal)
end

function M.set_highlights()
  local function hl(name, link) vim.api.nvim_set_hl(0, name, { default = true, link = link }) end
  hl("ReviewUnread", "DiagnosticWarn")
  hl("ReviewProposed", "Constant")
  hl("ReviewUnsent", "DiagnosticInfo")
  hl("ReviewOpen", "String")
  hl("ReviewResolved", "NonText")
  hl("ReviewBar", "NonText")
  hl("ReviewAuthor", "Title")
  hl("ReviewMine", "Special")
  hl("ReviewText", "Comment")
  hl("ReviewHeader", "Folded")
end

-- Layout ----------------------------------------------------------------

local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    if para == "" then
      table.insert(out, "")
    else
      local indent = para:match("^%s*")
      local line = ""
      for word in para:gmatch("%S+") do
        if line ~= "" and #line + 1 + #word > width then
          table.insert(out, line)
          line = indent .. word
        else
          line = (line == "" and indent or line .. " ") .. word
        end
      end
      table.insert(out, line)
    end
  end
  return out
end

local function first_line(body)
  return (vim.split(body, "\n", { plain = true })[1] or "")
end

local function who(c)
  if c.source == "remote" then return "@" .. (c.author or "unknown"), c.mine and "ReviewMine" or "ReviewAuthor" end
  return c.source == "proposed" and "me (proposed)" or "me (not published)", "ReviewMine"
end

--- Tags worth a word next to the icon.
---@param f review_notes.Flags
---@return string
local function tags(f)
  local t = {}
  if f.resolved_by then
    table.insert(t, "resolved by @" .. f.resolved_by)
  elseif f.resolved then
    table.insert(t, "resolved")
  end
  if f.proposed then table.insert(t, "proposed") end
  if f.unsent and not f.proposed then table.insert(t, f.new and "new" or "unsent") end
  if f.orphan then table.insert(t, "deleted on the remote") end
  return table.concat(t, ", ")
end

---@param entry review_notes.Entry
---@return review_notes.Flags, { icon: string, hl: string }
local function look(entry)
  local f = merge.flags(entry.thread, entry.state)
  return f, M.style[(merge.urgency(f))]
end

--- Label of a thread in a header, so its place is never mistaken.
local function label(thread)
  local kind = store.anchor_kind(thread.anchor)
  if kind == "change" then return "change" end
  return "file " .. vim.fs.basename(thread.anchor.path)
end

--- The virtual lines of one thread.
---@param entry review_notes.Entry
---@param expanded boolean
---@param width integer
---@param header boolean show the label (change and file threads)
---@param indent string
---@return table[] lines each a list of { text, hl } chunks
function M.thread_lines(entry, expanded, width, header, indent)
  local t = entry.thread
  local f, st = look(entry)
  local lines = {}
  local head = { { indent, "Normal" }, { st.icon .. " ", st.hl } }
  if header then table.insert(head, { label(t) .. "  ", "ReviewHeader" }) end

  local last = t.comments[#t.comments]
  local n = #t.comments
  local tag = tags(f)

  if not expanded then
    local text = ""
    if last then
      local name = who(last)
      text = (n > 1 and (n .. " comments, ") or "") .. name .. ": " .. first_line(last.body)
    else
      text = "empty"
    end
    table.insert(head, { text, f.resolved and "ReviewResolved" or "ReviewText" })
    if tag ~= "" then table.insert(head, { "  [" .. tag .. "]", st.hl }) end
    table.insert(lines, head)
    return lines
  end

  table.insert(head, { tag ~= "" and ("[" .. tag .. "]") or (n == 1 and "1 comment" or (n .. " comments")), st.hl })
  table.insert(lines, head)
  local bar = { indent .. "\u{2502} ", "ReviewBar" }
  local inner = math.max(20, width - #indent - 2)
  for i, c in ipairs(t.comments) do
    if i > 1 then table.insert(lines, { bar }) end
    local name, name_hl = who(c)
    table.insert(lines, { bar, { name, name_hl } })
    local body_hl = c.source == "remote" and "Normal" or "ReviewMine"
    for _, l in ipairs(wrap(c.body, inner)) do
      table.insert(lines, { bar, { l, body_hl } })
    end
  end
  return lines
end

-- Rendering -------------------------------------------------------------

---@class review_notes.Drawn
---@field entry review_notes.Entry
---@field mark integer extmark of the anchor
---@field header boolean

---@type table<integer, review_notes.Drawn[]>
local drawn = {}

---@class review_notes.RenderOpts
---@field expanded table<string, boolean>
---@field signs boolean
---@field width integer?
---@field buf_rows table<string, { row: integer, end_row: integer }>? live rows to keep (unsaved edits), by key

---@param buf integer
---@return integer
local function width_of(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then return 80 end
  local info = vim.fn.getwininfo(win)[1]
  return math.max(20, vim.api.nvim_win_get_width(win) - (info and info.textoff or 0) - 2)
end

--- Remove everything drawn in *buf*.
---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  drawn[buf] = nil
end

--- Draw the entries of *buf*. A header collects the change and file threads.
--- With `visible` false only the signs are drawn.
---@param buf integer
---@param entries review_notes.Entry[] the entries anchored in this file, plus the change ones
---@param rel string path of the buffer's file, as in anchors
---@param visible boolean review mode: the thread text
---@param opts review_notes.RenderOpts
function M.render(buf, entries, rel, visible, opts)
  local keep = opts.buf_rows or {}
  M.clear(buf)
  local last = vim.api.nvim_buf_line_count(buf)
  local width = opts.width or width_of(buf)
  local list = {}
  local header = {}

  for _, entry in ipairs(entries) do
    local a = entry.thread.anchor
    local kind = store.anchor_kind(a)
    if kind == "change" or a.path == rel then
      local first, stop
      if kind == "line" then
        local live = keep[entry.key]
        if live then
          first, stop = live.row, live.end_row
        else
          first = math.max(1, math.min(a.line, last)) - 1
          stop = math.max(first, math.min(a.end_line or a.line, last) - 1)
        end
      else
        first, stop = 0, 0
      end
      local is_header = kind ~= "line"
      -- Both ends move down when a line is inserted at them, so a thread
      -- stays with its code (`O` on its first line).
      local mark = vim.api.nvim_buf_set_extmark(buf, ns, first, 0, {
        end_row = stop,
        end_col = 0,
        end_right_gravity = true,
        invalidate = true,
        undo_restore = false,
      })
      local drawn_entry = { entry = entry, mark = mark, header = is_header }
      table.insert(list, drawn_entry)
      if is_header then table.insert(header, drawn_entry) end
    end
  end
  drawn[buf] = list

  -- Signs: the file's own threads only. A range is a bar with the icon on its
  -- last line. Priority below diagnostics (10) so problems keep the gutter.
  if opts.signs then
    for _, d in ipairs(list) do
      if not d.header then
        local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, d.mark, { details = true })
        local _, st = look(d.entry)
        local row, stop = m[1], math.max(m[1], m[3].end_row or m[1])
        for r = row, stop do
          vim.api.nvim_buf_set_extmark(buf, ns, r, 0, {
            sign_text = r == stop and st.icon or "\u{258e}",
            sign_hl_group = st.hl,
            number_hl_group = st.hl,
            priority = 9,
          })
        end
      end
    end
  end

  if not visible then return end

  -- Text of the threads under their last line, one block per row.
  local below = {} ---@type table<integer, table[]>
  for _, d in ipairs(list) do
    if not d.header then
      local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, d.mark, { details = true })
      local stop = math.max(m[1], m[3].end_row or m[1])
      below[stop] = below[stop] or {}
      vim.list_extend(below[stop], M.thread_lines(d.entry, opts.expanded[d.entry.key] == true, width, false, "  "))
    end
  end
  for row, lines in pairs(below) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { virt_lines = lines })
  end

  if #header > 0 then
    local lines = {}
    for _, d in ipairs(header) do
      vim.list_extend(lines, M.thread_lines(d.entry, opts.expanded[d.entry.key] == true, width, true, ""))
    end
    vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = lines, virt_lines_above = true })
  end
end

-- Queries ---------------------------------------------------------------

---@class review_notes.Anchored
---@field entry review_notes.Entry
---@field row integer 0-based first row
---@field end_row integer
---@field header boolean
---@field moved boolean its lines were deleted

--- Where the threads of *buf* are now, sorted by position (header first).
---@param buf integer
---@return review_notes.Anchored[]
function M.anchored(buf)
  local out = {}
  for _, d in ipairs(drawn[buf] or {}) do
    local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, d.mark, { details = true })
    if m[1] then
      table.insert(out, {
        entry = d.entry,
        row = m[1],
        end_row = math.max(m[1], m[3].end_row or m[1]),
        header = d.header,
        moved = m[3].invalid == true,
      })
    end
  end
  table.sort(out, function(a, b)
    if a.header ~= b.header then return a.header end
    return a.row < b.row
  end)
  return out
end

--- The threads that cover *row*; the header ones when *row* is 0 and
--- *include_header* is set.
---@param buf integer
---@param row integer 0-based
---@param include_header boolean?
---@return review_notes.Anchored[]
function M.at(buf, row, include_header)
  return vim.tbl_filter(function(a)
    if a.header then return include_header == true and row == 0 end
    return row >= a.row and row <= a.end_row
  end, M.anchored(buf))
end

--- Live rows by key, to redraw after the notes were re-read while the buffer
--- has unsaved edits.
---@param buf integer
---@return table<string, { row: integer, end_row: integer }>
function M.live_rows(buf)
  local out = {}
  for _, a in ipairs(M.anchored(buf)) do
    if not a.header then out[a.entry.key] = { row = a.row, end_row = a.end_row } end
  end
  return out
end

return M
