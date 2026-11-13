local review = require("review_notes")

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fixtures"
local script = fixtures .. "/backend.sh"

local function cmd(...) return { script, ... } end

local function wait_for(cond, what)
  assert.is_true(vim.wait(5000, cond, 20), "timed out waiting for " .. what)
end

describe("pull and push", function()
  local repo, log, threads_file, notes_path, restore

  local function read(path)
    return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
  end

  before_each(function()
    vim.wait(100) -- let a previous spec's trailing pull finish
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q", "-b", "main" })
    vim.fn.writefile({ "x" }, repo .. "/a.c")
    vim.cmd("cd " .. repo)
    notes_path = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "review" }))
      .. "/main.txt"
    log = repo .. "/calls.log"
    threads_file = repo .. "/threads.json"
    vim.fn.writefile({ "[]" }, threads_file)
    vim.env.FAKE_LOG, vim.env.FAKE_THREADS = log, threads_file
    review.config.backend = {
      threads = cmd("threads"),
      add = cmd("add", "{path}:{line}", "-"),
      reply = cmd("reply", "{thread}", "-"),
      resolve = cmd("resolve", "{thread}"),
      unresolve = cmd("unresolve", "{thread}"),
      submit = cmd("submit", "-"),
      discard = cmd("discard"),
    }
    local select = vim.ui.select
    vim.ui.select = function(_, _, on_choice) on_choice("Send") end
    restore = function() vim.ui.select = select end
  end)

  after_each(function()
    restore()
    vim.fn.delete(repo, "rf")
  end)

  local function write_threads(list) vim.fn.writefile({ vim.json.encode(list) }, threads_file) end

  it("pull writes remote threads into the notes, flagged new", function()
    write_threads({ { id = "t1", path = "a.c", line = 1, resolved = false, comments = { { author = "al", body = "why?" } } } })
    review.pull()
    wait_for(function() return #read(notes_path) > 0 end, "pull")
    assert.are.same({ "a.c:1: [id:t1] [new] @al: why?" }, read(notes_path))
  end)

  it("pull reports a failing backend and leaves the notes alone", function()
    review.config.backend.threads = cmd("fail")
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "a.c:1: mine" }, notes_path)
    review.pull()
    vim.wait(500)
    assert.are.same({ "a.c:1: mine" }, read(notes_path))
  end)

  it("push sends notes, replies and state, then syncs", function()
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({
      "Overall fine.",
      "",
      "a.c:1: a new note",
      "a.c:1: [draft] held back",
      "a.c:1: [id:t1] @al: why?",
      "  my reply",
    }, notes_path)
    write_threads({
      { id = "n1", path = "a.c", line = 1, resolved = false, comments = { { author = "me", body = "a new note" } } },
      { id = "t1", path = "a.c", line = 1, resolved = false,
        comments = { { author = "al", body = "why?" }, { author = "me", body = "my reply" } } },
    })
    review.push()
    -- Done once the final pull has written the remote's version of the thread.
    wait_for(function() return table.concat(read(notes_path), "\n"):find("[id:n1]", 1, true) end, "push")
    local calls = table.concat(read(log), "\n")
    assert.is_truthy(calls:find("add a.c:1 -\nstdin: a new note", 1, true))
    assert.is_truthy(calls:find("reply t1 -\nstdin: my reply", 1, true))
    assert.is_truthy(calls:find("submit -\nstdin: Overall fine.", 1, true))
    assert.is_nil(calls:find("held back", 1, true))
    -- Sent entries are gone, replaced by what the remote now has, unflagged.
    local out = table.concat(read(notes_path), "\n")
    assert.is_nil(out:find("[new]", 1, true))
    assert.is_truthy(out:find("a.c:1: [draft] held back", 1, true))
    assert.is_truthy(out:find("[id:n1] @me: a new note", 1, true))
    assert.is_truthy(out:find("> @me: my reply", 1, true))
    assert.is_nil(out:find("Overall fine", 1, true))
  end)

  it("sync pushes first, so a local resolve survives the pull", function()
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "a.c:1: [resolved] [id:t1] @al: why?" }, notes_path)
    -- What the remote reports once the resolve has been sent.
    write_threads({ { id = "t1", path = "a.c", line = 1, resolved = true, comments = { { author = "al", body = "why?" } } } })
    review.sync()
    wait_for(function() return table.concat(read(notes_path), "\n"):find("> (resolved)", 1, true) end, "pull")
    local calls = table.concat(read(log), "\n")
    assert.is_true(calls:find("resolve t1", 1, true) < calls:find("threads", 1, true))
    assert.are.same({ "a.c:1: [resolved] [id:t1] @al: why?", "  > (resolved)" }, read(notes_path))
  end)

  it("sync does not pull when the push was cancelled", function()
    vim.ui.select = function(_, _, on_choice) on_choice("Cancel") end
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "a.c:1: [resolved] [id:t1] @al: why?" }, notes_path)
    review.sync()
    vim.wait(500)
    assert.are.same({}, read(log))
    assert.are.same({ "a.c:1: [resolved] [id:t1] @al: why?" }, read(notes_path))
  end)

  it("sync with nothing to send only pulls", function()
    write_threads({})
    review.sync()
    wait_for(function() return #read(log) > 0 end, "pull " .. log .. " cwd=" .. vim.fn.getcwd())
    vim.wait(400)
    assert.are.same({ "threads" }, read(log))
  end)

  it("push changes thread state after publishing", function()
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "a.c:1: [resolved] [id:t1] @al: why?", "  my reply" }, notes_path)
    review.push()
    wait_for(function() return table.concat(read(log), "\n"):find("resolve t1", 1, true) end, "resolve")
    local calls = table.concat(read(log), "\n")
    assert.is_true(calls:find("submit", 1, true) < calls:find("resolve t1", 1, true))
  end)

  it("push keeps failed entries and discards the queue when submit fails", function()
    review.config.backend.submit = cmd("fail")
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "a.c:1: a new note" }, notes_path)
    review.push()
    wait_for(function() return table.concat(read(log), "\n"):find("discard", 1, true) end, "discard")
    vim.wait(300)
    assert.are.same({ "a.c:1: a new note" }, read(notes_path))
  end)

  it("push with nothing to send does not call the backend", function()
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "a.c:1: [draft] later" }, notes_path)
    review.push()
    vim.wait(300)
    assert.are.same({}, read(log))
  end)
