-- Pending review notes, kept outside the code (format: see notes.lua): for a
-- file in a git worktree in `.git/review/<branch>.txt`, one review per branch;
-- for any other file in a sibling `<file>.notes`, one review per file, local
-- only (no backend). Notes are written while reviewing, shown with their
-- own signs (deliberately not vim.diagnostic, so they never mix with LSP
-- problems in ]d, pickers or counts), and synced with the remote through the
-- configured backend commands (see M.config): pull brings the remote threads
-- in (remote wins), push pulls, then sends my notes, replies and resolved
-- state, holding back what the pull flagged [new].
--
-- Line numbers in the file refer to the files as saved on disk. While a buffer
-- is edited, each note follows its code through an extmark; on save the new
-- positions are written back to the notes file.
local nf = require("review_notes.notes")
local backend = require("review_notes.backend")

local M = {}

---@class review_notes.Config
---@field watch boolean refresh when a shown notes file changes on disk
---@field backend table<string, string[]> Command lines, run in the repo root.
---  `{path}`, `{line}`, `{thread}` and `{ids}` are substituted; text goes on stdin.
---    threads    prints [{id, path, line, resolved, comments = [{author, body}]}]
---    threads lists general threads (on the whole change) with path = null;
---               line (and start_line, multi-line) are lines of the files on disk.
---               Optional: comments[].mine (my own, so they never flag a
---               thread) and resolved_by, resolved_by_me (a resolve by
---               someone else flags the thread)
---    add        starts a thread at {path}:{line}, text on stdin
---    general    starts a thread on the whole change, text on stdin
---    reply      replies to {thread}, text on stdin
---               add, general, reply print {id} (with submit: the queued draft)
---    resolve, unresolve  change the state of {thread}
---    submit     optional: publishes what add/general/reply queued: {ids}, the
---               comma-separated ids they printed, so drafts queued elsewhere
---               (a review started in the browser) stay pending; may print
---               {published = [ids]}, also when it fails part way
---    discard    optional: drops the queued {ids} that submit did not publish
M.config = {
  -- Watch the notes files shown, to follow changes made by pi or git-lab.
  watch = true,
  backend = {
    threads = { "git-lab", "comment", "list", "--json" },
    add = { "git-lab", "comment", "add", "--draft", "--json", "{path}:{line}", "-" },
    reply = { "git-lab", "comment", "reply", "--draft", "--json", "{thread}", "-" },
    resolve = { "git-lab", "comment", "resolve", "{thread}" },
    unresolve = { "git-lab", "comment", "unresolve", "{thread}" },
    general = { "git-lab", "comment", "add", "--draft", "--json", "-" },
    submit = { "git-lab", "review", "submit", "--only", "{ids}", "--json" },
    discard = { "git-lab", "review", "discard", "--only", "{ids}" },
  },
}

local ns = vim.api.nvim_create_namespace("review_notes")
local ns_signs = vim.api.nvim_create_namespace("review_notes_signs")

-- Nerd Font icons: comment, comment-discussion, pencil (draft), bell (new),
-- upload (things a push would send), check (resolved).
---@type table<string, { icon: string, hl: string }>
M.style = {
  note = { icon = "\u{ea6b}", hl = "ReviewNote" },
  thread = { icon = "\u{eac7}", hl = "ReviewThread" },
  draft = { icon = "\u{ea73}", hl = "ReviewDraft" },
  new = { icon = "\u{f0f3}", hl = "ReviewNew" },
  send = { icon = "\u{f093}", hl = "ReviewSend" },
  resolved = { icon = "\u{f00c}", hl = "ReviewResolved" },
}

---@class review_notes.Context
---@field kind "git"|"file"
---@field root string repo root, or the file's directory
---@field path string the notes file

-- What a push would send, per notes file, and the context of each file
-- buffer, for the statusline (which must not run git on every redraw).
local to_send = {} ---@type table<string, integer>
-- Entries waiting for me per notes file, to notify when that grows.
local waiting = {} ---@type table<string, integer>
local contexts = {} ---@type table<integer, review_notes.Context>
-- Open entries per state, per notes file: the whole review, for the statusline.
local counts = {} ---@type table<string, table<string, integer>>
-- The review of the last reviewed buffer seen by `status()`, shown while the
-- current buffer is not one (a picker, a terminal).
local last_ctx ---@type review_notes.Context?

local function count_to_send(lines)
  local plan = nf.plan(lines)
  return #plan.new + #plan.replies + #plan.states
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

-- The review of the repo with worktree *root*: its branch's notes file.
---@return review_notes.Context?
local function git_context(root)
  local gitdir = git({ "rev-parse", "--path-format=absolute", "--git-path", "review" }, root)
  if not gitdir then return nil end
  local branch = git({ "branch", "--show-current" }, root)
  -- Mid-rebase HEAD is detached; keep showing the rebased branch's notes.
  for _, dir in ipairs({ "rebase-merge", "rebase-apply" }) do
    if branch and branch ~= "" then break end
    local head = git({ "rev-parse", "--path-format=absolute", "--git-path", dir .. "/head-name" }, root)
    local lines = head and vim.fn.filereadable(head) == 1 and vim.fn.readfile(head) or {}
    branch = lines[1] and lines[1]:gsub("^refs/heads/", "") or nil
  end
  if not branch or branch == "" then branch = "HEAD" end
  return { kind = "git", root = root, path = gitdir .. "/" .. branch .. ".txt" }
