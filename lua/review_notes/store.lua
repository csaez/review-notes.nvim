-- The notes file and its sidecar: parsing, rendering and atomic writes. No
-- buffers and no processes, so everything is testable with plain line lists.
--
-- The notes file is markdown for humans and agents (see DESIGN.md):
--
--   # Review of feature/timeouts
--
--   ## change {id=ghi789}               a thread on the whole change
--   status: open
--
--   ### @alice {id=11}                  a remote comment
--   please add a changelog entry
--
--   ### me (local)                      mine, not published
--   done, see the next push
--
--   ## src/http.cpp:120-124 {id=abc123} a thread on code (path, path:N, path:N-M)
--   status: resolved
--
--   ### me (proposed)                   written by a tool, waits for approval
--   Matches the studio default.
--
-- `## <anchor> {attrs}` starts a thread, `### <who> {attrs}` a comment. Attrs
-- are `key=value` or flags: `id=`, `mine` (remote comment of mine), `orphan`,
-- `moved`. A thread without `id` is new. A body line that starts with `#` is
-- written with a leading `\`. A thread with text but no `###` section is read
-- as one local comment, so a hand-written thread works.
local M = {}

local uv = vim.uv or vim.loop

---@alias review_notes.Source "remote"|"local"|"proposed"

---@class review_notes.Anchor
---@field path string? nil for the whole change
---@field line integer? nil for the whole file
---@field end_line integer?

---@class review_notes.Comment
---@field source review_notes.Source
---@field author string? remote comments only
---@field id string? remote comments only
---@field mine boolean? remote comment written by me
---@field body string

---@class review_notes.Thread
---@field anchor review_notes.Anchor
---@field status "open"|"resolved"
---@field id string? remote thread id; nil for a thread not published yet
---@field orphan boolean? deleted on the remote but holds local text
---@field moved boolean? its line was deleted by edits
---@field comments review_notes.Comment[]

---@class review_notes.Doc
---@field title string?
---@field threads review_notes.Thread[]

-- Anchors ---------------------------------------------------------------

---@param s string
---@return review_notes.Anchor
function M.parse_anchor(s)
  if s == "change" then return {} end
  local path, first, last = s:match("^(.-):(%d+)-(%d+)$")
  if path then return { path = path, line = tonumber(first), end_line = tonumber(last) } end
  path, first = s:match("^(.-):(%d+)$")
  if path then return { path = path, line = tonumber(first) } end
  return { path = s }
end

---@param a review_notes.Anchor
---@return string
function M.anchor_string(a)
  if not a.path then return "change" end
  if not a.line then return a.path end
  if a.end_line and a.end_line ~= a.line then return ("%s:%d-%d"):format(a.path, a.line, a.end_line) end
  return ("%s:%d"):format(a.path, a.line)
end

---@param a review_notes.Anchor
---@return "change"|"file"|"line"
function M.anchor_kind(a)
  if not a.path then return "change" end
  return a.line and "line" or "file"
end

-- Attrs and escaping -----------------------------------------------------

local function parse_attrs(s)
  local attrs = {}
  for token in (s or ""):gmatch("%S+") do
    local k, v = token:match("^([%w_]+)=(.+)$")
    if k then
      attrs[k] = v
    else
      attrs[token] = true
    end
  end
  return attrs
end

local function render_attrs(parts)
  return #parts > 0 and (" {" .. table.concat(parts, " ") .. "}") or ""
end

--- Split `text {attrs}` into text and attrs.
local function split_attrs(s)
  local text, attrs = s:match("^(.-)%s*{([^{}]*)}%s*$")
  if text then return text, parse_attrs(attrs) end
  return vim.trim(s), {}
end

---@param line string
---@return string
function M.escape(line)
  return line:match("^\\*#") and ("\\" .. line) or line
end

---@param line string
---@return string
function M.unescape(line)
  return line:match("^\\+#") and line:sub(2) or line
end

local function heading_level(line)
  local hashes = line:match("^(#+)%s")
  return hashes and #hashes <= 3 and #hashes or nil
end

-- Parse -----------------------------------------------------------------

local function body_of(lines)
  local out = {}
  for _, l in ipairs(lines) do
    table.insert(out, M.unescape((l:gsub("%s+$", ""))))
  end
  while #out > 0 and out[1] == "" do table.remove(out, 1) end
  while #out > 0 and out[#out] == "" do table.remove(out) end
  return table.concat(out, "\n")
end

local function parse_comment(heading, body)
  local who, attrs = split_attrs(heading)
  local c = { source = "remote", body = body_of(body) }
  local mine = who:match("^me%s*%((%a+)%)$")
  if mine == "local" or mine == "proposed" then
    c.source = mine
  elseif who == "me" then
    c.source = "local"
  else
    c.author = (who:gsub("^@", ""))
    c.id = attrs.id
    c.mine = attrs.mine and true or nil
  end
  return c
end

local function parse_thread(heading, body)
  local anchor_text, attrs = split_attrs(heading)
  local thread = {
    anchor = M.parse_anchor(anchor_text),
    status = "open",
    id = attrs.id,
    orphan = attrs.orphan and true or nil,
    moved = attrs.moved and true or nil,
    comments = {},
  }
  local i = 1
  while i <= #body and vim.trim(body[i]) == "" do i = i + 1 end
  local status = body[i] and body[i]:match("^status:%s*(%a+)%s*$")
  if status then
    thread.status = status == "resolved" and "resolved" or "open"
    i = i + 1
  end

  local current, chunk = nil, {}
  local function flush()
    if current then
      table.insert(thread.comments, parse_comment(current, chunk))
    elseif body_of(chunk) ~= "" then
      table.insert(thread.comments, { source = "local", body = body_of(chunk) })
    end
    chunk = {}
  end
  for j = i, #body do
    if heading_level(body[j]) == 3 then
      flush()
      current = body[j]:match("^###%s+(.*)$")
    else
      table.insert(chunk, body[j])
    end
  end
  flush()
  return thread
