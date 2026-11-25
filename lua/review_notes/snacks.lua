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

local function entry(item) return review.entry(item.ctx, item.key) end

--- Run *fn* on the item, then refresh the list (the item moved section).
local function act(fn)
  return function(picker, item)
    if not item then return end
    local e = entry(item)
    if not e then return review.notify("that thread is gone", vim.log.levels.WARN) end
    fn(item, e)
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
      if item then require("review_notes").goto_item(item) end
    end,
    review_reply = function(picker, item)
      if not item then return end
      local e = entry(item)
      picker:close()
      if e then actions.reply(item.ctx, e) end
    end,
    review_resolve = act(function(item) actions.resolve(item.ctx, item.key) end),
    review_read = act(function(item) actions.read(item.ctx, item.key) end),
    review_approve = act(function(item) actions.approve(item.ctx, item.key) end),
    review_discard = function(picker, item)
      local e = item and entry(item)
      if not (item and e) then return end
      if not actions.can_discard(e) then return review.notify("nothing unpublished here") end
      local function go()
        actions.discard(item.ctx, item.key)
        picker:find()
      end
      -- As in the panel: only deleting a whole new thread asks.
      if e.thread.id then return go() end
      actions.confirm_discard(e, go)
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
