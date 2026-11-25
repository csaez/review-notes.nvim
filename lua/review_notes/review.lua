-- The current review: which notes file a buffer belongs to, reading it as
-- entries and items, changing it, and telling listeners when it changed
-- (an edit here, or a write by someone else seen by the file watcher).
local store = require("review_notes.store")
local merge = require("review_notes.merge")
local config = require("review_notes.config")

local M = {}
local uv = vim.uv or vim.loop

---@class review_notes.Context
---@field kind "git"|"file"
---@field root string repo root, or the file's directory
---@field path string the notes file

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "review" })
end

-- Change listeners ---------------------------------------------------------

local listeners = {} ---@type fun()[]

--- Call *fn* after every change of a notes file.
---@param fn fun()
function M.on_change(fn) table.insert(listeners, fn) end

function M.changed()
  for _, fn in ipairs(listeners) do fn() end
end

local watchers = {} ---@type table<string, boolean>
local debounce

--- Watch the directory of *path*, not the file: writes are renames, which a
--- watch on the file itself would lose.
---@param path string
function M.watch(path)
  if not config.values.watch then return end
  local dir = vim.fs.dirname(path)
  if watchers[dir] or vim.fn.isdirectory(dir) == 0 then return end
  local handle = uv.new_fs_event()
  if not handle then return end
  watchers[dir] = true
  debounce = debounce or uv.new_timer()
  handle:start(dir, {}, function(err, name)
    if err or (name and name:find(".tmp.", 1, true)) then return end
    debounce:stop()
    debounce:start(60, 0, vim.schedule_wrap(M.changed))
  end)
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
--- branch's review, any other file has its own, next to it. Buffers that are
--- not files (the home, pickers) belong to the cwd's repo.
---@param buf integer? defaults to the current buffer
---@param memo table?
---@return review_notes.Context?
function M.context(buf, memo)
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
---@return review_notes.Context?
function M.remote_context()
  local ctx = M.context()
  if ctx and ctx.kind == "git" then return ctx end
  ctx = repo_context(vim.fn.getcwd(), {})
  if not ctx then M.notify("local review (no git repository): nothing to sync") end
  return ctx
end