end

---@param lines string[]
---@return review_notes.Doc
function M.parse(lines)
  local doc = { threads = {} }
  local heading, body
  local function flush()
    if heading then table.insert(doc.threads, parse_thread(heading, body)) end
    heading, body = nil, {}
  end
  for _, line in ipairs(lines) do
    local level = heading_level(line)
    if level == 1 and not heading and not doc.title then
      doc.title = line:match("^#%s+(.*)$")
    elseif level == 2 then
      flush()
      heading = line:match("^##%s+(.*)$")
    elseif heading then
      table.insert(body, line)
    end
  end
  flush()
  return doc
end

-- Render ----------------------------------------------------------------

local function render_comment(out, c)
  local who, parts
  if c.source == "remote" then
    who = "@" .. (c.author or "unknown")
    parts = {}
    if c.id then table.insert(parts, "id=" .. c.id) end
    if c.mine then table.insert(parts, "mine") end
  else
    who, parts = "me (" .. c.source .. ")", {}
  end
  table.insert(out, "### " .. who .. render_attrs(parts))
  for _, l in ipairs(vim.split(c.body, "\n", { plain = true })) do
    table.insert(out, M.escape(l))
  end
  table.insert(out, "")
end

---@param doc review_notes.Doc
---@return string[]
function M.render(doc)
  local out = {}
  if doc.title then vim.list_extend(out, { "# " .. doc.title, "" }) end
  for _, t in ipairs(doc.threads) do
    local parts = {}
    if t.id then table.insert(parts, "id=" .. t.id) end
    if t.orphan then table.insert(parts, "orphan") end
    if t.moved then table.insert(parts, "moved") end
    table.insert(out, "## " .. M.anchor_string(t.anchor) .. render_attrs(parts))
    table.insert(out, "status: " .. t.status)
    table.insert(out, "")
    for _, c in ipairs(t.comments) do render_comment(out, c) end
  end
  while #out > 0 and out[#out] == "" do table.remove(out) end
  return out
end

-- Files -----------------------------------------------------------------

---@param path string
---@return string[]
function M.read_lines(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local text = f:read("*a")
  f:close()
  if text == "" then return {} end
  return vim.split((text:gsub("\n$", "")), "\n", { plain = true })
end

--- Write through a temporary file and a rename, so a reader (an agent, the
--- file watcher) never sees half a file.
---@param path string
---@param lines string[]
---@return boolean ok, string? err
function M.write_lines(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = ("%s.tmp.%d"):format(path, uv.os_getpid())
  local f, err = io.open(tmp, "w")
  if not f then return false, err end
  f:write(#lines > 0 and (table.concat(lines, "\n") .. "\n") or "")
  f:close()
  local ok, rename_err = uv.fs_rename(tmp, path)
  if not ok then
    uv.fs_unlink(tmp)
    return false, rename_err
  end
  return true
end

--- A cheap fingerprint of a file, to notice that it changed.
---@param path string
---@return string
function M.stamp(path)
  local st = uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size) or "none"
end

--- Read the notes file, let *fn* change the document, write it back. If
--- another process wrote the file meanwhile, the change is redone on the new
--- content, so an agent's lines are never overwritten with a stale copy.
---@generic T
---@param path string
---@param fn fun(doc: review_notes.Doc): T?
---@return T? result
function M.update(path, fn)
  for _ = 1, 5 do
    local before = M.stamp(path)
    local lines = M.read_lines(path)
    local doc = M.parse(lines)
    local result = fn(doc)
    if M.stamp(path) == before then
      local out = M.render(doc)
      -- No write when nothing changed: it would wake every file watcher.
      if vim.deep_equal(out, lines) then return result end
      local ok, err = M.write_lines(path, out)
      if not ok then error("cannot write " .. path .. ": " .. tostring(err)) end
      return result
    end
  end
  error("notes file keeps changing: " .. path)
end

-- Sidecar ---------------------------------------------------------------

---@class review_notes.ThreadState
---@field status "open"|"resolved" the remote status at the last pull
---@field resolved_by string? who resolved it, when not me
---@field seen table<string, boolean> remote comment ids I have seen
---@field seen_status boolean whether I have seen who resolved it

---@class review_notes.MrRecord
---@field iid integer|string
---@field ref string?
---@field state string? "opened", "merged", "closed"
---@field url string?
---@field me string? my user name on the remote
---@field reviewers string[]? who is assigned to review it
---@field approved boolean? enough approvals to merge
---@field approved_by string[]? who approved it
---@field approvals_left integer?

---@class review_notes.Sidecar
---@field threads table<string, review_notes.ThreadState>
---@field mr review_notes.MrRecord? the merge request the review is on

--- The sidecar next to a notes file: `x.md` gives `x.json`.
---@param notes_path string
---@return string
function M.sidecar_path(notes_path)
  return (notes_path:gsub("%.md$", "")) .. ".json"
end

---@param path string
---@return review_notes.Sidecar
function M.read_sidecar(path)
  local text = table.concat(M.read_lines(path), "\n")
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= "table" or type(data.threads) ~= "table" then return { threads = {} } end
  return data
end

---@param path string
---@param side review_notes.Sidecar
function M.write_sidecar(path, side)
  local ok, err = M.write_lines(path, { vim.json.encode(side) })
  if not ok then error("cannot write " .. path .. ": " .. tostring(err)) end
end

return M
