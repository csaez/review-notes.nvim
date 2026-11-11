-- :checkhealth review_notes
local M = {}

local OPTIONAL = { submit = true, discard = true }

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
  for _, name in ipairs({ "threads", "add", "reply", "resolve", "unresolve" }) do
    if not cmds[name] then health.error(("backend command `%s` is not configured"):format(name)) end
  end
  if not cmds.submit then
    health.info("no `submit` command: notes are sent one by one and the summary stays in the notes")
  end

  if cmds.threads and cmds.threads[1] == "git-lab" then
    if (vim.env.GITLAB_TOKEN or "") ~= "" then
      health.ok("GITLAB_TOKEN is set")
    else
      health.error("GITLAB_TOKEN is not set (needed by git-lab)")
    end
  end

  local notes = review.notes_file()
  if not notes then
    health.info("not in a git repository: no notes file to check")
  elseif vim.fn.filereadable(notes) == 1 then
    health.ok(("notes file: %s (%d entries)"):format(notes, #require("review_notes.notes").parse(vim.fn.readfile(notes))))
  else
    health.info(("notes file: %s (does not exist yet)"):format(notes))
  end
end

return M
