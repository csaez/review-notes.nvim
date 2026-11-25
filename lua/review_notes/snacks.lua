-- A snacks.nvim picker source for the threads of the current review, built
-- on `actions` so its keys match the panel and the home:
--   <CR> show in the panel, <a-o> go to the code,
--   <a-r> reply, <a-x> resolve, <a-a> approve, <a-d> discard, <a-m> mark read.
-- Register it with `picker = { sources = { review_notes = require("review_notes.snacks").source } }`
-- or open it directly with `require("review_notes.snacks").open()`.
local review = require("review_notes.review")
local actions = require("review_notes.actions")
local panel = require("review_notes.panel")

local M = {}

--- Run *fn* on the item, then refresh the list (the item moved section).
local function act(fn)
  return function(picker, item)
    if not item then return end
    fn(item.ctx, item.key)
    picker:find()
  end
end

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
    ctx.preview:set_lines(ctx.item.thread or {})
    ctx.preview:highlight({ ft = "markdown" })
  end,
  confirm = function(picker, item)
    picker:close()
    if item then panel.show(item.ctx, item.key, { reorder = true }) end
  end,
  actions = {
    review_code = function(picker, item)
      picker:close()
      if item then panel.go_to(item) end
    end,
    review_reply = function(picker, item)
      picker:close()
      if item then actions.reply(item.ctx, item.entry) end
    end,
    review_resolve = act(actions.resolve),
    review_read = act(actions.read),
    review_approve = function(picker, item)
      if not item then return end
      actions.approve_items({ item })
      picker:find()
    end,
    review_discard = function(picker, item)
      if item then actions.discard_items({ item }, function() picker:find() end) end
    end,
  },
  win = {
    input = {
      keys = {
        ["<a-o>"] = { "review_code", mode = { "n", "i" }, desc = "go to the code" },
        ["<a-r>"] = { "review_reply", mode = { "n", "i" }, desc = "reply" },
        ["<a-x>"] = { "review_resolve", mode = { "n", "i" }, desc = "resolve / reopen" },
        ["<a-a>"] = { "review_approve", mode = { "n", "i" }, desc = "approve proposed" },
        ["<a-d>"] = { "review_discard", mode = { "n", "i" }, desc = "discard unpublished" },
        ["<a-m>"] = { "review_read", mode = { "n", "i" }, desc = "mark read" },
      },
    },
  },
}

--- Open the picker (snacks.nvim must be installed).
---@param opts table? merged into the source
function M.open(opts)
  local ok, snacks = pcall(require, "snacks")
  if not ok then return review.notify("snacks.nvim is not installed", vim.log.levels.ERROR) end
  snacks.picker.pick(vim.tbl_deep_extend("force", {}, M.source, opts or {}))
end

return M
