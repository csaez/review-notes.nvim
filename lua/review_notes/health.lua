-- :checkhealth review_notes
local M = {}

local OPTIONAL = { submit = true, discard = true, general = true }

function M.check()
  local health = vim.health
  health.start("review_notes")

  if vim.fn.executable("git") == 1 then
    health.ok("git found")
  else
    health.error("git not found")
  end

  local review = require("review_notes")
  local cmds = review.config.backend
  local names = vim.tbl_keys(cmds)
  table.sort(names)
  for _, name in ipairs(names) do
    local exe = cmds[name][1] or ""
    if vim.fn.executable(exe) == 1 then
      health.ok(("%s: `%s` found"):format(name, exe))
    else
      local report = OPTIONAL[name] and health.warn or health.error
      report(("%s: `%s` is not executable"):format(name, exe))
    end
  end
  for _, name in ipairs({ "threads", "add", "general", "reply", "resolve", "unresolve" }) do
    if not cmds[name] then health.error(("backend command `%s` is not configured"):format(name)) end
  end
  if not cmds.submit then
    health.info("no `submit` command: each comment is posted as soon as it is sent")
  elseif not require("review_notes.backend").uses(cmds, "submit", "ids") then
    health.warn("`submit` takes no `{ids}`: publish sends every pending draft, browser ones included")
  end
end

return M
