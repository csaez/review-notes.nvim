local review = require("review_notes")
local sidebar = require("review_notes.sidebar")
local thread = require("review_notes.thread")
local store = require("review_notes.store")

describe("sidebar, list mode", function()
  local repo, notes_path

  local function doc() return store.parse(store.read_lines(notes_path)) end
  local function text() return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n") end
  local function line_of(pattern)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find(pattern, 1, true) then return i end
    end
  end
  local function on(pattern)
    vim.api.nvim_win_set_cursor(0, { assert(line_of(pattern), "no line with " .. pattern), 0 })
  end
  local function press(keys) vim.api.nvim_feedkeys(vim.keycode(keys), "x", false) end

  before_each(function()
    vim.cmd("silent! only")
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q", "-b", "main" })
    vim.fn.writefile({ "a", "b", "c", "d" }, repo .. "/a.c")
    vim.cmd("cd " .. repo)
    review.setup({ backend = {}, watch = false, mr = false, auto_pull = false })
    notes_path = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "review" })) .. "/main.md"
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({
      "## change {id=g}", "status: open", "", "### @bo {id=1}", "overall", "",
      "## a.c:2-3 {id=t1}", "status: open", "", "### @al {id=2}", "why?", "",
      "## a.c:4", "status: open", "", "### me (proposed)", "NIT: pi says", "",
      "## a.c:1", "status: open", "", "### me (proposed)", "NIT: another", "",
      "## a.c:3 {id=t2}", "status: resolved", "", "### @al {id=3}", "old", "",
    }, notes_path)
    store.write_sidecar(store.sidecar_path(notes_path), {
      threads = {
        g = { status = "open", seen = { ["1"] = true } },
        t1 = { status = "open", seen = {} },
        t2 = { status = "resolved", seen = { ["3"] = true }, seen_status = true },
      },
    })
    vim.cmd("edit a.c")
    local select = vim.ui.select
    vim.ui.select = function(items, _, cb) cb(items[1]) end
    vim.g.restore_select = select
    review.open()
  end)

  after_each(function()
    sidebar.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(repo, "rf")
  end)

  it("lists the threads by urgency, the change ones included, resolved folded", function()
    local t = text()
    assert.truthy(t:find("Review  main", 1, true))
    local unread, proposed, open, resolved = line_of("Unread (1)"), line_of("Proposed (2)"), line_of("Open (1)"), line_of("Resolved (1)")
    assert.truthy(unread and proposed and open and resolved)
    assert.is_true(unread < proposed and proposed < open and open < resolved)
    assert.truthy(line_of("@al: why?") > unread)
    assert.truthy(line_of("change") > open)
    assert.are_not.equal(-1, vim.fn.foldclosed(resolved))
    assert.are.equal(-1, vim.fn.foldclosed(unread))
  end)

  it("opens beside the code, which keeps its window", function()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    assert.are.equal(2, #wins)
    assert.are.equal(sidebar.win(), vim.api.nvim_get_current_win())
    local code = vim.tbl_filter(function(w) return w ~= sidebar.win() end, wins)[1]
    assert.truthy(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code)):match("a%.c$"))
  end)

  it("starts on the first thread, <CR> shows it in the same window and - comes back", function()
    local win = vim.api.nvim_get_current_win()
    press("<CR>")
    local _, key = thread.shown()
    assert.are.equal("t1", key)
    assert.is_true(thread.is_shown())
    assert.are.equal(win, vim.api.nvim_get_current_win())
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    -- The code followed in the other window.
    local code = sidebar.code_win()
    assert.are.equal(2, vim.api.nvim_win_get_cursor(code)[1])
    press("]t")
    local _, next_key = thread.shown()
    press("-")
    assert.is_false(thread.is_shown())
    local shown = vim.tbl_filter(function(i) return i.key == next_key end, review.items())[1]
    assert.truthy(vim.api.nvim_get_current_line():find(shown.summary, 1, true))
  end)

  it("toggles from inside, and o goes to the code", function()
    review.toggle()
    assert.is_false(sidebar.is_open())
    review.toggle()
    assert.is_true(sidebar.is_open())
    on("why?")
    press("o")
    assert.are.equal(sidebar.code_win(), vim.api.nvim_get_current_win())
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("one level at a time: <leader>rr from a thread goes to the list, from the list closes", function()
    press("<CR>")
    assert.is_true(thread.is_shown())
    review.toggle()
    assert.is_true(sidebar.is_open())
    assert.is_false(thread.is_shown())
    assert.truthy(vim.api.nvim_get_current_line():find("why?", 1, true))
    review.toggle()
    assert.is_false(sidebar.is_open())
  end)

  it("hints only the keys that apply to the row under the cursor", function()
    on("why?")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    local bar = vim.wo.winbar
    assert.truthy(bar:find("R read", 1, true))
    assert.is_nil(bar:find("a approve", 1, true))
    assert.truthy(bar:find("? keys", 1, true))
    on("NIT: pi says")
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    bar = vim.wo.winbar
    assert.truthy(bar:find("a approve", 1, true))
    assert.is_nil(bar:find("R read", 1, true))
    -- Off a thread: only the review-wide keys.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    assert.is_nil(vim.wo.winbar:find("reply", 1, true))
    assert.truthy(vim.wo.winbar:find("p pull", 1, true))
  end)

  it("? lists every key, and a key pressed there runs on the row", function()
    local list = vim.api.nvim_get_current_win()
    on("NIT: pi says")
    press("?")
    local menu = vim.api.nvim_get_current_win()
    assert.are_not.equal(list, menu)
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    for _, want in ipairs({ "Thread", "Review", "approve every proposed comment", "merge request actions" }) do
      assert.truthy(text:find(want, 1, true), want)
    end
    press("a")
    vim.wait(100, function() return doc().threads[3].comments[1].source == "local" end)
    assert.are.equal("local", doc().threads[3].comments[1].source)
    assert.is_false(vim.api.nvim_win_is_valid(menu))
    assert.are.equal(list, vim.api.nvim_get_current_win())
  end)

  it("approves a visual selection of proposed comments at once", function()
    on("NIT: pi says")
    press("Vj")
    press("a")
    for _, i in ipairs({ 3, 4 }) do
      assert.are.equal("local", doc().threads[i].comments[1].source)
    end
    -- Approved comments are mine, not proposed any more: redrawn as such.
    assert.is_nil(line_of("Proposed ("))
  end)

  it("resolves, and redraws with the new state", function()
    on("why?")
    press("x")
    assert.are.equal("resolved", doc().threads[2].status)
    -- Still unread, so it stays first, tagged.
    assert.is_not_nil(line_of("[resolved, unsent] @al: why?"))
    press("R")
    assert.is_not_nil(line_of("Not published (1)"))
  end)

  it("discards every proposed comment with D", function()
    press("D")
    assert.are.equal(3, #doc().threads)
  end)

  it("is the review of its notes, also as the current buffer for the API", function()
    assert.are.equal(5, #review.items())
  end)
end)
