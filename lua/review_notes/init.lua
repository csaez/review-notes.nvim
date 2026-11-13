-- Pending review notes, kept outside the code in `.git/review/<branch>.txt`
-- (format: see notes.lua). Notes are written while reviewing, shown with their
-- own signs (deliberately not vim.diagnostic, so they never mix with LSP
-- problems in ]d, pickers or counts), and synced with the remote through the
-- configured backend commands (see M.config): pull brings the remote threads
-- in (remote wins), push sends my notes, replies and resolved state.
--
-- Line numbers in the file refer to the files as saved on disk. While a buffer
-- is edited, each note follows its code through an extmark; on save the new
-- positions are written back to the notes file.
local nf = require("review_notes.notes")
local backend = require("review_notes.backend")

local M = {}

---@class review_notes.Config
---@field backend table<string, string[]> Command lines, run in the repo root.
---  `{path}`, `{line}` and `{thread}` are substituted; text goes on stdin.
---    threads    prints [{id, path, line, resolved, comments = [{author, body}]}]
---    add        starts a thread at {path}:{line}, text on stdin
---    reply      replies to {thread}, text on stdin
---    resolve, unresolve  change the state of {thread}
---    submit     optional: publishes what add/reply queued; the summary is on stdin
---    discard    optional: drops what add/reply queued (used if submit fails)
M.config = {
  backend = {
    threads = { "git-lab", "comment", "list", "--json" },
    add = { "git-lab", "comment", "add", "--draft", "{path}:{line}", "-" },
    reply = { "git-lab", "comment", "reply", "--draft", "{thread}", "-" },
    resolve = { "git-lab", "comment", "resolve", "{thread}" },
    unresolve = { "git-lab", "comment", "unresolve", "{thread}" },
    submit = { "git-lab", "review", "submit", "-m", "-" },
    discard = { "git-lab", "review", "discard" },
  },
}

local ns = vim.api.nvim_create_namespace("review_notes")
local ns_cursor = vim.api.nvim_create_namespace("review_notes_cursor")
local ns_signs = vim.api.nvim_create_namespace("review_notes_signs")

-- Nerd Font icons: comment, comment-discussion, pencil (draft), bell (new),
-- upload (things a push would send).
---@type table<string, { icon: string, hl: string }>
M.style = {
  note = { icon = "\u{ea6b}", hl = "ReviewNote" },
  thread = { icon = "\u{eac7}", hl = "ReviewThread" },
  draft = { icon = "\u{ea73}", hl = "ReviewDraft" },
  new = { icon = "\u{f0f3}", hl = "ReviewNew" },
  send = { icon = "\u{f093}", hl = "ReviewSend" },
}

-- What a push would send, per repo root, and the root of each file buffer, for
-- the statusline (which must not run git on every redraw).
local to_send = {} ---@type table<string, integer>
local roots = {} ---@type table<integer, string>

local function count_to_send(lines)
  local plan = nf.plan(lines)
  return #plan.new + #plan.replies + #plan.states + (plan.summary ~= "" and 1 or 0)
end

-- Entries shown per buffer, each with the id of the extmark that tracks it.
---@type table<integer, review_notes.Entry[]>
local shown = {}

--- Live 0-based (first, last) rows of a shown entry, following buffer edits.
---@return integer?, integer?
local function rows(buf, e)
  if not e.mark then return nil end
  local m = vim.api.nvim_buf_get_extmark_by_id(buf, ns, e.mark, { details = true })
  if not m[1] then return nil end
  return m[1], math.max(m[1], m[3].end_row or m[1])
end

local function set_highlights()
  -- `default` so a colorscheme or user config can override them.
  vim.api.nvim_set_hl(0, "ReviewNote", { default = true, link = "Function" })
  vim.api.nvim_set_hl(0, "ReviewThread", { default = true, link = "String" })
  vim.api.nvim_set_hl(0, "ReviewDraft", { default = true, link = "Constant" })
  vim.api.nvim_set_hl(0, "ReviewText", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "ReviewRange", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "ReviewResolved", { default = true, link = "NonText" })
  vim.api.nvim_set_hl(0, "ReviewNew", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "ReviewSend", { default = true, link = "DiagnosticInfo" })
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review" })
end

local function git(args, cwd)
  local out = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
  if out.code ~= 0 then return nil end
  return vim.trim(out.stdout)
end

