-- The notes file: parsing, rendering, and the pure edits done on it (pull
-- merge, push plan, tag changes, clean). No buffers and no processes here, so
-- everything is testable with plain line lists.
--
-- Format: an unindented line starts an entry, indented lines belong to it.
-- `path:line[-end]:` in front makes it a note on code; without a location it
-- is a general note, about the whole change (a GitLab overview thread):
--
--   main concern is the connect timeout                           general note
--   [id:ghi789] [new] @alice: please add a changelog entry        general thread
--     > @bob: +1
--
--   src/http.cpp:88: timeout must cover connect, not only read    new note
--   src/http.cpp:90: [draft] maybe a leak here?                   never sent
--   src/http.cpp:120: [id:abc123] [new] @alice: why 30s?          remote thread
--     > @bob: +1                                                  remote (cache)
--     matches the studio default                                  my reply
--   src/http.cpp:50: [resolved] [id:def456] @alice: typo          resolved
--     > (resolved)                                                remote state
--
-- Tags after the location, in this order: [resolved] [draft] [id:X] [new].
--   [draft]  never sent; removing it approves the entry (notes and replies).
--   [id:X]   the remote thread id; entries without one are new threads.
--   [new]    someone else changed the entry since I last acted on it: set by
--            pull (a thread is new or its comments changed) and by pi after a
--            round (an entry it added or changed). Stays until I reply,
--            resolve, reopen or accept it; until then push holds the entry
--            back, so nothing is sent over what I have not read.
-- Quoted (`> `) lines are a cache of the remote thread, rewritten on pull
-- (remote wins). Other indented lines are mine and pull never touches them.
-- Body lines lose exactly their two-space indent, so code keeps its own
-- indentation, and blank lines between my lines are kept (paragraphs). A line
-- of mine that starts with `>` is written as `\>` so it is not read as quoted.
-- Lines starting with `#` are ignored. A general note whose text would read
-- as something else (a location, a tag, `#`) is written with a leading `\`.
-- Paths are relative to the review's root; an absolute one (written by hand)
-- is never sent: GitLab only takes repo paths.
--
-- Line 0 is the whole file. An entry on a directory (a submodule pointer)
-- has no code to show it on; it lives in the notes file only.
--
--   src/http.cpp:0: [id:jkl012] @bob: split this file         whole file
--   extern/lib:1: [id:mno345] @bob: bump to the 2.1 tag       submodule
--
-- Pull keeps the file in order: general entries first, then notes on code
-- by path and line.
local M = {}

local RESOLVED_MARK = "> (resolved)"

--- Line of a conversation view (thread_view, entry_view) for a resolved thread.
M.RESOLVED_VIEW = "> [!TIP] Resolved"

--- Lines of an entry view above my unsent reply to a thread: what follows is
--- still local, as a draft (needs approval) or ready for the next push.
M.UNSENT_VIEW = "> [!NOTE] Not sent yet"
M.UNSENT_DRAFT_VIEW = "> [!WARNING] Draft, not sent"

--- Escape a line of my text so it is not read as a quoted (remote) line.
---@param line string
---@return string
function M.escape(line)
  return line:match("^\\*>") and ("\\" .. line) or line
end

---@param line string
---@return string
function M.unescape(line)
  return line:match("^\\+>") and line:sub(2) or line
end

-- Body line without its indent: two spaces (or a tab) as written by render;
-- anything else is trimmed, for hand-written files.
local function dedent(raw)
  local l = raw:match("^  (.*)$") or raw:match("^\t(.*)$") or vim.trim(raw)
  return (l:gsub("%s+$", ""))
end

---@class review_notes.Entry
---@field general boolean about the whole change: no path, line or loc
---@field path string?
---@field line integer?
---@field end_line integer?
---@field head string first-line text, without tags
---@field text string head and body lines, for display
---@field kind "note"|"thread"
---@field id string? remote thread id
---@field resolved boolean
---@field draft boolean
---@field new boolean
---@field body string[] indented lines, trimmed
---@field quoted string[] remote cache, without the resolved marker
---@field mine string[] my unsent lines
---@field remote_resolved boolean the thread's resolved state as of the last pull
---@field src integer line of the entry head in the file
---@field last integer last line of the entry
---@field loc string? location as written, e.g. "a.py:3-5"
---@field raw string the head line as read
---@field send string? text to send, set by plan()

-- An entry head; *path* nil makes it a general entry.
local function new_entry(i, raw, path, first, last, text)
  local e = {
    general = path == nil,
    path = path,
    line = tonumber(first),
    end_line = last and tonumber(last) or nil,
    resolved = false,
    draft = false,
    new = false,
    body = {},
    src = i,
    last = i,
    raw = raw,
    loc = path and (path .. ":" .. first .. (last and ("-" .. last) or "")) or nil,
  }
  while true do
    local tag, after = text:match("^%[([%w:_%.%-]+)%]%s*(.*)$")
    if tag == "resolved" then
      e.resolved = true
    elseif tag == "draft" then
      e.draft = true
    elseif tag == "new" then
      e.new = true
    elseif tag and tag:match("^id:.") then
      e.id = tag:sub(4)
    else
      break
    end
    text = after
  end
  if e.general and text:sub(1, 1) == "\\" then text = text:sub(2) end
  e.head = text
  return e
end

local LOC_PAT = "^([^%s#>:\\][^%s:]*):(%d+)"

-- The head of a general entry, escaped when it would read as something else.
local function escape_general(head)
  if head:match("^[%[#\\]") or head:match(LOC_PAT .. "%-?%d*:") then return "\\" .. head end
  return head
end

local function finish(e)
  -- scan only keeps blank lines that have body lines after them.
  e.quoted, e.mine, e.remote_resolved = {}, {}, false
  local blanks, prev = 0, nil
  for _, l in ipairs(e.body) do
    if l == "" then
      blanks = blanks + 1
    else
      local kind = l == RESOLVED_MARK and "mark" or l:sub(1, 1) == ">" and "quoted" or "mine"
      if kind == "mark" then
        e.remote_resolved = true
      elseif kind == "quoted" then
        table.insert(e.quoted, l)
      else
        -- Paragraph breaks only count inside my own text.
        if prev == "mine" then
          for _ = 1, blanks do table.insert(e.mine, "") end
        end
        table.insert(e.mine, l)
      end
      blanks, prev = 0, kind
    end
  end
  e.kind = e.id and "thread" or "note"
  e.text = table.concat(vim.list_extend({ e.head }, vim.tbl_map(M.unescape, e.body)), "\n")
end

--- My lines of *e* as text (unescaped), for display and sending.
---@param lines string[]
---@return string
function M.my_text(lines)
  return table.concat(vim.tbl_map(M.unescape, lines), "\n")
end

---@param lines string[]
---@return review_notes.Entry[] entries
local function scan(lines)
  local entries = {}
  local cur ---@type review_notes.Entry?
  local blanks = 0 -- blank lines seen in the current entry, kept if more body follows
  for i, raw in ipairs(lines) do
    -- `path:line: text` or `path:first-last: text`
    local path, first, last, text = raw:match(LOC_PAT .. "%-(%d+):%s?(.*)$")
    if not path then
      path, first, text = raw:match(LOC_PAT .. ":%s?(.*)$")
    end
    if path == "." and first == "0" and not last then
      -- The old way of writing a general note; rewritten without it on edit.
      cur = new_entry(i, raw, nil, nil, nil, text or "")
      table.insert(entries, cur)
      blanks = 0
    elseif path then
      cur = new_entry(i, raw, path, first, last, text or "")
      table.insert(entries, cur)
      blanks = 0
    elseif cur and raw:match("^%s*$") then
      blanks = blanks + 1
    elseif cur and raw:match("^%s") then
      for _ = 1, blanks do table.insert(cur.body, "") end
      blanks = 0
      table.insert(cur.body, dedent(raw))
      cur.last = i
    elseif raw:match("^#") then
      cur = nil
    elseif cur and cur.general and not cur.id and blanks == 0 and not raw:match("^%[") then
      -- Hand-written prose: the lines of a paragraph are one general note.
      table.insert(cur.body, vim.trim(raw))
      cur.last = i
    elseif not raw:match("^%s*$") then
      cur = new_entry(i, raw, nil, nil, nil, raw)
      table.insert(entries, cur)
      blanks = 0
    end
  end
  for _, e in ipairs(entries) do
    finish(e)
  end
  return entries
end

---@param lines string[]
---@return review_notes.Entry[]
function M.parse(lines)
  return scan(lines)
end

--- The head line of *e*, with its tags.
---@param e review_notes.Entry
---@return string
function M.head_line(e)
  local tags = {}
  if e.resolved then table.insert(tags, "[resolved]") end
  if e.draft then table.insert(tags, "[draft]") end
  if e.id then table.insert(tags, "[id:" .. e.id .. "]") end
  if e.new then table.insert(tags, "[new]") end
  table.insert(tags, e.general and escape_general(e.head) or e.head)
  local line = table.concat(tags, " ")
  if not e.general then line = e.loc .. ": " .. line end
  return (line:gsub("%s+$", ""))
end

---@param e review_notes.Entry
---@return string[]
local function render(e)
  local out = { M.head_line(e) }
  local function add(l) table.insert(out, (("  " .. l):gsub("%s+$", ""))) end
  for _, l in ipairs(e.quoted) do add(l) end
  if e.remote_resolved then add(RESOLVED_MARK) end
  for _, l in ipairs(e.mine) do add(l) end
  return out
end

local function splice(lines, first, last, repl)
  local out = {}
  for i = 1, first - 1 do out[#out + 1] = lines[i] end
  for _, l in ipairs(repl) do out[#out + 1] = l end
  for i = last + 1, #lines do out[#out + 1] = lines[i] end
  return out
end

-- Collapse blank runs and strip blank edges, as left behind by removals.
local function tidy(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if l:match("%S") or (#out > 0 and out[#out]:match("%S")) then table.insert(out, l) end
  end
  while #out > 0 and not out[#out]:match("%S") do table.remove(out) end
  return out
end

--- Apply *fn* to the entry whose head is at line *idx* and rewrite that head.
---@param fn fun(e: review_notes.Entry)
---@return string[]
function M.edit_entry(lines, idx, fn)
  local out = vim.deepcopy(lines)
  for _, e in ipairs(M.parse(lines)) do
    if e.src == idx then
      fn(e)
      out[idx] = M.head_line(e)
      break
    end
  end
  return out
end

local function entry_at(lines, idx)
  for _, e in ipairs(M.parse(lines)) do
    if e.src == idx then return e end
  end
end

---@class review_notes.Turn
---@field whole boolean the turn is the whole note, head included
---@field first integer first line of the turn in the file
---@field last integer last line (first - 1 when the turn is empty)
---@field text string[] the turn as plain text (no indent, unescaped)

--- My latest turn in the entry at *idx*, which the editor opens with: the
--- whole note while nobody has answered it, else my lines after the last
--- quoted one (none when I have not answered yet).
---@return review_notes.Turn?
function M.turn(lines, idx)
  local e = entry_at(lines, idx)
  if not e then return nil end
  local last_quote
  for i = e.src + 1, e.last do
    if dedent(lines[i]):sub(1, 1) == ">" then last_quote = i end
  end
  local whole = not last_quote and not e.id
  local from = whole and e.src + 1 or (last_quote or e.src) + 1
  local text = whole and { e.head } or {}
  for i = from, e.last do
    table.insert(text, M.unescape(dedent(lines[i])))
  end
  return { whole = whole, first = whole and e.src or from, last = e.last, text = text }
end

--- Remove the entry at *idx*.
---@return string[]
function M.delete_entry(lines, idx)
  local e = entry_at(lines, idx)
  if not e then return lines end
  return tidy(splice(lines, e.src, e.last, {}))
end

--- Replace my latest turn in the entry at *idx* (see `turn`) with *text*.
--- *fn*, when given, edits the entry's tags.
---@param text string[]
---@param fn fun(e: review_notes.Entry)?
---@return string[]
function M.set_turn(lines, idx, text, fn)
  local e, t = entry_at(lines, idx), M.turn(lines, idx)
  if not e or not t then return lines end
  if fn then fn(e) end
  local repl = {}
  if t.whole then
    e.head = text[1] or ""
    repl[1] = M.head_line(e)
  end
  for i = t.whole and 2 or 1, #text do
    table.insert(repl, text[i] == "" and "" or ("  " .. M.escape(text[i])))
  end
  local out = splice(lines, t.first, t.last, repl)
  if not t.whole then out[idx] = M.head_line(e) end
  return out
end

--- The conversation of the entry at *idx* as markdown lines, for reading: the
--- head and quoted comments, and my lines before my latest turn (see `turn`).
--- Empty when there is nothing but my own turn.
---@return string[]
function M.thread_view(lines, idx)
  local e, t = entry_at(lines, idx), M.turn(lines, idx)
  if not e or not t then return {} end
  local out = {}
  local function author_line(who, text)
    if #out > 0 then table.insert(out, "") end
    table.insert(out, "### " .. who .. (text ~= "" and (" " .. text) or ""))
  end
  if t.whole then return out end
  local who, rest = e.head:match("^(@[%w._-]+):%s*(.*)$")
  if who then
    author_line(who, "")
    table.insert(out, rest)
  else
    table.insert(out, e.head)
  end
  for i = e.src + 1, t.first - 1 do
    local l = dedent(lines[i])
    if l == RESOLVED_MARK then
      table.insert(out, "")
      table.insert(out, M.RESOLVED_VIEW)
    elseif l:sub(1, 1) == ">" then
      l = l:gsub("^>%s?", "")
      local w, r = l:match("^(@[%w._-]+):%s?(.*)$")
      if w then
        author_line(w, "")
        table.insert(out, r)
      else
        table.insert(out, l)
      end
    else
      table.insert(out, M.unescape(l))
    end
  end
  return out
end

--- The whole conversation of *e* as markdown lines: head, remote comments and
--- my lines, in file order.
---@param e review_notes.Entry
---@return string[]
function M.entry_view(e)
  local out = {}
  local function author(who, rest)
    if #out > 0 then table.insert(out, "") end
    table.insert(out, "### " .. who)
    table.insert(out, rest)
  end
  local who, rest = e.head:match("^(@[%w._-]+):%s*(.*)$")
  if who then
    author(who, rest)
  else
    table.insert(out, e.head)
  end
  local first = true
  -- On a thread my lines are a reply that only exists here; without the
  -- marker they read as part of the last remote comment.
  local unsent = e.id ~= nil
  for _, raw in ipairs(e.body) do
    if raw == RESOLVED_MARK then
      vim.list_extend(out, { "", M.RESOLVED_VIEW })
    elseif raw:sub(1, 1) ~= ">" and unsent then
      unsent = false
      vim.list_extend(out, { "", e.draft and M.UNSENT_DRAFT_VIEW or M.UNSENT_VIEW, M.unescape(raw) })
    elseif raw:sub(1, 1) == ">" then
      local l = raw:gsub("^>%s?", "")
      -- Some backends repeat the first comment, the head, as the first quote.
      local dup = first and l == e.head
      first = false
      if dup then goto continue end
      local w, r = l:match("^(@[%w._-]+):%s?(.*)$")
      if w then author(w, r) else table.insert(out, l) end
    else
      table.insert(out, M.unescape(raw))
    end
    ::continue::
  end
  return out
end

--- Lines of a new entry at *loc* (nil: a general entry) with *text* (first
--- line is the head).
---@param loc string?
---@param text string[]
---@return string[]
function M.new_entry_lines(loc, text)
  local out = { loc and (loc .. ": " .. text[1]) or escape_general(text[1]) }
  for i = 2, #text do
    table.insert(out, text[i] == "" and "" or ("  " .. M.escape(text[i])))
  end
  return out
end

--- Head text and quoted cache of a remote thread: the first comment is the
--- head, later comments are quoted.
---@return string head
---@return string[] quoted
function M.thread_lines(thread)
  local head, quoted = "", {}
  for i, c in ipairs(thread.comments or {}) do
    local body = ((c.body or ""):gsub("\r", ""):gsub("%s+$", ""))
    for j, raw in ipairs(vim.split(body, "\n", { plain = true })) do
      local l = raw:gsub("%s+$", "")
      if i == 1 and j == 1 then
        head = "@" .. c.author .. ": " .. l
      elseif j == 1 then
        table.insert(quoted, ("> @%s: %s"):format(c.author, l))
      else
        table.insert(quoted, ((("> " .. l):gsub("%s+$", ""))))
      end
    end
  end
  return head, quoted
end

local function same(a, b)
  return table.concat(a, "\n") == table.concat(b, "\n")
end

-- Whether the backend says which comments are mine, and my username (nil
-- when it does but none is: then every comment is someone else's).
---@return boolean known
---@return string? me
local function identity(threads)
  local known, me = false, nil
  for _, t in ipairs(threads) do
    for _, c in ipairs(t.comments or {}) do
      if type(c.mine) == "boolean" then known = true end
      if c.mine == true then me = c.author end
    end
  end
  return known, me
end

-- The conversation (head and quoted cache, as written by thread_lines)
-- without the comments of *me*, to tell someone else's activity from mine.
-- A body line that itself reads as `@user: ` splits a comment, the same way
-- on both sides of a comparison.
local function others_text(head, quoted, me)
  local out, skip = {}, false
  local function add(l, first)
    local who = l:match("^@([%w._-]+):%s") or l:match("^@([%w._-]+):$")
    if who or first then skip = me ~= nil and who == me end
    if not skip then table.insert(out, l) end
  end
  add(head, true)
  for _, q in ipairs(quoted) do
    add((q:gsub("^>%s?", "")), false)
  end
  return table.concat(out, "\n")
end

---@class review_notes.Thread
---@field id string
---@field path string? nil (JSON null) for a thread on the whole change
---@field line integer? last line (where the remote anchors a range)
---@field start_line integer? first line of a multi-line comment
---@field resolved boolean
---@field resolvable boolean? false for a one-off comment, which has no resolved state on the remote
---@field resolved_by string? who resolved it, when known
---@field resolved_by_me boolean? whether I did (in the browser too), when known
---@field comments { author: string, body: string, mine: boolean? }[]

--- Merge remote threads into the notes: remote wins. A known thread gets its
--- quoted block and [resolved] state rewritten (my lines stay), except a
--- resolve or reopen of mine not sent yet (the tag differs from the last
--- remote state), and is flagged [new] when its comments changed while it is
--- open on either side (push then holds my unsent resolve or reopen back
--- until I read what came in); it keeps its line, which follows my edits,
--- but takes the remote's location when that is another file or none (the
--- file had it wrong: written by hand, an older format, a rename). An unknown
--- thread is added as an entry. A thread gone from the remote is dropped,
--- unless it has unsent lines of mine: those stay, reported as `gone`. A one-off
--- comment (not resolvable) keeps the resolved state I gave it, since the
--- remote has none; the remote's guess only applies when it is new.
---
--- When the backend says which comments are mine (`mine`), only someone
--- else's comments count as a change, so mine (sent by push or written in the
--- browser) never flag a thread, and a resolve by someone else
--- (`resolved_by_me == false`) flags it too: a claim to check. Otherwise a
--- resolved thread is never flagged, and `opts.quiet` flags nothing: used for
--- the pull right after a push, so what I just sent does not come back as new
--- (a draft's id is not the thread's id, so threads cannot be told apart).
--- With `mine`, `opts.quiet` is not needed and ignored.
---@param threads review_notes.Thread[]
---@param opts { quiet: boolean? }?
---@return string[] lines
---@return { added: integer, updated: integer, new: integer, removed: integer, gone: integer } stats
function M.merge(lines, threads, opts)
  local known, me = identity(threads)
  local quiet = opts and opts.quiet and not known
  local by_id = {}
  for _, e in ipairs(M.parse(lines)) do
    if e.id then by_id[e.id] = e end
  end
  local stats = { added = 0, updated = 0, new = 0, removed = 0, gone = 0 }
  local edits, appended, seen = {}, {}, {}
  for _, t in ipairs(threads) do
    local head, quoted = M.thread_lines(t)
    local e = by_id[t.id]
    seen[t.id] = true
    local path = t.path ~= vim.NIL and t.path or nil
    local start = t.start_line ~= vim.NIL and t.start_line or nil
    local first, last = path and tostring(t.line or 0), nil
    if path and start and start < (t.line or 0) then first, last = tostring(start), tostring(t.line) end
    local resolved, remote = t.resolved, t.resolved
    if e and t.resolvable == false then
      resolved, remote = e.resolved, e.resolved
    elseif e and e.resolved ~= e.remote_resolved then
      -- Unsent: either the remote is as before, or it already agrees.
      resolved = e.resolved
    end
    -- Open on either side: a reply there is something to read before my
    -- unsent resolve or reopen goes out.
    local open = not resolved or (t.resolvable ~= false and not t.resolved)
    local flag = open and not quiet
    if e then
      local changed = e.head ~= head or not same(e.quoted, quoted)
      if changed and known then changed = others_text(e.head, e.quoted, me) ~= others_text(head, quoted, me) end
      -- Resolved since the last pull by someone else, over my open thread.
      local claim = t.resolvable ~= false and t.resolved and not e.remote_resolved and not e.resolved
        and t.resolved_by_me == false and type(t.resolved_by) == "string"
      local before = table.concat(render(e), "\n")
      e.head, e.quoted, e.resolved, e.remote_resolved = head, quoted, resolved, remote
      if e.path ~= path then
        local moved = new_entry(0, "", path, first, last, "")
        e.general, e.path, e.line, e.end_line, e.loc = moved.general, moved.path, moved.line, moved.end_line, moved.loc
      end
      if (changed and flag) or claim then
        e.new = true
        stats.new = stats.new + 1
      end
      local block = render(e)
      -- The head as written may differ from its rendering (an older format).
      if table.concat(block, "\n") ~= before or lines[e.src] ~= block[1] then
        stats.updated = stats.updated + 1
        table.insert(edits, { first = e.src, last = e.last, lines = block })
      end
    else
      if known and others_text(head, quoted, me) == "" then flag = false end
      local fresh = new_entry(0, "", path, first, last, head)
      fresh.id, fresh.resolved, fresh.remote_resolved = t.id, t.resolved, t.resolved
      fresh.quoted, fresh.mine, fresh.new = quoted, {}, flag
      if flag then stats.new = stats.new + 1 end
      stats.added = stats.added + 1
      table.insert(appended, render(fresh))
    end
  end
  for id, e in pairs(by_id) do
    if not seen[id] then
      if #e.mine > 0 then
        stats.gone = stats.gone + 1
      else
        stats.removed = stats.removed + 1
        table.insert(edits, { first = e.src, last = e.last, lines = {} })
      end
    end
  end
  table.sort(edits, function(a, b) return a.first > b.first end)
  local out = vim.deepcopy(lines)
  for _, ed in ipairs(edits) do
    out = splice(out, ed.first, ed.last, ed.lines)
  end
  for _, block in ipairs(appended) do
    if #out > 0 then table.insert(out, "") end
    vim.list_extend(out, block)
  end
  return M.sort(tidy(out)), stats
end

-- Where an entry goes in a sorted file: general entries first, then by path
-- and line; the file order breaks ties.
local function before(a, b)
  if a.general ~= b.general then return a.general end
  if not a.general then
    if a.path ~= b.path then return a.path < b.path end
    if a.line ~= b.line then return a.line < b.line end
    local ae, be = a.end_line or a.line, b.end_line or b.line
    if ae ~= be then return ae < be end
  end
  return a.src < b.src
end

--- Put the entries in order (see `before`), each moved as a block with the
--- comment lines after it. A file already in order is returned as it is.
---@param lines string[]
---@return string[]
function M.sort(lines)
  local entries = M.parse(lines)
  local sorted = vim.list_extend({}, entries)
  table.sort(sorted, before)
  local moved = false
  for i, e in ipairs(sorted) do
    if e ~= entries[i] then moved = true end
  end
  if not moved then return lines end
  local next_src = {}
  for i, e in ipairs(entries) do
    next_src[e] = entries[i + 1] and entries[i + 1].src or #lines + 1
  end
  local out = vim.list_slice(lines, 1, entries[1].src - 1)
  for _, e in ipairs(sorted) do
    while #out > 0 and not out[#out]:match("%S") do table.remove(out) end
    if #out > 0 then table.insert(out, "") end
    vim.list_extend(out, vim.list_slice(lines, e.src, next_src[e] - 1))
  end
  return tidy(out)
end

--- Add the entry *entry* (lines from `new_entry_lines`): a general one after
--- the last general entry, any other at the end.
---@param entry string[]
---@param general boolean
---@return string[]
function M.add_entry(lines, entry, general)
  local out = vim.deepcopy(lines)
  local at = #out + 1
  if general then
    at = 1
    for _, e in ipairs(M.parse(lines)) do
      if e.general then
        at = e.last + 1
      elseif at == 1 then
        at = e.src
        break
      end
    end
  end
  local block = vim.list_extend({}, entry)
  if at > 1 and (out[at - 1] or ""):match("%S") then table.insert(block, 1, "") end
  if at <= #out and out[at]:match("%S") then table.insert(block, "") end
  return tidy(splice(out, at, at - 1, block))
end

---@class review_notes.Plan
---@field new review_notes.Entry[] entries to start as new threads (`send` has the text)
---@field replies review_notes.Entry[] threads with a reply of mine (`send` has the text)
---@field states review_notes.Entry[] threads whose resolved tag differs from the remote
---@field drafts integer draft entries waiting for approval (open, or resolved with something to send), never sent
---@field held integer entries tagged new with something to send, held back until read

--- Whether *e* has something a push would send, were it approved and read:
--- a new note, a reply, or a resolve / reopen.
---@param e review_notes.Entry
---@return boolean
function M.has_changes(e)
  if e.id then return #e.mine > 0 or e.resolved ~= e.remote_resolved end
  return not e.resolved and vim.trim(e.head .. "\n" .. M.my_text(e.mine)) ~= ""
end
local has_changes = M.has_changes

--- What a push would send.
---@return review_notes.Plan
function M.plan(lines)
  local plan = { new = {}, replies = {}, states = {}, drafts = 0, held = 0 }
  for _, e in ipairs(M.parse(lines)) do
    if e.path and vim.startswith(e.path, "/") then
      -- not a repo path: nothing GitLab could anchor it to
    elseif e.draft then
      -- A resolved draft still counts when it holds a reply or a resolve:
      -- that is how pi hands back a thread it handled.
      if not e.resolved or has_changes(e) then plan.drafts = plan.drafts + 1 end
    elseif e.new then
      if has_changes(e) then plan.held = plan.held + 1 end
    elseif not e.id then
      if not e.resolved then
        e.send = vim.trim(e.head .. "\n" .. M.my_text(e.mine))
        if e.send ~= "" then table.insert(plan.new, e) end
      end
    else
      if #e.mine > 0 then
        e.send = M.my_text(e.mine)
        table.insert(plan.replies, e)
      end
      if e.resolved ~= e.remote_resolved then table.insert(plan.states, e) end
    end
  end
  return plan
end

local function count(n, one, many) return n .. " " .. (n == 1 and one or many) end

--- One-line description of a plan, or nil when there is nothing to send.
---@param plan review_notes.Plan
---@return string?
function M.describe(plan)
  local parts = {}
  if #plan.new > 0 then table.insert(parts, count(#plan.new, "new thread", "new threads")) end
  if #plan.replies > 0 then table.insert(parts, count(#plan.replies, "reply", "replies")) end
  if #plan.states > 0 then table.insert(parts, count(#plan.states, "state change", "state changes")) end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

--- What a push leaves out (drafts, [new] entries), as " (...)", or "".
---@param plan review_notes.Plan
---@return string
function M.describe_skipped(plan)
  local parts = {}
  if plan.drafts > 0 then table.insert(parts, count(plan.drafts, "draft", "drafts") .. " not sent") end
  if plan.held > 0 then
    table.insert(parts, count(plan.held, "[new] entry", "[new] entries") .. " held back until read")
  end
  return #parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or ""
end

--- Remove what was sent from the notes: new entries go (pull brings them back
--- as threads), replies lose my lines.
---@param plan review_notes.Plan
---@param ok { new: table<table, boolean>, replies: table<table, boolean> }
---@return string[]
function M.apply_sent(lines, plan, ok)
  local ops, used = {}, {}
  local function locate(e)
    -- The file may have changed since the plan was made; find the head by text.
    for i, l in ipairs(lines) do
      if l == e.raw and not used[i] then
        used[i] = true
        return i
      end
    end
  end
  for _, e in ipairs(plan.new) do
    local i = ok.new[e] and locate(e)
    if i then table.insert(ops, { first = i, last = i + e.last - e.src, lines = {} }) end
  end
  for _, e in ipairs(plan.replies) do
    local i = ok.replies[e] and locate(e)
    if i then
      local copy = vim.tbl_extend("force", e, { mine = {} })
      table.insert(ops, { first = i, last = i + e.last - e.src, lines = render(copy) })
    end
  end
  table.sort(ops, function(a, b) return a.first > b.first end)
  local out = vim.deepcopy(lines)
  for _, op in ipairs(ops) do
    out = splice(out, op.first, op.last, op.lines)
  end
  return tidy(out)
end

--- Drop resolved entries that have nothing left to send.
---@return string[] lines
---@return integer count
function M.clean(lines)
  local ops = {}
  for _, e in ipairs(M.parse(lines)) do
    local pending = e.id and (#e.mine > 0 or e.resolved ~= e.remote_resolved)
    if e.resolved and not pending then
      table.insert(ops, { first = e.src, last = e.last })
    end
  end
  table.sort(ops, function(a, b) return a.first > b.first end)
  local out = vim.deepcopy(lines)
  for _, op in ipairs(ops) do
    out = splice(out, op.first, op.last, {})
  end
  return tidy(out), #ops
end

return M
