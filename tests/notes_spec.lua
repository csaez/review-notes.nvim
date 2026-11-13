local notes = require("review_notes.notes")

local function thread(id, resolved, path, line, ...)
  local comments = {}
  for _, c in ipairs({ ... }) do
    table.insert(comments, { author = c[1], body = c[2] })
  end
  return { id = id, path = path, line = line, resolved = resolved, comments = comments }
end

describe("parse", function()
  it("reads single-line and range entries", function()
    local e = notes.parse({ "a.c:3: one", "b/c.h:10-12: two" })
    assert.are.equal(2, #e)
    assert.are.same({ "a.c", 3, nil, "one" }, { e[1].path, e[1].line, e[1].end_line, e[1].head })
    assert.are.same({ "b/c.h", 10, 12, "two" }, { e[2].path, e[2].line, e[2].end_line, e[2].head })
    assert.are.equal("b/c.h:10-12", e[2].loc)
    assert.are.equal(2, e[2].src)
  end)

  it("joins indented continuation lines, keeping paragraphs", function()
    local e = notes.parse({ "a.c:3: first", "  second", "", "  third", "", "b.c:1: x" })
    assert.are.equal("first\nsecond\n\nthird", e[1].text)
    assert.are.same({ "second", "", "third" }, e[1].mine)
    assert.are.equal(4, e[1].last)
    assert.are.equal("note", e[1].kind)
  end)

  it("keeps the indentation of code in a note", function()
    local e = notes.parse({ "a.c:3: try", "  if x:", "      return 1", "\tdeep" })[1]
    assert.are.same({ "if x:", "    return 1", "deep" }, e.mine)
  end)

  it("reads an escaped > as my text, not as a remote line", function()
    local e = notes.parse({ "a.c:1: [id:t1] @al: why", "  > @bo: +1", "  \\> as you said", "  mine" })[1]
    assert.are.same({ "> @bo: +1" }, e.quoted)
    assert.are.same({ "\\> as you said", "mine" }, e.mine)
    assert.are.equal("@al: why\n> @bo: +1\n> as you said\nmine", e.text)
    assert.are.equal("> as you said\nmine", notes.plan({ "a.c:1: [id:t1] @al: why", "  \\> as you said", "  mine" }).replies[1].send)
  end)

  it("drops blank lines around quoted lines", function()
    local e = notes.parse({ "a.c:1: [id:t1] @al: why", "", "  > @bo: +1", "", "  mine" })[1]
    assert.are.same({ "mine" }, e.mine)
  end)

  it("ignores lines that only look like entries", function()
    assert.are.same({}, notes.parse({ "> a.c:1: quoted", "#a.c:1: comment", "a.c:x: nope" }))
  end)

  it("reads tags in any order and keeps the rest as text", function()
    local e = notes.parse({ "a.c:1: [new] [id:abc] [draft] [resolved] hello [world]" })[1]
    assert.is_true(e.new and e.draft and e.resolved)
    assert.are.equal("abc", e.id)
    assert.are.equal("thread", e.kind)
    assert.are.equal("hello [world]", e.head)
  end)

  it("splits the body into the remote cache and my lines", function()
    local e = notes.parse({
      "a.c:1: [id:t1] @al: why",
      "  > @bo: +1",
      "  > (resolved)",
      "  my reply",
    })[1]
    assert.are.same({ "> @bo: +1" }, e.quoted)
    assert.are.same({ "my reply" }, e.mine)
    assert.is_true(e.remote_resolved)
  end)

  it("reads the summary from lines outside entries", function()
    local lines = { "Looks good.", "More.", "", "# note to self", "a.c:1: x", "  body", "tail" }
    assert.are.equal("Looks good.\nMore.\ntail", (notes.summary(lines)))
  end)
end)

describe("merge", function()
  it("appends threads that are not in the file, flagged new", function()
    local out, st = notes.merge({}, { thread("t1", false, "a.c", 7, { "al", "why?" }, { "bo", "+1" }) })
    assert.are.same({
      "a.c:7: [id:t1] [new] @al: why?",
      "  > @bo: +1",
    }, out)
    assert.are.same({ added = 1, updated = 0, new = 1 }, st)
  end)

  it("does not flag an unchanged thread and keeps my lines", function()
    local lines = {
      "a.c:7: [id:t1] @al: why?",
      "  > @bo: +1",
      "  my draft reply",
    }
    local out, st = notes.merge(lines, { thread("t1", false, "a.c", 7, { "al", "why?" }, { "bo", "+1" }) })
    assert.are.same(lines, out)
    assert.are.same({ added = 0, updated = 0, new = 0 }, st)
  end)

  it("appends new comments to the quoted block and flags the thread", function()
    local lines = { "a.c:7: [id:t1] @al: why?", "  my reply", "", "b.c:1: other" }
    local out, st = notes.merge(lines, { thread("t1", false, "a.c", 7, { "al", "why?" }, { "bo", "line1\nline2" }) })
    assert.are.same({
      "a.c:7: [id:t1] [new] @al: why?",
      "  > @bo: line1",
      "  > line2",
      "  my reply",
      "",
      "b.c:1: other",
    }, out)
    assert.are.equal(1, st.new)
  end)

  it("flags a remote edit of an existing comment", function()
    local lines = { "a.c:7: [id:t1] @al: why?", "  > @bo: +1" }
    local out = notes.merge(lines, { thread("t1", false, "a.c", 7, { "al", "why?" }, { "bo", "-1" }) })
    assert.are.same({ "a.c:7: [id:t1] [new] @al: why?", "  > @bo: -1" }, out)
  end)

  it("resolves locally when resolved remotely, without flagging", function()
    local lines = { "a.c:7: [id:t1] @al: why?", "  > @bo: +1" }
    local out, st = notes.merge(lines, { thread("t1", true, "a.c", 7, { "al", "why?" }, { "bo", "+1" }) })
    assert.are.same({ "a.c:7: [resolved] [id:t1] @al: why?", "  > @bo: +1", "  > (resolved)" }, out)
    assert.are.equal(0, st.new)
    assert.are.equal(1, st.updated)
  end)

  it("reopens locally when reopened remotely", function()
    local lines = { "a.c:7: [resolved] [id:t1] @al: why?", "  > (resolved)" }
    local out = notes.merge(lines, { thread("t1", false, "a.c", 7, { "al", "why?" }) })
    assert.are.same({ "a.c:7: [id:t1] @al: why?" }, out)
  end)

  it("leaves entries whose thread is gone and plain notes alone", function()
    local lines = { "a.c:1: [id:gone] old", "a.c:2: my note" }
    local out, st = notes.merge(lines, {})
    assert.are.same(lines, out)
    assert.are.same({ added = 0, updated = 0, new = 0 }, st)
  end)

  it("keeps the new flag until cleared", function()
    local lines = { "a.c:7: [id:t1] [new] @al: why?" }
    local out = notes.merge(lines, { thread("t1", false, "a.c", 7, { "al", "why?" }) })
    assert.are.same(lines, out)
  end)

  it("flags nothing when quiet", function()
    local out, st = notes.merge({}, { thread("t1", false, "a.c", 7, { "me", "sent" }) }, { quiet = true })
    assert.are.same({ "a.c:7: [id:t1] @me: sent" }, out)
    assert.are.equal(0, st.new)
  end)

  it("is idempotent", function()
    local t = { thread("t1", false, "a.c", 7, { "al", "why?" }, { "bo", "+1" }) }
    local once = notes.merge({ "a.c:1: mine" }, t)
    assert.are.same(once, (notes.merge(once, t)))
  end)
end)

describe("plan", function()
  local lines = {
    "Overall fine.",
    "",
    "a.c:1: new note",
    "  more",
    "a.c:2: [draft] not yet",
    "a.c:3: [resolved] dismissed",
    "/tmp/plan.md:4: outside the repo",
    "a.c:5: [id:t1] @al: why?",
    "  > @bo: +1",
    "  my reply",
    "a.c:6: [draft] [id:t2] @al: q",
    "  a draft reply",
    "a.c:7: [resolved] [id:t3] @al: done",
    "a.c:8: [id:t4] @al: x",
    "  > (resolved)",
  }

  it("sends new notes, replies and state changes only", function()
    local plan = notes.plan(lines)
    assert.are.equal(1, #plan.new)
    assert.are.equal("new note\nmore", plan.new[1].send)
    assert.are.equal(1, #plan.replies)
    assert.are.equal("my reply", plan.replies[1].send)
    local states = vim.tbl_map(function(e) return e.id end, plan.states)
    assert.are.same({ "t3", "t4" }, states)
    assert.are.equal("Overall fine.", plan.summary)
  end)

  it("counts drafts, including draft replies, and sends none", function()
    assert.are.equal(2, notes.plan(lines).drafts)
  end)

  it("describes the plan", function()
    assert.are.equal("1 new thread, 1 reply, 2 state changes, summary", notes.describe(notes.plan(lines)))
    assert.is_nil(notes.describe(notes.plan({ "a.c:1: [draft] x" })))
  end)
end)

describe("apply_sent", function()
  local lines = {
    "Summary text.",
    "",
    "a.c:1: new note",
    "  more",
    "",
    "a.c:5: [id:t1] @al: why?",
    "  > @bo: +1",
    "  my reply",
    "a.c:6: [id:t2] @al: q",
    "  other reply",
  }

  it("removes what was sent and keeps what failed", function()
    local plan = notes.plan(lines)
    local out = notes.apply_sent(lines, plan, {
      new = { [plan.new[1]] = true },
      replies = { [plan.replies[1]] = true },
      summary = true,
    })
    assert.are.same({
      "a.c:5: [id:t1] @al: why?",
      "  > @bo: +1",
      "a.c:6: [id:t2] @al: q",
      "  other reply",
    }, out)
  end)

  it("keeps everything when nothing succeeded", function()
    local plan = notes.plan(lines)
    local out = notes.apply_sent(lines, plan, { new = {}, replies = {}, summary = false })
    assert.are.same(lines, out)
  end)
end)

describe("edits", function()
  it("edits one entry head", function()
    local out = notes.edit_entry({ "a.c:1: [new] x", "a.c:2: y" }, 1, function(e)
      e.new, e.resolved = false, true
    end)
    assert.are.same({ "a.c:1: [resolved] x", "a.c:2: y" }, out)
  end)

  it("cleans resolved entries with nothing left to send", function()
    local out, n = notes.clean({
      "a.c:1: [resolved] [id:a] x",
      "  > (resolved)",
      "a.c:2: [resolved] [id:b] y",
      "  my reply",
      "a.c:3: [resolved] [id:c] z",
      "a.c:4: [resolved] note",
      "a.c:5: open",
    })
    assert.are.equal(2, n)
    assert.are.same({
      "a.c:2: [resolved] [id:b] y",
      "  my reply",
      "a.c:3: [resolved] [id:c] z",
      "a.c:5: open",
    }, out)
  end)
end)

describe("turns", function()
  it("is the whole note while nobody answered", function()
    local lines = { "x", "a.c:1: [draft] head", "  more", "", "  para", "b.c:1: y" }
    local t = notes.turn(lines, 2)
    assert.are.same({ whole = true, first = 2, last = 5, text = { "head", "more", "", "para" } }, t)
    assert.are.same(
      { "x", "a.c:1: [draft] new head", "  \\> quoted", "b.c:1: y" },
      notes.set_turn(lines, 2, { "new head", "> quoted" })
    )
  end)

  it("is my reply after the last quoted line", function()
    local lines = { "a.c:1: [new] mine", "  > @pi: done", "  my answer" }
    assert.are.same({ "my answer" }, notes.turn(lines, 1).text)
    local out = notes.set_turn(lines, 1, { "longer", "", "answer" }, function(e) e.new = false end)
    assert.are.same({ "a.c:1: mine", "  > @pi: done", "  longer", "", "  answer" }, out)
  end)

  it("is empty for a thread I have not answered", function()
    local lines = { "a.c:1: [id:t1] @al: why", "  > @bo: +1", "a.c:2: other" }
    local t = notes.turn(lines, 1)
    assert.are.same({}, t.text)
    assert.are.same(
      { "a.c:1: [id:t1] @al: why", "  > @bo: +1", "  reply", "a.c:2: other" },
      notes.set_turn(lines, 1, { "reply" })
    )
  end)

  it("writes new entries with escaped and blank lines", function()
    assert.are.same({ "a.c:1-2: head", "", "  \\> q", "  code" }, notes.new_entry_lines("a.c:1-2", { "head", "", "> q", "code" }))
  end)
end)

describe("my turn", function()
  it("is set by an open note ending with a pi question", function()
    local e = notes.parse({ "a.c:1: x", "  > @pi: QUESTION: which?", "a.c:2: [resolved] y", "  > @pi: QUESTION: q" })
    assert.is_true(e[1].my_turn)
    assert.is_false(e[2].my_turn)
  end)

  it("is cleared by my answer", function()
    assert.is_false(notes.parse({ "a.c:1: x", "  > @pi: QUESTION: which?", "  this one" })[1].my_turn)
  end)
end)
