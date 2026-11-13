-- The notes file: parsing, rendering, and the pure edits done on it (pull
-- merge, push plan, tag changes, clean). No buffers and no processes here, so
-- everything is testable with plain line lists.
--
-- Format, one entry per `path:line[-end]:` line, indented lines belong to it:
--
--   Overall looks good, main concern is the connect timeout.      summary
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
--            resolve, reopen or accept it.
-- Quoted (`> `) lines are a cache of the remote thread, rewritten on pull
-- (remote wins). Other indented lines are mine and pull never touches them.
-- Body lines lose exactly their two-space indent, so code keeps its own
-- indentation, and blank lines between my lines are kept (paragraphs). A line
-- of mine that starts with `>` is written as `\>` so it is not read as quoted.
-- Lines starting with `#` are ignored. Absolute paths are notes on files
-- outside the repo and are never sent.
local M = {}

local RESOLVED_MARK = "> (resolved)"
-- How pi asks under a note (coding-workflow.ts, /fixup).
M.PI_QUESTION = "> @pi: QUESTION:"

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
---@field path string
---@field line integer
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
---@field my_turn boolean open and ending with a question from pi: waiting for my answer
---@field src integer line of the entry head in the file
---@field last integer last line of the entry
---@field loc string location as written, e.g. "a.py:3-5"
---@field raw string the head line as read
---@field send string? text to send, set by plan()

local function new_entry(i, raw, path, first, last, text)
  local e = {
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
    loc = path .. ":" .. first .. (last and ("-" .. last) or ""),
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
  e.head = text
  return e
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
  -- Remote threads have no such marker: pull flags their changes as [new]
  -- (quoted lines do not say which author is me).
  local last = prev == "quoted" and e.quoted[#e.quoted] or ""
  e.my_turn = not e.resolved and vim.startswith(last, M.PI_QUESTION)
end

--- My lines of *e* as text (unescaped), for display and sending.
---@param lines string[]
---@return string
function M.my_text(lines)
  return table.concat(vim.tbl_map(M.unescape, lines), "\n")
end

---@param lines string[]
---@return review_notes.Entry[] entries
---@return integer[] summary indices of the summary lines
local function scan(lines)
  local entries, summary = {}, {}
  local cur ---@type review_notes.Entry?
  local blanks = 0 -- blank lines seen in the current entry, kept if more body follows
  for i, raw in ipairs(lines) do
    -- `path:line: text` or `path:first-last: text`
    local path, first, last, text = raw:match("^([^%s#>:][^%s:]*):(%d+)%-(%d+):%s?(.*)$")
    if not path then
      path, first, text = raw:match("^([^%s#>:][^%s:]*):(%d+):%s?(.*)$")
    end
    if path then
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
    elseif not raw:match("^%s*$") then
      cur = nil
      if not raw:match("^#") then table.insert(summary, i) end
    end
  end
  for _, e in ipairs(entries) do
    finish(e)
  end
  return entries, summary
end

---@param lines string[]
---@return review_notes.Entry[]
function M.parse(lines)
  return (scan(lines))
end

--- The overall review comment: the lines that belong to no entry.
---@return string text
---@return integer[] indices
function M.summary(lines)
  local _, idx = scan(lines)
  local parts = {}
  for _, i in ipairs(idx) do
    table.insert(parts, lines[i])
  end
  return vim.trim(table.concat(parts, "\n")), idx
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
  table.insert(tags, e.head)
  local line = e.loc .. ": " .. table.concat(tags, " ")
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

--- Lines of a new entry at *loc* with *text* (first line is the head).
---@param text string[]
---@return string[]
function M.new_entry_lines(loc, text)
  local out = { loc .. ": " .. text[1] }
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

---@class review_notes.Thread
---@field id string
---@field path string
---@field line integer
---@field resolved boolean
---@field comments { author: string, body: string }[]

--- Merge remote threads into the notes: remote wins. A known thread gets its
--- quoted block and [resolved] state rewritten (my lines stay) and is flagged
--- [new] when its comments changed; an unknown thread is appended as an
--- entry. Entries whose id is gone from the remote are left alone. A resolved
--- thread is never flagged, and `opts.quiet` flags nothing: used for the pull
--- right after a push, so what I just sent does not come back as new (a
--- draft's id is not the thread's id, so threads cannot be told apart).
---@param threads review_notes.Thread[]
---@param opts { quiet: boolean? }?
---@return string[] lines
---@return { added: integer, updated: integer, new: integer } stats
function M.merge(lines, threads, opts)
  local quiet = opts and opts.quiet
  local by_id = {}
  for _, e in ipairs(M.parse(lines)) do
    if e.id then by_id[e.id] = e end
  end
  local stats = { added = 0, updated = 0, new = 0 }
  local edits, appended = {}, {}
  for _, t in ipairs(threads) do
    local head, quoted = M.thread_lines(t)
    local flag = not t.resolved and not quiet
    local e = by_id[t.id]
    if e then
      local changed = e.head ~= head or not same(e.quoted, quoted)
      local before = table.concat(render(e), "\n")
      e.head, e.quoted, e.resolved, e.remote_resolved = head, quoted, t.resolved, t.resolved
      if changed and flag then
        e.new = true
        stats.new = stats.new + 1
      end
      local block = render(e)
      if table.concat(block, "\n") ~= before then
        stats.updated = stats.updated + 1
        table.insert(edits, { first = e.src, last = e.last, lines = block })
      end
    else
      local fresh = new_entry(0, "", t.path, tostring(t.line), nil, head)
      fresh.id, fresh.resolved, fresh.remote_resolved = t.id, t.resolved, t.resolved
      fresh.quoted, fresh.mine, fresh.new = quoted, {}, flag
      if flag then stats.new = stats.new + 1 end
      stats.added = stats.added + 1
      table.insert(appended, render(fresh))
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
  return out, stats
end

---@class review_notes.Plan
---@field new review_notes.Entry[] entries to start as new threads (`send` has the text)
---@field replies review_notes.Entry[] threads with a reply of mine (`send` has the text)
---@field states review_notes.Entry[] threads whose resolved tag differs from the remote
---@field drafts integer open [draft] entries, which are never sent
---@field summary string

--- What a push would send.
---@return review_notes.Plan
function M.plan(lines)
  local plan = { new = {}, replies = {}, states = {}, drafts = 0, summary = (M.summary(lines)) }
  for _, e in ipairs(M.parse(lines)) do
    if vim.startswith(e.path, "/") then
      -- outside the repo
    elseif e.draft then
      if not e.resolved then plan.drafts = plan.drafts + 1 end
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
  if plan.summary ~= "" then table.insert(parts, "summary") end
  if #parts == 0 then return nil end
  return table.concat(parts, ", ")
end

--- Remove what was sent from the notes: new entries go (pull brings them back
--- as threads), replies lose my lines, the summary goes.
---@param plan review_notes.Plan
---@param ok { new: table<table, boolean>, replies: table<table, boolean>, summary: boolean }
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
  if ok.summary then
    local text, idx = M.summary(lines)
    if text == plan.summary then
      for _, i in ipairs(idx) do
        table.insert(ops, { first = i, last = i, lines = {} })
      end
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
