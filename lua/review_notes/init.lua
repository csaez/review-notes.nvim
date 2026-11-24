-- Code review notes kept outside the code, shown inline, synced on demand.
-- See DESIGN.md. The notes of a branch live in `.git/review/<branch>.md` (a
-- file outside git gets a sibling `<file>.review.md`); `store` reads and
-- writes them, `merge` has the pull and publish rules, `view` draws the
-- threads and `compose` is the editor float. This module is the glue:
-- context, commands, autocmds and the public API.
local store = require("review_notes.store")
local merge = require("review_notes.merge")
local view = require("review_notes.view")
local compose = require("review_notes.compose")
local backend = require("review_notes.backend")

local M = {}
local uv = vim.uv or vim.loop

---@class review_notes.Config
---@field visible boolean show the thread text (review mode) at startup
---@field signs boolean sign column marks on the anchors
---@field watch boolean redraw when a notes file changes on disk
---@field backend table<string, string[]> Command lines, run in the repo root.
---  `{path}`, `{line}`, `{thread}` and `{ids}` are substituted; text goes on stdin.
---    threads    prints [{id, path, line, resolved, comments = [{id, author, body}]}]
---               path = null is a thread on the whole change; line 0 a whole
---               file; line (and start_line) are lines of the files on disk.
---               Optional: comments[].mine (my own comments never count as
---               unread), resolved_by, resolved_by_me
---    add        starts a thread at {path}:{line}, text on stdin
---    general    starts a thread on the whole change, text on stdin
---    reply      replies to {thread}, text on stdin
---               add, general, reply print {id} (with submit: the queued draft)
---    resolve, unresolve  change the state of {thread}
---    submit     optional: publishes what add/general/reply queued: {ids}, the
---               comma-separated ids they printed, so drafts queued elsewhere
---               stay pending; may print {published = [ids]}, also on failure
---    discard    optional: drops the queued {ids} that submit did not publish
M.config = {
  visible = true,
  signs = true,
  watch = true,
  backend = {
    threads = { "git-lab", "comment", "list", "--json" },
    add = { "git-lab", "comment", "add", "--draft", "--json", "{path}:{line}", "-" },
    general = { "git-lab", "comment", "add", "--draft", "--json", "-" },
    reply = { "git-lab", "comment", "reply", "--draft", "--json", "{thread}", "-" },
    resolve = { "git-lab", "comment", "resolve", "{thread}" },
    unresolve = { "git-lab", "comment", "unresolve", "{thread}" },
    submit = { "git-lab", "review", "submit", "--only", "{ids}", "--json" },
    discard = { "git-lab", "review", "discard", "--only", "{ids}" },
  },
}

--- Icons and highlight groups per state (see `view.style`).
M.style = view.style

---@class review_notes.Context
---@field kind "git"|"file"
---@field root string repo root, or the file's directory
---@field path string the notes file

local visible = true
local contexts = {} ---@type table<integer, review_notes.Context>
local last_ctx ---@type review_notes.Context?
local expanded = {} ---@type table<string, table<string, boolean>> by notes path, then thread key
local counts = {} ---@type table<string, table<string, integer>> by notes path

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review" })
end

-- Context ---------------------------------------------------------------

local function git(args, cwd)
  local out = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
  if out.code ~= 0 then return nil end
  return vim.trim(out.stdout)
end

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
  return { kind = "git", root = root, path = gitdir .. "/" .. branch .. ".md" }
end

-- Memoised per root in *memo*: one refresh walks every buffer.
local function repo_context(dir, memo)
  local root = vim.fn.isdirectory(dir) == 1 and vim.fs.root(dir, ".git") or nil
  if not root then return nil end
  if memo[root] == nil then memo[root] = git_context(root) or false end
  return memo[root] or nil
end

--- The review a buffer belongs to: a file in a git worktree is in its
--- branch's review, any other file has its own, next to it.
---@param buf integer? defaults to the current buffer
---@param memo table?
---@return review_notes.Context?
local function context(buf, memo)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  memo = memo or {}
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" or name:find("/.git/", 1, true) then
    return repo_context(vim.fn.getcwd(), memo)
  end
  local dir = vim.fs.dirname(name)
  if name:match("%.review%.md$") then return { kind = "file", root = dir, path = name } end
  return repo_context(dir, memo) or { kind = "file", root = dir, path = name .. ".review.md" }
