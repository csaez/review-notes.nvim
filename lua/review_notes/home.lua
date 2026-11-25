-- The home: one buffer for the whole review, like fugitive's `:G`. A header
-- with the branch, the MR and the counts, then the threads in sections by
-- urgency (each a fold). The thread keys of the panel work on the thread
-- under the cursor (or a visual selection), and the review-wide keys live
-- here: pull, publish, approve or discard all proposed, the MR actions.
local review = require("review_notes.review")
local actions = require("review_notes.actions")
local config = require("review_notes.config")
local backend = require("review_notes.backend")
local panel = require("review_notes.panel")
local sync = require("review_notes.sync")

local M = {}

local ns = vim.api.nvim_create_namespace("review_notes_home")

local SECTIONS = {
  { state = "unread", title = "Unread" },
  { state = "proposed", title = "Proposed" },
  { state = "unsent", title = "Not published" },
  { state = "open", title = "Open" },
  { state = "resolved", title = "Resolved", folded = true },
}

local HELP = {
  "Threads (on the line under the cursor, or a visual selection):",
  "  <CR> show in the panel    o  go to the code",
  "  r    reply                x  resolve / reopen",
  "  a    approve proposed     d  discard unpublished",
  "  R    mark read",
  "Review:",
  "  p    pull (sends nothing) P  publish (summary, confirm)",
  "  n    new thread on the whole change",
  "  A    approve all proposed D  discard all proposed",
  "  m    merge request actions",
  "  f    changed files        e  edit the notes file",
  "  <Tab> fold a section      q  close",
}

---@class review_notes.HomeState
---@field ctx review_notes.Context
---@field rows table<integer, review_notes.Item> thread by buffer line
---@field mr table? what `mr.info` printed
---@field mr_error string?
---@field folded table<string, boolean> by section state
---@field first boolean? the next draw puts the cursor on the first thread

---@type table<integer, review_notes.HomeState> by buffer
local homes = {}

local function notify(msg, level) review.notify(msg, level) end

local function branch_of(ctx)
  -- The notes are <gitdir>/review/<branch>.md, and a branch may hold slashes.
  return ctx.kind == "git" and ctx.path:match("/review/(.+)%.md$") or vim.fs.basename(ctx.path)
end

local function ago(t)
  if not t then return "not pulled this session" end
  local s = os.time() - t
  if s < 60 then return "pulled just now" end
  if s < 3600 then return ("pulled %d min ago"):format(math.floor(s / 60)) end
  return ("pulled %d h ago"):format(math.floor(s / 3600))
end

-- Drawing ---------------------------------------------------------------------

