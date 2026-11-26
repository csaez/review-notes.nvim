-- The finder: a snacks.nvim picker source to jump to a thread of the current
-- review from anywhere. It searches the anchor, the tags and the whole
-- conversation. Acting on threads is the sidebar's job, so the keys are few:
--   <CR> show the thread in the sidebar, <a-o> go to the code.
-- Register it with `picker = { sources = { review_notes = require("review_notes.snacks").source } }`
-- or open it directly with `require("review_notes.snacks").open()`.
local review = require("review_notes.review")
local thread = require("review_notes.thread")

local M = {}

M.source = {
  title = "Review threads",
  finder = function(_, ctx)
    local rctx = review.context(ctx.filter.current_buf)
    local items = rctx and review.items(rctx) or {}
    for _, item in ipairs(items) do
      item.pos, item.end_pos = { item.line, 0 }, { item.end_line, 0 }
    end
    return items
  end,
  format = function(item, picker)
    local ret = { { item.icon .. " ", item.hl } }
    if item.kind == "change" then
      table.insert(ret, { "change  ", "SnacksPickerDir" })
    else
      vim.list_extend(ret, Snacks.picker.format.filename(item, picker))
    end
    for _, tag in ipairs(item.tags or {}) do
      table.insert(ret, { "[" .. tag .. "] ", "SnacksPickerComment" })
    end
    if item.who ~= "" then table.insert(ret, { item.who .. ": ", item.who:sub(1, 2) == "me" and "ReviewMine" or "ReviewAuthor" }) end
    table.insert(ret, { item.summary, item.state == "resolved" and "ReviewResolved" or "ReviewText" })
    return ret
  end,
  preview = function(ctx)
    ctx.preview:reset()
    ctx.preview:set_title(ctx.item.anchor)
    ctx.preview:set_lines(thread.lines(ctx.item))
    ctx.preview:highlight({ ft = "markdown" })
  end,
  confirm = function(picker, item)
    picker:close()
    if item then thread.show(item.ctx, item.key, { reorder = true }) end
  end,
  actions = {
    review_code = function(picker, item)
      picker:close()
      if item then thread.go_to(item) end
    end,
  },
  win = {
    input = {
      keys = {
        ["<a-o>"] = { "review_code", mode = { "n", "i" }, desc = "go to the code" },
      },
    },
  },
}

--- Open the finder (snacks.nvim must be installed).
---@param opts table? merged into the source
function M.open(opts)
  local ok, snacks = pcall(require, "snacks")
  if not ok then return review.notify("snacks.nvim is not installed", vim.log.levels.ERROR) end
  snacks.picker.pick(vim.tbl_deep_extend("force", {}, M.source, opts or {}))
end

return M