end

--- The review that remote commands act on: the buffer's when it is a branch
--- review, else the cwd's repo.
local function remote_context()
  local ctx = context()
  if ctx and ctx.kind == "git" then return ctx end
  ctx = repo_context(vim.fn.getcwd(), {})
  if not ctx then notify("local review (no git repository): nothing to sync") end
  return ctx
end

local function is_reviewed(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ""
    and name ~= ""
    and not name:match("%.review%.md$")
    and not name:find("/.git/", 1, true)
end

local function note_path(name, root)
  if name:sub(1, #root + 1) == root .. "/" then return name:sub(#root + 2) end
  return name
end

local function full_path(path, root)
  return vim.startswith(path, "/") and path or (root .. "/" .. path)
end

-- Reading ---------------------------------------------------------------

--- A key per thread that stays the same across reads: the remote id, or the
--- anchor and the place among threads not published yet.
---@param doc review_notes.Doc
---@return string[]
local function keys_of(doc)
  local count, keys = {}, {}
  for i, t in ipairs(doc.threads) do
    local anchor = store.anchor_string(t.anchor)
    local n = 0
    if not t.id then
      n = (count[anchor] or 0) + 1
      count[anchor] = n
    end
    keys[i] = view.key(t, n)
  end
  return keys
end

---@param ctx review_notes.Context
---@return review_notes.Doc, review_notes.Sidecar
local function read_review(ctx)
  return store.parse(store.read_lines(ctx.path)), store.read_sidecar(store.sidecar_path(ctx.path))
end

---@return review_notes.Entry[]
local function entries_of(doc, side)
  local keys = keys_of(doc)
  local out = {}
  for i, t in ipairs(doc.threads) do
    out[i] = { key = keys[i], thread = t, state = t.id and side.threads[t.id] or nil }
  end
  return out
end

--- Change the document and the sidecar together. *fn* may run more than once
--- (the file changed under it), so it works on what it is given.
---@generic T
---@param ctx review_notes.Context
---@param fn fun(doc: review_notes.Doc, side: review_notes.Sidecar): T?
---@return T?
local function edit(ctx, fn)
  local side_path = store.sidecar_path(ctx.path)
  local side
  local result = store.update(ctx.path, function(doc)
    side = store.read_sidecar(side_path)
    return fn(doc, side)
  end)
  store.write_sidecar(side_path, side)
  return result
end

-- Drawing ---------------------------------------------------------------

local function tally(entries)
  local n = { unread = 0, proposed = 0, unsent = 0, open = 0 }
  for _, e in ipairs(entries) do
    local f = merge.flags(e.thread, e.state)
    if f.unread then n.unread = n.unread + 1 end
    if f.proposed then n.proposed = n.proposed + 1 end
    if f.unsent then n.unsent = n.unsent + 1 end
    if not f.resolved then n.open = n.open + 1 end
  end
  return n
end

local watch

---@param buf integer
---@param memo table?
local function redraw_buffer(buf, memo)
  if not is_reviewed(buf) then return end
  local ctx = context(buf, memo)
  if not ctx then return end
  contexts[buf], last_ctx = ctx, ctx
  local doc, side = read_review(ctx)
  local entries = entries_of(doc, side)
  counts[ctx.path] = tally(entries)
  view.render(buf, entries, note_path(vim.api.nvim_buf_get_name(buf), ctx.root), visible, {
    expanded = expanded[ctx.path] or {},
    signs = M.config.signs,
    -- Unsaved edits: the file's lines are stale, keep where the threads are.
    buf_rows = vim.bo[buf].modified and view.live_rows(buf) or nil,
  })
  watch(ctx.path)
end

--- Redraw every shown file.
function M.refresh()
  local memo = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    redraw_buffer(buf, memo)
  end
end

local watchers = {} ---@type table<string, boolean>
local debounce

--- Watch the directory, not the file: writes are renames, which a watch on
--- the file itself would lose.
function watch(path)
  if not M.config.watch then return end
  local dir = vim.fs.dirname(path)
  if watchers[dir] or vim.fn.isdirectory(dir) == 0 then return end
  local handle = uv.new_fs_event()
  if not handle then return end
  watchers[dir] = true
  debounce = debounce or uv.new_timer()
  handle:start(dir, {}, function(err, name)
    if err or (name and name:find(".tmp.", 1, true)) then return end
    debounce:stop()
    debounce:start(60, 0, vim.schedule_wrap(M.refresh))
  end)
end

-- Anchors follow edits through extmarks; saving the file writes the new
-- lines back to the notes.
local function sync_anchors(buf)
  local anchored = view.anchored(buf)
  local ctx = contexts[buf]
  if not ctx or #anchored == 0 then return end
  local rel = note_path(vim.api.nvim_buf_get_name(buf), ctx.root)
  local live = {}
  for _, a in ipairs(anchored) do
    if not a.header then live[a.entry.key] = a end
  end
  if vim.tbl_isempty(live) then return end
  pcall(store.update, ctx.path, function(doc)
    local keys = keys_of(doc)
    for i, t in ipairs(doc.threads) do
      local a = live[keys[i]]
      if a and t.anchor.path == rel and t.anchor.line then
        t.anchor.line = a.row + 1
        t.anchor.end_line = a.end_row > a.row and (a.end_row + 1) or nil
        t.moved = a.moved or nil
      end
    end
  end)
end

-- Threads at the cursor ---------------------------------------------------

---@param buf integer
---@param header boolean? threads of the header (change and file) instead
---@return review_notes.Anchored[]
local function threads_here(buf, header)
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  if header then
    return vim.tbl_filter(function(a) return a.header end, view.anchored(buf))
  end
  local here = view.at(buf, row, false)
  if #here > 0 then return here end
  return view.at(buf, row, true)
end

local function describe_thread(entry)
  local t = entry.thread
  local last = t.comments[#t.comments]
  local text = last and vim.split(last.body, "\n", { plain = true })[1] or ""
  return ("%s  %s"):format(store.anchor_string(t.anchor), text)
end

---@param list review_notes.Anchored[]
---@param prompt string
---@param cb fun(a: review_notes.Anchored)
local function choose_thread(list, prompt, cb)
  if #list == 0 then return notify("no thread here") end
  if #list == 1 then return cb(list[1]) end
  vim.ui.select(list, {
    prompt = prompt,
    format_item = function(a) return describe_thread(a.entry) end,
  }, function(choice) if choice then cb(choice) end end)
end

-- Editing threads -----------------------------------------------------------

---@param ctx review_notes.Context
---@param key string
---@param fn fun(thread: review_notes.Thread, doc: review_notes.Doc, side: review_notes.Sidecar)
local function edit_thread(ctx, key, fn)
  local found = edit(ctx, function(doc, side)
    for i, k in ipairs(keys_of(doc)) do
      if k == key then
        fn(doc.threads[i], doc, side)
        return true
      end
    end
  end)
  if not found then notify("that thread is gone", vim.log.levels.WARN) end
  M.refresh()
end

--- Save my comment of a thread (the one not published yet); an empty text
--- removes it, and a new thread with nothing left.
---@param ctx review_notes.Context
---@param target { key: string? , anchor: review_notes.Anchor? }
---@param text string
local function save_comment(ctx, target, text)
  edit(ctx, function(doc)
    local thread
    if target.key then
      for i, k in ipairs(keys_of(doc)) do
        if k == target.key then thread = doc.threads[i] end
      end
    end
    if not thread then
      if text == "" or not target.anchor then return end
      thread = { anchor = target.anchor, status = "open", comments = {} }
      table.insert(doc.threads, thread)
    end
    local mine
    for _, c in ipairs(thread.comments) do
      if c.source == "local" then mine = c end
    end
    if text == "" then
      if mine then
        thread.comments = vim.tbl_filter(function(c) return c ~= mine end, thread.comments)
      end
      if not thread.id and #thread.comments == 0 then
        doc.threads = vim.tbl_filter(function(t) return t ~= thread end, doc.threads)
      end
    elseif mine then
      mine.body = text
    else
      table.insert(thread.comments, { source = "local", body = text })
    end
    merge.sort(doc.threads)
  end)
  M.refresh()
end

local function open_composer(ctx, target, title, thread)
  local existing
  for _, c in ipairs(thread and thread.comments or {}) do
    if c.source == "local" then existing = c.body end
  end
  compose.open({
    title = title,
    text = existing,
    on_save = function(text) save_comment(ctx, target, text) end,
  })
end

--- Visual range as 1-based lines, leaving visual mode.
local function visual_range()
  local mode = vim.fn.mode()
  if mode ~= "v" and mode ~= "V" and mode ~= "\22" then return nil end
  local a, b = vim.fn.line("v"), vim.fn.line(".")
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  return math.min(a, b), math.max(a, b)
end

local function current_review(buf)
  local ctx = contexts[buf] or context(buf)
  if not ctx then notify("not in a reviewable file") end
  return ctx
end

--- Reply to the thread at the cursor, or start one on the line (or the
--- selected lines). Writes into the notes only; `publish` sends it.
function M.add()
  local buf = vim.api.nvim_get_current_buf()
  local first, last = visual_range()
  local ctx = current_review(buf)
  if not ctx then return end
  if not first then
    local here = threads_here(buf)
    if #here > 0 then
      return choose_thread(here, "Reply to", function(a)
        open_composer(ctx, { key = a.entry.key }, "reply to " .. store.anchor_string(a.entry.thread.anchor), a.entry.thread)
      end)
    end
    first = vim.api.nvim_win_get_cursor(0)[1]
    last = first
  end
  local anchor = {
    path = note_path(vim.api.nvim_buf_get_name(buf), ctx.root),
    line = first,
    end_line = last > first and last or nil,
  }
  open_composer(ctx, { anchor = anchor }, "new thread on " .. store.anchor_string(anchor))
end

--- Start a thread on the whole change, or on the current file.
---@param file boolean? the whole current file instead
function M.add_general(file)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = current_review(buf)
  if not ctx then return end
  local anchor = {}
  if file then anchor = { path = note_path(vim.api.nvim_buf_get_name(buf), ctx.root) } end
  open_composer(ctx, { anchor = anchor }, "new thread on " .. (file and anchor.path or "the change"))
end

--- Reply to a thread of the header (the change or the file).
function M.reply_general()
  local buf = vim.api.nvim_get_current_buf()
  local ctx = current_review(buf)
  if not ctx then return end
  choose_thread(threads_here(buf, true), "Reply to", function(a)
    open_composer(ctx, { key = a.entry.key }, "reply to " .. store.anchor_string(a.entry.thread.anchor), a.entry.thread)
  end)
end

local function with_target(prompt, fn)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = contexts[buf]
  if not ctx then return notify("no review in this buffer") end
  choose_thread(threads_here(buf), prompt, function(a) fn(ctx, a.entry) end)
end

local function set_expanded(ctx, key, value)
  expanded[ctx.path] = expanded[ctx.path] or {}
  expanded[ctx.path][key] = value or nil
end

local function mark_seen(ctx, key)
  edit_thread(ctx, key, function(t, _, side) merge.mark_seen(t, side) end)
end

--- Expand or collapse the thread at the cursor (or those of the header).
--- Expanding marks it as seen.
---@param header boolean? the change and file threads
function M.toggle_expand(header)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = contexts[buf]
  if not ctx then return end
  local list = threads_here(buf, header)
  if #list == 0 then return notify("no thread here") end
  local open = not (expanded[ctx.path] or {})[list[1].entry.key]
  for _, a in ipairs(list) do
    set_expanded(ctx, a.entry.key, open)
    if open and merge.is_unread(a.entry.thread, a.entry.state) then mark_seen(ctx, a.entry.key) end
  end
  M.refresh()
end

--- Expand every thread, or collapse them all when all are expanded.
function M.toggle_expand_all()
  local buf = vim.api.nvim_get_current_buf()
  local ctx = contexts[buf]
  if not ctx then return end
  local doc, side = read_review(ctx)
  local entries = entries_of(doc, side)
  local all = true
  for _, e in ipairs(entries) do
    if not (expanded[ctx.path] or {})[e.key] then all = false end
  end
  expanded[ctx.path] = {}
  if not all then
    for _, e in ipairs(entries) do expanded[ctx.path][e.key] = true end
    edit(ctx, function(d, s)
      for _, t in ipairs(d.threads) do merge.mark_seen(t, s) end
    end)
  end
  M.refresh()
end

--- Toggle review mode: threads as text under the code, or just the signs.
function M.toggle()
  visible = not visible
  M.refresh()
  notify("review mode " .. (visible and "on" or "off"))
end

--- Resolve or reopen the thread at the cursor. Resolving something someone
--- else resolved only accepts it. Sent by `publish`.
function M.toggle_resolved()
  with_target("Resolve", function(ctx, entry)
    edit_thread(ctx, entry.key, function(t, _, side)
      if merge.resolved_unseen(t, t.id and side.threads[t.id]) then
        merge.mark_seen(t, side)
      else
        t.status = t.status == "resolved" and "open" or "resolved"
      end
    end)
  end)
end

--- Mark the thread at the cursor as seen.
function M.mark_read()
  with_target("Mark read", function(ctx, entry) mark_seen(ctx, entry.key) M.refresh() end)
end

--- Approve what a tool proposed on the thread at the cursor, so `publish`
--- sends it. With *all*, on every thread.
---@param all boolean?
function M.approve(all)
  if all then
    local buf = vim.api.nvim_get_current_buf()
    local ctx = current_review(buf)
    if not ctx then return end
    local n = edit(ctx, function(doc)
      local total = 0
      for _, t in ipairs(doc.threads) do total = total + merge.approve(t) end
      return total
    end)
    M.refresh()
    return notify(("approved %d proposed comments"):format(n or 0))
  end
  with_target("Approve", function(ctx, entry)
    edit_thread(ctx, entry.key, function(t) merge.approve(t) end)
  end)
end

--- Delete my text on the thread at the cursor (local and proposed); a thread
--- not published yet goes with it.
function M.discard()
  with_target("Discard", function(ctx, entry)
    if not merge.has_unpublished(entry.thread) then return notify("nothing unpublished here") end
    vim.ui.select({ "Discard", "Keep" }, { prompt = "Discard unpublished text?" }, function(choice)
      if choice ~= "Discard" then return end
      edit_thread(ctx, entry.key, function(t, doc)
        t.comments = vim.tbl_filter(function(c) return c.source == "remote" end, t.comments)
        if not t.id then
          doc.threads = vim.tbl_filter(function(x) return x ~= t end, doc.threads)
        end
      end)
    end)
  end)
end

--- Open the notes file in a split, to edit by hand.
function M.open()
  local ctx = current_review(vim.api.nvim_get_current_buf())
  if not ctx then return end
  vim.cmd("split " .. vim.fn.fnameescape(ctx.path))
end

-- Moving ------------------------------------------------------------------

--- Next or previous thread in the buffer.
---@param dir integer 1 or -1
function M.jump(dir)
  local buf = vim.api.nvim_get_current_buf()
  local list = vim.tbl_filter(function(a) return not a.header end, view.anchored(buf))
  if #list == 0 then return notify("no threads in this buffer") end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local target
  if dir > 0 then
    for _, a in ipairs(list) do
      if a.row > row then target = a break end
    end
    target = target or list[1]
  else
    for i = #list, 1, -1 do
      if list[i].row < row then target = list[i] break end
    end
    target = target or list[#list]
  end
  vim.api.nvim_win_set_cursor(0, { target.row + 1, 0 })
end

---@class review_notes.Item
---@field key string
---@field ctx review_notes.Context
---@field kind "change"|"file"|"line"
---@field anchor string
---@field file string where the thread is: the code, or the notes file for the change
---@field line integer
---@field end_line integer
---@field state string "unread"|"proposed"|"unsent"|"open"|"resolved"
---@field icon string
---@field hl string
---@field tags string[]
---@field summary string
---@field thread string[] the conversation as markdown lines, for a preview
---@field text string searchable text

local function thread_markdown(t)
  local out = {}
  for _, c in ipairs(t.comments) do
    local who = c.source == "remote" and ("@" .. (c.author or "unknown"))
      or (c.source == "proposed" and "me (proposed)" or "me (not published)")
    vim.list_extend(out, { "### " .. who, "" })
    vim.list_extend(out, vim.split(c.body, "\n", { plain = true }))
    table.insert(out, "")
  end
  return out
end

--- Every thread of the review of *buf*, urgent first: unread, proposed, not
--- published, open, resolved; each by position. One kind of row for all, the
--- change threads included.
---@param buf integer?
---@return review_notes.Item[]
function M.items(buf)
  local ctx = context(buf)
  if not ctx then return {} end
  local doc, side = read_review(ctx)
  local heading = {}
  local n = 0
  for i, l in ipairs(store.read_lines(ctx.path)) do
    if l:match("^## ") then
      n = n + 1
      heading[n] = i
    end
  end
  local items = {}
  for i, e in ipairs(entries_of(doc, side)) do
    local t = e.thread
    local f = merge.flags(t, e.state)
    local state, rank = merge.urgency(f)
    local kind = store.anchor_kind(t.anchor)
    local last = t.comments[#t.comments]
    local tags = {}
    if f.resolved and state ~= "resolved" then table.insert(tags, "resolved") end
    if f.proposed and state ~= "proposed" then table.insert(tags, "proposed") end
    if f.unsent and state ~= "unsent" then table.insert(tags, "unsent") end
    local summary = last and vim.split(last.body, "\n", { plain = true })[1] or ""
    items[i] = {
      key = e.key,
      ctx = ctx,
      kind = kind,
      anchor = store.anchor_string(t.anchor),
      file = kind == "change" and ctx.path or full_path(t.anchor.path, ctx.root),
      line = kind == "change" and heading[i] or math.max(1, t.anchor.line or 1),
      end_line = kind == "line" and (t.anchor.end_line or t.anchor.line) or (heading[i] or 1),
      state = state,
      icon = view.style[state].icon,
      hl = view.style[state].hl,
      tags = tags,
      summary = summary,
      thread = thread_markdown(t),
      text = table.concat({ state, store.anchor_string(t.anchor), table.concat(tags, " "), summary }, " "),
      rank = rank,
      order = i,
    }
  end
  table.sort(items, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.order < b.order
  end)
  return items
end

--- Go to the code of *item*; for a change thread, the top of the current
--- buffer (where its header is), or the notes file outside a reviewed buffer.
---@param item review_notes.Item
function M.goto_item(item)
  if item.kind == "change" then
    if is_reviewed(vim.api.nvim_get_current_buf()) then
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      return
    end
  end
  vim.cmd("edit " .. vim.fn.fnameescape(item.file))
  local last = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.min(item.line, last), 0 })
end

--- Go to *item* and show its conversation.
---@param item review_notes.Item
function M.open_item(item)
  M.goto_item(item)
  set_expanded(item.ctx, item.key, true)
  mark_seen(item.ctx, item.key)
end

---@param item review_notes.Item
---@param action "resolve"|"read"|"approve"
function M.item_action(item, action)
  edit_thread(item.ctx, item.key, function(t, _, side)
    if action == "resolve" then
      if merge.resolved_unseen(t, t.id and side.threads[t.id]) then
        merge.mark_seen(t, side)
      else
        t.status = t.status == "resolved" and "open" or "resolved"
      end
    elseif action == "read" then
      merge.mark_seen(t, side)
    elseif action == "approve" then
      merge.approve(t)
    end
  end)
end

--- Next or previous unread thread, across the files of the review.
---@param dir integer 1 or -1
function M.jump_unread(dir)
  local buf = vim.api.nvim_get_current_buf()
  local ctx = current_review(buf)
  if not ctx then return end
  local unread = vim.tbl_filter(function(i) return i.state == "unread" end, M.items(buf))
  if #unread == 0 then return notify("nothing unread") end
  table.sort(unread, function(a, b) return a.order < b.order end)
  local rel = note_path(vim.api.nvim_buf_get_name(buf), ctx.root)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local function ahead(item)
    local path = item.kind == "change" and "" or note_path(item.file, ctx.root)
    if path ~= rel then return path > rel end
    return item.kind ~= "change" and item.line > row
  end
  local target
  if dir > 0 then
    for _, item in ipairs(unread) do
      if ahead(item) then target = item break end
    end
    target = target or unread[1]
  else
    for i = #unread, 1, -1 do
      if not ahead(unread[i]) and not (unread[i].kind ~= "change" and unread[i].line == row and
        note_path(unread[i].file, ctx.root) == rel) then
        target = unread[i]
        break
      end
    end
    target = target or unread[#unread]
  end
  M.open_item(target)
end

--- The list of threads in the quickfix window.
function M.list()
  local items = M.items()
  if #items == 0 then return notify("no threads") end
  local qf = {}
  for _, item in ipairs(items) do
    table.insert(qf, {
      filename = item.file,
      lnum = item.line,
      text = ("%s [%s] %s %s"):format(item.icon, item.state, item.anchor, item.summary),
    })
  end
  vim.fn.setqflist({}, " ", { title = "Review threads", items = qf })
  vim.cmd("copen")
end

--- A statusline component: what waits for me in the current review.
---@return string
function M.status()
  local ctx = contexts[vim.api.nvim_get_current_buf()] or last_ctx
  local n = ctx and counts[ctx.path]
  if not n then return "" end
  local parts = {}
  for _, k in ipairs({ "unread", "proposed", "unsent" }) do
    if n[k] > 0 then table.insert(parts, view.style[k].icon .. " " .. n[k]) end
  end
  return table.concat(parts, " ")
end

-- Sync --------------------------------------------------------------------

local function choose(prompt, choices)
  local co = assert(coroutine.running())
  vim.ui.select(choices, { prompt = prompt }, function(choice)
    vim.schedule(function() backend.resume(co, choice) end)
  end)
  return coroutine.yield()
end

--- Bring the remote threads in, inside an async function. Never sends.
---@return boolean ok
local function pull(ctx, opts)
  local r = backend.run(M.config.backend, "threads", { root = ctx.root })
  if not r.ok or type(r.json) ~= "table" then
    notify("pull failed: " .. (r.ok and "the backend printed no thread list" or backend.message(r)), vim.log.levels.ERROR)
    return false
  end
  local report
  edit(ctx, function(doc, side)
    report = merge.pull(doc, side, r.json)
  end)
  M.refresh()
  if not (opts and opts.quiet) then
    local n = counts[ctx.path] or { unread = 0 }
    local msg = ("pulled: %d new threads, %d updated, %d unread"):format(report.added, report.changed, n.unread)
    if #report.orphaned > 0 then
      msg = msg .. "\ndeleted on the remote, kept because they hold your text: " .. table.concat(report.orphaned, ", ")
    end
    notify(msg, #report.orphaned > 0 and vim.log.levels.WARN or nil)
  end
  return true
end

--- Bring the remote threads in. Never sends anything.
function M.pull()
  local ctx = remote_context()
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function() pull(ctx) end)
end

local function label(item)
  local t = item.thread
  return t.anchor.path and store.anchor_string(t.anchor) or "the change"
end

local function describe_plan(items, held)
  local lines, n = {}, { thread = 0, reply = 0, resolve = 0, unresolve = 0 }
  for _, item in ipairs(items) do
    n[item.kind] = n[item.kind] + 1
    local what = ({
      thread = "new thread on ", reply = "reply on ", resolve = "resolve ", unresolve = "reopen ",
    })[item.kind]
    table.insert(lines, ("  %s%s%s"):format(what, label(item), item.stale and "  (new comments since you wrote this)" or ""))
  end
  if #lines > 8 then
    local extra = #lines - 7
    lines = vim.list_slice(lines, 1, 7)
    table.insert(lines, ("  ... and %d more"):format(extra))
  end
  if #held > 0 then
    table.insert(lines, ("  %d thread(s) with proposed comments not approved: skipped"):format(#held))
  end
  return table.concat(lines, "\n")
end

local function submit(ctx, ids)
  local cmds = M.config.backend
  local r = backend.run(cmds, "submit", { root = ctx.root, vars = { ids = table.concat(ids, ",") } })
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

--- Pull, show what would be sent, and send it after a confirm. Everything is
--- queued as drafts and published together (one notification), only the
--- drafts created here.
function M.publish()
  local ctx = remote_context()
  if not ctx then return end
  vim.cmd("silent! wall")
  backend.async(function()
    local cmds = M.config.backend
    if not pull(ctx, { quiet = true }) then return end
    local doc, side = read_review(ctx)
    local plan = merge.plan(doc, side)
    if #plan.items == 0 then
      return notify("nothing to publish" .. (#plan.held > 0 and (" (%d proposed, not approved)"):format(#plan.held) or ""))
    end
    local stale = vim.tbl_filter(function(i) return i.stale end, plan.items)
    local choices = #stale > 0 and { "Publish all", "Skip the ones with new comments", "Cancel" } or { "Publish", "Cancel" }
    local choice = choose("Publish?\n" .. describe_plan(plan.items, plan.held), choices)
    if not choice or choice == "Cancel" then return end
    local items = plan.items
    if choice:match("^Skip") then
      items = vim.tbl_filter(function(i) return not i.stale end, items)
    end

    local failures, done = {}, {}
    local function fail(what, r) table.insert(failures, what .. ": " .. backend.message(r)) end
    local by_id = cmds.submit and backend.uses(cmds, "submit", "ids")
    local queued, ids = {}, {}
    local function sent(item, r)
      if not r.ok then return fail(label(item), r) end
      local id = type(r.json) == "table" and r.json.id
      if by_id and not id then
        return fail(label(item), { stderr = "queued, but the backend printed no id: left pending on the remote" })
      end
      if by_id then
        queued[item] = tostring(id)
        table.insert(ids, tostring(id))
      end
      done[item] = true
    end

    for _, item in ipairs(items) do
      local t, text = item.thread, item.comment and item.comment.body
      if item.kind == "thread" then
        local a = t.anchor
        if a.path then
          -- A range is anchored at its last line, as on the remote.
          local vars = { path = a.path, line = a.end_line or a.line or 0 }
          sent(item, backend.run(cmds, "add", { root = ctx.root, vars = vars, stdin = text }))
        else
          sent(item, backend.run(cmds, "general", { root = ctx.root, stdin = text }))
        end
      elseif item.kind == "reply" then
        sent(item, backend.run(cmds, "reply", { root = ctx.root, vars = { thread = t.id }, stdin = text }))
      end
    end
    if by_id and #ids > 0 then
      local published, err = submit(ctx, ids)
      if err then fail("submit", err) end
      for item in pairs(queued) do
        if not published[queued[item]] then done[item] = nil end
      end
    elseif cmds.submit and not by_id then
      local r = backend.run(cmds, "submit", { root = ctx.root })
      if not r.ok then
        fail("submit", r)
        if cmds.discard then backend.run(cmds, "discard", { root = ctx.root }) end
        for item in pairs(queued) do done[item] = nil end
        for item in pairs(done) do
          if item.kind ~= "resolve" and item.kind ~= "unresolve" then done[item] = nil end
        end
      end
    end
    -- After submit: publishing a queued reply reopens a resolved thread.
    for _, item in ipairs(items) do
      if item.kind == "resolve" or item.kind == "unresolve" then
        local r = backend.run(cmds, item.kind, { root = ctx.root, vars = { thread = item.thread.id } })
        if r.ok then done[item] = true else fail(item.kind .. " " .. label(item), r) end
      end
    end

    edit(ctx, function(d, s)
      for _, item in ipairs(items) do
        local found = done[item] and merge.relocate(d, item)
        if found then merge.published(d, s, found) end
      end
    end)
    -- What was sent comes back as remote comments, mine, so not unread.
    pull(ctx, { quiet = true })
    if #failures > 0 then
      notify("published with problems:\n" .. table.concat(failures, "\n"), vim.log.levels.ERROR)
    else
      local sent_count = vim.tbl_count(done)
      notify(("published %d item%s"):format(sent_count, sent_count == 1 and "" or "s"))
    end
  end)
end

-- Setup -------------------------------------------------------------------

local commands = {
  pull = M.pull,
  publish = M.publish,
  list = M.list,
  open = M.open,
  approve = function(args) M.approve(args == "all") end,
  toggle = M.toggle,
  expand = function() M.toggle_expand_all() end,
}

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  visible = M.config.visible
  view.set_highlights()
  local group = vim.api.nvim_create_augroup("ReviewNotes", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufEnter", "FocusGained" }, {
    group = group,
    callback = function(ev) redraw_buffer(ev.buf) end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if is_reviewed(ev.buf) then sync_anchors(ev.buf) redraw_buffer(ev.buf) end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function() if visible then M.refresh() end end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = view.set_highlights })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev) contexts[ev.buf] = nil end,
  })
  vim.api.nvim_create_user_command("Review", function(a)
    local name, rest = a.args:match("^(%S*)%s*(.*)$")
    if name == "" then name = "toggle" end
    local fn = commands[name]
    if not fn then return notify("unknown subcommand: " .. name, vim.log.levels.ERROR) end
    fn(rest)
  end, {
    nargs = "*",
    complete = function(lead, line)
      if line:match("^%S+%s+approve%s") then return { "all" } end
      return vim.tbl_filter(function(c) return c:find(lead, 1, true) == 1 end, vim.tbl_keys(commands))
    end,
  })
  M.refresh()
end

return M
