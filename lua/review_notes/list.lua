-- List mode of the sidebar: the whole review. A header with the branch, the
-- MR and the counts, then the threads in sections by urgency (each a fold).
-- The thread keys work on the thread under the cursor (or a visual
-- selection), and the review-wide keys live here: pull, publish, approve or
-- discard all proposed, the MR actions.
local review = require("review_notes.review")
local actions = require("review_notes.actions")
local config = require("review_notes.config")
local backend = require("review_notes.backend")
local thread = require("review_notes.thread")
local sidebar = require("review_notes.sidebar")
local sync = require("review_notes.sync")
local keys = require("review_notes.keys")
local checkpoint = require("review_notes.checkpoint")

local M = {}

local ns = vim.api.nvim_create_namespace("review_notes_list")

local SECTIONS = {
  { state = "unread", title = "Unread" },
  { state = "proposed", title = "Proposed" },
  { state = "unsent", title = "Not published" },
  { state = "open", title = "Open" },
  { state = "resolved", title = "Resolved", folded = true },
}


---@class review_notes.ListState
---@field ctx review_notes.Context
---@field rows table<integer, review_notes.Item> thread by buffer line
---@field mr table? what `mr.info` printed
---@field mr_error string?
---@field mr_for string? the `{mr}` the info was loaded for
---@field folded table<string, boolean> by section state
---@field want string|true|nil the next draw puts the cursor on this thread
---  (true: the first one)
---@field last string? the thread shown last, for the cursor when coming back
---@field keys review_notes.Key[]

---@type table<integer, review_notes.ListState> by buffer
local lists = {}

local function notify(msg, level) review.notify(msg, level) end

local function branch_of(ctx)
  return ctx.kind == "git" and ctx.branch or vim.fs.basename(ctx.path)
end

local function ago(t)
  local s = os.time() - t
  if s < 60 then return "just now" end
  if s < 3600 then return ("%d min ago"):format(math.floor(s / 60)) end
  return ("%d h ago"):format(math.floor(s / 3600))
end

--- The sync line: when it last worked, and why it fails now.
---@return string text, string hl
local function sync_line(ctx)
  local s = sync.state(ctx)
  local at = sync.pulled_at[ctx.path]
  local last = at and ("pulled " .. ago(at)) or "not pulled this session"
  if s.running then return "pulling...  (" .. last .. ")", "Comment" end
  if s.failing then
    local why = ({
      offline = "offline since " .. os.date("%H:%M", s.since),
      no_access = "no access to the MR",
      no_remote = "no remote for this repository",
      no_mr = "no merge request yet",
    })[s.kind] or "pull failing"
    local paused = s.paused and ", automatic pulls paused" or ""
    return ("%s%s  (%s)"):format(why, paused, last), s.kind == "no_mr" and "Comment" or "DiagnosticWarn"
  end
  if sync.ended(s.mr) then return last .. ", automatic pulls stopped", "Comment" end
  return last, "Comment"
end

local function at(users)
  return table.concat(vim.tbl_map(function(u) return "@" .. u end, users), ", ")
end

