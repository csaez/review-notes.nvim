-- Threads in code buffers: an extmark per anchor, so it follows edits, and a
-- sign on it (a bar down the range, the state icon on its last line). No
-- text: the conversation is in the sidebar. Threads on the whole change
-- or a whole file have no line and nothing here; they are in the list.
local store = require("review_notes.store")
local merge = require("review_notes.merge")
local review = require("review_notes.review")

local M = {}

local ns = vim.api.nvim_create_namespace("review_notes_signs")

function M.set_highlights()
  local function hl(name, link) vim.api.nvim_set_hl(0, name, { default = true, link = link }) end
  hl("ReviewUnread", "DiagnosticWarn")
  hl("ReviewProposed", "Constant")
  hl("ReviewUnsent", "DiagnosticInfo")
  hl("ReviewOpen", "String")
  hl("ReviewResolved", "NonText")
  hl("ReviewAuthor", "Title")
  hl("ReviewMine", "Special")
  hl("ReviewText", "Comment")
  hl("ReviewRange", "Visual")
end

---@class review_notes.Drawn
---@field entry review_notes.Entry
---@field mark integer extmark of the anchor

---@type table<integer, review_notes.Drawn[]>
local drawn = {}

--- Remove everything drawn in *buf*.
---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1) end
  drawn[buf] = nil
end

---@class review_notes.SignOpts
---@field signs boolean draw the signs (the anchors are tracked either way)
---@field buf_rows table<string, { row: integer, end_row: integer }>? live rows to keep (unsaved edits), by key

--- Track and mark the line threads of *buf*.
---@param buf integer
---@param entries review_notes.Entry[]
---@param rel string path of the buffer's file, as in anchors
---@param opts review_notes.SignOpts
function M.render(buf, entries, rel, opts)
  local keep = opts.buf_rows or {}
  M.clear(buf)
  local last = vim.api.nvim_buf_line_count(buf)
  local list = {}
  for _, entry in ipairs(entries) do
    local a = entry.thread.anchor
    if store.anchor_kind(a) == "line" and a.path == rel then
      local first, stop
      local live = keep[entry.key]
      if live then
        first, stop = live.row, live.end_row
      else
        first = math.max(1, math.min(a.line, last)) - 1
        stop = math.max(first, math.min(a.end_line or a.line, last) - 1)
      end
      -- Both ends move down when a line is inserted at them, so a thread
      -- stays with its code (`O` on its first line).
      local mark = vim.api.nvim_buf_set_extmark(buf, ns, first, 0, {
        end_row = stop,
        end_col = 0,
        end_right_gravity = true,
        invalidate = true,
        undo_restore = false,
      })
      table.insert(list, { entry = entry, mark = mark })
    end
  end
  drawn[buf] = list
  if not opts.signs then return end
  -- Priority below diagnostics (10) so problems keep the gutter.
  for _, d in ipairs(list) do
    local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, d.mark, { details = true })
    local st = review.style[(merge.urgency(merge.flags(d.entry.thread, d.entry.state)))]
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

---@class review_notes.Anchored
---@field entry review_notes.Entry
---@field row integer 0-based first row
---@field end_row integer
---@field moved boolean its lines were deleted

--- Where the threads of *buf* are now, sorted by position.
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
        moved = m[3].invalid == true,
      })
    end
  end
  table.sort(out, function(a, b) return a.row < b.row end)
  return out
end

--- The threads that cover *row* (0-based).
---@param buf integer
---@param row integer
---@return review_notes.Anchored[]
function M.at(buf, row)
  return vim.tbl_filter(function(a) return row >= a.row and row <= a.end_row end, M.anchored(buf))
end

--- Live rows by key, to redraw after the notes were re-read while the buffer
--- has unsaved edits.
---@param buf integer
---@return table<string, { row: integer, end_row: integer }>
function M.live_rows(buf)
  local out = {}
  for _, a in ipairs(M.anchored(buf)) do out[a.entry.key] = { row = a.row, end_row = a.end_row } end
  return out
end

return M
