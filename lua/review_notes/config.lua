-- The options, shared by every module. `setup` replaces `values`; read it
-- through the module each time, never keep a copy.
local M = {}

---@class review_notes.Config
---@field visible boolean show the thread text (review mode) at startup
---@field signs boolean sign column marks on the anchors
---@field watch boolean redraw when a notes file changes on disk
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

---@type review_notes.Config
M.values = {
  visible = true,
  signs = true,
  watch = true,
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
}

---@param opts table?
---@return review_notes.Config
function M.set(opts)
  M.values = vim.tbl_deep_extend("force", M.values, opts or {})
  return M.values
end

return M