end

-- Context of the repo containing *dir*, memoised per root in *memo* (one
-- refresh walks every buffer). vim.fs.root finds the worktree without a
-- process, so files outside git cost nothing; a submodule has its own root.
---@return review_notes.Context?
local function repo_context(dir, memo)
  local root = vim.fn.isdirectory(dir) == 1 and vim.fs.root(dir, ".git") or nil
  if not root then return nil end
  if memo[root] == nil then memo[root] = git_context(root) or false end
  return memo[root] or nil
end

-- The review a buffer belongs to: a file in a git worktree is in its
-- branch's review, any other file has its own, in `<file>.notes` next to it.
-- A notes file belongs to its document's review; other buffers (pickers,
-- terminals, the branch notes file inside .git) to the cwd's repo, if any.
---@param buf integer? defaults to the current buffer
---@param memo table? cache shared by the calls of one refresh
---@return review_notes.Context?
local function context(buf, memo)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  memo = memo or {}
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" or name:find("/.git/", 1, true) then
    return repo_context(vim.fn.getcwd(), memo)
  end
  local dir = vim.fs.dirname(name)
  if name:match("%.notes$") then return { kind = "file", root = dir, path = name } end
  return repo_context(dir, memo) or { kind = "file", root = dir, path = name .. ".notes" }
end

-- The review that remote commands act on: the current buffer's when it is a
-- branch review, else the cwd's repo (e.g. `:Review sync` from a file outside git).
---@return review_notes.Context?
local function remote_context()
  local ctx = context()
  if ctx and ctx.kind == "git" then return ctx end
  ctx = repo_context(vim.fn.getcwd(), {})
  if not ctx then notify("local review (no git repository): nothing to sync") end
  return ctx
end

