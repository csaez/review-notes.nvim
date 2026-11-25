local signs = require("review_notes.signs")
local review = require("review_notes.review")
local store = require("review_notes.store")

local function entries(lines)
  local out = {}
  for i, t in ipairs(store.parse(lines).threads) do
    out[i] = { key = review.key(t, i), thread = t }
  end
  return out
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("review_notes_signs"), 0, -1, { details = true })
end

describe("signs", function()
  local buf
  before_each(function()
    signs.set_highlights()
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
  end)

  local DOC = {
    "## change {id=g}", "status: open", "", "### @bo {id=1}", "overall", "",
    "## a.c:2-3 {id=t}", "status: open", "", "### @al {id=2}", "why?", "",
    "## b.c:1 {id=o}", "status: open", "", "### @al {id=3}", "elsewhere",
  }

  it("marks the range of this file's line threads, and draws no text", function()
    signs.render(buf, entries(DOC), "a.c", { signs = true })
    local rows = {}
    for _, m in ipairs(marks(buf)) do
      assert.is_nil(m[4].virt_lines)
      assert.is_nil(m[4].virt_text)
      if m[4].sign_text then rows[m[2]] = vim.trim(m[4].sign_text) end
    end
    assert.are.same({ 1, 2 }, vim.tbl_keys(rows))
    assert.are.equal("\u{258e}", rows[1])
    assert.are.equal(review.style.unread.icon, rows[2])
    assert.are.equal(1, #signs.anchored(buf))
  end)

  it("tracks the anchors without signs, and follows edits", function()
    signs.render(buf, entries(DOC), "a.c", { signs = false })
    for _, m in ipairs(marks(buf)) do assert.is_nil(m[4].sign_text) end
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new" })
    local a = signs.anchored(buf)[1]
    assert.are.same({ 2, 3 }, { a.row, a.end_row })
    assert.are.equal(1, #signs.at(buf, 3))
    assert.are.equal(0, #signs.at(buf, 0))
  end)
end)
