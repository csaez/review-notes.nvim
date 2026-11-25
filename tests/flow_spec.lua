local review = require("review_notes")
local store = require("review_notes.store")

local fixtures = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/fixtures"
local script = fixtures .. "/backend.sh"
local function cmd(...) return { script, ... } end
local function wait_for(cond, what)
  assert.is_true(vim.wait(5000, cond, 20), "timed out waiting for " .. what)
end

describe("pull and publish", function()
  local repo, log, threads_file, notes_path, restore

  local function read(path) return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {} end
  local function doc() return store.parse(read(notes_path)) end
  local function calls() return read(log) end
  local function write_threads(list) vim.fn.writefile({ vim.json.encode(list) }, threads_file) end
  local function write_after(list) vim.fn.writefile({ vim.json.encode(list) }, threads_file .. ".after") end
  local function remote(id, path, line, ...)
    local comments = {}
    for i, c in ipairs({ ... }) do
      table.insert(comments, { id = id .. "-" .. i, author = c[1], body = c[2], mine = c[1] == "me" })
    end
    return { id = id, path = path, line = line, resolved = false, comments = comments }
  end

  before_each(function()
    vim.wait(100)
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q", "-b", "main" })
    vim.fn.writefile({ "x" }, repo .. "/a.c")
    vim.cmd("cd " .. repo)
    notes_path = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "review" }))
      .. "/main.md"
    log, threads_file = repo .. "/calls.log", repo .. "/threads.json"
    vim.fn.writefile({ "[]" }, threads_file)
    vim.env.FAKE_LOG, vim.env.FAKE_THREADS = log, threads_file
    review.setup({
      auto_pull = false,
      backend = {
        threads = cmd("threads"),
        add = cmd("add", "{path}:{line}", "-"),
        general = cmd("general", "-"),
        reply = cmd("reply", "{thread}", "-"),
        resolve = cmd("resolve", "{thread}"),
        unresolve = cmd("unresolve", "{thread}"),
        submit = cmd("submit", "{ids}"),
        discard = cmd("discard", "{ids}"),
      },
    })
    local select = vim.ui.select
    vim.ui.select = function(items, _, on_choice) on_choice(items[1]) end
    restore = function() vim.ui.select = select end
  end)

  after_each(function()
    restore()
    vim.fn.delete(repo, "rf")
  end)

  it("pull writes remote threads into the notes, the change ones too, and sends nothing", function()
    write_threads({ remote("t1", "a.c", 1, { "al", "why?" }), remote("g1", nil, nil, { "bo", "overall" }) })
    review.pull()
    wait_for(function() return #read(notes_path) > 0 end, "pull")
    local d = doc()
    assert.are.equal(2, #d.threads)
    assert.are.same({}, d.threads[1].anchor)
    assert.are.same({ "threads" }, calls())
  end)

  it("pull copes with JSON nulls, as git-lab prints them", function()
    vim.fn.writefile({
      '[{"id":"t1","path":"a.c","line":1,"start_line":null,"resolved":false,"resolved_by":null,"comments":[{"id":"1","author":"al","body":"x","mine":false}]},'
        .. '{"id":"g1","path":null,"line":null,"start_line":null,"resolved":false,"comments":[{"id":"2","author":"bo","body":"y"}]}]',
    }, threads_file)
    review.pull()
    wait_for(function() return #read(notes_path) > 0 end, "pull")
    assert.are.equal(2, #doc().threads)
  end)

  it("pull keeps my unpublished text, even with new remote comments", function()
    write_threads({ remote("t1", "a.c", 1, { "al", "why?" }) })
    review.pull()
    wait_for(function() return #read(notes_path) > 0 end, "pull")
    store.update(notes_path, function(d) table.insert(d.threads[1].comments, { source = "local", body = "because" }) end)
    write_threads({ remote("t1", "a.c", 1, { "al", "why?" }, { "bo", "me too" }) })
    review.pull()
    wait_for(function() return #doc().threads[1].comments == 3 end, "second pull")
    local c = doc().threads[1].comments
    assert.are.same({ "remote", "remote", "local" }, { c[1].source, c[2].source, c[3].source })
    assert.are.same({ "threads", "threads" }, calls())
  end)

  it("pull reports a failing backend and leaves the notes alone", function()
    review.config.backend.threads = cmd("fail")
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "## a.c:1", "status: open", "", "### me (local)", "mine" }, notes_path)
    local before = read(notes_path)
    review.pull()
    vim.wait(400)
    assert.are.same(before, read(notes_path))
  end)

  it("pulls automatically at most once per auto_pull seconds, and not with auto_pull off", function()
    local sync = require("review_notes.sync")
    local ctx = require("review_notes.review").context()
    write_threads({ remote("t1", "a.c", 1, { "al", "why?" }) })
    review.config.auto_pull = false
    sync.auto_pull(ctx)
    vim.wait(300)
    assert.are.same({}, calls())
    review.config.auto_pull = 60
    sync.auto_pull(ctx)
    sync.auto_pull(ctx)
    wait_for(function() return #read(notes_path) > 0 end, "auto pull")
    sync.auto_pull(ctx)
    vim.wait(300)
    assert.are.same({ "threads" }, calls())
  end)

  it("an automatic pull that fails warns once and leaves the notes alone", function()
    local sync = require("review_notes.sync")
    local ctx = require("review_notes.review").context()
    review.config.backend.threads = cmd("fail")
    review.config.auto_pull = 0
    local notify, warnings = vim.notify, 0
    vim.notify = function(_, level) if level == vim.log.levels.WARN then warnings = warnings + 1 end end
    sync.auto_pull(ctx)
    wait_for(function() return #calls() == 1 end, "first attempt")
    vim.wait(100)
    sync.auto_pull(ctx)
    wait_for(function() return #calls() == 2 end, "second attempt")
    vim.wait(100)
    vim.notify = notify
    assert.are.equal(1, warnings)
    assert.are.same({}, read(notes_path))
  end)

  it("publish sends new threads, replies and resolves, once, then pulls", function()
    write_threads({ remote("t1", "a.c", 1, { "al", "why?" }) })
    review.pull()
    wait_for(function() return #read(notes_path) > 0 end, "pull")
    store.update(notes_path, function(d)
      table.insert(d.threads[1].comments, { source = "local", body = "because" })
      d.threads[1].status = "resolved"
      table.insert(d.threads, { anchor = { path = "a.c", line = 1 }, status = "open", comments = { { source = "local", body = "new" } } })
      table.insert(d.threads, { anchor = {}, status = "open", comments = { { source = "local", body = "overall" } } })
    end)
    write_after({
      remote("t1", "a.c", 1, { "al", "why?" }, { "me", "because" }),
      remote("n1", "a.c", 1, { "me", "new" }),
      remote("n2", nil, nil, { "me", "overall" }),
    })
    review.publish()
    wait_for(function()
      local n = 0
      for _, line in ipairs(calls()) do
        if line:match("^threads") then n = n + 1 end
      end
      return n >= 3 and not table.concat(read(notes_path), "\n"):find("me %(local%)")
    end, "publish")
    local l = table.concat(calls(), "\n")
    assert.truthy(l:find("general %-"))
    assert.truthy(l:find("add a.c:1 %-"))
    assert.truthy(l:find("reply t1 %-"))
    assert.truthy(l:find("resolve t1"))
    assert.truthy(l:find("submit d1,d2,d3"))
    for _, t in ipairs(doc().threads) do
      for _, c in ipairs(t.comments) do assert.are.equal("remote", c.source) end
    end
  end)

  it("publish never sends proposed comments", function()
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "## a.c:1", "status: open", "", "### me (proposed)", "agent says" }, notes_path)
    review.publish()
    vim.wait(500)
    assert.are.same({ "threads" }, calls())
    assert.are.equal("proposed", doc().threads[1].comments[1].source)
  end)

  it("a failing submit leaves the text local and discards the queued drafts", function()
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "## a.c:1", "status: open", "", "### me (local)", "mine" }, notes_path)
    review.config.backend.submit = cmd("fail", "{ids}")
    review.publish()
    wait_for(function() return table.concat(calls(), "\n"):find("discard d1") ~= nil end, "discard")
    assert.are.equal("local", doc().threads[1].comments[1].source)
  end)
end)

describe("discard", function()
  local repo, notes_path
  before_each(function()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    vim.fn.system({ "git", "-C", repo, "init", "-q", "-b", "main" })
    vim.fn.writefile({ "a", "b" }, repo .. "/a.c")
    vim.cmd("cd " .. repo)
    review.setup({ backend = {}, auto_pull = false })
    notes_path = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-path", "review" })) .. "/main.md"
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({
      "## a.c:1", "status: open", "", "### me (proposed)", "NIT: pi finding", "",
      "## a.c:2 {id=t1}", "status: resolved", "", "### @bo {id=1}", "q", "", "### me (proposed)", "fixed", "",
    }, notes_path)
    store.write_sidecar(store.sidecar_path(notes_path), { threads = { t1 = { status = "open", seen = { ["1"] = true }, seen_status = true } } })
    vim.cmd("edit a.c")
    local select = vim.ui.select
    vim.ui.select = function(items, _, cb) cb(items[1]) end
    vim.b.restore = select
  end)
  after_each(function() vim.fn.delete(repo, "rf") end)

  it("deletes a finding that was never published, as if it never existed", function()
    local item = vim.tbl_filter(function(i) return i.anchor == "a.c:1" end, review.items())[1]
    review.item_action(item, "discard")
    local d = store.parse(store.read_lines(notes_path))
    assert.are.equal(1, #d.threads)
    assert.are.equal("t1", d.threads[1].id)
  end)

  it("on a remote thread removes the proposed reply and the resolve that came with it", function()
    local item = vim.tbl_filter(function(i) return i.anchor == "a.c:2" end, review.items())[1]
    review.item_action(item, "discard")
    local t = store.parse(store.read_lines(notes_path)).threads[2]
    assert.are.equal("open", t.status)
    assert.are.equal(1, #t.comments)
    assert.are.equal("remote", t.comments[1].source)
  end)

  it("discard proposed clears them all and keeps the remote ones", function()
    require("review_notes.actions").discard_proposed(require("review_notes.review").context())
    local d = store.parse(store.read_lines(notes_path))
    assert.are.equal(1, #d.threads)
    assert.are.equal("open", d.threads[1].status)
  end)
end)
