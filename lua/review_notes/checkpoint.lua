-- Review checkpoints: the commit a review event happened at (my last
-- publish, the start of the agent's last fixup), offered as diff bases so I
-- read only what changed since. Each is a ref, `refs/review-notes/<branch>/
-- <name>`, so gc keeps the commit after a rebase or a force-push. When the
-- branch was rebased since, the checkpoint is replayed onto the branch's
-- current base, so the diff shows what the author changed and not upstream.
local M = {}

---@class review_notes.Base
---@field name string "target", "publish", "fixup"
---@field label string for a picker
---@field rev string what to diff against

--- What each checkpoint means, in picker order.
M.names = {
  { name = "publish", label = "since my last publish" },
  { name = "fixup", label = "since the agent's last fixup" },
}

local function git(root, args)
  local out = vim.system(vim.list_extend({ "git" }, args), { cwd = root, text = true }):wait()
  return out.code == 0 and vim.trim(out.stdout) or nil, out.code
end

---@param branch string
---@param name string
---@return string
function M.ref(branch, name) return ("refs/review-notes/%s/%s"):format(branch, name) end

--- Record *rev* (default HEAD) as checkpoint *name* of the review *ctx*.
---@param ctx review_notes.Context
---@param name string
---@param rev string?
---@return boolean ok
function M.record(ctx, name, rev)
  if ctx.kind ~= "git" or not ctx.branch or ctx.branch == "HEAD" then return false end
  local sha = git(ctx.root, { "rev-parse", "--verify", "--quiet", (rev or "HEAD") .. "^{commit}" })
  if not sha then return false end
  return git(ctx.root, { "update-ref", M.ref(ctx.branch, name), sha }) ~= nil
end

--- *sha* replayed onto the merge base of HEAD and *target*: a commit whose
--- tree is the checkpoint's changes on today's base. nil when it does not
--- apply cleanly.
local function replay(root, sha, target)
  local old_base = git(root, { "merge-base", sha, target })
  local new_base = git(root, { "merge-base", "HEAD", target })
  if not (old_base and new_base) then return nil end
  if old_base == new_base then return sha end
  local tree = git(root, { "merge-tree", "--write-tree", "--merge-base=" .. old_base, new_base, sha })
  if not tree then return nil end
  tree = vim.split(tree, "\n", { plain = true })[1]
  return git(root, { "commit-tree", tree, "-p", new_base, "-m", "review-notes: replayed checkpoint" })
end

--- The diff bases of the review *ctx*: the MR target, then each recorded
--- checkpoint. A checkpoint that HEAD no longer contains (rebased since) is
--- replayed onto the current base; when that conflicts it is offered as is,
--- and says so.
---@param ctx review_notes.Context
---@param target string? the MR target (`origin/main`)
---@return review_notes.Base[]
function M.bases(ctx, target)
  local out = {}
  if target then table.insert(out, { name = "target", label = "the whole change (" .. target .. ")", rev = target }) end
  if ctx.kind ~= "git" or not ctx.branch then return out end
  for _, n in ipairs(M.names) do
    local sha = git(ctx.root, { "rev-parse", "--verify", "--quiet", M.ref(ctx.branch, n.name) })
    if sha then
      local short = sha:sub(1, 8)
      local _, code = git(ctx.root, { "merge-base", "--is-ancestor", sha, "HEAD" })
      if code == 0 then
        table.insert(out, { name = n.name, label = ("%s (%s)"):format(n.label, short), rev = sha })
      else
        local replayed = target and replay(ctx.root, sha, target)
        if replayed then
          table.insert(out, { name = n.name, label = ("%s (%s, rebased since)"):format(n.label, short), rev = replayed })
        else
          table.insert(out, {
            name = n.name,
            label = ("%s (%s, rebased since: includes upstream changes)"):format(n.label, short),
            rev = sha,
          })
        end
      end
    end
  end
  return out
end

--- How HEAD compares with the MR's head commit *sha*: commits only here
--- (ahead) and only there (behind). nil when *sha* is not in the repository
--- (not fetched).
---@param root string
---@param sha string
---@return integer? ahead, integer? behind
function M.ahead_behind(root, sha)
  local out = git(root, { "rev-list", "--left-right", "--count", "HEAD..." .. sha })
  if not out then return nil end
  local a, b = out:match("^(%d+)%s+(%d+)$")
  return tonumber(a), tonumber(b)
end

--- Commits between the upstream of HEAD and HEAD: what peers cannot see yet.
--- nil without an upstream.
---@param root string
---@return integer?
function M.unpushed(root)
  local out = git(root, { "rev-list", "--count", "@{upstream}..HEAD" })
  return out and tonumber(out) or nil
end

return M
