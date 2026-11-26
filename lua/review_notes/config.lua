-- The options, shared by every module. `setup` replaces `values`; read it
-- through the module each time, never keep a copy.
local M = {}

---@class review_notes.Config
---@field signs boolean sign column marks on the anchors
---@field watch boolean redraw when a notes file changes on disk
---@field auto_pull integer|false pull in the background on focus and on
---  entering the list, when the last pull is older than this many seconds
---@field backend table<string, string[]> Command lines, run in the repo root.
---  `{path}`, `{line}`, `{thread}` and `{ids}` are substituted; text goes on stdin.
---    threads    prints [{id, path, line, resolved, comments = [{id, author, body}]}]
---               path = null is a thread on the whole change; line 0 a whole
---               file; line (and start_line) are lines of the files on disk.
---               Optional: comments[].mine (my own comments never count as
---               unread), resolved_by, resolved_by_me
---    add        starts a thread at {path}:{line}, text on stdin
---    general    starts a thread on the whole change, text on stdin
---    reply      replies to {thread}, text on stdin
---               add, general, reply print {id} (with submit: the queued draft)
---    resolve, unresolve  change the state of {thread}
---    submit     optional: publishes what add/general/reply queued: {ids}, the
---               comma-separated ids they printed, so drafts queued elsewhere
---               stay pending; may print {published = [ids]}, also on failure
---    discard    optional: drops the queued {ids} that submit did not publish
---@field mr review_notes.MrConfig? the merge request in the list; nil or false: none
---@field files fun(review: review_notes.ListInfo)? `f` in the list: the changed files

---@class review_notes.MrConfig
---@field info string[]? prints {ref, title, url, target, source, author} as JSON
---@field actions review_notes.MrAction[]? under `m` in the list

---@class review_notes.MrAction
---@field key string
---@field desc string
---@field cmd string[]? run in the repo root; `{input}` asks for a line first,
---  `{url}`, `{ref}`, `{target}` come from `info`
---@field fn fun(mr: table, review: review_notes.ListInfo)? instead of cmd

---@class review_notes.ListInfo
---@field ctx review_notes.Context
---@field mr table? what `mr.info` printed

---@type review_notes.Config
M.values = {
  signs = true,
  watch = true,
  auto_pull = 60,
  backend = {
    threads = { "git-lab", "comment", "list", "--json" },
    add = { "git-lab", "comment", "add", "--draft", "--json", "{path}:{line}", "-" },
    general = { "git-lab", "comment", "add", "--draft", "--json", "-" },
    reply = { "git-lab", "comment", "reply", "--draft", "--json", "{thread}", "-" },
    resolve = { "git-lab", "comment", "resolve", "{thread}" },
    unresolve = { "git-lab", "comment", "unresolve", "{thread}" },
    submit = { "git-lab", "review", "submit", "--only", "{ids}", "--json" },
    discard = { "git-lab", "review", "discard", "--only", "{ids}" },
  },
  mr = {
    info = { "git-lab", "mr", "info", "--json" },
    actions = {
      { key = "a", desc = "approve the MR (optional comment)", cmd = { "git-lab", "mr", "approve", "-m", "{input}" } },
      { key = "o", desc = "open in the browser", fn = function(mr) if mr.url then vim.ui.open(mr.url) end end },
    },
  },
}

---@param opts table?
---@return review_notes.Config
function M.set(opts)
  M.values = vim.tbl_deep_extend("force", M.values, opts or {})
  return M.values
end

return M
