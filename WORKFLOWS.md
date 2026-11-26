# review-notes.nvim: workflows

The ways the plugin, git-lab and the pi extension are used together, step by
step, with what each step relies on today. Writing them side by side is how
the gaps at the end were found. DESIGN.md says how things work; this says
what they are for.

## Places and actors

| Who / what      | Role                                                        |
| --------------- | ----------------------------------------------------------- |
| me              | the human, in nvim                                          |
| pi              | the agent, in its own terminal; `/review`, `/fixup`         |
| peers           | other humans, on GitLab                                     |
| notes file      | `<git-path review>/<branch>.md`: one review per branch      |
| sidecar         | `<branch>.json` next to it: seen state, the MR              |
| GitLab          | the MR and its threads; the source of truth for those       |
| git             | commits are the only handover between me and pi             |

Comment sources: `remote` (on GitLab), `local` (mine, unpublished),
`proposed` (pi's, unpublished until I approve). Publish sends local text
and status changes; never proposed text.

---

## A. Reviewing a peer's MR

1. **Pick an MR.** `<leader>rm`: the picker lists open MRs with who
   approved and who reviews; approved by a peer sorts last, dimmed.
2. **Check it out.** `git-lab mr checkout` (fork MRs as `mr/IID`), in my
   checkout or a worktree.
3. **Have a look.** gitsigns against the MR target (`git-lab mr target`),
   `f` in the list for the changed files. The list's header shows reviewers
   and approvals, refreshed by every pull.
4. **Take it.** `m r`: assign me unless someone else reviews it (asked
   fresh from GitLab). `m R` joins anyway.
5. **Optionally, pi first.** `/review` in pi: findings arrive as proposed
   threads (tagged FIX, CHECK, CONSIDER, QUESTION, NIT). I approve the ones
   I agree with (`a`, `A`), edit or discard the rest.
6. **Comment.** `<leader>rn` on a line or selection, `<leader>rN` on the
   whole change; reply and resolve on peers' threads in the sidebar.
7. **Publish.** `P`: pulls, shows the plan, confirms (warns when a peer
   approved meanwhile, or the MR was merged or closed), sends everything as
   drafts and submits them as one review.
8. **Approve or wait.** `m a` to approve. Otherwise the author pushes
   fixes and replies; they come in as unread on the next pull.
9. **Re-review.** Update the checkout (`git-lab mr checkout` again), read
   the replies (`]u`), look at what changed, reply or resolve, publish.
10. **Done.** Approved or merged: automatic pulls stop. The notes stay.

## B. Developing on my own branch

1. **Explore.** Read the code, build the mental model.
2. **Plan with pi.** Draft a plan together, review it, agree.
3. **pi executes.** pi edits and commits on the branch.
4. **Read the diff.** In nvim: gitsigns against the target (guessed as the
   nearest protected branch while there is no MR).
5. **Self-review.** `<leader>rn` on the changes: notes for pi, not for
   peers.
6. **pi fixes.** `/fixup` (clean tree required): one `fixup!` commit per
   note's commit, a proposed reply and a resolve per thread; unclear notes
   get a proposed question instead.
7. **Review the fixes.** Read pi's replies in the sidebar and what changed
   in the code; reopen what is not right, add notes; back to 6.
8. **Set up the MR.** Push (autosquashed or not), create the MR.
9. **Peers comment.** Pulls bring their threads in as unread.
10. **pi addresses them.** Once a batch is in, `/fixup`: fixups and
    proposed replies on the peers' threads.
11. **Review pi's work.** Read the replies and the fixes; approve the
    replies (`a`, `A`), edit or discard.
12. **Push, publish.** Push the fixups, publish the replies and resolves.
13. Repeat 9-12 until approved.
14. **Merge.** Automatic pulls stop. The notes stay.

## C. Reviewing a document outside git

1. A markdown file outside any repository (or one passed by path): notes go
   to `<file>.review.md` next to it, local only, never published.
2. `<leader>rn` in the document, or `/review <file>` in pi.
3. `/fixup <file>` edits the document in place (no commits), with a
   proposed reply and a resolve per note.

---

## Gaps

Found by walking the workflows above. Severity: **high** loses work or
sends the wrong thing; **medium** misleads or blocks a step; **low** costs
time.

### Sending the wrong thing

1. **Self-review notes get published (B5, B8; high).** Publish sends
   every thread without a remote id: my notes for pi, even resolved ones,
   would be posted as open threads, with pi's replies once approved.
   Nothing marks a thread "between me and pi".
2. **"Approve" means two things (A5 vs B6, B11; high).** On a peer's MR,
   approving pi's finding means "send it". On my own branch, approving pi's
   reply to my own note means "agreed", and approving pi's reply to a peer
   means "send it". One key, two intents; with gap 1 unfixed, agreeing
   sends.
3. **"Fixed" before it is pushed (B12; medium).** pi's replies say
   "fixed" about local `fixup!` commits; publishing before pushing tells
   peers about code they cannot see. Nothing compares the branch with its
   remote before publish.

### Losing notes

4. **Removing a worktree deletes its notes (A2, B; high).** The notes
   live under `git rev-parse --git-path review`, which in a linked
   worktree is `.git/worktrees/<name>/review`; `git worktree remove`
   deletes it. Checked: notes written there are gone after the remove. My
   own worktree rule removes the worktree once the MR is open, so B's notes
   would go exactly when peers start commenting. The review belongs to the
   branch, not to the worktree: it should live under the common git dir.
5. **A reused branch name inherits an old review (A10, B14; medium).**
   After a merge the notes stay under the branch's name; a new branch with
   the same name (common for `fix-x`-style names, or a reviewer's `mr/IID`
   on another project's MR) starts with the old threads and the old MR
   recorded, and pulls the merged MR's threads.

### Before the MR exists

6. **"No MR" is treated as a failure (B4-B8; medium).** Every pull warns,
   the header shows a warning, automatic pulls pause, and stay paused after
   the MR is created until a manual pull: peers' comments (B9) do not come
   in by themselves.
7. **No way to create the MR from here (B8; low).** Push and create are
   by hand (web UI, or `git push -o merge_request.create`).

### Anchors and checkouts

8. **Local notes drift when pi edits (B6-B7; medium).** Remote threads
   are re-mapped to the files on disk on every pull. Local and proposed
   threads only follow edits made in nvim buffers (extmarks); pi's commits,
   a rebase or an autosquash shift lines under them, and the notes point at
   the wrong code.
9. **New threads need HEAD at the MR head (A9, B12; medium).**
   `git-lab comment add` refuses a line comment unless HEAD is the MR head.
   In B, unpushed fixups make every new line thread fail at publish; in A,
   a stale checkout after the author pushed does too. Nothing says so
   before publish, and the header does not show that the checkout is behind
   or ahead of the MR.
10. **Fork MRs cannot find their MR (A2; medium).** A fork MR is checked
    out as `mr/IID`; git-lab finds the MR by source branch, which is the
    fork's name, so the first pull fails with "no MR", and the review never
    learns its `{mr}`. Checkout could record the MR (it already records the
    target in the branch config).

### Seeing what changed

11. **No "what did pi change" view (B7, B11; medium).** The diff base is
    the MR target, so after a `/fixup` I see the whole branch again. pi's
    replies carry no commit (on purpose: SHAs change on squash), so there
    is no way from a thread to its fix.
12. **No "since I last reviewed" view (A9; medium).** The same need on
    a peer's MR: after the author pushes, what changed since my last
    publish. Gaps 11 and 12 are one feature: remember a commit per review
    event (my last publish, the start of the last `/fixup`) and offer each
    as a diff base under `f`.

### Plans and documents

13. **A plan file inside the repo is part of the branch review (B2; low,
    unclear).** If pi's plan lives in the worktree (untracked), notes on it
    go to the branch's review: publish tries to post them on a file the MR
    does not change, and git-lab refuses. Workflow C only covers files
    outside git. Depends on where plans live.

### Cleanup

14. **Notes of merged branches pile up (A10, B14; low).** Nothing lists
    or removes them. Gap 4 makes this worse once notes outlive worktrees.

## Order

The high ones first, as they decide the model:

- **Gaps 1 and 2 together: private threads.** A thread is private or
  published-to-be; private never publishes, and on my own branch "approve"
  on a private thread just means agreed. Default: private while the
  review has no MR, and for `/review` findings on my own branch.
- **Gap 4: notes under the common git dir**, so they follow the branch,
  not the worktree; migrate existing files.
- Then 6 and 9-10 (the MR's lifecycle around my checkout), 8 (anchors
  that survive pi), 11-12 (review checkpoints), 3, 5, 14, 7, 13.

## Open questions

- Private by default only before the MR, or always (with an explicit
  "make public")?
- MR creation: `git-lab mr create`, or the web UI / push options?
- `fixup!` commits: autosquashed before pushing, or pushed and squashed at
  merge? Decides what gap 3 checks.
- Where do pi's plans live: outside the repo, untracked in the worktree,
  or committed?