--- A buffer of a file under review (not the notes, not git internals).
---@param buf integer
---@return boolean
function M.is_reviewed(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return vim.api.nvim_buf_is_loaded(buf)
    and vim.bo[buf].buftype == ""
    and name ~= ""
    and not name:match("%.review%.md$")
    and not name:find("/.git/", 1, true)
end

--- *name* as an anchor path: relative to *root* when inside it.
function M.note_path(name, root)
  if name:sub(1, #root + 1) == root .. "/" then return name:sub(#root + 2) end
  return name
end

function M.full_path(path, root)
  return vim.startswith(path, "/") and path or (root .. "/" .. path)
end

-- Reading ---------------------------------------------------------------

--- A key for *thread*: its remote id, or its place among new threads.
---@param thread review_notes.Thread
---@param ordinal integer
---@return string
function M.key(thread, ordinal)
  return thread.id or ("new:" .. store.anchor_string(thread.anchor) .. "#" .. ordinal)
end

--- A key per thread that stays the same across reads: the remote id, or the
--- anchor and the place among threads not published yet.
---@param doc review_notes.Doc
---@return string[]
function M.keys_of(doc)
  local count, keys = {}, {}
  for i, t in ipairs(doc.threads) do
    local anchor = store.anchor_string(t.anchor)
    local n = 0
    if not t.id then
      n = (count[anchor] or 0) + 1
      count[anchor] = n
    end
    keys[i] = M.key(t, n)
  end
  return keys
end

---@param ctx review_notes.Context
---@return review_notes.Doc, review_notes.Sidecar
function M.read(ctx)
  return store.parse(store.read_lines(ctx.path)), store.read_sidecar(store.sidecar_path(ctx.path))
end

---@class review_notes.Entry
---@field key string stable across re-reads
---@field thread review_notes.Thread
---@field state review_notes.ThreadState?

---@param doc review_notes.Doc
---@param side review_notes.Sidecar
---@return review_notes.Entry[]
function M.entries_of(doc, side)
  local keys = M.keys_of(doc)
  local out = {}
  for i, t in ipairs(doc.threads) do
    out[i] = { key = keys[i], thread = t, state = t.id and side.threads[t.id] or nil }
  end
  return out
end

--- The entry of *key*, read now.
---@param ctx review_notes.Context
---@param key string
---@return review_notes.Entry?
function M.entry(ctx, key)
  local doc, side = M.read(ctx)
  for _, e in ipairs(M.entries_of(doc, side)) do
    if e.key == key then return e end
  end
end

-- Changing ----------------------------------------------------------------

--- Change the document and the sidecar together, then tell the listeners.
--- *fn* may run more than once (the file changed under it), so it works on
--- what it is given.
---@generic T
---@param ctx review_notes.Context
---@param fn fun(doc: review_notes.Doc, side: review_notes.Sidecar): T?
---@return T?
function M.edit(ctx, fn)
  local side_path = store.sidecar_path(ctx.path)
  local side
  local result = store.update(ctx.path, function(doc)
    side = store.read_sidecar(side_path)
    return fn(doc, side)
  end)
  store.write_sidecar(side_path, side)
  M.changed()
  return result
end

--- Change the thread of *key*.
---@param ctx review_notes.Context
---@param key string
---@param fn fun(thread: review_notes.Thread, doc: review_notes.Doc, side: review_notes.Sidecar)
---@return boolean found
function M.edit_thread(ctx, key, fn)
  local found = M.edit(ctx, function(doc, side)
    for i, k in ipairs(M.keys_of(doc)) do
      if k == key then
        fn(doc.threads[i], doc, side)
        return true
      end
    end
  end)
  if not found then M.notify("that thread is gone", vim.log.levels.WARN) end
  return found == true
end

-- Items -------------------------------------------------------------------

-- Nerd Font icons by state.
---@type table<string, { icon: string, hl: string }>
M.style = {
  unread = { icon = "\u{f0f3}", hl = "ReviewUnread" },
  proposed = { icon = "\u{ea73}", hl = "ReviewProposed" },
  unsent = { icon = "\u{f093}", hl = "ReviewUnsent" },
  open = { icon = "\u{eac7}", hl = "ReviewOpen" },
  resolved = { icon = "\u{f00c}", hl = "ReviewResolved" },
}

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
---@field rank integer
---@field order integer place in the notes file

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

--- Every thread of *ctx*, urgent first: unread, proposed, not published,
--- open, resolved; each by position. One kind of row for all, the change
--- threads included.
---@param ctx review_notes.Context
---@return review_notes.Item[]
function M.items(ctx)
  local doc, side = M.read(ctx)
  local heading = {}
  local n = 0
  for i, l in ipairs(store.read_lines(ctx.path)) do
    if l:match("^## ") then
      n = n + 1
      heading[n] = i
    end
  end
  local items = {}
  for i, e in ipairs(M.entries_of(doc, side)) do
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
    local file = kind == "change" and ctx.path or M.full_path(t.anchor.path, ctx.root)
    -- A submodule's pointer change is anchored on a directory: editing it
    -- would open a file explorer, show the thread in the notes instead.
    local in_notes = kind == "change" or vim.fn.isdirectory(file) == 1
    items[i] = {
      key = e.key,
      ctx = ctx,
      kind = kind,
      anchor = store.anchor_string(t.anchor),
      file = in_notes and ctx.path or file,
      line = in_notes and (heading[i] or 1) or math.max(1, t.anchor.line or 1),
      end_line = (in_notes or kind ~= "line") and (heading[i] or 1) or (t.anchor.end_line or t.anchor.line),
      state = state,
      icon = M.style[state].icon,
      hl = M.style[state].hl,
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

return M
