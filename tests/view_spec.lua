local view = require("review_notes.view")
local store = require("review_notes.store")

local function entries(lines)
  local out = {}
  for i, t in ipairs(store.parse(lines).threads) do
    out[i] = { key = view.key(t, i), thread = t }
  end
  return out
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("review_notes_view"), 0, -1, { details = true })
end

describe("view", function()
  local buf
  before_each(function()
    view.set_highlights()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
  end)

  local DOC = {
    "## change {id=g}", "status: open", "", "### @bo {id=1}", "overall", "",
    "## a.c:2-3 {id=t}", "status: open", "", "### @al {id=2}", "why?", "",
    "## b.c:1 {id=o}", "status: open", "", "### @al {id=3}", "elsewhere",
  }

  it("draws change threads in a header above line 1 and code threads below their last line", function()
    view.render(buf, entries(DOC), "a.c", true, { expanded = {}, signs = true, width = 60 })
    local above, below = 0, 0
    for _, m in ipairs(marks(buf)) do
      if m[4].virt_lines then
        if m[4].virt_lines_above then above = above + 1; assert.are.equal(0, m[2]) else below = below + 1; assert.are.equal(2, m[2]) end
      end
    end
    assert.are.same({ 1, 1 }, { above, below })
  end)

  it("scrolls a window at the top into the header so it is on screen", function()
    vim.api.nvim_set_current_buf(buf)
    local height = view.render(buf, entries(DOC), "a.c", true, { expanded = {}, signs = false, width = 60 })
    assert.is_true(height > 0)
    view.show_header(buf, height)
    assert.are.equal(height, vim.fn.winsaveview().topfill)
    assert.are.equal(0, view.render(buf, entries(DOC), "a.c", false, { expanded = {}, signs = false, width = 60 }))
  end)

  it("draws only signs when not visible, and nothing for other files' threads", function()
    view.render(buf, entries(DOC), "a.c", false, { expanded = {}, signs = true, width = 60 })
    local signs = 0
    for _, m in ipairs(marks(buf)) do
      assert.is_nil(m[4].virt_lines)
      if m[4].sign_text then signs = signs + 1 end
    end
    assert.are.equal(2, signs) -- the 2-3 range
  end)

  it("expands to the whole conversation", function()
    local e = entries(DOC)
    local short = #view.thread_lines(e[2], false, 60, false, "  ")
    local long = #view.thread_lines(e[2], true, 60, false, "  ")
    assert.are.equal(1, short)
    assert.is_true(long > short)
  end)

  it("follows edits", function()
    view.render(buf, entries(DOC), "a.c", true, { expanded = {}, signs = false, width = 60 })
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new" })
    local a = vim.tbl_filter(function(x) return not x.header end, view.anchored(buf))[1]
    assert.are.same({ 2, 3 }, { a.row, a.end_row })
    assert.are.equal(1, #view.at(buf, 3))
    assert.are.equal(0, #view.at(buf, 0))
  end)
end)