end)

describe("picker", function()
  local repo, restore

  before_each(function()
    -- A buffer left over from another spec would point at a deleted repo.
    vim.cmd("silent! %bwipeout!")
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q", "-b", "main" })
    vim.fn.writefile({ "one", "two" }, repo .. "/a.c")
    vim.cmd("cd " .. repo)
    local dir = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "review" }))
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "a.c:2: [draft] second line", "a.c:1: [resolved] first" }, dir .. "/main.txt")
    restore = function() end
  end)

  after_each(function()
    restore()
    vim.fn.delete(repo, "rf")
  end)

  it("lists notes as items, sorted by position, searchable by state", function()
    local items = review.items()
    assert.are.equal(2, #items)
    assert.are.equal(1, items[1].line)
    assert.is_truthy(items[1].text:find("resolved", 1, true))
    assert.is_truthy(items[2].text:find("draft", 1, true))
    assert.are.equal("second line", items[2].summary)
  end)

  it("opens an item at its icon line", function()
    review.goto_item(review.items()[2])
    assert.are.equal(2, vim.fn.line("."))
  end)
end)

describe("status", function()
  local repo

  before_each(function()
    vim.cmd("silent! %bwipeout!")
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q", "-b", "main" })
    vim.fn.writefile({ "one", "two" }, repo .. "/a.c")
    vim.cmd("cd " .. repo)
    vim.cmd("edit a.c")
  end)

  after_each(function() vim.fn.delete(repo, "rf") end)

  local function write_notes(lines)
    local dir = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "review" }))
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile(lines, dir .. "/main.txt")
  end

  it("counts what a push would send, and not drafts", function()
    write_notes({
      "a.c:1: a new note",
      "a.c:2: [draft] held back",
      "a.c:1: [id:t1] @al: why?",
      "  my reply",
      "a.c:2: [resolved] [id:t2] @al: done",
    })
    review.refresh()
    local status = review.status()
    -- a new thread, a reply and a resolve
    assert.is_truthy(status:find(review.style.send.icon .. " 3", 1, true))
  end)

  it("shows nothing to send when everything is in sync", function()
    write_notes({ "a.c:1: [id:t1] @al: why?", "  > @bo: +1" })
    review.refresh()
    assert.is_nil(review.status():find(review.style.send.icon, 1, true))
  end)
end)

describe("compose", function()
  local repo, notes_path

  before_each(function()
    vim.cmd("silent! %bwipeout!")
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q", "-b", "main" })
    vim.fn.writefile({ "one", "two", "three" }, repo .. "/a.c")
    vim.cmd("cd " .. repo)
    vim.cmd("edit a.c")
    notes_path = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "review" }))
      .. "/main.txt"
  end)

  after_each(function()
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(repo, "rf")
  end)

  local function read() return vim.fn.filereadable(notes_path) == 1 and vim.fn.readfile(notes_path) or {} end
  local function type_and(lines, finish)
    vim.cmd.stopinsert()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd("doautocmd TextChanged") -- not fired for API edits in headless specs
    if finish == "write" then vim.cmd("write") else vim.cmd("close") end
  end

  it("adds a multiline note from the float", function()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    review.add()
    assert.are.equal("markdown", vim.bo.filetype)
    assert.are.equal("win", vim.api.nvim_win_get_config(0).relative)
    type_and({ "first line", "", "  code()", "> not quoted" }, "write")
    assert.are.same({ "a.c:2: first line", "", "    code()", "  \\> not quoted" }, read())
    assert.are.equal(vim.fn.bufnr(repo .. "/a.c"), vim.api.nvim_get_current_buf())
  end)

  it("keeps the text as a draft when closed without sending", function()
    review.add()
    type_and({ "half written" }, "close")
    assert.are.same({}, read())
    review.add()
    assert.are.same({ "half written" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    type_and({ "done" }, "write")
    assert.are.same({ "a.c:1: done" }, read())
  end)

  it("edits my note, then replies after an answer", function()
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "a.c:1: [resolved] [new] mine", "  > @pi: done" }, notes_path)
    review.refresh()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    review.add()
    assert.are.same({ "" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    type_and({ "not quite" }, "write")
    assert.are.same({ "a.c:1: mine", "  > @pi: done", "  not quite" }, read())
    review.add()
    assert.are.same({ "not quite" }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
  end)
end)