--- Who reviews and who approved: what to know before picking a review up.
--- From the last pull when it has them (approvals change while I review),
--- else from `mr.info`.
---@return string? text, string hl
local function review_line(h)
  local pulled = sync.state(h.ctx).mr
  local mr = pulled and pulled.reviewers and pulled or h.mr
  if not (mr and (mr.reviewers or mr.approved_by)) then return nil, "" end
  local me = mr.me
  local parts, hl = {}, "Comment"
  local peers = vim.tbl_filter(function(u) return u ~= me end, mr.approved_by or {})
  local mine = me and vim.tbl_contains(mr.approved_by or {}, me)
  if #peers > 0 then
    table.insert(parts, "approved by " .. at(peers))
    hl = "DiagnosticWarn"
  elseif mr.approvals_left and mr.approvals_left > 0 then
    table.insert(parts, ("%d approval%s left"):format(mr.approvals_left, mr.approvals_left == 1 and "" or "s"))
  end
  if mine then table.insert(parts, "approved by me") end
  local reviewers = mr.reviewers or {}
  if #reviewers == 0 then
    table.insert(parts, "no reviewer")
  else
    local others = vim.tbl_filter(function(u) return u ~= me end, reviewers)
    local list = vim.tbl_contains(reviewers, me) and (#others > 0 and ("me, " .. at(others)) or "me") or at(others)
    table.insert(parts, "reviewer" .. (#reviewers == 1 and "" or "s") .. ": " .. list)
  end
  return table.concat(parts, "  "), hl
end

--- How my checkout compares with the MR's head: what peers see is not what
--- I read. nil when they are the same, or the MR's head is unknown.
---@return string?
local function checkout_line(h)
  local mr = sync.state(h.ctx).mr
  local sha = mr and mr.sha or (h.mr and h.mr.sha)
  if not sha or h.ctx.kind ~= "git" then return nil end
  local ahead, behind = checkpoint.ahead_behind(h.ctx.root, sha)
  if not ahead then return "the MR's head is not in this checkout: fetch" end
  if ahead == 0 and behind == 0 then return nil end
  local parts = {}
  if ahead > 0 then table.insert(parts, ("%d ahead (not pushed)"):format(ahead)) end
  if behind > 0 then table.insert(parts, ("%d behind (update)"):format(behind)) end
  return "checkout vs MR: " .. table.concat(parts, ", ")
end

-- Drawing ---------------------------------------------------------------------

local update_hints ---@type fun(buf: integer)

local function draw(buf)
  local h = lists[buf]
  if not h or not vim.api.nvim_buf_is_valid(buf) then return end
  -- Keep each window on its thread: rows move when the MR line arrives or a
  -- thread changes section.
  local keep = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local lnum = vim.api.nvim_win_get_cursor(win)[1]
    keep[win] = { lnum = lnum, key = h.rows[lnum] and h.rows[lnum].key }
  end
  local items = review.items(h.ctx)
  local by_state = {}
  local counts = {}
  for _, item in ipairs(items) do
    by_state[item.state] = by_state[item.state] or {}
    table.insert(by_state[item.state], item)
    counts[item.state] = (counts[item.state] or 0) + 1
  end

  local lines, hls, rows, folds = {}, {}, {}, {}
  local function add(text, chunks)
    table.insert(lines, text)
    if chunks then hls[#lines] = chunks end
  end

  add("Review  " .. branch_of(h.ctx), { { 0, 6, "Title" } })
  if h.mr and h.mr.ref then
    local target = h.mr.target and (" -> " .. h.mr.target:gsub("^origin/", "")) or ""
    local head = h.mr.ref .. target
    local state = sync.ended(h.mr) and ("  [" .. h.mr.state .. "]") or ""
    local chunks = { { #head, -1, "Comment" } }
    if state ~= "" then chunks = { { #head, #head + #state, "DiagnosticWarn" }, { #head + #state, -1, "Comment" } } end
    add(head .. state .. (h.mr.title and ("  " .. h.mr.title) or ""), chunks)
  end
  local review_text, review_hl = review_line(h)
  if review_text then add(review_text, { { 0, -1, review_hl } }) end
  local checkout_text = checkout_line(h)
  if checkout_text then add(checkout_text, { { 0, -1, "DiagnosticWarn" } }) end
  if h.mr_error then add("MR: " .. h.mr_error, { { 0, -1, "DiagnosticWarn" } }) end
  local parts = {}
  for _, s in ipairs(SECTIONS) do
    if (counts[s.state] or 0) > 0 then table.insert(parts, ("%d %s"):format(counts[s.state], s.title:lower())) end
  end
  add(#parts > 0 and table.concat(parts, "  ") or "no threads", { { 0, -1, "Comment" } })
  local sync_text, sync_hl = sync_line(h.ctx)
  add(sync_text, { { 0, -1, sync_hl } })
  add("")

  -- The sidebar is narrow: anchors longer than this are cut from the left.
  local width = 0
  for _, item in ipairs(items) do width = math.max(width, #item.anchor) end
  width = math.min(width, 28)

  for _, s in ipairs(SECTIONS) do
    local list = by_state[s.state]
    if list then
      local style = review.style[s.state]
      add(("%s %s (%d)"):format(style.icon, s.title, #list), { { 0, -1, style.hl } })
      local first = #lines
      for _, item in ipairs(list) do
        local anchor = #item.anchor > width and ("..." .. item.anchor:sub(-(width - 3))) or item.anchor
        local tags = #item.tags > 0 and ("[" .. table.concat(item.tags, ", ") .. "] ") or ""
        local who = item.who ~= "" and (item.who .. ": ") or ""
        local text = ("  %s  %s%s%s"):format(anchor .. (" "):rep(width - #anchor), tags, who, item.summary)
        local a0 = 2
        local chunks = { { a0, a0 + width, item.kind == "change" and "Special" or "Directory" } }
        local t0 = a0 + width + 2
        if tags ~= "" then table.insert(chunks, { t0, t0 + #tags, "Comment" }) end
        local w0 = t0 + #tags
        if who ~= "" then
          table.insert(chunks, { w0, w0 + #who, item.who:sub(1, 2) == "me" and "ReviewMine" or "ReviewAuthor" })
        end
        if s.state == "resolved" then chunks = { { 0, -1, "ReviewResolved" } } end
        add(text, chunks)
        rows[#lines] = item
      end
      table.insert(folds, { first, #lines, s.state, s.folded })
      add("")
    end
  end
  while lines[#lines] == "" do table.remove(lines) end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for lnum, chunks in pairs(hls) do
    for _, c in ipairs(chunks) do
      local stop = c[2] == -1 and #lines[lnum] or math.min(c[2], #lines[lnum])
      if stop > c[1] then
        vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, c[1], { end_col = stop, hl_group = c[3] })
      end
    end
  end
  h.rows = rows
  local first_row = math.huge
  for lnum in pairs(rows) do first_row = math.min(first_row, lnum) end
  if first_row == math.huge then first_row = 1 end
  for win, k in pairs(keep) do
    local want = h.want or k.key
    local target = want == true and first_row or math.min(k.lnum, #lines)
    for lnum, item in pairs(rows) do
      if item.key == want then target = lnum end
    end
    vim.api.nvim_win_set_cursor(win, { target, 0 })
  end
  if next(keep) then h.want = nil end

  -- Folds: each section header and its rows. Manual folds, redone on every
  -- draw; a fold the user opened or closed keeps its state by section.
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_call(win, function()
      vim.wo[win][0].foldmethod = "manual"
      vim.cmd("silent! normal! zE")
      for _, f in ipairs(folds) do
        if f[2] > f[1] then
          vim.cmd(("silent! %d,%dfold"):format(f[1], f[2]))
          local closed = h.folded[f[3]]
          if closed == nil then closed = f[4] end
          if closed then vim.cmd(("silent! %dfoldclose"):format(f[1])) else vim.cmd(("silent! %dfoldopen"):format(f[1])) end
        end
      end
    end)
  end
  update_hints(buf)
end

local function redraw_all()
  for buf in pairs(lists) do
    if vim.api.nvim_buf_is_valid(buf) then draw(buf) else lists[buf] = nil end
  end
end

-- Targets -----------------------------------------------------------------------

--- The threads under the cursor, or in the visual selection.
---@param buf integer
---@return review_notes.Item[]
local function selected(buf)
  local first, last = review.visual_lines()
  if not first then
    first = vim.api.nvim_win_get_cursor(0)[1]
    last = first
  end
  local out = {}
  for l = first, last do
    if lists[buf].rows[l] then table.insert(out, lists[buf].rows[l]) end
  end
  if #out == 0 then notify("no thread on this line") end
  return out
end

local function one(buf) return selected(buf)[1] end

--- Run *fn* on each selected thread.
local function each(buf, fn)
  return function()
    for _, item in ipairs(selected(buf)) do fn(item.ctx, item.key) end
  end
end

-- MR ------------------------------------------------------------------------------

local function load_mr(buf)
  local h = lists[buf]
  local mr = config.values.mr
  local vars = sync.vars(h.ctx)
  h.mr_for = vars.mr
  if not (mr and mr.info) or h.ctx.kind ~= "git" then return end
  backend.async(function()
    local r = backend.run({ info = mr.info }, "info", { root = h.ctx.root, vars = vars })
    if not lists[buf] then return end
    if r.ok and type(r.json) == "table" then
      h.mr, h.mr_error = r.json, nil
    elseif r.kind == "offline" and h.mr then
      -- Keep what we knew; the sync line says we are offline.
      h.mr_error = nil
    else
      h.mr, h.mr_error = nil, backend.message(r):gsub("\n.*", "")
    end
    draw(buf)
  end)
end

local function info(buf, base)
  local h = lists[buf]
  return { ctx = h.ctx, mr = h.mr, base = base or (h.mr and h.mr.target) }
end

--- `f`: the changed files against a base. With checkpoints (my last
--- publish, the agent's last fixup) a menu picks the base first.
local function files(buf)
  local h = lists[buf]
  if not config.values.files then return notify("no `files` function configured") end
  local bases = checkpoint.bases(h.ctx, h.mr and h.mr.target)
  if #bases <= 1 then return config.values.files(info(buf, bases[1] and bases[1].rev)) end
  vim.ui.select(bases, {
    prompt = "Changed files",
    format_item = function(b) return b.label end,
  }, function(b) if b then config.values.files(info(buf, b.rev)) end end)
end

local function run_mr_action(buf, a)
  local h = lists[buf]
  if a.fn then return a.fn(h.mr or {}, info(buf)) end
  if not a.cmd then return end
  local function go(input)
    local vars = { input = input or "" }
    for k, v in pairs(h.mr or {}) do
      if type(v) == "string" or type(v) == "number" then vars[k] = v end
    end
    local argv = {}
    for _, arg in ipairs(a.cmd) do
      -- An empty {input} drops the option before it too (`-m ""`).
      if arg == "{input}" and vars.input == "" then
        if #argv > 0 and argv[#argv]:sub(1, 1) == "-" then table.remove(argv) end
      else
        table.insert(argv, arg)
      end
    end
    backend.async(function()
      local r = backend.run({ action = argv }, "action", { root = h.ctx.root, vars = vars })
      local text = vim.trim(r.stdout .. (r.stderr ~= "" and ("\n" .. r.stderr) or ""))
      notify(text ~= "" and text or (a.desc .. (r.ok and ": done" or ": failed")), not r.ok and vim.log.levels.ERROR or nil)
      -- Reviewers or approvals may have changed: the header shows them.
      if r.ok and lists[buf] then sync.refresh(h.ctx) end
    end)
  end
  if vim.tbl_contains(a.cmd, "{input}") then
    vim.ui.input({ prompt = a.desc .. " (optional, enter to skip): " }, function(text)
      if text ~= nil then go(text) end
    end)
  else
    go()
  end
end

local function mr_menu(buf)
  local mr = config.values.mr
  local list = mr and mr.actions or {}
  if #list == 0 then return notify("no merge request actions configured (`mr.actions`)") end
  vim.ui.select(list, {
    prompt = "Merge request" .. (lists[buf].mr and (" " .. (lists[buf].mr.ref or "")) or ""),
    format_item = function(a) return a.key .. "  " .. a.desc end,
  }, function(a) if a then run_mr_action(buf, a) end end)
end

-- Keys ------------------------------------------------------------------------------

---@param buf integer
---@return review_notes.Key[]
local function keys_of(buf)
  local h = lists[buf]
  local nx = { "n", "x" }
  local function under_cursor()
    local win = sidebar.win()
    if not win or vim.api.nvim_win_get_buf(win) ~= buf then return nil end
    return h.rows[vim.api.nvim_win_get_cursor(win)[1]]
  end
  local function when(label, test) return keys.when(under_cursor, label, test) end
  return {
    { lhs = "<CR>", group = "Thread", desc = "show the thread", hint = when("open"), fn = function()
      local item = one(buf)
      if item then thread.show(item.ctx, item.key, { reorder = true, focus = "sidebar" }) end
    end },
    { lhs = "o", group = "Thread", desc = "show the thread and go to the code", fn = function()
      local item = one(buf)
      if item then thread.go_to(item) end
    end },
    { lhs = "r", group = "Thread", desc = "reply, or edit my reply not published yet", hint = when("reply"), fn = function()
      local item = one(buf)
      if item then actions.reply(item.ctx, item.entry, sidebar.win()) end
    end },
    { lhs = "x", group = "Thread", desc = "resolve / reopen (also a visual selection)", modes = nx,
      hint = when(actions.resolve_verb), fn = each(buf, actions.resolve) },
    { lhs = "a", group = "Thread", desc = "approve proposed (also a visual selection)", modes = nx,
      hint = when("approve", actions.can_approve), fn = function() actions.approve_items(selected(buf)) end },
    { lhs = "d", group = "Thread", desc = "discard unpublished (also a visual selection)", modes = nx,
      hint = when("discard", actions.can_discard), fn = function() actions.discard_items(selected(buf)) end },
    { lhs = "t", group = "Thread", desc = "make private (never published) / public (also a visual selection)",
      modes = nx, hint = when(function(i) return "make " .. actions.private_verb(i) end, actions.can_toggle_private),
      fn = function() actions.toggle_private_items(selected(buf)) end },
    { lhs = "R", group = "Thread", desc = "mark read (also a visual selection)", modes = nx,
      hint = when("read", function(i) return i.state == "unread" end), fn = each(buf, actions.read) },

    { lhs = "p", group = "Review", desc = "pull (sends nothing)", hint = "pull", fn = function() sync.pull(h.ctx) end },
    { lhs = "P", group = "Review", desc = "publish: summary, confirm, send", hint = "publish", fn = function() sync.publish(h.ctx) end },
    { lhs = "n", group = "Review", desc = "new thread on the whole change", fn = function() actions.new_thread(h.ctx, {}) end },
    { lhs = "A", group = "Review", desc = "approve every proposed comment", fn = function()
      notify(("approved %d proposed comments"):format(actions.approve_all(h.ctx)))
    end },
    { lhs = "D", group = "Review", desc = "discard every proposed comment", fn = function() actions.discard_proposed(h.ctx) end },
    { lhs = "m", group = "Review", desc = "merge request actions", hint = "MR", fn = function() mr_menu(buf) end },
    { lhs = "f", group = "Review", desc = "changed files: the whole change, since my publish, since the fixup",
      fn = function() files(buf) end },
    { lhs = "e", group = "Review", desc = "edit the notes file (in the code window)", fn = function() sidebar.edit(h.ctx.path) end },

    { lhs = "<Tab>", group = "Move", desc = "fold or unfold a section", fn = function()
      local lnum = vim.api.nvim_win_get_cursor(0)[1]
      local start = vim.fn.foldclosed(lnum)
      local line = vim.fn.getline(start ~= -1 and start or lnum)
      for _, s in ipairs(SECTIONS) do
        if line:find(s.title .. " (", 1, true) then
          h.folded[s.state] = start == -1
          break
        end
      end
      vim.cmd("silent! normal! za")
    end },
    { lhs = "q", group = "Move", desc = "close the sidebar", fn = function() sidebar.close() end },
  }
end

--- The hint bar follows the thread under the cursor.
---@param buf integer
function update_hints(buf)
  local h = lists[buf]
  local win = sidebar.win()
  if not (h and win and vim.api.nvim_win_get_buf(win) == buf) then return end
  vim.wo[win][0].statusline = keys.hints(h.keys, keys.bar_width(win))
end

-- Opening -----------------------------------------------------------------------------

---@param ctx review_notes.Context
---@return integer buf
local function ensure_buf(ctx)
  local name = "reviewnotes://review/" .. ctx.path
  local buf = vim.fn.bufnr(name)
  if buf ~= -1 and lists[buf] then return buf end
  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "reviewlist"
  lists[buf] = { ctx = ctx, rows = {}, folded = {}, want = true, keys = {} }
  review.bind(buf, ctx)
  sidebar.register(buf)
  lists[buf].keys = keys_of(buf)
  keys.bind(buf, "Review", lists[buf].keys)
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = function() update_hints(buf) end })
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function()
    lists[buf] = nil
    review.bind(buf, nil)
  end })
  -- Also on entering: the list is where I go to see what is new.
  vim.api.nvim_create_autocmd("BufEnter", { buffer = buf, callback = function() sync.auto_pull(ctx) end })
  review.watch(ctx.path)
  load_mr(buf)
  return buf
end

---@class review_notes.ListOpts
---@field key string? put the cursor on this thread (default: the one shown last)
---@field focus boolean? move the cursor into the sidebar (default true)

--- Show the list of *ctx* (default: the current buffer's review) in the
--- sidebar, opening it when needed.
---@param ctx review_notes.Context?
---@param opts review_notes.ListOpts?
function M.open(ctx, opts)
  ctx = ctx or review.context()
  if not ctx then return notify("not in a review (no git repository here)") end
  opts = opts or {}
  local buf = ensure_buf(ctx)
  local h = lists[buf]
  h.want = opts.key or h.last or h.want
  sidebar.show(buf, {
    focus = opts.focus ~= false,
    wo = {
      wrap = false,
      cursorline = true,
      foldtext = "v:lua.require'review_notes.list'.foldtext()",
      fillchars = "fold: ",
    },
  })
  draw(buf)
  update_hints(buf)
end

--- Toggle, one level at a time: from the code, open the list of *ctx*;
--- from a thread in the sidebar, back to the list; from the list, close.
---@param ctx review_notes.Context?
function M.toggle(ctx)
  local win = sidebar.win()
  if win and win == vim.api.nvim_get_current_win() then
    if lists[vim.api.nvim_win_get_buf(win)] then return sidebar.close() end
    local tctx, key = thread.shown()
    return M.open(tctx or ctx, { key = key })
  end
  M.open(ctx)
end

--- Thread *key* of *ctx* is shown: the list's cursor goes there when it comes back.
---@param ctx review_notes.Context
---@param key string
function M.follow(ctx, key)
  for _, h in pairs(lists) do
    if h.ctx.path == ctx.path then h.last = key end
  end
end

--- The text of a closed section: its header line.
function M.foldtext()
  return vim.fn.getline(vim.v.foldstart) .. "  ..."
end

review.on_change(redraw_all)
-- A pull came back: redraw, and reload the MR when the review moved to
-- another one or the info is stale (it failed, or the state changed).
sync.on_status(function()
  for buf, h in pairs(lists) do
    if vim.api.nvim_buf_is_valid(buf) then
      local s = sync.state(h.ctx)
      local mr = s.mr
      local moved = sync.vars(h.ctx).mr ~= h.mr_for
      local stale = not s.running and not s.failing and (h.mr_error
        or (mr and h.mr and (mr.state ~= h.mr.state or not vim.deep_equal(mr.reviewers, h.mr.reviewers))))
      if moved or stale then load_mr(buf) end
      draw(buf)
    end
  end
end)

return M
