# review-notes.nvim: workflows

How the plugin is used, step by step, and the gaps left. Steps describe the
workflow as intended; where the plugin does not support a step, a gap says
so. DESIGN.md says how things work; this says what they are for.

## Scope

- **In:** the notes, their threads and anchors; diff bases for reading the
  change in nvim; pull and publish through a backend; MR actions as
  configured commands (assign, approve); what the agent is asked to do
  with the notes.
- **Out:** git (push, pull, rebase, checkout), creating MRs, telling people
  a review needs them (Slack), the agent's work beyond the notes and its
  commits. Steps that use these say so; gaps stay inside the plugin.

## Two loops

Every workflow combines two loops around one notes file per branch.

| Loop   | Between         | Through                            | Today                      |
| ------ | --------------- | ---------------------------------- | -------------------------- |
| local  | me and an agent | the notes file, commits            | pi (`extras/pi`)           |
| remote | me and peers    | the review platform: pull, publish | GitLab (`git-lab` backend) |

- The agent (pi, Claude Code, ...) writes **proposed** comments and
  commits; it never talks to the platform. I steer it with **private**
  comments, never published.
- The platform (GitLab, GitHub, ...) is the source of truth for the MR and
  its threads, reached through a backend CLI.
- Approve, whose turn, storage and checkpoints: DESIGN.md ("The two
  loops", "Storage", "Checkpoints").

"Agent review" and "agent fixup" are `/review` and `/fixup` in pi; `m r`,
`m a` are MR actions configured to call the backend.

---

## A. Reviewing a peer's MR (remote, with a local loop inside)

1. **Pick.** A picker over `git-lab mr list --approvals` (outside: my own
   config, not the plugin) lists open MRs with reviewers and approvals;
   approved by a peer sorts last, dimmed.
2. **Size it up.** Check it out (outside: `git-lab mr checkout`, fork MRs
   as `mr/IID`), in my checkout or a worktree. gitsigns against the
   target and a changed-files picker (outside: my own config; `bases()`
   adds the checkpoints if wanted).
3. **Take it.** `m r` assigns me unless someone else reviews it; `m R`
   joins anyway.
4. **Agent reviews.** `/review PROJ-123` (free text: ticket, scope, focus).
   The agent reads the ticket read-only for intent. Findings arrive as
   proposed threads tagged FIX, CHECK, CONSIDER, QUESTION, NIT.
5. **I review meanwhile.** `<leader>rn` on a line or selection,
   `<leader>rN` on the whole change; reply and resolve on peers' threads.
   Writing alongside the agent is safe (atomic writes, it only appends).
6. **Triage the agent.** `d` what I disagree with (then `r` to write my
   own), `A` to approve the rest.
7. **Publish.** `P`: pulls, shows the plan, confirms (warns if a peer
   approved meanwhile, the MR was merged or closed, or my checkout is not
   the MR's head), sends everything as drafts and submits them as one
   review. Records the `publish` checkpoint.
8. **Author pushes fixes.** Replies, and comments edited in the browser,
   come in as unread. The header shows how far behind my checkout is;
   update it (outside), possibly after a rebase or force-push.
9. **Check the fixes.** `/review` again: it first checks each of my open
   threads the author answered (a proposed resolve, or a reply saying what
   is missing), then looks for new findings. I read the replies (`]u`) and
   the diff "since my last publish" (`bases()`, replayed past a rebase).
10. **Decide.** Good: `m a`. Not: back to 5, or 4 on the new commits.
11. **Done.** Approved or merged: automatic pulls stop. The notes stay.

`/fixup` refuses here: it plays the author, and this MR is a peer's.

## B. My branch, before the MR (local only)

1. **Plan and build.** Explore, agree on a plan with the agent; it edits
   and commits.
2. **Read the diff.** gitsigns against the target (the nearest protected
   branch while there is no MR).
3. **Agent reviews.** `/review` on my branch: findings for me.
4. **Self-review.** `<leader>rn` writes private comments for the agent;
   discard the findings I disagree with. The rest need no approval: the
   agent acts on its own findings (approving one only makes it private).
   Nothing here can publish.
5. **Agent fixes.** `/fixup` (clean tree): records the `fixup` checkpoint,
   one `fixup!` commit per note's commit, a proposed reply per thread,
   resolved when fixed, verified or declined; open when it needs my
   decision, with a proposed question when unclear.
6. **Check.** The diff "since the agent's last fixup", read its replies; reopen,
   add private comments; back to 5.

## C. My MR under review (remote, with a local loop inside)

1. **Send.** Push and create the MR (outside). The next automatic pull
   finds it.
2. **Peers comment.** Pulls bring their threads, and edits, in as unread.
3. **Triage.** Reply (`r`) where it needs discussion: my published reply
   keeps the agent off the thread. Leave the clear ones to the agent, add
   a private comment (`<C-t>` in the composer, `t` in the sidebar) to steer it, or fix them by hand.
4. **Agent fixes.** `/fixup`: fixups and proposed replies, as in B5.
5. **Review the agent's work.** The diff "since the agent's last fixup", its
   replies; approve (`a`, `A`), edit or discard.
6. **Push, publish.** Push the fixups (outside; publish warns about
   unpushed commits), then `P` sends replies and resolves.
7. **Approved:** merge, automatic pulls stop. **Not:** back to 2.

## D. A document outside git (local only)

1. A markdown file outside any repository (or passed by path): notes go to
   `<file>.review.md` next to it, never published.
2. `<leader>rn` in the document, or `/review` on the file.
3. `/fixup` on the file edits it in place (no commits), with a proposed
   reply per note, resolved as in B5.

---

## Gaps

Severity: **medium** misleads or blocks a step; **low** costs time.

### Anchors and history

1. **Local notes drift (A8, B5, C4; medium).** Remote threads are re-mapped
   on every pull. Local, private and proposed ones only follow edits made in
   nvim buffers; the agent's commits, a rebase, a force-push or an
   autosquash shift lines under them.
2. **A reused branch name inherits an old review (A11, C7; medium).** A new
   branch with a merged one's name (`fix-x`, `mr/IID` from another project)
   starts with the old threads, the old MR and its checkpoints.

### The MR

3. **Fork MRs cannot find their MR (A2; medium).** git-lab looks the MR up
   by source branch, which is the fork's name, not `mr/IID`: pulls see
   "no MR yet" forever. Checkout could record the MR, as it does the
   target.

### Comments

4. **Published comments cannot be edited or deleted (A7; medium).** The
   backend has no such operation; a typo or a wrong comment needs the web
   UI. Direction: `r` / `d` on my published comment in the sidebar, kept
   pending and sent by publish (new backend operations `edit`, `delete`);
   stale if it changed on the platform meanwhile.
5. **Agent replies to edited comments (A8, C2; low).** An edit makes the
   comment unread and my own reply stale, but a proposed reply the agent
   wrote against the old text is not flagged.
6. **No suggested changes (A5, C3; low).** Writing one means typing the
   platform's syntax by hand; agent fixup does not treat a peer's
   suggestion as "apply this".
7. **Co-reviewer overlap (A7; low).** Publish pulls first but does not
   flag a new peer thread on the same lines as one of mine.

### Friction

8. **Reject-then-send is two steps (A6; low).** `d` alone leaves the rest
   unsendable; `A` is needed too.
9. **The MR picker (A1-A2; low).** No "needs a reviewer" sort or filter;
   no look at the diff before checking out.
10. **Duplicate findings (A4-A5; low).** The agent skips findings already
    in the notes when it writes, not ones I add later.
11. **A plan file inside the repo (B1, C; low).** Before the MR its threads
    are notes, so safe; after, a comment on it publishes and the platform
    refuses a file the MR does not change. D only covers files outside git.
12. **Notes of merged branches pile up (A11, C7; low).** Nothing lists or
    removes them, or their checkpoint refs; notes no longer go away with
    worktrees.
13. **One integration per loop (all; low).** Only pi has the agent
    commands and only GitLab has a backend. The notes format is the
    contract, but the review and fixup instructions live in pi's extension.

## Order

4, 1, 3, 8, 9, 6, 2, 12, 5, 7, 10, 11, 13.

## Open questions

- Where do the agent's plans live: outside the repo, untracked in the
  worktree, or committed? Decides gap 11.
- Gap 13: move the agent instructions out of pi's extension (a shared
  prompt file any agent can load)?
