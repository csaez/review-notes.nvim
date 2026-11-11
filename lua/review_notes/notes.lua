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
--   [new]    set by pull when a thread is new or its comments changed.
-- Quoted (`> `) lines are a cache of the remote thread, rewritten on pull
-- (remote wins). Other indented lines are mine and pull never touches them.
-- Lines starting with `#` are ignored. Absolute paths are notes on files
-- outside the repo and are never sent.
local M = {}

local RESOLVED_MARK = "> (resolved)"

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
  e.quoted, e.mine, e.remote_resolved = {}, {}, false
  for _, l in ipairs(e.body) do
    if l == RESOLVED_MARK then
      e.remote_resolved = true
    elseif l:sub(1, 1) == ">" then
      table.insert(e.quoted, l)
    else
      table.insert(e.mine, l)
    end
  end
  e.kind = e.id and "thread" or "note"
  e.text = table.concat(vim.list_extend({ e.head }, e.body), "\n")
end

---@param lines string[]
---@return review_notes.Entry[] entries
---@return integer[] summary indices of the summary lines
local function scan(lines)
  local entries, summary = {}, {}
  local cur ---@type review_notes.Entry?
  for i, raw in ipairs(lines) do
    -- `path:line: text` or `path:first-last: text`
    local path, first, last, text = raw:match("^([^%s#>:][^%s:]*):(%d+)%-(%d+):%s?(.*)$")
    if not path then
      path, first, text = raw:match("^([^%s#>:][^%s:]*):(%d+):%s?(.*)$")
    end
    if path then
      cur = new_entry(i, raw, path, first, last, text or "")
      table.insert(entries, cur)
    elseif cur and raw:match("^%s") then
      local body = vim.trim(raw)
      if body ~= "" then
        table.insert(cur.body, body)
        cur.last = i
      end
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

--- Drop every [new] tag.
---@return string[] lines
---@return integer count
function M.clear_new(lines)
  local out, n = vim.deepcopy(lines), 0
  for _, e in ipairs(M.parse(lines)) do
    if e.new then
      e.new = false
      out[e.src] = M.head_line(e)
      n = n + 1
    end
  end
  return out, n
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
        e.send = vim.trim(table.concat(vim.list_extend({ e.head }, e.mine), "\n"))
        if e.send ~= "" then table.insert(plan.new, e) end
      end
    else
      if #e.mine > 0 then
        e.send = table.concat(e.mine, "\n")
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