local function read_lines(path)
  local fh = io.open(path, "r")
  if not fh then return {} end
  local lines = vim.split(fh:read("*a"), "\n", { plain = true })
  fh:close()
  if lines[#lines] == "" then table.remove(lines) end
  return lines
end

-- Repo root and notes path for the file in the current buffer (or cwd), so
-- submodules get their own notes file. Files outside any repo (e.g. pi's
-- plans) belong to the cwd's review.
local function context()
  local name = vim.api.nvim_buf_get_name(0)
  local dir = (name ~= "" and vim.bo.buftype == "") and vim.fs.dirname(name) or vim.fn.getcwd()
  local root = git({ "rev-parse", "--show-toplevel" }, dir)
    or git({ "rev-parse", "--show-toplevel" }, vim.fn.getcwd())
  if not root then return nil end
  local gitdir = git({ "rev-parse", "--path-format=absolute", "--git-path", "review" }, root)
  local branch = git({ "branch", "--show-current" }, root)
  -- Mid-rebase HEAD is detached; keep showing the rebased branch's notes.
  for _, dir in ipairs({ "rebase-merge", "rebase-apply" }) do
    if branch and branch ~= "" then break end
    local head = git({ "rev-parse", "--path-format=absolute", "--git-path", dir .. "/head-name" }, root)
    local lines = head and vim.fn.filereadable(head) == 1 and vim.fn.readfile(head) or {}
    branch = lines[1] and lines[1]:gsub("^refs/heads/", "") or nil
  end
  if not branch or branch == "" then branch = "HEAD" end
  return { root = root, path = gitdir .. "/" .. branch .. ".txt" }
end

-- The notes file may also be open in a buffer (<leader>ro). Changes made
-- from code buffers go through the file, so the buffer is written before
-- reading (load) and reloaded after writing (save); otherwise saving a stale
-- buffer would silently undo them.
local function notes_buf(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_name(buf) == path then return buf end
  end
end

local function load(path)
  local buf = notes_buf(path)
  if buf and vim.bo[buf].modified then
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent noautocmd write") end)
  end
  return read_lines(path)
end

local function save(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  local buf = notes_buf(path)
  if buf then
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent! noautocmd edit") end)
  end
end

-- Path of *name* as written in the notes file: repo-relative, or absolute for
-- files outside the repo.
local function note_path(name, root)
  if name:sub(1, #root + 1) == root .. "/" then return name:sub(#root + 2) end
  return name
end

local function full_path(path, root)
  return vim.startswith(path, "/") and path or (root .. "/" .. path)
end

-- Shown notes with their live rows, sorted by last row (where the icon is).
---@return { e: review_notes.Entry, row: integer, end_row: integer }[]
local function live_notes(buf)
  local result = {}
  for _, e in ipairs(shown[buf] or {}) do
    local r, er = rows(buf, e)
    if r then table.insert(result, { e = e, row = r, end_row = er }) end
  end
  table.sort(result, function(a, b) return a.end_row < b.end_row end)
  return result
end

-- Icon and highlight for an entry: resolved entries are dimmed, new ones
-- (changed on the remote since I last looked) stand out, drafts are marked.
local function look(e)
  if e.resolved then return "\u{f00c}", "ReviewResolved" end
  local style = M.style[e.new and "new" or e.draft and "draft" or e.kind]
  return style.icon, style.hl
end

-- Gutter signs from the live positions, redrawn on every change so a range
-- stays continuous when lines are inserted inside it.
local function draw_signs(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns_signs, 0, -1)
  for _, n in ipairs(live_notes(buf)) do
    local icon, hl = look(n.e)
    -- A range reads like GitLab: a bar down the lines, the icon (and the
    -- text, see show_cursor_notes) on the last one. The sign yields to
    -- diagnostics (priority 10) so problems keep the gutter; the coloured
    -- line number keeps the note visible on those lines.
    for row = n.row, n.end_row do
      vim.api.nvim_buf_set_extmark(buf, ns_signs, row, 0, {
        sign_text = row == n.end_row and icon or "\u{258e}",
        sign_hl_group = hl,
        number_hl_group = hl,
        priority = 9,
      })
    end
  end
end

local function refresh_buffer(buf, entries, root)
  if not vim.api.nvim_buf_is_loaded(buf) or vim.bo[buf].buftype ~= "" then return end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return end
  roots[buf] = root
  local rel = note_path(name, root)
  -- Unsaved edits: the file's line numbers are stale, keep where the notes
  -- have moved to (matched by their location in the file).
  local live = {} ---@type table<string, integer[]>
  if vim.bo[buf].modified then
    for _, e in ipairs(shown[buf] or {}) do
      local r, er = rows(buf, e)
      if r then live[e.loc] = { r, er } end
    end
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local last = vim.api.nvim_buf_line_count(buf)
  local mine = {}
  for _, e in ipairs(entries) do
    if e.path == rel then
      local first, stop
      if live[e.loc] then
        first, stop = live[e.loc][1], live[e.loc][2]
      else
        first = math.min(e.line, last) - 1
        stop = math.max(first, math.min(e.end_line or e.line, last) - 1)
      end
      -- Both ends move down when a line is inserted at them, so the note
      -- stays with its code (e.g. `O` on its first line).
      e.mark = vim.api.nvim_buf_set_extmark(buf, ns, first, 0, {
        end_row = stop,
        end_col = 0,
        end_right_gravity = true,
      })
      table.insert(mine, e)
    end
  end
  shown[buf] = mine
  draw_signs(buf)
end

local function notes_on_row(buf, row)
  return vim.tbl_filter(function(n) return row >= n.row and row <= n.end_row end, live_notes(buf))
end

-- Index of *e*'s first line in the notes file *lines*: its original index if
-- still there, else the first line with the same location (the file may have
-- been edited since it was shown).
local function find_line(lines, e, used)
  local prefix = e.loc .. ":"
  if lines[e.src] and vim.startswith(lines[e.src], prefix) and not used[e.src] then
    return e.src
  end
  for i, line in ipairs(lines) do
    if vim.startswith(line, prefix) and not used[i] then return i end
  end
end

-- Write the live positions of *buf*'s notes back to the notes file.
local function sync(buf, ctx)
  if not shown[buf] or #shown[buf] == 0 then return end
  local lines = load(ctx.path)
  local used, changed = {}, false
  for _, e in ipairs(shown[buf]) do
    local r, er = rows(buf, e)
    local idx = r and find_line(lines, e, used)
    if idx then
      used[idx] = true
      local loc = e.path .. ":" .. (r + 1) .. (er > r and ("-" .. (er + 1)) or "")
      if loc ~= e.loc then
        lines[idx] = loc .. lines[idx]:sub(#e.loc + 1)
        changed = true
      end
    end
  end
  -- Position updates are bookkeeping, not an edit to undo.
  if changed then save(ctx.path, lines) end
end

-- Text of the notes whose icon is on the cursor line, as virtual lines under
-- it, with the lines a range covers highlighted. Only on the icon line: the
-- bar lines of a range stay quiet, so text never appears ahead of its icon.
local function show_cursor_notes()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_clear_namespace(buf, ns_cursor, 0, -1)
  if not shown[buf] or vim.fn.mode() ~= "n" then return end
  local row = vim.fn.line(".") - 1
  local here = vim.tbl_filter(function(n) return n.end_row == row end, live_notes(buf))
  local by_row = {} ---@type table<integer, table[]>
  for _, n in ipairs(here) do
    local icon, hl = look(n.e)
    local text_hl = n.e.resolved and "ReviewResolved" or "ReviewText"
    local indent = string.rep(" ", vim.fn.indent(n.end_row + 1))
    local lines = by_row[n.end_row] or {}
    for i, text in ipairs(vim.split(n.e.text, "\n", { plain = true })) do
      local lead = i == 1 and (icon .. " ") or "  "
      table.insert(lines, { { indent .. lead, hl }, { text, text_hl } })
    end
    by_row[n.end_row] = lines
    if n.end_row > n.row then
      vim.api.nvim_buf_set_extmark(buf, ns_cursor, n.row, 0, {
        end_row = n.end_row + 1,
        hl_group = "ReviewRange",
        hl_eol = true,
      })
    end
  end
  for row, lines in pairs(by_row) do
    vim.api.nvim_buf_set_extmark(buf, ns_cursor, row, 0, { virt_lines = lines })
  end
end

--- Jump to the next (dir = 1) or previous (dir = -1) note in the buffer,
--- wrapping around, like ]d for diagnostics.
function M.jump(dir)
  local notes = live_notes(vim.api.nvim_get_current_buf())
  if #notes == 0 then return end
  local row = vim.fn.line(".") - 1
  local target
  -- Notes are anchored (icon and text) at their last row.
  if dir > 0 then
    for _, n in ipairs(notes) do
      if n.end_row > row then
        target = n
        break
      end
    end
    target = target or notes[1]
  else
    for i = #notes, 1, -1 do
      if notes[i].end_row < row then
        target = notes[i]
        break
      end
    end
    target = target or notes[#notes]
  end
  vim.api.nvim_win_set_cursor(0, { target.end_row + 1, 0 })
  show_cursor_notes()
end

--- Statusline component for the current buffer: open entries per state, then
--- the number of things `:Review push` would send (for the whole review).
function M.status()
  local counts = {}
  for _, e in ipairs(shown[vim.api.nvim_get_current_buf()] or {}) do
    -- Resolved entries are done; count what is still open.
    if not e.resolved then
      local kind = e.new and "new" or e.draft and "draft" or e.kind
      counts[kind] = (counts[kind] or 0) + 1
    end
  end
  local parts = {}
  for _, kind in ipairs({ "new", "note", "thread", "draft" }) do
    if counts[kind] then
      local style = M.style[kind]
      table.insert(parts, "%#" .. style.hl .. "#" .. style.icon .. " " .. counts[kind])
    end
  end
  local n = to_send[roots[vim.api.nvim_get_current_buf()] or ""]
  if n and n > 0 then
    table.insert(parts, "%#" .. M.style.send.hl .. "#" .. M.style.send.icon .. " " .. n)
  end
  return table.concat(parts, " ")
end

--- Re-read the notes file and update the signs in all loaded buffers.
function M.refresh()
  local ctx = context()
  if not ctx then return end
  local lines = read_lines(ctx.path)
  to_send[ctx.root] = count_to_send(lines)
  local entries = nf.parse(lines)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    refresh_buffer(buf, entries, ctx.root)
  end
  show_cursor_notes()
  vim.cmd.redrawstatus({ bang = true })
end

---@param entry string[]
local function append(path, entry)
  local lines = load(path)
  if #lines > 0 and lines[#lines] ~= "" then table.insert(lines, "") end
  vim.list_extend(lines, entry)
  save(path, lines)
end

-- The visible entry on the cursor row, preferring one whose icon is there.
local function entry_on_cursor_row()
  local row = vim.fn.line(".") - 1
  local here = notes_on_row(vim.api.nvim_get_current_buf(), row)
  for _, n in ipairs(here) do
    if n.end_row == row then return n.e end
  end
  return here[1] and here[1].e
end

-- Virtual lines (a shown thread) under *row*, so the editor opens below them.
local function virt_lines_at(buf, row)
  local n = 0
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns_cursor, { row, 0 }, { row, -1 }, { details = true })) do
    n = n + #((m[4] or {}).virt_lines or {})
  end
  return n
end

-- Open the editor on an entry with my latest turn (see notes.turn): the whole
-- note while nobody has answered, else my reply after the last quoted line.
-- Sending reopens a resolved entry and clears [new]: I have acted on it.
local function reply(ctx, e, n)
  local lines = load(ctx.path)
  local idx = find_line(lines, e, {})
  local turn = idx and nf.turn(lines, idx)
  if not idx or not turn then return end
  local who = e.head:match("^@[%w._-]+")
  local title = (turn.whole and "Edit note " or (#turn.text > 0 and "Edit reply " or "Reply "))
    .. (who and ("to " .. who .. " ") or "")
    .. "at " .. e.loc
    .. (e.resolved and " (reopens)" or "")
  local buf = vim.api.nvim_get_current_buf()
  require("review_notes.compose").open({
    key = ctx.path .. "\0" .. (e.id or e.raw),
    title = title,
    initial = turn.text,
    row = n.row,
    end_row = n.end_row,
    skip = virt_lines_at(buf, n.end_row),
    on_submit = function(text)
      local now = load(ctx.path)
      local i = find_line(now, e, {})
      if not i then return notify("the note moved in the notes file, nothing saved", vim.log.levels.WARN) end
      save(ctx.path, nf.set_turn(now, i, text, function(x)
        x.resolved, x.new = false, false
      end))
      M.refresh()
    end,
  })
end

--- Add a note for the cursor line, or the visual selection when called from
--- visual mode, in a small editor under the code. On a line that already has
--- a note (normal mode), reply to it or edit my latest text instead.
function M.add()
  local ctx = context()
  if not ctx or vim.bo.buftype ~= "" or vim.api.nvim_buf_get_name(0) == "" then
    vim.notify("review: not a file", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local first, last = vim.fn.line("."), vim.fn.line(".")
  local mode = vim.fn.mode()
  if mode == "n" then
    local row = first - 1
    local here = notes_on_row(buf, row)
    for _, n in ipairs(here) do
      if n.end_row == row then return reply(ctx, n.e, n) end
    end
    if here[1] then return reply(ctx, here[1].e, here[1]) end
  end
  if mode == "v" or mode == "V" or mode == "\22" then
    first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then first, last = last, first end
    vim.api.nvim_feedkeys(vim.keycode("<esc>"), "nx", false)
  end
  local rel = note_path(vim.api.nvim_buf_get_name(0), ctx.root)
  local loc = rel .. ":" .. first .. (last ~= first and ("-" .. last) or "")
  require("review_notes.compose").open({
    key = ctx.path .. "\0" .. loc,
    title = "Note at " .. loc,
    row = first - 1,
    end_row = last - 1,
    skip = virt_lines_at(buf, last - 1),
    on_submit = function(text)
      append(ctx.path, nf.new_entry_lines(loc, text))
      M.refresh()
    end,
  })
end

-- The note under the cursor and the index of its line in the notes file.
---@return review_notes.Entry?, integer?
local function entry_at_cursor(lines)
  local e = entry_on_cursor_row()
  local idx = e and find_line(lines, e, {})
  if not idx then
    vim.notify("review: no note on this line", vim.log.levels.INFO)
    return nil
  end
  return e, idx
end

--- Resolve the note under the cursor, or reopen it when it is resolved. For
--- remote threads the change is sent by `:Review push`.
function M.toggle_resolved()
  local ctx = context()
  if not ctx then return end
  local lines = load(ctx.path)
  local e, idx = entry_at_cursor(lines)
  if not e or not idx then return end
  save(ctx.path, nf.edit_entry(lines, idx, function(x)
    x.resolved, x.new = not x.resolved, false
  end))
  M.refresh()
  vim.notify(
    ("review: %s %s (<leader>rd again to undo)"):format(e.kind, e.resolved and "reopened" or "resolved"),
    vim.log.levels.INFO
  )
end

--- Toggle the note under the cursor between pending and approved. A pending
--- note carries the [draft] tag and is held back from push (the whole entry:
--- a thread's reply and resolve too); removing the tag approves it.
function M.toggle_pending()
  local ctx = context()
  if not ctx then return end
  local lines = load(ctx.path)
  local e, idx = entry_at_cursor(lines)
  if not e or not idx then return end
  save(ctx.path, nf.edit_entry(lines, idx, function(x) x.draft = not x.draft end))
  M.refresh()
  vim.notify(
    ("review: %s %s"):format(e.kind, e.draft and "approved, will be sent" or "pending, held back from push"),
    vim.log.levels.INFO
  )
end

--- Open the notes file in a split (for editing, reordering, the summary).
function M.open()
  local ctx = context()
  if not ctx then
    vim.notify("review: not in a git repository", vim.log.levels.WARN)
    return
  end
  vim.fn.mkdir(vim.fs.dirname(ctx.path), "p")
  vim.cmd("split " .. vim.fn.fnameescape(ctx.path))
  vim.bo.filetype = "reviewnotes"
  -- Locations are repo-relative; make gF/:cfile resolve them from the root.
  vim.cmd("lcd " .. vim.fn.fnameescape(ctx.root))
end

-- All notes of the review in file order, with 1-based lines: live positions for
-- open buffers (unsaved edits included), the notes file for the rest.
---@return { e: review_notes.Entry, file: string, line: integer, end_line: integer }[]
local function all_notes(ctx)
  local live = {} ---@type table<string, table>
  for buf, _ in pairs(shown) do
    if vim.api.nvim_buf_is_valid(buf) then
      for _, n in ipairs(live_notes(buf)) do
        live[n.e.path .. "\0" .. n.e.src] = n
      end
    end
  end
  local result = {}
  for _, e in ipairs(nf.parse(read_lines(ctx.path))) do
    local n = live[e.path .. "\0" .. e.src]
    table.insert(result, {
      e = e,
      file = full_path(e.path, ctx.root),
      line = n and n.row + 1 or e.line,
      end_line = n and n.end_row + 1 or (e.end_line or e.line),
    })
  end
  table.sort(result, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    return a.end_line < b.end_line
  end)
  return result
end

-- Open *n* (from all_notes) at its icon line and show its text.
local function goto_note(n)
  if vim.api.nvim_buf_get_name(0) ~= n.file then
    vim.cmd("edit " .. vim.fn.fnameescape(n.file))
  end
  vim.api.nvim_win_set_cursor(0, { math.min(n.end_line, vim.api.nvim_buf_line_count(0)), 0 })
  vim.cmd("normal! zz")
  show_cursor_notes()
end

---@class review_notes.Item
---@field text string searchable text: kind, state, path and the note ("new", "draft", "resolved", ...)
---@field file string absolute path
---@field line integer first line, 1-based
---@field end_line integer last line, where the icon is
---@field icon string
---@field hl string highlight of the icon
---@field summary string first line of the note
---@field summary_hl string
---@field note table the note, for `M.goto_item`

--- All notes of the review as picker items, across files, resolved included.
---@return review_notes.Item[]
function M.items()
  local ctx = context()
  if not ctx then return {} end
  local items = {}
  for _, n in ipairs(all_notes(ctx)) do
    local icon, hl = look(n.e)
    table.insert(items, {
      text = table.concat({
        n.e.kind,
        n.e.resolved and "resolved" or "open",
        n.e.new and "new" or "",
        n.e.draft and "draft" or "",
        n.e.path,
        n.e.text,
      }, " "),
      file = n.file,
      line = n.line,
      end_line = n.end_line,
      icon = icon,
      hl = hl,
      summary = n.e.text:match("^[^\n]*"),
      summary_hl = n.e.resolved and "ReviewResolved" or "ReviewText",
      note = n,
    })
  end
  return items
end

--- Open an item from `M.items()` at its icon line and show its text.
---@param item review_notes.Item
function M.goto_item(item) goto_note(item.note) end

-- Ask inside an async function; yields until answered.
---@return string?
local function choose(prompt, choices)
  local co = assert(coroutine.running())
  vim.ui.select(choices, { prompt = prompt }, function(choice)
    -- Resumed from the event loop, even if the UI answered synchronously.
    vim.schedule(function() coroutine.resume(co, choice) end)
  end)
  return coroutine.yield()
end

-- Pull inside an async function. Returns true when the notes are current.
local function pull(ctx, opts)
  local r = backend.run(M.config.backend, "threads", { root = ctx.root })
  if not r.ok then
    notify("pull failed: " .. backend.message(r), vim.log.levels.ERROR)
    return false
  end
  if type(r.json) ~= "table" then
    notify("pull failed: `threads` did not print a JSON list", vim.log.levels.ERROR)
    return false
  end
  local lines = load(ctx.path)
  local out, st = nf.merge(lines, r.json, opts)
  if st.added > 0 or st.updated > 0 then save(ctx.path, out) end
  M.refresh()
  if not (opts and opts.quiet) then
    notify(("pulled: %d new, %d added, %d updated"):format(st.new, st.added, st.updated))
  end
  return true
end

--- Bring the remote threads into the notes (remote wins).
function M.pull()
  local ctx = context()
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function() pull(ctx) end)
end

--- Send my notes, replies and resolved state, after confirming the plan. With
--- a `submit` command everything is queued first and published at the end; if
--- publishing fails the queue is discarded, so a retry cannot duplicate.
local function push(ctx, opts)
  local cmds = M.config.backend
  local lines = load(ctx.path)
  local plan = nf.plan(lines)
  local summary = nf.describe(plan)
  local skipped = plan.drafts > 0 and (" (%d draft%s not sent)"):format(plan.drafts, plan.drafts == 1 and "" or "s") or ""
  if not summary then
    if not (opts and opts.quiet_empty) then notify("nothing to send" .. skipped) end
    return true, false
  end
  if choose(summary .. skipped .. ". Send?", { "Send", "Cancel" }) ~= "Send" then return false, false end

  local ok = { new = {}, replies = {}, summary = false }
  local failures = {}
  local function fail(what, r) table.insert(failures, what .. ": " .. backend.message(r)) end

  for _, e in ipairs(plan.new) do
    -- A range is anchored at its last line, as on the remote.
    local last = e.end_line or e.line
    local r = backend.run(cmds, "add", { root = ctx.root, vars = { path = e.path, line = last }, stdin = e.send })
    if r.ok then ok.new[e] = true else fail(e.path .. ":" .. last, r) end
  end
  for _, e in ipairs(plan.replies) do
    local r = backend.run(cmds, "reply", { root = ctx.root, vars = { thread = e.id }, stdin = e.send })
    if r.ok then ok.replies[e] = true else fail("reply " .. e.path .. ":" .. e.line, r) end
  end
  if cmds.submit then
    local r = backend.run(cmds, "submit", { root = ctx.root, stdin = plan.summary })
    if r.ok then
      ok.summary = plan.summary ~= ""
    else
      fail("submit", r)
      if cmds.discard then backend.run(cmds, "discard", { root = ctx.root }) end
      ok.new, ok.replies = {}, {}
    end
  elseif plan.summary ~= "" then
    table.insert(failures, "the summary needs a `submit` command and stays in the notes")
  end

  -- After submit: publishing a queued reply reopens a resolved thread.
  for _, e in ipairs(plan.states) do
    local r = backend.run(cmds, e.resolved and "resolve" or "unresolve", { root = ctx.root, vars = { thread = e.id } })
    if not r.ok then fail((e.resolved and "resolve " or "reopen ") .. e.path .. ":" .. e.line, r) end
  end

  save(ctx.path, nf.apply_sent(load(ctx.path), plan, ok))
  -- What I just sent comes back from the remote as the thread's comments;
  -- quiet so it is not flagged as new.
  pull(ctx, { quiet = true })
  if #failures > 0 then
    notify("pushed with problems:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
  else
    notify("pushed: " .. summary)
  end
  return true, true
end

function M.push()
  local ctx = context()
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function() push(ctx) end)
end

--- Push, then pull: one key to send my side and bring the remote in. Pushing
--- first means the remote already has my resolves when its state comes back
--- (remote wins). Cancelling the push stops there. A push ends with a pull of
--- its own, so a separate one only runs when nothing was sent.
function M.sync()
  local ctx = context()
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function()
    local proceed, sent = push(ctx, { quiet_empty = true })
    if proceed and not sent then pull(ctx) end
  end)
end

--- Drop resolved entries that have nothing left to send.
function M.clean()
  local ctx = context()
  if not ctx then return end
  local out, n = nf.clean(load(ctx.path))
  if n > 0 then save(ctx.path, out) end
  M.refresh()
  notify(("removed %d resolved entries"):format(n))
end

local commands = {
  push = M.push,
  pull = M.pull,
  sync = M.sync,
  clean = M.clean,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local group = vim.api.nvim_create_augroup("ReviewNotes", { clear = true })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    callback = function(ev)
      local ctx = context()
      if not ctx then return end
      local lines = read_lines(ctx.path)
      to_send[ctx.root] = count_to_send(lines)
      refresh_buffer(ev.buf, nf.parse(lines), ctx.root)
    end,
  })
  -- Saving a source file writes the notes' new positions back to the notes
  -- file; saving the notes file (or pi/git-lab changing it) updates the signs.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local ctx = context()
      if ctx then sync(ev.buf, ctx) end
      M.refresh()
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function() M.refresh() end,
  })
  vim.api.nvim_create_autocmd({ "CursorMoved", "ModeChanged", "BufEnter" }, {
    group = group,
    callback = show_cursor_notes,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(ev)
      if shown[ev.buf] and #shown[ev.buf] > 0 then draw_signs(ev.buf) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(ev)
      shown[ev.buf], roots[ev.buf] = nil, nil
    end,
  })
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

  -- Keymaps are defined by the caller (see lua/plugins/review_notes.lua).

  -- Remote operations happen once per review round: a command, not keys.
  vim.api.nvim_create_user_command("Review", function(opts)
    local fn = commands[opts.args]
    if not fn then
      vim.notify("review: usage :Review sync|push|pull|clean", vim.log.levels.WARN)
      return
    end
    fn()
  end, {
    nargs = 1,
    desc = "Review notes: sync (pull then push), push (confirms), pull (remote threads), clean (drop resolved)",
    complete = function(lead)
      return vim.tbl_filter(function(c) return vim.startswith(c, lead) end, vim.tbl_keys(commands))
    end,
  })
end

return M
