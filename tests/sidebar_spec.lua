local review = require("review_notes")
local sidebar = require("review_notes.sidebar")
local thread = require("review_notes.thread")
local store = require("review_notes.store")

describe("sidebar, thread mode", function()
  local repo, notes_path, ctx

  local function doc() return store.parse(store.read_lines(notes_path)) end
  local function panel_lines()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_get_name(b):match("reviewnotes://thread$") then
        return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"), w
      end
    end
  end
  -- The hint bar as drawn: the statusline evaluated, highlights gone.
  local function bar(win)
    win = win or vim.api.nvim_get_current_win()
    return vim.api.nvim_eval_statusline(vim.wo[win].statusline, { winid = win, maxwidth = 200 }).str
  end
  local function press(keys)
    local _, w = panel_lines()
    vim.api.nvim_set_current_win(w)
    vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
  end

  before_each(function()
    vim.cmd("silent! only")
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q", "-b", "main" })
    vim.fn.writefile({ "a", "b", "c", "d" }, repo .. "/a.c")
    vim.cmd("cd " .. repo)
    review.setup({ backend = {}, watch = false, auto_pull = false })
    notes_path = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir" })) .. "/review" .. "/main.md"
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({
      "## change {id=g}", "status: open", "", "### @bo {id=1}", "overall", "",
      "## a.c:2-3 {id=t1}", "status: open", "", "### @al {id=2}", "why?", "",
      "## a.c:4", "status: open", "", "### me (proposed)", "NIT: pi says", "",
    }, notes_path)
    store.write_sidecar(store.sidecar_path(notes_path), {
      threads = { g = { status = "open", seen = { ["1"] = true } }, t1 = { status = "open", seen = {} } },
      mr = { iid = 1, ref = "!1", state = "opened" },
    })
    vim.cmd("edit a.c")
    ctx = require("review_notes.review").context()
    local select = vim.ui.select
    vim.ui.select = function(items, _, cb) cb(items[1]) end
    vim.b.restore_select = select
  end)

  after_each(function()
    sidebar.close()
    vim.cmd("silent! only")
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(repo, "rf")
  end)

  it("shows the thread, marks it seen and shows its code", function()
    local item = vim.tbl_filter(function(i) return i.anchor == "a.c:2-3" end, review.items())[1]
    assert.are.equal("unread", item.state)
    local code = vim.api.nvim_get_current_win()
    review.open_item(item)
    local text = panel_lines()
    assert.truthy(text:find("# a.c:2-3", 1, true))
    assert.truthy(text:find("why?", 1, true))
    assert.are.equal(code, vim.api.nvim_get_current_win())
    assert.are.equal(2, vim.api.nvim_win_get_cursor(code)[1])
    item = vim.tbl_filter(function(i) return i.anchor == "a.c:2-3" end, review.items())[1]
    assert.are_not.equal("unread", item.state)
  end)

  it("goto_item goes to the code window and shows the thread", function()
    vim.cmd("enew")
    local win = vim.api.nvim_get_current_win()
    local item = vim.tbl_filter(function(i) return i.anchor == "a.c:2-3" end, review.items())[1]
    review.goto_item(item)
    assert.are.equal(win, vim.api.nvim_get_current_win())
    assert.are.equal(item.file, vim.api.nvim_buf_get_name(0))
    assert.is_true(sidebar.is_open())
    assert.are.equal(2, vim.api.nvim_win_get_cursor(win)[1])
    assert.truthy(panel_lines():find("# a.c:2-3", 1, true))
  end)

  it("resolves, approves and walks the threads with its keys", function()
    thread.show(ctx, "t1")
    press("x")
    assert.are.equal("resolved", doc().threads[2].status)
    assert.truthy(panel_lines():find("resolved", 1, true))
    press("]t")
    local _, key = thread.shown()
    assert.are_not.equal("t1", key)
    -- Walk to the proposed thread and approve it.
    for _ = 1, 3 do
      if panel_lines():find("me (proposed)", 1, true) then break end
      press("]t")
    end
    press("a")
    assert.are.equal("local", doc().threads[3].comments[1].source)
  end)

  it("discard on a new thread deletes it after a confirm and says it is gone", function()
    thread.show(ctx, "new:a.c:4#1")
    press("d")
    assert.are.equal(2, #doc().threads)
    assert.truthy(panel_lines():find("gone", 1, true))
  end)

  it("change threads are threads like any other", function()
    thread.show(ctx, "g")
    assert.truthy(panel_lines():find("change (the whole merge request)", 1, true))
    press("o")
    assert.truthy(vim.api.nvim_buf_get_name(0):match("reviewnotes://thread$"))
  end)

  it("never takes the code window, and keeps its options to itself", function()
    local code = vim.api.nvim_get_current_win()
    vim.wo[code].number = true
    thread.show(ctx, "t1")
    local _, w = panel_lines()
    assert.are_not.equal(code, w)
    assert.is_true(vim.wo[w].winfixbuf)
    assert.is_true(vim.wo[code].number)
    -- A file opened from a split of the sidebar gets the global options back.
    vim.api.nvim_set_current_win(w)
    vim.cmd("vsplit")
    vim.wo.winfixbuf = false
    vim.cmd("edit a.c")
    assert.is_false(vim.wo.winfixbuf)
    assert.are.equal(vim.go.statusline, vim.wo.statusline)
  end)

  it("opens a window for the code when the sidebar is alone", function()
    thread.show(ctx, "g")
    local _, w = panel_lines()
    vim.api.nvim_set_current_win(w)
    vim.cmd("only")
    thread.show(ctx, "t1")
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    local code = sidebar.code_win()
    assert.are.equal(vim.fn.fnamemodify("a.c", ":p"), vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(code)))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(code)[1])
  end)

  it("shows where it is in the hint bar", function()
    thread.show(ctx, "t1")
    local _, w = panel_lines()
    assert.truthy(bar(w):find("1 of 3", 1, true))
    -- Only what applies: t1 has no proposed comment and no text of mine.
    assert.is_nil(bar(w):find("approve", 1, true))
    assert.is_nil(bar(w):find("discard", 1, true))
    thread.show(ctx, "new:a.c:4#1")
    assert.truthy(bar(w):find("a approve", 1, true))
    assert.truthy(bar(w):find("d discard", 1, true))
  end)

  it("items search the whole conversation, for the items API", function()
    local text = vim.tbl_filter(function(i) return i.key == "t1" end, review.items())[1].text
    assert.truthy(text:find("@al why?", 1, true))
    assert.truthy(table.concat(thread.lines(review.items()[1]), "\n"):find("^# ", 1))
  end)

  it("reuses one window, and q goes back to the list", function()
    thread.show(ctx, "t1")
    thread.show(ctx, "g")
    assert.are.equal(2, #vim.api.nvim_tabpage_list_wins(0))
    press("q")
    assert.is_false(thread.is_shown())
    assert.is_true(sidebar.is_open())
  end)
end)
