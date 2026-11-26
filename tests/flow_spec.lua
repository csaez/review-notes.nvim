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
    notes_path = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir" })) .. "/review"
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

  it("an offline remote shows as offline, and keeps retrying", function()
    local sync = require("review_notes.sync")
    local ctx = require("review_notes.review").context()
    review.config.backend.threads = cmd("offline")
    review.config.auto_pull = 0
    local notify = vim.notify
    vim.notify = function() end
    sync.auto_pull(ctx)
    wait_for(function() return sync.state(ctx).failing end, "first attempt")
    assert.are.equal("offline", sync.state(ctx).kind)
    assert.is_falsy(sync.state(ctx).paused)
    sync.auto_pull(ctx)
    wait_for(function() return #calls() == 2 end, "retry")
    vim.notify = notify
  end)

  it("a backend that hangs is stopped after `timeout` seconds and counts as offline", function()
    local sync = require("review_notes.sync")
    local ctx = require("review_notes.review").context()
    review.config.backend.threads = cmd("slow")
    review.config.timeout = 1
    local notify, msgs = vim.notify, {}
    vim.notify = function(m) table.insert(msgs, m) end
    review.pull()
    wait_for(function() return sync.state(ctx).failing end, "timeout")
    vim.notify = notify
    review.config.timeout = 30
    assert.are.equal("offline", sync.state(ctx).kind)
    assert.truthy(table.concat(msgs, "\n"):find("timed out"))
  end)

  it("no MR is not a failure: automatic pulls go on quietly, and find the MR once it exists", function()
    local sync = require("review_notes.sync")
    local ctx = require("review_notes.review").context()
    review.config.backend.threads = cmd("nomr")
    review.config.auto_pull = 0
    local notify, msgs = vim.notify, {}
    vim.notify = function(m) table.insert(msgs, m) end
    sync.auto_pull(ctx)
    wait_for(function() return #calls() == 1 and not sync.state(ctx).running end, "first attempt")
    assert.are.equal("no_mr", sync.state(ctx).kind)
    assert.is_falsy(sync.state(ctx).paused)
    assert.are.same({}, msgs)
    -- The MR is created: the next automatic pull brings its threads in.
    review.config.backend.threads = cmd("threads")
    write_threads({ remote("t1", "a.c", 1, { "al", "why?" }) })
    sync.auto_pull(ctx)
    wait_for(function() return #doc().threads == 1 end, "automatic pull")
    vim.notify = notify
  end)

  it("a repository that is not on GitLab pauses automatic pulls, with one short message", function()
    local sync = require("review_notes.sync")
    local ctx = require("review_notes.review").context()
    review.config.backend.threads = cmd("notgitlab")
    review.config.auto_pull = 0
    local notify, msgs = vim.notify, {}
    vim.notify = function(m) table.insert(msgs, m) end
    sync.auto_pull(ctx)
    wait_for(function() return sync.state(ctx).failing end, "first attempt")
    sync.auto_pull(ctx)
    vim.wait(300)
    vim.notify = notify
    assert.are.equal("no_remote", sync.state(ctx).kind)
    assert.is_true(sync.state(ctx).paused)
    assert.are.equal(1, #calls())
    assert.are.equal(1, #msgs)
    assert.truthy(msgs[1]:find("not a GitLab server", 1, true))
  end)

  describe("with the MR in the thread list", function()
    local mr_file
    local function write_mr(mr, iid)
      vim.fn.writefile({ vim.json.encode(mr) }, mr_file .. (iid and ("." .. iid) or ""))
    end
    before_each(function()
      mr_file = repo .. "/mr.json"
      vim.env.FAKE_MR = mr_file
      review.config.backend.threads = cmd("threads-mr", "--mr={mr}")
      review.config.backend.add = cmd("add", "--mr={mr}", "{path}:{line}", "-")
    end)

    it("records the MR, then addresses it by IID", function()
      write_mr({ iid = 12, ref = "!12", state = "opened" })
      review.pull()
      wait_for(function() return #read(notes_path) > 0 or #calls() > 0 end, "pull")
      wait_for(function() return require("review_notes.sync").state(require("review_notes.review").context()).mr end, "mr")
      local side = store.read_sidecar(store.sidecar_path(notes_path))
      assert.are.equal(12, side.mr.iid)
      review.pull()
      wait_for(function() return #calls() == 2 end, "second pull")
      assert.are.same({ "threads-mr", "threads-mr --mr=12" }, calls())
    end)

    it("a merged MR stops automatic pulls but still pulls and publishes, after a warning", function()
      local sync = require("review_notes.sync")
      local ctx = require("review_notes.review").context()
      write_mr({ iid = 12, ref = "!12", state = "merged" })
      local prompts = {}
      vim.ui.select = function(items, o, cb) table.insert(prompts, o.prompt) cb(items[1]) end
      local notify, msgs = vim.notify, {}
      vim.notify = function(m) table.insert(msgs, m) end
      review.pull()
      wait_for(function() return sync.state(ctx).paused end, "pull")
      assert.truthy(table.concat(msgs, "\n"):find("!12 is merged"))
      review.config.auto_pull = 0
      sync.auto_pull(ctx)
      vim.wait(300)
      assert.are.equal(1, #calls())
      store.update(notes_path, function(d)
        table.insert(d.threads, { anchor = { path = "a.c", line = 1 }, status = "open", comments = { { source = "local", body = "late" } } })
      end)
      review.publish()
      wait_for(function() return table.concat(calls(), "\n"):find("submit") ~= nil end, "publish")
      vim.notify = notify
      assert.truthy(prompts[1]:find("!12 is merged"))
      assert.truthy(table.concat(calls(), "\n"):find("add %-%-mr=12 a.c:1"))
    end)

    it("asks before moving to the branch's new MR, and says what happens to the threads", function()
      local sync = require("review_notes.sync")
      local ctx = require("review_notes.review").context()
      write_threads({ remote("t1", "a.c", 1, { "al", "why?" }) })
      write_mr({ iid = 12, ref = "!12", state = "opened" })
      review.pull()
      wait_for(function() return #doc().threads == 1 end, "first pull")
      store.update(notes_path, function(d) table.insert(d.threads[1].comments, { source = "local", body = "mine" }) end)
      -- !12 closed; the branch has !13 now, which has none of its threads.
      write_mr({ iid = 12, ref = "!12", state = "closed", successor = { iid = 13, ref = "!13", state = "opened" } }, 12)
      write_mr({ iid = 13, ref = "!13", state = "opened" }, 13)
      local prompt
      vim.ui.select = function(items, o, cb)
        prompt = o.prompt
        -- What !13 serves: none of the threads of !12.
        write_threads({})
        cb(items[1])
      end
      review.pull()
      wait_for(function() return #calls() == 3 and not sync.state(ctx).running end, "pull of the new MR")
      assert.are.equal(13, sync.state(ctx).mr.iid)
      assert.truthy(prompt:find("new MR !13"))
      assert.truthy(prompt:find("publish as new threads on !13"))
      assert.are.equal("threads-mr --mr=13", calls()[3])
      wait_for(function() return doc().threads[1].orphan == true end, "orphan")
    end)

    it("a peer approving while I review is said once, in the list and before publish", function()
      local sync = require("review_notes.sync")
      local ctx = require("review_notes.review").context()
      local mr = { iid = 12, ref = "!12", state = "opened", me = "me", reviewers = { "me" }, approved_by = {}, approvals_left = 1 }
      write_mr(mr)
      local notify, warns = vim.notify, {}
      vim.notify = function(m, l) if l == vim.log.levels.WARN then table.insert(warns, m) end end
      review.pull()
      wait_for(function() return sync.state(ctx).mr and not sync.state(ctx).running end, "pull")
      require("review_notes.list").open(ctx)
      local function header() return table.concat(vim.api.nvim_buf_get_lines(0, 0, 6, false), "\n") end
      assert.truthy(header():find("1 approval left  reviewer: me", 1, true))
      -- bo approves meanwhile.
      mr.approved_by, mr.approvals_left, mr.reviewers = { "bo" }, 0, { "me", "bo" }
      write_mr(mr)
      review.pull()
      wait_for(function() return #warns == 1 end, "warning")
      assert.truthy(warns[1]:find("MR !12 approved by @bo", 1, true))
      wait_for(function() return header():find("approved by @bo", 1, true) ~= nil end, "header")
      assert.truthy(header():find("reviewers: me, @bo", 1, true))
      review.pull()
      wait_for(function() return #calls() == 3 and not sync.state(ctx).running end, "third pull")
      assert.are.equal(1, #warns)
      store.update(notes_path, function(d)
        table.insert(d.threads, { anchor = { path = "a.c", line = 1 }, status = "open", comments = { { source = "local", body = "x" } } })
      end)
      local prompt
      vim.ui.select = function(items, o, cb) prompt = o.prompt cb(items[#items]) end
      review.publish()
      wait_for(function() return prompt ~= nil end, "confirm")
      vim.notify = notify
      require("review_notes.sidebar").close()
      assert.truthy(prompt:find("MR !12 is already approved by @bo", 1, true))
    end)

    it("warns on the first pull of an MR approved before I came, not about my own approval", function()
      local sync = require("review_notes.sync")
      local ctx = require("review_notes.review").context()
      write_mr({ iid = 12, ref = "!12", state = "opened", me = "me", reviewers = {}, approved_by = { "me", "al" } })
      local notify, warns = vim.notify, {}
      vim.notify = function(m, l) if l == vim.log.levels.WARN then table.insert(warns, m) end end
      review.pull()
      wait_for(function() return sync.state(ctx).mr and not sync.state(ctx).running end, "pull")
      vim.notify = notify
      assert.are.same({ "MR !12 approved by @al" }, warns)
    end)

    it("staying on the old MR is remembered for the session", function()
      local sync = require("review_notes.sync")
      local ctx = require("review_notes.review").context()
      write_mr({ iid = 12, ref = "!12", state = "closed", successor = { iid = 13, ref = "!13" } })
      local asked = 0
      vim.ui.select = function(items, _, cb) asked = asked + 1 cb(items[2]) end
      local notify = vim.notify
      vim.notify = function() end
      review.pull()
      wait_for(function() return #calls() == 1 and not sync.state(ctx).running end, "pull")
      review.pull()
      wait_for(function() return #calls() == 2 and not sync.state(ctx).running end, "second pull")
      vim.notify = notify
      assert.are.equal(1, asked)
      assert.are.equal(12, sync.state(ctx).mr.iid)
    end)
  end)

  it("publish records a checkpoint and warns about commits peers cannot see", function()
    local git = function(...) return vim.trim(vim.fn.system(vim.list_extend({ "git", "-C", repo }, { ... }))) end
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "base")
    local head = git("rev-parse", "HEAD")
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "local only")
    local mr_file = repo .. "/mr.json"
    vim.env.FAKE_MR = mr_file
    vim.fn.writefile({ vim.json.encode({ iid = 12, ref = "!12", state = "opened", sha = head }) }, mr_file)
    review.config.backend.threads = cmd("threads-mr", "--mr={mr}")
    store.update(notes_path, function(d)
      table.insert(d.threads, { anchor = { path = "a.c", line = 1 }, status = "open", comments = { { source = "local", body = "x" } } })
      table.insert(d.threads, { anchor = { path = "a.c", line = 1 }, status = "open", comments = { { source = "private", body = "for pi" } } })
    end)
    local prompt
    vim.ui.select = function(items, o, cb) prompt = o.prompt cb(items[1]) end
    review.publish()
    wait_for(function() return git("rev-parse", "--verify", "--quiet", "refs/review-notes/main/publish") ~= "" end, "checkpoint")
    assert.truthy(prompt:find("1 commit(s) not pushed", 1, true))
    assert.are.equal(git("rev-parse", "HEAD"), git("rev-parse", "refs/review-notes/main/publish"))
    local sent = table.concat(calls(), "\n")
    assert.truthy(sent:find("stdin: x", 1, true))
    assert.is_nil(sent:find("for pi", 1, true))
    local bases = require("review_notes.checkpoint").bases(require("review_notes.review").context(), "HEAD~1")
    assert.are.same({ "target", "publish" }, vim.tbl_map(function(b) return b.name end, bases))
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

  it("says which drafts may be left on the remote when the cleanup fails too", function()
    vim.fn.mkdir(vim.fs.dirname(notes_path), "p")
    vim.fn.writefile({ "## a.c:1", "status: open", "", "### me (local)", "mine" }, notes_path)
    review.config.backend.submit = cmd("offline", "{ids}")
    review.config.backend.discard = cmd("offline", "{ids}")
    local notify, msgs = vim.notify, {}
    vim.notify = function(m) table.insert(msgs, m) end
    review.publish()
    wait_for(function() return table.concat(msgs, "\n"):find("published with problems") ~= nil end, "report")
    vim.notify = notify
    assert.truthy(table.concat(msgs, "\n"):find("pending on the remote, unpublished: d1"))
  end)
end)

describe("worktrees", function()
  it("keep the notes in the common git dir, and move them there from the worktree's own", function()
    local main = vim.fn.tempname()
    local git = function(...) return vim.trim(vim.fn.system(vim.list_extend({ "git" }, { ... }))) end
    git("init", "-q", "-b", "main", main)
    git("-C", main, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "x")
    local wt = main .. "-wt"
    git("-C", main, "worktree", "add", "-q", "-b", "feat", wt)
    local own = git("-C", wt, "rev-parse", "--path-format=absolute", "--git-path", "review") .. "/feat.md"
    vim.fn.mkdir(vim.fs.dirname(own), "p")
    vim.fn.writefile({ "## change", "status: open", "", "### me (local)", "keep me" }, own)
    vim.fn.writefile({ "{}" }, store.sidecar_path(own))
    vim.cmd("cd " .. wt)
    local ctx = require("review_notes.review").context(vim.api.nvim_create_buf(false, true))
    assert.are.equal(git("-C", main, "rev-parse", "--path-format=absolute", "--git-common-dir") .. "/review/feat.md", ctx.path)
    assert.are.equal("feat", ctx.branch)
    assert.are.equal(0, vim.fn.filereadable(own))
    assert.are.equal("keep me", store.parse(store.read_lines(ctx.path)).threads[1].comments[1].body)
    assert.are.equal(1, vim.fn.filereadable(store.sidecar_path(ctx.path)))
    git("-C", main, "worktree", "remove", "--force", wt)
    assert.are.equal(1, vim.fn.filereadable(ctx.path))
    vim.cmd("cd " .. vim.fn.tempname():match("^(.*)/"))
    vim.fn.delete(main, "rf")
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
    notes_path = vim.trim(vim.fn.system({ "git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir" })) .. "/review" .. "/main.md"
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
