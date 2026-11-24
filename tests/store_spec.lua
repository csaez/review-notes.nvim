local store = require("review_notes.store")

local SAMPLE = {
  "# Review of x",
  "",
  "## change {id=g1}",
  "status: open",
  "",
  "### @alice {id=11}",
  "please add a changelog entry",
  "",
  "### me (local)",
  "done",
  "",
  "## src/a.c:3-5 {id=t1}",
  "status: resolved",
  "",
  "### @bob {id=12 mine}",
  "why?",
  "",
  "### me (proposed)",
  "\\# not a heading",
  "",
  "## src/b.c:7",
  "status: open",
  "",
  "### me (local)",
  "first",
  "",
  "second",
}

describe("anchors", function()
  it("round-trips every kind", function()
    for _, s in ipairs({ "change", "a/b.c", "a/b.c:3", "a/b.c:3-9" }) do
      assert.are.equal(s, store.anchor_string(store.parse_anchor(s)))
    end
    assert.are.equal("change", store.anchor_kind({}))
    assert.are.equal("file", store.anchor_kind({ path = "a" }))
    assert.are.equal("line", store.anchor_kind({ path = "a", line = 1 }))
  end)
end)

describe("parse", function()
  local doc = store.parse(SAMPLE)

  it("reads the title and threads", function()
    assert.are.equal("Review of x", doc.title)
    assert.are.equal(3, #doc.threads)
  end)

  it("treats the change like any other thread", function()
    local t = doc.threads[1]
    assert.are.same({}, t.anchor)
    assert.are.equal("g1", t.id)
    assert.are.equal(2, #t.comments)
    assert.are.same({ "remote", "alice", "11" }, { t.comments[1].source, t.comments[1].author, t.comments[1].id })
    assert.are.equal("local", t.comments[2].source)
  end)

  it("reads status, ranges, flags and escaped headings", function()
    local t = doc.threads[2]
    assert.are.equal("resolved", t.status)
    assert.are.same({ path = "src/a.c", line = 3, end_line = 5 }, t.anchor)
    assert.is_true(t.comments[1].mine)
    assert.are.equal("proposed", t.comments[2].source)
    assert.are.equal("# not a heading", t.comments[2].body)
  end)

  it("keeps paragraphs and leaves new threads without an id", function()
    local t = doc.threads[3]
    assert.is_nil(t.id)
    assert.are.equal("first\n\nsecond", t.comments[1].body)
  end)

  it("reads bare text under a thread as one local comment", function()
    local d = store.parse({ "## a.c:1", "just text", "more" })
    assert.are.equal("open", d.threads[1].status)
    assert.are.same({ source = "local", body = "just text\nmore" }, d.threads[1].comments[1])
  end)
end)

describe("render", function()
  it("round-trips", function()
    local once = store.render(store.parse(SAMPLE))
    assert.are.same(once, store.render(store.parse(once)))
    assert.are.same(store.parse(SAMPLE), store.parse(once))
  end)
end)

describe("update", function()
  local dir = vim.fn.tempname()
  local path = dir .. "/r.md"

  it("writes atomically and re-reads", function()
    store.update(path, function(doc)
      table.insert(doc.threads, { anchor = { path = "a" }, status = "open", comments = {} })
    end)
    assert.are.equal(1, #store.parse(store.read_lines(path)).threads)
    assert.are.equal(0, #vim.fn.glob(path .. ".tmp.*", false, true))
  end)

  it("redoes the change when the file changed underneath", function()
    local runs = 0
    store.update(path, function(doc)
      runs = runs + 1
      if runs == 1 then
        store.update(path, function(d) table.insert(d.threads, { anchor = { path = "b" }, status = "open", comments = {} }) end)
      end
      table.insert(doc.threads, { anchor = { path = "c" }, status = "open", comments = {} })
    end)
    assert.are.equal(2, runs)
    assert.are.equal(3, #store.parse(store.read_lines(path)).threads)
  end)
end)

describe("sidecar", function()
  it("falls back to empty on garbage", function()
    local p = vim.fn.tempname()
    store.write_lines(p, { "not json" })
    assert.are.same({ threads = {} }, store.read_sidecar(p))
    assert.are.equal("/x/b.json", store.sidecar_path("/x/b.md"))
  end)
end)