-- A file whose notes this buffer shows (not a notes file itself).
local function is_reviewed(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ""
    and name ~= ""
    and not name:match("%.notes$")
    and not name:find("/.git/", 1, true)
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
  -- A sibling `.notes` file with nothing left is removed, so reviewing
  -- documents does not litter directories. Branch files live in .git.
  if path:match("%.notes$") and not vim.iter(lines):any(function(l) return l:match("%S") end) then
    local buf = notes_buf(path)
    if buf then vim.api.nvim_buf_delete(buf, { force = true }) end
    vim.fn.delete(path)
    return
  end
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  local buf = notes_buf(path)
  if buf then
    vim.api.nvim_buf_call(buf, function() vim.cmd("silent! noautocmd edit") end)
  end
end

-- Path of *name* as written in the notes file: relative to the review's root
-- (the worktree, or the directory of a file outside git).
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

-- A draft waiting for my approval: open, or resolved with a reply or a
-- resolve still to send (how pi hands back a thread it handled).
local function awaits_approval(e) return e.draft and (not e.resolved or nf.has_changes(e)) end

-- What an entry needs from me, most urgent first: something someone else
-- changed (new, even if resolved: pi resolving a note is a claim to check),
-- a draft to approve, else just its kind.
local function state(e)
  if e.new then return "new" end
  if awaits_approval(e) then return "draft" end
  if e.resolved then return "resolved" end
  return e.kind
end

-- Tags worth showing next to the icon, which shows only the most urgent.
local function badges(e)
  local out = {}
  if e.new then table.insert(out, "new") end
  if e.draft then table.insert(out, "draft") end
  if e.resolved then table.insert(out, "resolved") end
  if e.id and nf.has_changes(e) and not e.draft then table.insert(out, "unsent") end
  return out
end

-- Needs my attention: changed by someone else, whoever that is.
local function wants_me(e) return e.new end

-- Icon and highlight for an entry: resolved entries are dimmed, the ones
-- waiting for me stand out, drafts are marked.
local function look(e)
  local s = state(e)
  return M.style[s].icon, M.style[s].hl
end

-- Gutter signs from the live positions, redrawn on every change so a range
-- stays continuous when lines are inserted inside it.
local function draw_signs(buf)
  vim.api.nvim_buf_clear_namespace(buf, ns_signs, 0, -1)
  for _, n in ipairs(live_notes(buf)) do
    local icon, hl = look(n.e)
    -- A range reads like GitLab: a bar down the lines, the icon on the
    -- last one. The sign yields to
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

---@param ctx review_notes.Context
local function refresh_buffer(buf, entries, ctx)
  if not is_reviewed(buf) then return end
  local name = vim.api.nvim_buf_get_name(buf)
  contexts[buf] = ctx
  local rel = note_path(name, ctx.root)
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
        -- Line 0 (the whole file) shows on the first line.
        first = math.max(1, math.min(e.line, last)) - 1
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
  if e.general then
    -- No location to go by: the head line as read.
    for i, line in ipairs(lines) do
      if line == e.raw and not used[i] then return i end
    end
    return nil
  end
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
    -- A note on the whole file stays at line 0 wherever its sign moves.
    local idx = r and e.line > 0 and find_line(lines, e, used)
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
end

--- Statusline component for the review of the current buffer: open entries
--- per state across all its files, then the number of things `:Review push`
--- would send. Outside git every file has its own notes, so it adds up the
--- files opened. Reads cached counts only: safe to call on every redraw.
function M.status()
  local ctx = contexts[vim.api.nvim_get_current_buf()]
  if ctx then last_ctx = ctx end
  ctx = ctx or last_ctx
  if not ctx then return "" end
  local total, send = {}, 0
  if ctx.kind == "git" then
    total, send = counts[ctx.path] or {}, to_send[ctx.path] or 0
  else
    local seen = {}
    for buf, c in pairs(contexts) do
      if c.kind == "file" and not seen[c.path] and vim.api.nvim_buf_is_loaded(buf) then
        seen[c.path] = true
        for kind, n in pairs(counts[c.path] or {}) do total[kind] = (total[kind] or 0) + n end
      end
    end
  end
  local parts = {}
  for _, kind in ipairs({ "new", "note", "thread", "draft" }) do
    if total[kind] then
      local style = M.style[kind]
      table.insert(parts, "%#" .. style.hl .. "#" .. style.icon .. " " .. total[kind])
    end
  end
  if send > 0 then
    table.insert(parts, "%#" .. M.style.send.hl .. "#" .. M.style.send.icon .. " " .. send)
  end
  return table.concat(parts, " ")
end

-- Notes files are written by other processes (pi, git-lab): watch the ones
-- shown, so the signs follow without waiting for focus. Watching the
-- directory also catches files that are replaced (written by rename) or
-- created after the buffer was opened (a first `.notes`).
local watchers = {} ---@type table<string, uv.uv_fs_event_t>
local pending = {} ---@type table<string, boolean>

local function on_notes_changed(path)
  if pending[path] then return end
  pending[path] = true
  -- Writers touch the file more than once; settle first.
  vim.defer_fn(function()
    pending[path] = nil
    local before = waiting[path] or 0
    M.refresh()
    local now = waiting[path] or 0
    if now > before then
      notify(("%s: %d note%s waiting for you"):format(
        vim.fs.basename(path), now, now == 1 and "" or "s"))
    end
  end, 150)
end

local function watch(path)
  local dir = vim.fs.dirname(path)
  if watchers[path] or vim.fn.isdirectory(dir) == 0 then return end
  local w = vim.uv.new_fs_event()
  if not w then return end
  local name = vim.fs.basename(path)
  local ok = w:start(dir, {}, function(err, file)
    if not err and (file == nil or file == name) then vim.schedule(function() on_notes_changed(path) end) end
  end)
  if ok then watchers[path] = w else w:close() end
end

-- Read *ctx*'s notes file (once per refresh, through *cache*).
local function entries_of(ctx, cache)
  if not cache[ctx.path] then
    local lines = read_lines(ctx.path)
    if ctx.kind == "git" then to_send[ctx.path] = count_to_send(lines) end
    cache[ctx.path] = nf.parse(lines)
    waiting[ctx.path] = #vim.tbl_filter(wants_me, cache[ctx.path])
    local n = {}
    for _, e in ipairs(cache[ctx.path]) do
      -- Resolved entries are done, unless pi resolved them and I have not looked.
      local st = state(e)
      if st ~= "resolved" then n[st] = (n[st] or 0) + 1 end
      -- Drafts are counted even when [new] wins the icon: each one waits for me.
      if st ~= "draft" and awaits_approval(e) then n.draft = (n.draft or 0) + 1 end
    end
    counts[ctx.path] = n
    if M.config.watch then watch(ctx.path) end
  end
  return cache[ctx.path]
end

local function refresh_one(buf, memo, cache)
  local ctx = context(buf, memo)
  if ctx then
    refresh_buffer(buf, entries_of(ctx, cache), ctx)
  elseif shown[buf] then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    shown[buf], contexts[buf] = nil, nil
    draw_signs(buf)
  end
end

local refresh_note -- the note float, defined with it below

--- Re-read the notes files and update the signs in all loaded buffers, each
--- from its own review (a branch's, or a file's sibling notes).
function M.refresh()
  local memo, cache = {}, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_reviewed(buf) then refresh_one(buf, memo, cache) end
  end
  refresh_note()
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

local resolve_at, pending_at, read_at -- defined below, used by the note keys
local open_note, all_notes, goto_note

--- Keys inside the note float (buffer-local, normal mode).
M.keys = {
  resolve = "<localleader>x",
  draft = "<localleader>p",
  read = "<localleader>r",
  delete = "<localleader>d",
  next = "]n",
  prev = "[n",
  code = "gd",
}

-- The code window a note float was opened from: navigation moves it along.
local origin ---@type integer?
-- Open note buffers by entry, and what each one shows.
local note_bufs = {} ---@type table<string, integer>
---@class review_notes.OpenNote
---@field ctx review_notes.Context
---@field ref { loc: string, id: string?, head: string?, fresh: boolean? }
---@field key string
local open_by_buf = {} ---@type table<integer, review_notes.OpenNote>

-- Where an entry lives across rewrites of the notes file: a thread by id, a
-- note by path and head (its line moves with the code).
local function ref_of(e) return { loc = e.loc, id = e.id, head = e.head } end

local function is_ref(e, ref)
  if ref.fresh then return false end
  if ref.id then return e.id == ref.id end
  if e.id or e.head ~= ref.head then return false end
  if not ref.loc then return e.general end
  return e.path == ref.loc:match("^(.*):[%d-]+$")
end

-- The entry *ref* in *lines*; among notes with the same text, the one still
-- at the same location.
local function find_ref(lines, ref)
  local found
  for _, e in ipairs(nf.parse(lines)) do
    if is_ref(e, ref) then
      if ref.id or e.loc == ref.loc then return e end
      found = found or e
    end
  end
  return found
end

local function ref_key(ctx, ref)
  local loc = ref.loc or ""
  return ctx.path .. "\0" .. (ref.fresh and ("new\0" .. loc) or ref.id or (loc .. "\0" .. (ref.head or "")))
end

-- The conversation and my latest turn of *e* (see notes.turn).
local function views(lines, e)
  local t = nf.turn(lines, e.src)
  return nf.thread_view(lines, e.src), t and t.text or {}
end

local function where(loc)
  if not loc then return "whole change" end
  if loc:match(":0$") then return loc:sub(1, -3) .. " (whole file)" end
  return loc
end

local function note_title(e, ref)
  if not e then return (ref.fresh and "New note on " or "Gone: ") .. where(ref.loc) end
  local tags = badges(e)
  local who = e.head:match("^@[%w._-]+")
  return where(e.loc) .. (who and ("  " .. who) or "") .. (#tags > 0 and ("  [" .. table.concat(tags, ", ") .. "]") or "")
end

-- Save my turn from the float. A new note becomes an entry; on a note it
-- replaces my latest text, which reopens it and clears [new]: I have acted.
local function write_note(cur, text, buf)
  local ctx = cur.ctx
  if cur.ref.fresh then
    if #text == 0 then
      notify("empty note, nothing saved")
      return false
    end
    save(ctx.path, nf.add_entry(load(ctx.path), nf.new_entry_lines(cur.ref.loc, text), not cur.ref.loc))
    cur.ref = { loc = cur.ref.loc, head = text[1] }
  else
    local now = load(ctx.path)
    local e = find_ref(now, cur.ref)
    if not e then
      notify("the note is gone from the notes file, nothing saved", vim.log.levels.WARN)
      return false
    end
    local t = nf.turn(now, e.src)
    if t and t.whole and #text == 0 then
      notify("empty note, nothing saved (" .. M.keys.delete .. " deletes it)")
      return false
    end
    save(ctx.path, nf.set_turn(now, e.src, text, #text > 0 and function(x)
      x.resolved, x.new = false, false
    end or nil))
    if t and t.whole then cur.ref.head = text[1] end
  end
  local key = ref_key(ctx, cur.ref)
  if key ~= cur.key then
    if note_bufs[cur.key] == buf then note_bufs[cur.key] = nil end
    cur.key, note_bufs[key] = key, buf
  end
  vim.bo[buf].modified = false
  M.refresh()
  return true
end

-- Run *fn* on the entry the float shows, as it is in the file now.
local function on_entry(cur, fn)
  if cur.ref.fresh then return notify("save the note first (:w)") end
  local now = load(cur.ctx.path)
  local e = find_ref(now, cur.ref)
  if not e then return notify("the note is gone from the notes file", vim.log.levels.WARN) end
  fn(cur.ctx, now, e.src, e)
end

local function close_note(buf)
  require("review_notes.note").close()
  if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
end

-- The next (dir 1) or previous note of the review after the one shown, its
-- code shown in the window the float came from.
local function step(cur, dir)
  local list = all_notes(cur.ctx)
  if #list == 0 then return end
  local at
  for i, n in ipairs(list) do
    if is_ref(n.e, cur.ref) then at = i end
  end
  local n = list[at and ((at - 1 + dir) % #list) + 1 or (dir > 0 and 1 or #list)]
  if not n.dir and origin and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_win_call(origin, function() goto_note(n) end)
  end
  open_note(n.ctx, ref_of(n.e))
end

local function note_actions(cur)
  return {
    { key = M.keys.resolve, desc = "resolve", run = function() on_entry(cur, resolve_at) end },
    { key = M.keys.draft, desc = "draft", run = function() on_entry(cur, pending_at) end },
    { key = M.keys.read, desc = "read", run = function() on_entry(cur, read_at) end },
    {
      key = M.keys.delete,
      desc = "delete",
      run = function(buf)
        if cur.ref.fresh then return close_note(buf) end
        on_entry(cur, function(ctx, lines, idx, e)
          if e.id then return notify("a remote thread cannot be deleted: resolve it") end
          save(ctx.path, nf.delete_entry(lines, idx))
          close_note(buf)
          M.refresh()
          notify("note deleted")
        end)
      end,
    },
    { key = M.keys.next, desc = "next", run = function() step(cur, 1) end },
    { key = M.keys.prev, desc = "prev", run = function() step(cur, -1) end },
    {
      key = M.keys.code,
      desc = "code",
      run = function()
        local list = all_notes(cur.ctx)
        require("review_notes.note").close()
        if origin and vim.api.nvim_win_is_valid(origin) then vim.api.nvim_set_current_win(origin) end
        for _, n in ipairs(list) do
          if is_ref(n.e, cur.ref) then return goto_note(n) end
        end
      end,
    },
  }
end

-- Show the note *ref* of *ctx* in the float: an entry of the notes file, or
-- with `ref.fresh` a new note at `ref.loc`.
open_note = function(ctx, ref)
  local lines = load(ctx.path)
  local e = find_ref(lines, ref)
  if not ref.fresh and not e then return notify("the note is gone from the notes file", vim.log.levels.WARN) end
  local cur = { ctx = ctx, ref = ref, key = ref_key(ctx, ref) }
  local conversation, reply_lines = {}, {}
  if e then conversation, reply_lines = views(lines, e) end
  local buf = note_bufs[cur.key]
  if buf and open_by_buf[buf] then cur = open_by_buf[buf] end
  buf = require("review_notes.note").show({
    buf = buf,
    name = (e and e.loc or ref.loc or "general"),
    title = function() return note_title(find_ref(read_lines(cur.ctx.path), cur.ref), cur.ref) end,
    conversation = conversation,
    reply = reply_lines,
    insert = ref.fresh,
    actions = note_actions(cur),
    on_write = function(text, b) return write_note(cur, text, b) end,
    on_wipe = function(b)
      if note_bufs[cur.key] == b then note_bufs[cur.key] = nil end
      open_by_buf[b] = nil
    end,
  })
  note_bufs[cur.key], open_by_buf[buf] = buf, cur
end

-- Follow the notes file in the float (pi, a pull, an action).
refresh_note = function()
  local note = require("review_notes.note")
  local buf = note.current()
  local cur = buf and open_by_buf[buf]
  if not cur then return end
  local lines = read_lines(cur.ctx.path)
  local e = find_ref(lines, cur.ref)
  if e then
    note.update(buf, views(lines, e))
  else
    note.retitle(buf)
  end
end

local function remember_origin()
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(win).relative == "" then origin = win end
end

--- Open the note on the cursor line in the note float, or start a new one on
--- the line (or the visual selection, from visual mode).
function M.add()
  local ctx = context()
  if not ctx or not is_reviewed(vim.api.nvim_get_current_buf()) then
    vim.notify("review: not a file", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  remember_origin()
  local first, last = vim.fn.line("."), vim.fn.line(".")
  local mode = vim.fn.mode()
  if mode == "n" then
    local row = first - 1
    local here = notes_on_row(buf, row)
    for _, n in ipairs(here) do
      if n.end_row == row then return open_note(ctx, ref_of(n.e)) end
    end
    if here[1] then return open_note(ctx, ref_of(here[1].e)) end
  end
  if mode == "v" or mode == "V" or mode == "\22" then
    first, last = vim.fn.line("v"), vim.fn.line(".")
    if first > last then first, last = last, first end
    vim.api.nvim_feedkeys(vim.keycode("<esc>"), "nx", false)
  end
  local rel = note_path(vim.api.nvim_buf_get_name(0), ctx.root)
  open_note(ctx, { loc = rel .. ":" .. first .. (last ~= first and ("-" .. last) or ""), fresh = true })
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

-- Resolve the entry at *idx*, or reopen it when it is resolved. For remote
-- threads the change is sent by `:Review push`.
resolve_at = function(ctx, lines, idx, e)
  -- Resolved by someone else (pi, the remote) and not seen yet: the first
  -- toggle accepts it as it is.
  local accept = e.resolved and e.new
  save(ctx.path, nf.edit_entry(lines, idx, function(x)
    if accept then
      x.new = false
    else
      x.resolved, x.new = not x.resolved, false
    end
  end))
  M.refresh()
  local what = accept and "accepted (stays resolved)" or e.resolved and "reopened" or "resolved"
  vim.notify(("review: %s %s"):format(e.kind, what), vim.log.levels.INFO)
end

-- A pending entry carries the [draft] tag and is held back from push (the
-- whole entry: a thread's reply and resolve too); removing the tag approves it.
pending_at = function(ctx, lines, idx, e)
  save(ctx.path, nf.edit_entry(lines, idx, function(x) x.draft = not x.draft end))
  M.refresh()
  vim.notify(
    ("review: %s %s"):format(e.kind, e.draft and "approved, will be sent" or "pending, held back from push"),
    vim.log.levels.INFO
  )
end

-- Clear [new] without replying or resolving: read, nothing to say.
read_at = function(ctx, lines, idx, e)
  if not e.new then return notify(e.kind .. " is not new") end
  save(ctx.path, nf.edit_entry(lines, idx, function(x) x.new = false end))
  M.refresh()
  vim.notify(("review: %s marked as read"):format(e.kind), vim.log.levels.INFO)
end

--- Resolve the note under the cursor, or reopen it when it is resolved.
function M.toggle_resolved()
  local ctx = context()
  if not ctx then return end
  local lines = load(ctx.path)
  local e, idx = entry_at_cursor(lines)
  if e and idx then resolve_at(ctx, lines, idx, e) end
end

--- Toggle the note under the cursor between pending and approved.
function M.toggle_pending()
  local ctx = context()
  if not ctx then return end
  local lines = load(ctx.path)
  local e, idx = entry_at_cursor(lines)
  if e and idx then pending_at(ctx, lines, idx, e) end
end

-- Show *ctx*'s notes file in a split, or go to its window when it is shown.
local function open_notes(ctx)
  local win = vim.fn.bufwinid(ctx.path)
  if win ~= -1 then return vim.api.nvim_set_current_win(win) end
  vim.fn.mkdir(vim.fs.dirname(ctx.path), "p")
  vim.cmd("split " .. vim.fn.fnameescape(ctx.path))
  vim.bo.filetype = "reviewnotes"
  -- Locations are repo-relative; make gF/:cfile resolve them from the root.
  vim.cmd("lcd " .. vim.fn.fnameescape(ctx.root))
end

--- Open the notes file in a split (for editing by hand).
function M.open()
  local ctx = context()
  if not ctx then
    vim.notify("review: no review here (not a file, not in a git repository)", vim.log.levels.WARN)
    return
  end
  open_notes(ctx)
end

--- Start a note on the whole change (a general note, a GitLab overview
--- thread), or with *file* on the whole current file (`path:0`), in the note
--- float.
---@param file boolean?
function M.add_general(file)
  local ctx = context()
  if not ctx then
    vim.notify("review: no review here (not a file, not in a git repository)", vim.log.levels.WARN)
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  if file and not is_reviewed(buf) then
    vim.notify("review: not a file", vim.log.levels.WARN)
    return
  end
  remember_origin()
  open_note(ctx, { loc = file and (note_path(vim.api.nvim_buf_get_name(buf), ctx.root) .. ":0") or nil, fresh = true })
end

-- All notes of the review in file order, with 1-based lines: live positions for
-- open buffers (unsaved edits included), the notes file for the rest. General
-- notes come first; `dir` marks the ones without code (general, on a
-- directory such as a submodule), which only live in the notes file.
---@return { e: review_notes.Entry, file: string, line: integer, end_line: integer, dir: boolean, ctx: review_notes.Context }[]
all_notes = function(ctx)
  local live = {} ---@type table<string, table>
  for buf, _ in pairs(shown) do
    -- Only buffers of this review: src indices of other notes files collide.
    if vim.api.nvim_buf_is_valid(buf) and contexts[buf] and contexts[buf].path == ctx.path then
      for _, n in ipairs(live_notes(buf)) do
        live[n.e.path .. "\0" .. n.e.src] = n
      end
    end
  end
  local result = {}
  for _, e in ipairs(nf.parse(read_lines(ctx.path))) do
    if e.general then
      -- Its place is the notes file (a picker previews it there).
      table.insert(result, { e = e, file = ctx.path, line = e.src, end_line = e.src, dir = true, ctx = ctx })
    else
      local n = live[e.path .. "\0" .. e.src]
      local file = full_path(e.path, ctx.root)
      table.insert(result, {
        e = e,
        file = file,
        line = n and n.row + 1 or e.line,
        end_line = n and n.end_row + 1 or (e.end_line or e.line),
        dir = vim.fn.isdirectory(file) == 1,
        ctx = ctx,
      })
    end
  end
  table.sort(result, function(a, b)
    if a.e.general ~= b.e.general then return a.e.general end
    if a.file ~= b.file then return a.file < b.file end
    return a.end_line < b.end_line
  end)
  return result
end

-- Open *n* (from all_notes) at its icon line; a note on a
-- directory has no code, so it opens at its entry in the notes file.
goto_note = function(n)
  if n.dir then
    open_notes(n.ctx)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local idx = find_line(lines, n.e, {})
    if idx then vim.api.nvim_win_set_cursor(0, { idx, 0 }) end
    return
  end
  if vim.api.nvim_buf_get_name(0) ~= n.file then
    vim.cmd("edit " .. vim.fn.fnameescape(n.file))
  end
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(n.end_line, vim.api.nvim_buf_line_count(0))), 0 })
  vim.cmd("normal! zz")
end

--- Jump to the next (dir = 1) or previous (dir = -1) [new] note (changed by
--- someone else: pi, the remote) across the files of
--- the review, wrapping around: the way through a round of answers.
function M.jump_new(dir)
  local ctx = context()
  if not ctx then return end
  local list = vim.tbl_filter(function(n) return wants_me(n.e) end, all_notes(ctx))
  if #list == 0 then return notify("nothing new in this review") end
  -- The cursor's place in the order of all_notes: in the notes file, among
  -- the general notes; in a file, by path and line.
  local here = { file = vim.api.nvim_buf_get_name(0), line = vim.fn.line(".") }
  here.general = here.file == ctx.path
  local function cmp(n)
    if n.e.general ~= here.general then return n.e.general and -1 or 1 end
    if n.file ~= here.file then return n.file < here.file and -1 or 1 end
    return n.end_line < here.line and -1 or (n.end_line > here.line and 1 or 0)
  end
  local function after(n) return cmp(n) > 0 end
  local function before(n) return cmp(n) < 0 end
  local target
  if dir > 0 then
    for _, n in ipairs(list) do
      if after(n) then
        target = n
        break
      end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      if before(list[i]) then
        target = list[i]
        break
      end
    end
    target = target or list[#list]
  end
  goto_note(target)
  local count = #list
  vim.api.nvim_echo({ { ("review: %d waiting for you"):format(count), "ReviewNew" } }, false, {})
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
---@field tags string[] states beyond the icon, in order: "new", "draft", "resolved", "unsent"
---@field general boolean about the whole change: `file` is the notes file, `line` the entry
---@field thread string[] the whole conversation as markdown lines, for a preview
---@field note table the note, for `M.goto_item`

--- All notes of the review as picker items, across files, resolved included:
--- the branch's review for a file in git, the file's own for any other file.
---@param buf integer? whose review (default: the current buffer)
---@return review_notes.Item[]
function M.items(buf)
  local ctx = context(buf)
  if not ctx then return {} end
  local items = {}
  for _, n in ipairs(all_notes(ctx)) do
    local icon, hl = look(n.e)
    local tags = badges(n.e)
    table.insert(items, {
      text = table.concat({
        n.e.kind,
        n.e.resolved and "resolved" or "open",
        table.concat(tags, " "),
        n.e.path or "general",
        n.e.text,
      }, " "),
      tags = tags,
      file = n.file,
      line = n.line,
      end_line = n.end_line,
      icon = icon,
      hl = hl,
      summary = n.e.text:match("^[^\n]*"),
      thread = nf.entry_view(n.e),
      general = n.e.general,
      -- Dimmed only when done: a resolved entry with something to send is not.
      summary_hl = n.e.resolved and not nf.has_changes(n.e) and "ReviewResolved" or "ReviewText",
      note = n,
    })
  end
  return items
end

--- Go to the code of an item from `M.items()` (a note without code: its
--- entry in the notes file).
---@param item review_notes.Item
function M.goto_item(item) goto_note(item.note) end

--- Open an item from `M.items()` in the note float, its code in the current
--- window.
---@param item review_notes.Item
function M.open_item(item)
  local n = item.note
  if not n.dir then goto_note(n) end
  remember_origin()
  open_note(n.ctx, ref_of(n.e))
end

--- Run a note action on an item from `M.items()`: "resolve" (resolve/reopen),
--- "draft" (toggle) or "read" (clear [new]).
---@param item review_notes.Item
---@param action "resolve"|"draft"|"read"
function M.item_action(item, action)
  local n = item.note
  local fn = ({ resolve = resolve_at, draft = pending_at, read = read_at })[action]
  on_entry({ ctx = n.ctx, ref = ref_of(n.e) }, assert(fn, "unknown action"))
end

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
  if st.added > 0 or st.updated > 0 or st.removed > 0 then save(ctx.path, out) end
  M.refresh()
  local changed = st.new > 0 or st.added > 0 or st.updated > 0 or st.removed > 0
  if not (opts and opts.quiet) and (changed or not (opts and opts.brief)) then
    local msg = ("pulled: %d new, %d added, %d updated"):format(st.new, st.added, st.updated)
    if st.removed > 0 then msg = msg .. (", %d gone from the remote"):format(st.removed) end
    notify(msg)
  end
  if st.gone > 0 then
    notify(("%d thread%s gone from the remote still hold%s unsent text of mine"):format(
      st.gone, st.gone == 1 and "" or "s", st.gone == 1 and "s" or ""), vim.log.levels.WARN)
  end
  return true
end

--- Bring the remote threads into the notes (remote wins).
function M.pull()
  local ctx = remote_context()
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function() pull(ctx) end)
end

-- Publish the queued drafts *ids*. Returns the set of ids published and an
-- error result, if any; what was not published is discarded, so a retry
-- cannot duplicate.
local function submit(ctx, ids)
  local cmds = M.config.backend
  local vars = { ids = table.concat(ids, ",") }
  local r = backend.run(cmds, "submit", { root = ctx.root, vars = vars })
  local published = {}
  local listed = type(r.json) == "table" and type(r.json.published) == "table"
  for _, id in ipairs(listed and r.json.published or (r.ok and ids or {})) do
    published[tostring(id)] = true
  end
  local left = vim.tbl_filter(function(id) return not published[id] end, ids)
  if #left > 0 and cmds.discard then
    backend.run(cmds, "discard", { root = ctx.root, vars = { ids = table.concat(left, ",") } })
  end
  return published, not r.ok and r or nil
end

--- Pull, then send my notes, replies and resolved state, after confirming the
--- plan. The pull first brings in what changed on the remote since the last
--- one (flagged [new], which holds those entries back), so nothing is sent
--- over a reply I have not read. With a `submit` command everything is queued
--- first and published at the end, only the drafts queued here.
local function push(ctx, opts)
  local cmds = M.config.backend
  if not pull(ctx, opts and opts.pull) then return false, false end
  local lines = load(ctx.path)
  local plan = nf.plan(lines)
  local summary = nf.describe(plan)
  local skipped = nf.describe_skipped(plan)
  if not summary then
    if not (opts and opts.quiet_empty) or plan.held > 0 then notify("nothing to send" .. skipped) end
    return true, false
  end
  if choose(summary .. skipped .. ". Send?", { "Send", "Cancel" }) ~= "Send" then return false, false end

  local ok = { new = {}, replies = {} }
  local failures = {}
  local function fail(what, r) table.insert(failures, what .. ": " .. backend.message(r)) end
  local function label(e) return e.general and "general note" or e.loc end
  -- Without the ids, a submit could only publish every pending draft.
  local by_id = cmds.submit and backend.uses(cmds, "submit", "ids")
  local queued, ids = {}, {} -- entry -> draft id, and the ids in order
  local function sent(set, e, r, what)
    if not r.ok then return fail(what, r) end
    local id = type(r.json) == "table" and r.json.id
    if by_id and not id then
      return fail(what, { stderr = "queued, but the backend printed no id: left pending on the remote" })
    end
    if by_id then
      queued[e] = tostring(id)
      table.insert(ids, tostring(id))
    end
    set[e] = true
  end

  for _, e in ipairs(plan.new) do
    local r
    if e.general then
      r = backend.run(cmds, "general", { root = ctx.root, stdin = e.send })
    else
      -- A range is anchored at its last line, as on the remote.
      local last = e.end_line or e.line
      r = backend.run(cmds, "add", { root = ctx.root, vars = { path = e.path, line = last }, stdin = e.send })
    end
    sent(ok.new, e, r, label(e))
  end
  for _, e in ipairs(plan.replies) do
    local r = backend.run(cmds, "reply", { root = ctx.root, vars = { thread = e.id }, stdin = e.send })
    sent(ok.replies, e, r, "reply " .. label(e))
  end
  if by_id and #ids > 0 then
    local published, err = submit(ctx, ids)
    if err then fail("submit", err) end
    for _, set in pairs(ok) do
      for e in pairs(set) do
        if not published[queued[e]] then set[e] = nil end
      end
    end
  elseif cmds.submit and not by_id then
    -- An older backend config: submit publishes all pending drafts.
    local r = backend.run(cmds, "submit", { root = ctx.root })
    if not r.ok then
      fail("submit", r)
      if cmds.discard then backend.run(cmds, "discard", { root = ctx.root }) end
      ok.new, ok.replies = {}, {}
    end
  end

  -- After submit: publishing a queued reply reopens a resolved thread.
  for _, e in ipairs(plan.states) do
    local r = backend.run(cmds, e.resolved and "resolve" or "unresolve", { root = ctx.root, vars = { thread = e.id } })
    if not r.ok then fail((e.resolved and "resolve " or "reopen ") .. label(e), r) end
  end

  save(ctx.path, nf.apply_sent(load(ctx.path), plan, ok))
  -- What I just sent comes back from the remote as the thread's comments;
  -- quiet so it is not flagged as new. Only what happened during the push
  -- itself goes unflagged: the pull before it brought in the rest.
  pull(ctx, { quiet = true })
  if #failures > 0 then
    notify("pushed with problems:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
  else
    notify("pushed: " .. summary)
  end
  return true, true
end

function M.push()
  local ctx = remote_context()
  if not ctx then return end
  vim.cmd("silent! wall")
  -- The pull before sending only speaks up when it brought something in.
  backend.async(function() push(ctx, { pull = { brief = true } }) end)
end

--- Pull, then push what is ready: one key to bring the remote in and send my
--- side. A push starts with a pull, so this is a push that reports its pull
--- and stays quiet when there is nothing to send.
function M.sync()
  local ctx = remote_context()
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function() push(ctx, { quiet_empty = true }) end)
end

--- Drop resolved entries that have nothing left to send.
function M.clean()
  local ctx = context()
  if not ctx then return end
  local out, n = nf.clean(load(ctx.path))
  if n > 0 then save(ctx.path, out) end
  M.refresh()
  notify(("removed %d resolved entries"):format(n)
    .. ((ctx.kind == "file" and vim.fn.filereadable(ctx.path) == 0 and n > 0) and ", notes file deleted" or ""))
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
      if is_reviewed(ev.buf) then refresh_one(ev.buf, {}, {}) end
    end,
  })
  -- Saving a source file writes the notes' new positions back to the notes
  -- file; saving the notes file (or pi/git-lab changing it) updates the signs.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local ctx = is_reviewed(ev.buf) and contexts[ev.buf]
      if ctx then sync(ev.buf, ctx) end
      M.refresh()
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function() M.refresh() end,
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
      shown[ev.buf], contexts[ev.buf] = nil, nil
    end,
  })
  set_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_highlights })

  -- Keymaps are defined by the caller (see the README).

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
