local merge = require("review_notes.merge")
local store = require("review_notes.store")

local function remote(id, resolved, path, line, ...)
  local comments = {}
  for i, c in ipairs({ ... }) do
    table.insert(comments, { id = id .. "-" .. i, author = c[1], body = c[2], mine = c[1] == "me" or nil })
  end
  return { id = id, path = path, line = line, resolved = resolved, comments = comments }
end

local function pulled(text_lines, side, threads)
  local doc = store.parse(text_lines)
  local report = merge.pull(doc, side, threads)
  return doc, report
end

describe("pull", function()
  it("adds remote threads, change threads included, general first", function()
    local side = { threads = {} }
    local doc, report = pulled({}, side, {
      remote("t1", false, "b.c", 9, { "alice", "x" }),
      remote("g1", false, nil, nil, { "bob", "overall" }),
    })
    assert.are.equal(2, report.added)
    assert.are.same({}, doc.threads[1].anchor)
    assert.are.equal("b.c:9", store.anchor_string(doc.threads[2].anchor))
  end)

  it("never touches local or proposed comments", function()
    local side = { threads = {} }
    local doc = pulled({
      "## a.c:1 {id=t1}", "status: open", "", "### @alice {id=t1-1}", "old", "", "### me (local)", "mine", "",
      "### me (proposed)", "agent", "",
    }, side, { remote("t1", false, "a.c", 1, { "alice", "new text" }, { "bob", "reply" }) })
    local c = doc.threads[1].comments
    assert.are.same({ "remote", "remote", "local", "proposed" }, { c[1].source, c[2].source, c[3].source, c[4].source })
    assert.are.equal("new text", c[1].body)
    assert.are.equal("mine", c[3].body)
  end)

  it("keeps my line unless it is plainly wrong", function()
    local side = { threads = {} }
    local doc = pulled({ "## a.c:20 {id=t1}", "status: open" }, side, { remote("t1", false, "a.c", 12, { "a", "x" }) })
    assert.are.equal(20, doc.threads[1].anchor.line)
    doc = pulled({ "## a.c {id=t1}", "status: open" }, side, { remote("t1", false, "a.c", 12, { "a", "x" }) })
    assert.are.equal(12, doc.threads[1].anchor.line)
  end)

  it("keeps a status change I have not published", function()
    local side = { threads = { t1 = { status = "open", seen = {}, seen_status = true } } }
    local doc = pulled({ "## a.c:1 {id=t1}", "status: resolved" }, side, { remote("t1", false, "a.c", 1, { "a", "x" }) })
    assert.are.equal("resolved", doc.threads[1].status)
  end)

  it("takes a status change made on the remote and flags it unseen", function()
    local side = { threads = { t1 = { status = "open", seen = {}, seen_status = true } } }
    local r = remote("t1", true, "a.c", 1, { "a", "x" })
    r.resolved_by = "bob"
    local doc = pulled({ "## a.c:1 {id=t1}", "status: open" }, side, { r })
    assert.are.equal("resolved", doc.threads[1].status)
    assert.is_true(merge.resolved_unseen(doc.threads[1], side.threads.t1))
    merge.mark_seen(doc.threads[1], side)
    assert.is_false(merge.is_unread(doc.threads[1], side.threads.t1))
    pulled(store.render(doc), side, { r })
    assert.is_false(merge.resolved_unseen(doc.threads[1], side.threads.t1))
  end)

  it("a thread I resolved myself is not unseen", function()
    local side = { threads = {} }
    local r = remote("t1", true, "a.c", 1, { "me", "x" })
    r.resolved_by_me = true
    local doc = pulled({}, side, { r })
    assert.is_false(merge.is_unread(doc.threads[1], side.threads.t1))
  end)

  it("drops a thread deleted remotely, unless it holds my text", function()
    local side = { threads = { t1 = { status = "open", seen = {}, seen_status = true }, t2 = { status = "open", seen = {}, seen_status = true } } }
    local doc, report = pulled({
      "## a.c:1 {id=t1}", "status: open", "", "### @x {id=1}", "hi", "",
      "## b.c:2 {id=t2}", "status: open", "", "### me (local)", "keep me", "",
    }, side, {})
    assert.are.equal(1, #doc.threads)
    assert.is_true(doc.threads[1].orphan)
    assert.are.same({ "b.c:2" }, report.orphaned)
    assert.is_nil(side.threads.t1)
  end)

  it("counts unread per comment, not mine", function()
    local side = { threads = {} }
    local doc = pulled({}, side, { remote("t1", false, "a.c", 1, { "alice", "x" }, { "me", "y" }) })
    assert.are.equal(1, merge.unread_count(doc.threads[1], side.threads.t1))
    merge.mark_seen(doc.threads[1], side)
    assert.are.equal(0, merge.unread_count(doc.threads[1], side.threads.t1))
    doc = pulled(store.render(doc), side, { remote("t1", false, "a.c", 1, { "alice", "x" }, { "me", "y" }, { "bob", "z" }) })
    assert.are.equal(1, merge.unread_count(doc.threads[1], side.threads.t1))
  end)
end)

describe("plan", function()
  local side = { threads = { t1 = { status = "open", seen = { ["t1-1"] = true }, seen_status = true } } }

  it("lists new threads, replies and status changes", function()
    local doc = store.parse({
      "## a.c:1", "status: open", "", "### me (local)", "new one", "",
      "## b.c:2 {id=t1}", "status: resolved", "", "### @x {id=t1-1}", "q", "", "### me (local)", "answer", "",
    })
    local kinds = {}
    for _, i in ipairs(merge.plan(doc, side).items) do table.insert(kinds, i.kind) end
    assert.are.same({ "thread", "reply", "resolve" }, kinds)
  end)

  it("never sends proposed comments, nor a resolve held with them", function()
    local doc = store.parse({
      "## b.c:2 {id=t1}", "status: resolved", "", "### @x {id=t1-1}", "q", "", "### me (proposed)", "fixed", "",
    })
    local plan = merge.plan(doc, side)
    assert.are.equal(0, #plan.items)
    assert.are.equal(1, #plan.held)
    merge.approve(doc.threads[1])
    plan = merge.plan(doc, side)
    assert.are.same({ "reply", "resolve" }, { plan.items[1].kind, plan.items[2].kind })
  end)

  it("marks a reply stale when unread remote comments arrived, without blocking it", function()
    local doc = store.parse({
      "## b.c:2 {id=t1}", "status: open", "", "### @x {id=t1-1}", "q", "", "### @y {id=t1-2}", "late", "", "### me (local)", "answer", "",
    })
    local plan = merge.plan(doc, side)
    assert.are.equal(1, #plan.items)
    assert.is_true(plan.items[1].stale)
  end)

  it("published removes a new thread with its text, and keeps the status", function()
    local doc = store.parse({ "## a.c:1", "status: open", "", "### me (local)", "x", "" })
    local s = { threads = {} }
    merge.published(doc, s, merge.plan(doc, s).items[1])
    assert.are.equal(0, #doc.threads)

    doc = store.parse({ "## a.c:1 {id=t1}", "status: resolved", "", "### me (local)", "x", "" })
    s = { threads = { t1 = { status = "open", seen = {}, seen_status = true } } }
    for _, item in ipairs(merge.plan(doc, s).items) do merge.published(doc, s, item) end
    assert.are.equal(1, #doc.threads)
    assert.are.equal(0, #doc.threads[1].comments)
    assert.are.equal("resolved", s.threads.t1.status)
  end)

  it("sends an orphaned thread as a new one", function()
    local doc = store.parse({ "## a.c:1 {id=gone orphan}", "status: open", "", "### me (local)", "x", "" })
    assert.are.equal("thread", merge.plan(doc, { threads = {} }).items[1].kind)
  end)
end)

describe("flags", function()
  it("tells apart the states an icon needs", function()
    local doc = store.parse({
      "## a.c:1 {id=t1}", "status: open", "", "### @x {id=1}", "q", "", "### me (proposed)", "p", "",
    })
    local f = merge.flags(doc.threads[1], { status = "open", seen = {}, seen_status = true })
    assert.is_true(f.unread and f.proposed)
    assert.is_false(f.unsent)
    assert.are.equal("unread", (merge.urgency(f)))
    local state = { status = "resolved", seen = { ["1"] = true }, seen_status = true }
    f = merge.flags(doc.threads[1], state)
    assert.is_true(f.unsent) -- reopened locally, not published
    assert.are.equal("proposed", (merge.urgency(f)))
  end)
end)

describe("relocate", function()
  it("finds the sent comment in a document that changed meanwhile", function()
    local side = { threads = {} }
    local doc = store.parse({ "## a.c:1", "status: open", "", "### me (local)", "x", "" })
    local item = merge.plan(doc, side).items[1]
    local fresh = store.parse({
      "## b.c:9", "status: open", "", "### me (proposed)", "agent", "",
      "## a.c:1", "status: open", "", "### me (local)", "x", "", "### me (proposed)", "y", "",
    })
    local moved = merge.relocate(fresh, item)
    assert.are.equal(fresh.threads[2], moved.thread)
    merge.published(fresh, side, moved)
    assert.are.equal("proposed", fresh.threads[2].comments[1].source)
    assert.is_nil(merge.relocate(store.parse({ "## a.c:1", "status: open" }), item))
  end)
end)

describe("notes for the agent", function()
  local side = { threads = { t1 = { status = "open", seen = {}, seen_status = true } } }

  it("a thread started with a note never publishes, its replies and resolve neither", function()
    local doc = store.parse({
      "## a.c:1", "status: resolved", "", "### me (note)", "rename this", "", "### me (local)", "and that", "",
    })
    assert.is_true(merge.local_only(doc.threads[1]))
    assert.are.same({}, merge.plan(doc, side).items)
    local f = merge.flags(doc.threads[1], nil)
    assert.is_true(f.local_only)
    assert.is_false(f.unsent)
  end)

  it("a note on a remote thread is not sent, the rest of the thread is", function()
    local doc = store.parse({
      "## b.c:2 {id=t1}", "status: resolved", "", "### @x {id=1}", "q", "", "### me (note)", "ask pi", "",
    })
    local kinds = vim.tbl_map(function(i) return i.kind end, merge.plan(doc, side).items)
    assert.are.same({ "resolve" }, kinds)
    assert.is_true(merge.has_unpublished(doc.threads[1]))
  end)

  it("approve means agreed on a local-only thread and on a finding before the MR, send otherwise", function()
    local doc = store.parse({
      "## a.c:1", "status: open", "", "### me (note)", "x", "", "### me (proposed)", "done", "",
      "## a.c:2", "status: open", "", "### me (proposed)", "NIT: finding", "",
      "## a.c:3", "status: open", "", "### me (proposed)", "NIT: finding on an MR", "",
      "## b.c:2 {id=t1}", "status: open", "", "### @x {id=1}", "q", "", "### me (proposed)", "reply", "",
    })
    merge.approve(doc.threads[1], false)
    merge.approve(doc.threads[2], true)
    merge.approve(doc.threads[3], false)
    merge.approve(doc.threads[4], true)
    assert.are.equal("note", doc.threads[1].comments[2].source)
    assert.are.equal("note", doc.threads[2].comments[1].source)
    assert.is_true(merge.local_only(doc.threads[2]))
    assert.are.equal("local", doc.threads[3].comments[1].source)
    assert.are.equal("local", doc.threads[4].comments[2].source)
    local kinds = vim.tbl_map(function(i) return i.kind end, merge.plan(doc, side).items)
    assert.are.same({ "thread", "reply" }, kinds)
  end)
end)

describe("edited comments", function()
  it("a comment edited after I saw it is unread again, and makes my reply stale", function()
    local lines = { "## b.c:2 {id=t1}", "status: open", "", "### @x {id=1}", "q", "", "### me (local)", "answer", "" }
    local doc = store.parse(lines)
    local side = { threads = { t1 = { status = "open", seen = {}, seen_status = true } } }
    merge.mark_seen(doc.threads[1], side)
    assert.are.equal(0, merge.unread_count(doc.threads[1], side.threads.t1))
    assert.is_nil(merge.plan(doc, side).items[1].stale)
    doc.threads[1].comments[1].body = "q, and also r"
    assert.are.equal(1, merge.unread_count(doc.threads[1], side.threads.t1))
    assert.is_true(merge.plan(doc, side).items[1].stale)
  end)

  it("seen state from before text hashes still counts as seen", function()
    local doc = store.parse({ "## b.c:2 {id=t1}", "status: open", "", "### @x {id=1}", "q", "" })
    assert.are.equal(0, merge.unread_count(doc.threads[1], { status = "open", seen = { ["1"] = true } }))
  end)
end)
