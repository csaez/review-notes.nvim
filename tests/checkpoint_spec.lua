local checkpoint = require("review_notes.checkpoint")

describe("checkpoints", function()
  local repo
  local function git(...)
    return vim.trim(vim.fn.system(vim.list_extend({ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t" }, { ... })))
  end
  local function commit(file, text, msg)
    vim.fn.writefile({ text }, repo .. "/" .. file)
    git("add", file)
    git("commit", "-q", "-m", msg)
  end

  before_each(function()
    repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    git("init", "-q", "-b", "main")
    commit("up.txt", "1", "base")
    git("checkout", "-q", "-b", "feat")
    commit("feat.txt", "a", "feature")
  end)
  after_each(function() vim.fn.delete(repo, "rf") end)

  it("after a rebase, diffs against the checkpoint replayed onto the new base", function()
    local ctx = { kind = "git", root = repo, branch = "feat", path = repo .. "/notes.md" }
    assert.is_true(checkpoint.record(ctx, "publish"))
    -- Upstream moves on, the author rebases and changes the feature.
    git("checkout", "-q", "main")
    commit("up.txt", "2", "upstream")
    git("checkout", "-q", "feat")
    git("rebase", "-q", "main")
    commit("feat.txt", "b", "fix")
    local base = checkpoint.bases(ctx, "main")[2]
    assert.are.equal("publish", base.name)
    assert.truthy(base.label:find("rebased since", 1, true))
    -- Only the author's change, not upstream's.
    assert.are.equal("feat.txt", git("diff", "--name-only", base.rev, "HEAD"))
  end)

  it("tells ahead and behind against the MR head", function()
    local head = git("rev-parse", "HEAD")
    commit("feat.txt", "c", "local")
    assert.are.same({ 1, 0 }, { checkpoint.ahead_behind(repo, head) })
    assert.is_nil(checkpoint.ahead_behind(repo, "0123456789012345678901234567890123456789"))
  end)
end)
