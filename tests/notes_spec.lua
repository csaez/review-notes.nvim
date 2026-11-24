local notes = require("review_notes.notes")

local function thread(id, resolved, path, line, ...)
  local comments = {}
  for _, c in ipairs({ ... }) do
    table.insert(comments, { author = c[1], body = c[2] })
  end
  return { id = id, path = path, line = line, resolved = resolved, comments = comments }
end

-- A thread from a backend that says which comments are mine (I am @me).
local function mine_thread(...)
  local t = thread(...)
  for _, c in ipairs(t.comments) do c.mine = c.author == "me" end
  return t
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

  it("ignores comments", function()
    assert.are.same({}, notes.parse({ "#a.c:1: comment", "# more" }))
  end)

  it("reads unlocated lines as general entries", function()
    local e = notes.parse({
      "Overall fine,",
      "with one concern.",
      "",
      "[id:g1] [new] @al: changelog?",
      "  > @bo: +1",
      "\\[not a tag] text",
      "a.c:1: on code",
    })
    assert.are.equal(4, #e)
    assert.is_true(e[1].general and e[2].general and e[3].general)
    assert.is_nil(e[1].loc)
    assert.are.equal("Overall fine,\nwith one concern.", e[1].text)
    assert.are.same({ "g1", true, { "> @bo: +1" } }, { e[2].id, e[2].new, e[2].quoted })
    assert.are.equal("[not a tag] text", e[3].head)
    assert.are.equal("\\[not a tag] text", notes.head_line(e[3]))
    assert.is_false(e[4].general)
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

  it("reads the old `.:0:` notes as general ones", function()
    local e = notes.parse({ ".:0: [id:g1] @al: old" })[1]
    assert.is_true(e.general)
    assert.are.equal("[id:g1] @al: old", notes.head_line(e))
  end)

  it("escapes a general head that would read as something else", function()
    assert.are.same({ "\\a.c:1: is a path", "  [x] body" }, notes.new_entry_lines(nil, { "a.c:1: is a path", "[x] body" }))
    assert.are.equal("a.c:1: is a path", notes.parse({ "\\a.c:1: is a path" })[1].head)
  end)
end)

describe("merge", function()
  it("appends threads that are not in the file, flagged new", function()
    local out, st = notes.merge({}, { thread("t1", false, "a.c", 7, { "al", "why?" }, { "bo", "+1" }) })
    assert.are.same({
      "a.c:7: [id:t1] [new] @al: why?",
      "  > @bo: +1",
    }, out)
    assert.are.same({ added = 1, updated = 0, new = 1, removed = 0, gone = 0 }, st)
  end)

  it("does not flag an unchanged thread and keeps my lines", function()
    local lines = {
      "a.c:7: [id:t1] @al: why?",
      "  > @bo: +1",
      "  my draft reply",
    }
    local out, st = notes.merge(lines, { thread("t1", false, "a.c", 7, { "al", "why?" }, { "bo", "+1" }) })
    assert.are.same(lines, out)
    assert.are.same({ added = 0, updated = 0, new = 0, removed = 0, gone = 0 }, st)
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

  it("keeps my unsent resolve and reopen", function()
    local out = notes.merge({ "a.c:7: [resolved] [id:t1] @al: why?" }, { thread("t1", false, "a.c", 7, { "al", "why?" }) })
    assert.are.same({ "a.c:7: [resolved] [id:t1] @al: why?" }, out)
    assert.are.equal(1, #notes.plan(out).states)
    out = notes.merge({ "a.c:7: [id:t1] @al: why?", "  > (resolved)" }, { thread("t1", true, "a.c", 7, { "al", "why?" }) })
    assert.are.same({ "a.c:7: [id:t1] @al: why?", "  > (resolved)" }, out)
    -- Once the remote agrees there is nothing left to send.
    out = notes.merge({ "a.c:7: [resolved] [id:t1] @al: why?" }, { thread("t1", true, "a.c", 7, { "al", "why?" }) })
    assert.are.same({ "a.c:7: [resolved] [id:t1] @al: why?", "  > (resolved)" }, out)
  end)

  it("flags a reply on a thread I resolved but have not sent", function()
    local out, st = notes.merge({ "a.c:7: [resolved] [id:t1] @al: why?" },
      { thread("t1", false, "a.c", 7, { "al", "why?" }, { "bo", "still broken" }) })
    assert.are.same({ "a.c:7: [resolved] [id:t1] [new] @al: why?", "  > @bo: still broken" }, out)
    assert.are.equal(1, st.new)
  end)

  it("does not flag my own comments, wherever I wrote them", function()
    local out, st = notes.merge({ "a.c:7: [id:t1] @al: why?" },
      { mine_thread("t1", false, "a.c", 7, { "al", "why?" }, { "me", "replied in the browser" }) })
    assert.are.same({ "a.c:7: [id:t1] @al: why?", "  > @me: replied in the browser" }, out)
    assert.are.equal(0, st.new)
    out = notes.merge({}, { mine_thread("t2", false, "a.c", 1, { "me", "started in the browser" }) })
    assert.are.same({ "a.c:1: [id:t2] @me: started in the browser" }, out)
  end)

  it("flags someone else's comment even right after a push", function()
    local out = notes.merge({ "a.c:7: [id:t1] @al: why?" },
      { mine_thread("t1", false, "a.c", 7, { "al", "why?" }, { "me", "sent" }, { "bo", "meanwhile" }) }, { quiet = true })
    assert.are.equal("a.c:7: [id:t1] [new] @al: why?", out[1])
    out = notes.merge({}, { mine_thread("t2", false, "a.c", 1, { "me", "sent" }) }, { quiet = true })
    assert.are.same({ "a.c:1: [id:t2] @me: sent" }, out)
  end)

  it("flags a resolve by someone else, not mine", function()
    local function resolved_by(who)
      local t = mine_thread("t1", true, "a.c", 7, { "me", "why?" })
      t.resolved_by, t.resolved_by_me = who, who == "me"
      return t
    end
    local out, st = notes.merge({ "a.c:7: [id:t1] @me: why?" }, { resolved_by("al") })
    assert.are.same({ "a.c:7: [resolved] [id:t1] [new] @me: why?", "  > (resolved)" }, out)
    assert.are.equal(1, st.new)
    out = notes.merge({ "a.c:7: [id:t1] @me: why?" }, { resolved_by("me") })
    assert.are.same({ "a.c:7: [resolved] [id:t1] @me: why?", "  > (resolved)" }, out)
    -- Already resolved as of the last pull: nothing new.
    out = notes.merge({ "a.c:7: [resolved] [id:t1] @me: why?", "  > (resolved)" }, { resolved_by("al") })
    assert.are.same({ "a.c:7: [resolved] [id:t1] @me: why?", "  > (resolved)" }, out)
  end)

  it("reopens locally when reopened remotely", function()
    local lines = { "a.c:7: [resolved] [id:t1] @al: why?", "  > (resolved)" }
    local out = notes.merge(lines, { thread("t1", false, "a.c", 7, { "al", "why?" }) })
    assert.are.same({ "a.c:7: [id:t1] @al: why?" }, out)
  end)

  it("drops threads gone from the remote, unless I have unsent lines on them", function()
    local lines = { "a.c:1: [id:gone] old", "", "a.c:2: my note", "", "a.c:3: [id:mine] @al: q", "  my reply" }
    local out, st = notes.merge(lines, {})
    assert.are.same({ "a.c:2: my note", "", "a.c:3: [id:mine] @al: q", "  my reply" }, out)
    assert.are.same({ added = 0, updated = 0, new = 0, removed = 1, gone = 1 }, st)
  end)

  it("takes the remote's location when the file has another file or none", function()
    local lines = { ".:0: [id:t0] @al: old format", "", "./x.c:0: [id:t1] @al: changelog?", "", "a.c:5: [id:t2] @bo: why?", "", "b.c:3: [id:t3] @bo: moved" }
    local out = notes.merge(lines, {
      thread("t0", false, vim.NIL, nil, { "al", "old format" }),
      thread("t1", false, vim.NIL, nil, { "al", "changelog?" }),
      thread("t2", false, "a.c", 9, { "bo", "why?" }),
      thread("t3", false, "c.c", 3, { "bo", "moved" }),
    })
    assert.are.same({ "[id:t0] @al: old format", "", "[id:t1] @al: changelog?", "", "a.c:5: [id:t2] @bo: why?", "", "c.c:3: [id:t3] @bo: moved" }, out)
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

  it("puts general threads first and notes on code in order", function()
    local out = notes.merge({ "b.c:1: mine", "", "a.c:9: other" }, {
      thread("t2", false, "a.c", 0, { "bo", "split" }),
      thread("t1", false, vim.NIL, nil, { "al", "changelog?" }),
    })
    assert.are.same({
      "[id:t1] [new] @al: changelog?",
      "",
      "a.c:0: [id:t2] [new] @bo: split",
      "",
      "a.c:9: other",
      "",
      "b.c:1: mine",
    }, out)
  end)

  it("reads a multi-line comment as a range", function()
    local t = thread("t1", false, "a.c", 9, { "al", "these" })
    t.start_line = 7
    assert.are.same({ "a.c:7-9: [id:t1] [new] @al: these" }, (notes.merge({}, { t })))
  end)

  it("keeps my resolved state on a one-off comment", function()
    local t = thread("t1", false, nil, nil, { "al", "nice" })
    t.resolvable = false
    local lines = { "[resolved] [id:t1] @al: nice", "  > (resolved)" }
    local out, st = notes.merge(lines, { t })
    assert.are.same(lines, out)
    assert.are.equal(0, #notes.plan(out).states)
    out = notes.merge({ "[id:t1] @al: nice" }, { t })
    assert.are.same({ "[id:t1] @al: nice" }, out)
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
    assert.are.equal(1, #plan.replies)
    assert.are.equal("my reply", plan.replies[1].send)
    local states = vim.tbl_map(function(e) return e.id end, plan.states)
    assert.are.same({ "t3", "t4" }, states)
    assert.are.equal(2, #plan.new)
    assert.is_true(plan.new[1].general)
    assert.are.equal("Overall fine.", plan.new[1].send)
    assert.are.equal("new note\nmore", plan.new[2].send)
  end)

  it("counts drafts, including draft replies, and sends none", function()
    assert.are.equal(2, notes.plan(lines).drafts)
  end)

  it("counts a resolved draft that holds a reply, as pi hands back a thread", function()
    local plan = notes.plan({
      "a.c:1: [resolved] [draft] [id:t1] @al: q",
      "  > @al: q",
      "  fixed it",
      "a.c:2: [resolved] [draft] dismissed",
    })
    assert.are.equal(1, plan.drafts)
    assert.is_nil(notes.describe(plan))
  end)

  it("describes the plan", function()
    assert.are.equal("2 new threads, 1 reply, 2 state changes", notes.describe(notes.plan(lines)))
    assert.is_nil(notes.describe(notes.plan({ "a.c:1: [draft] x" })))
  end)

  it("holds back [new] entries with something to send", function()
    local plan = notes.plan({
      "a.c:1: [resolved] [id:t1] [new] @al: q",
      "a.c:2: [id:t2] [new] @al: q",
      "  my reply",
      "a.c:3: [id:t3] [new] @al: nothing of mine",
      "a.c:4: [new] a note pi added",
    })
    assert.is_nil(notes.describe(plan))
    assert.are.equal(3, plan.held)
    assert.are.equal(" (3 [new] entries held back until read)", notes.describe_skipped(plan))
  end)
end)

describe("entry_view", function()
  it("marks my unsent reply on a thread apart from the remote comments", function()
    local function view(l) return notes.entry_view(notes.parse(l)[1]) end
    local thread = { "a.c:1: [id:t1] @al: why?", "  > @bo: because", "  my answer" }
    assert.are.same({ "### @al", "why?", "", "### @bo", "because", "", notes.UNSENT_VIEW, "my answer" }, view(thread))
    thread[1] = "a.c:1: [draft] [id:t1] @al: why?"
    assert.are.equal(notes.UNSENT_DRAFT_VIEW, view(thread)[7])
    -- A note never sent is unsent as a whole: no marker inside it.
    assert.are.same({ "mine", "more" }, view({ "a.c:1: mine", "  more" }))
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
      new = { [plan.new[1]] = true, [plan.new[2]] = true },
      replies = { [plan.replies[1]] = true },
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
    local out = notes.apply_sent(lines, plan, { new = {}, replies = {} })
    assert.are.same(lines, out)
  end)
end)

describe("add_entry and sort", function()
  it("adds a general entry after the general ones, others at the end", function()
    local lines = { "first general", "", "a.c:1: code" }
    assert.are.same(
      { "first general", "", "second", "", "a.c:1: code" },
      notes.add_entry(lines, notes.new_entry_lines(nil, { "second" }), true)
    )
    assert.are.same({ "only", "", "a.c:1: code" }, notes.add_entry({ "a.c:1: code" }, { "only" }, true))
    assert.are.same({ "first general", "", "a.c:1: code", "", "b.c:2: x" }, notes.add_entry(lines, { "b.c:2: x" }, false))
  end)

  it("sorts blocks with their comments and keeps a sorted file as it is", function()
    local lines = { "b.c:1: b", "  body", "# about b", "", "general", "a.c:2: a" }
    assert.are.same({ "general", "", "a.c:2: a", "", "b.c:1: b", "  body", "# about b" }, notes.sort(lines))
    local sorted = { "general", "a.c:2: a" }
    assert.are.equal(sorted, notes.sort(sorted))
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