local function draw(buf)
  local h = homes[buf]
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

  local head = "Review  " .. branch_of(h.ctx)
  if h.mr and h.mr.ref then
    head = head .. "  " .. h.mr.ref .. (h.mr.target and (" -> " .. h.mr.target:gsub("^origin/", "")) or "")
  end
  add(head, { { 0, 6, "Title" } })
  if h.mr and h.mr.title then add("  " .. h.mr.title, { { 0, -1, "Comment" } }) end
  if h.mr_error then add("  MR: " .. h.mr_error, { { 0, -1, "DiagnosticWarn" } }) end
  local parts = {}
  for _, s in ipairs(SECTIONS) do
    if (counts[s.state] or 0) > 0 then table.insert(parts, ("%d %s"):format(counts[s.state], s.title:lower())) end
  end
  add((#parts > 0 and table.concat(parts, "  ") or "no threads") .. "    " .. ago(sync.pulled_at[h.ctx.path]),
    { { 0, -1, "Comment" } })
  add("")

  local width = 0
  for _, item in ipairs(items) do width = math.max(width, #item.anchor) end
  width = math.min(width, 48)

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
  add("<CR> show  r reply  x resolve  a approve  d discard  p pull  P publish  m MR  g? help", { { 0, -1, "Comment" } })

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
  for win, k in pairs(keep) do
    local target = math.min(k.lnum, #lines)
    for lnum, item in pairs(rows) do
      if item.key == k.key then target = lnum end
    end
    if not k.key and h.first then
      -- Opened before anything was drawn: the first thread.
      target = math.huge
      for lnum in pairs(rows) do target = math.min(target, lnum) end
      if target == math.huge then target = 1 end
    end
    vim.api.nvim_win_set_cursor(win, { target, 0 })
  end
  h.first = nil

  -- Folds: each section header and its rows. Manual folds, redone on every
  -- draw; a fold the user opened or closed keeps its state by section.
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    vim.api.nvim_win_call(win, function()
      vim.wo[win].foldmethod = "manual"
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
end

local function redraw_all()
  for buf in pairs(homes) do
    if vim.api.nvim_buf_is_valid(buf) then draw(buf) else homes[buf] = nil end
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
    if homes[buf].rows[l] then table.insert(out, homes[buf].rows[l]) end
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
  local h = homes[buf]
  local mr = config.values.mr
  if not (mr and mr.info) or h.ctx.kind ~= "git" then return end
  backend.async(function()
    local r = backend.run({ info = mr.info }, "info", { root = h.ctx.root })
    if not homes[buf] then return end
    if r.ok and type(r.json) == "table" then
      h.mr, h.mr_error = r.json, nil
    else
      h.mr, h.mr_error = nil, backend.message(r):gsub("\n.*", "")
    end
    draw(buf)
  end)
end

local function info(buf)
  local h = homes[buf]
  return { ctx = h.ctx, mr = h.mr }
end

local function run_mr_action(buf, a)
  local h = homes[buf]
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
    prompt = "Merge request" .. (homes[buf].mr and (" " .. (homes[buf].mr.ref or "")) or ""),
    format_item = function(a) return a.key .. "  " .. a.desc end,
  }, function(a) if a then run_mr_action(buf, a) end end)
end

-- Keys ------------------------------------------------------------------------------

local function set_keys(buf)
  local function map(lhs, fn, desc, modes)
    vim.keymap.set(modes or "n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
  end
  local nx = { "n", "x" }
  local h = homes[buf]

  map("<CR>", function()
    local item = one(buf)
    if item then panel.show(item.ctx, item.key, { reorder = true }) end
  end, "show in the panel")
  map("o", function()
    local item = one(buf)
    if item then panel.go_to(item) end
  end, "go to the code")
  map("r", function()
    local item = one(buf)
    if item then actions.reply(item.ctx, item.entry) end
  end, "reply")
  map("x", each(buf, actions.resolve), "resolve / reopen", nx)
  map("a", function() actions.approve_items(selected(buf)) end, "approve proposed", nx)
  map("d", function() actions.discard_items(selected(buf)) end, "discard unpublished", nx)
  map("R", each(buf, actions.read), "mark read", nx)

  map("p", function() sync.pull(h.ctx) end, "pull")
  map("P", function() sync.publish(h.ctx) end, "publish")
  map("n", function() actions.new_thread(h.ctx, {}) end, "new thread on the change")
  map("A", function() notify(("approved %d proposed comments"):format(actions.approve_all(h.ctx))) end, "approve all proposed")
  map("D", function() actions.discard_proposed(h.ctx) end, "discard all proposed")
  map("m", function() mr_menu(buf) end, "merge request")
  map("f", function()
    if config.values.files then return config.values.files(info(buf)) end
    notify("no `files` function configured")
  end, "changed files")
  map("e", function() vim.cmd("edit " .. vim.fn.fnameescape(h.ctx.path)) end, "edit the notes file")
  map("<Tab>", function()
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
  end, "fold section")
  map("q", function() M.close(buf) end, "close")
  map("g?", function() notify(table.concat(HELP, "\n")) end, "help")
end

-- Opening -----------------------------------------------------------------------------

--- Open the home of *ctx* (default: the current buffer's review) in the
--- current window. A second call goes back to the same buffer.
---@param ctx review_notes.Context?
function M.open(ctx)
  ctx = ctx or review.context()
  if not ctx then return notify("not in a review (no git repository here)") end
  local name = "reviewnotes://home/" .. ctx.path
  local buf = vim.fn.bufnr(name)
  if buf == -1 or not homes[buf] then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "reviewhome"
    homes[buf] = { ctx = ctx, rows = {}, folded = {} }
    review.bind(buf, ctx)
    set_keys(buf)
    vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, callback = function()
      homes[buf] = nil
      review.bind(buf, nil)
    end })
    -- Also on opening: the home is where I go to see what is new.
    vim.api.nvim_create_autocmd("BufEnter", { buffer = buf, callback = function() sync.auto_pull(ctx) end })
    review.watch(ctx.path)
    load_mr(buf)
  end
  vim.api.nvim_win_set_buf(0, buf)
  local wo = vim.wo[0]
  wo.number, wo.relativenumber, wo.signcolumn, wo.wrap = false, false, "no", false
  wo.foldcolumn, wo.statuscolumn = "0", ""
  wo.cursorline = true
  wo.foldtext = "v:lua.require'review_notes.home'.foldtext()"
  wo.fillchars = "fold: "
  -- On the first thread, so <CR> works at once.
  homes[buf].first = true
  draw(buf)
end

--- Leave the home: back to the previous buffer, or close the window.
---@param buf integer
function M.close(buf)
  local alt = vim.fn.bufnr("#")
  if alt ~= -1 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
    vim.api.nvim_win_set_buf(0, alt)
  elseif #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.api.nvim_win_close(0, false)
  else
    vim.cmd("enew")
  end
end

--- The text of a closed section: its header line.
function M.foldtext()
  return vim.fn.getline(vim.v.foldstart) .. "  ..."
end

review.on_change(redraw_all)

return M
