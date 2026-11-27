# review-notes.nvim: design

How the plugin works and why, as it is now (kept current, not a history).
[README.md](README.md) is the user documentation, [WORKFLOWS.md](WORKFLOWS.md)
the workflows it serves and their gaps. Exact formats and contracts live in
the code, linked below. Backward compatibility of commands, keymaps and
options is not a goal; the notes file format stays.

## Principles

- **Reading never writes to the remote.** Only publish does, and it shows
  what it will send first.
- **Everything is a thread.** An anchor, a status, a list of comments.
  Comments on the whole change are threads anchored at `change`; there is
  no other kind of thing.
- **The review lives in a sidebar.** One window on the right lists the
  review or shows one thread. The plugin never takes a code window's place;
  code buffers only get signs.
- **Keys belong to a context.** No global keys; the plugin's own buffers
  (sidebar, composer) have short ones. A verb has the same key everywhere
  it applies.
- **The notes file is for humans and agents.** Plain markdown, greppable,
  safe to hand-edit. Machine state lives in a sidecar.
- **Fits the existing workflow.** gitsigns for hunks, the user's picker for
  the diff, `/` in the list to find a thread. The plugin links to them
  through hooks; it does not replace them.
- **Forge-agnostic.** All remote work is configured command lines; GitLab is
  one backend (`extras/git-lab`).

## Model

### Thread and comment

A thread has an anchor (`change`, `path`, `path:N`, `path:N-M`), a status
(`open` or `resolved`), comments, and a remote id once it exists there.
Each comment has one source:

- **remote**: on the remote, read only here; pull rewrites it.
- **local**: mine, not published; editable and deletable.
- **proposed**: written by a tool (an agent); not published until I approve.
- **private**: mine, never published; for me and the agent.

Unpublished comments (local, proposed, private) come after the remote ones,
and there is at most one of mine (local or private): my reply. "Unsent" is
exactly: a thread with a local comment, or a status that differs from the
remote's.

### The two loops

The notes carry two conversations: with peers through the remote, and with
the agent, never published. "Private" is about publishing, not reading:
the agent reads everything.

- A thread whose first comment is private is private as a whole: publish
  sends none of it and it never counts as unsent.
- **Approve** means "send it" on a thread that publishes, and "agreed" on a
  private one (the proposed text becomes private). Before the MR exists,
  approving an agent's new thread also makes it private, and new threads
  start private.
- **Whose turn** (the agent's rule): an open thread is the agent's when the
  last comment not its own is a private comment, my unpublished comment
  before the MR, or a peer's comment on my MR. Its own fresh finding (a
  thread holding only its proposed comment) is its turn too: approval
  gates publishing, not the agent. Its reply last waits for me; my
  published reply last waits for the peer. Fixup plays the author, so it
  refuses on a peer's MR.

### Unread

A remote comment by someone else I have not seen, or a resolve by someone
else I have not looked at. The sidecar stores, per comment id, a hash of
the text I saw, so a comment edited on the remote is unread again. Showing
a thread marks it seen. Unread is a highlight and a counter; it never
blocks anything.

## Safe pull

A three-way merge ([`merge.lua`](lua/review_notes/merge.lua)):

1. Remote comments are replaced by the remote's version; new remote threads
   are added.
2. Local, proposed and private comments, and unpublished status changes,
   are never touched.
3. A thread deleted on the remote that holds my text stays, marked
   `orphan`, and publishes as a new thread.
4. A resolve by someone else comes in as resolved plus unread.
5. If the file changed on disk meanwhile (an agent wrote), the merge is
   redone on the new content. Writes are atomic (temp file, rename).

Because pull is safe, it also runs unasked: on focus and on entering the
list, when the last attempt is older than `auto_pull` seconds, and never
while the notes have unsaved edits in a buffer. It reports only what
changed, on the list's sync line; a notification only when the list of
that review is not in view (it would cover the list it repeats), or for
what the list cannot show: a failed pull I asked for, threads kept after
the remote deleted them.

Failures are told apart by exit status (contract in
[`config.lua`](lua/review_notes/config.lua)): offline and "no MR yet" keep
retrying quietly (a branch before its MR is not a failure); no access and
"not this kind of remote" pause automatic pulls until a manual one, since
retrying cannot fix them.

A review is tied to its MR: the sidecar records the IID and every command
gets it as `{mr}`. A merged or closed MR keeps syncing (automatic pulls
stop), and a new MR on the same branch never silently takes over: a manual
pull asks before moving the review.

## Safe publish

Always explicit ([`sync.lua`](lua/review_notes/sync.lua)):

1. Pull first. A local reply on a thread that just got unread comments is
   flagged "changed since you wrote this" and needs confirming.
2. Show the plan: new threads, replies, resolves and reopens. Proposed
   comments are skipped, and so is the status change of a thread that has
   one, so approving is one step. Private threads and comments never
   appear. Warn when the checkout differs from the MR's head, a peer
   approved meanwhile, or the MR is merged or closed. The plugin never
   pushes.
3. After confirm, create everything as drafts and submit exactly the ids
   created (one notification). What submit did not publish is discarded,
   so a retry cannot post twice.
4. Resolves and reopens go after the submit (a reply reopens on GitLab).
5. Pull again; record HEAD as the `publish` checkpoint.

## Checkpoints

A review event leaves a diff base: my last publish (`publish`), the start of
the agent's last fixup (`fixup`). Each is a local ref,
`refs/review-notes/<branch>/<name>`, so the commit survives gc after a
rebase. When HEAD no longer contains it, it is replayed onto the branch's
current merge base, so the diff shows the author's changes, not upstream's;
on conflict the raw one is offered, labelled as such
([`checkpoint.lua`](lua/review_notes/checkpoint.lua)). The plugin shows no
diff itself: `bases()` hands them to whatever diff or picker the user has.

## The sidebar

One window on the right of the tabpage, owned by the plugin
([`sidebar.lua`](lua/review_notes/sidebar.lua)), with two buffers:
**list** (the whole review, by urgency) and **thread** (one thread). The
code window is the last normal window entered; showing a thread shows its
anchor there. The window has `winfixbuf`, so nothing opens a file in it.

- `:Review` steps one level, like `<Esc>` in lazygit: code to list (or to
  the thread at the cursor), thread to list, list to closed. `q` steps back
  too.
- Both buffers redraw on any change to the notes or sidecar (file watcher),
  so pulls and agents show up live.
- **Finding the keys**, from lazygit: the sidebar's `statusline` is a hint
  bar with only the keys that apply to the thread at hand, and `?` opens
  every key, runnable. Both are built from the declarations in
  [`keys.lua`](lua/review_notes/keys.lua), with the mappings, so the three
  never disagree.
- Thread keys work in both modes (in the list, on the thread under the
  cursor or a visual selection). Review-wide keys (pull, publish, approve
  all, MR actions) live in the list.
- **MR hooks.** The MR header and `m` actions come from `mr` in the config.
  MR info
  rides on every pull, so a peer's approval shows up while I review.
  Checking out another MR changes which review is current, so it belongs to
  a global key, not the sidebar.
- **No picker.** `/` in the list finds a thread; a separate finder
  duplicated the list without its keys. `items()` stays as the API for
  anyone who wants one.

## Code buffers

Signs only ([`signs.lua`](lua/review_notes/signs.lua)): a bar down the
anchor range, the state icon on its last line. Anchors are extmarks, follow
edits, and are written back on save; a thread whose lines were deleted stays
on the nearest line, marked `moved`.

## Storage

Per review, in `review/` under the git common dir (shared by worktrees, so
removing a worktree keeps the review):

- `<branch>.md`: the notes. Grammar at the top of
  [`store.lua`](lua/review_notes/store.lua). Agents add a thread or a reply
  by appending a `### me (proposed)` section and need nothing else.
- `<branch>.json`: the sidecar: remote status, seen hashes, the MR. Safe to
  delete (everything shows as unread).

A file outside git gets a sibling `<file>.review.md`, local only.

## Code layout

| Module           | Responsibility                                               |
| ---------------- | ------------------------------------------------------------ |
| `store.lua`      | parse and write the notes and sidecar, atomic; no Neovim     |
| `merge.lua`      | pull merge and publish plan, pure functions                  |
| `backend.lua`    | run the configured commands; the only code that spawns them  |
| `config.lua`     | the options and the backend contract                         |
| `review.lua`     | the current review: context, items, sorting, watcher, listeners |
| `sync.lua`       | pull and publish                                             |
| `actions.lua`    | the verbs (resolve, approve, discard, reply, ...)           |
| `checkpoint.lua` | checkpoint refs, diff bases, ahead / behind                  |
| `sidebar.lua`    | the sidebar window and the code window                       |
| `keys.lua`       | key declarations: mappings, hint bar, `?` menu               |
| `list.lua`       | list mode, review-wide keys, MR hooks                        |
| `thread.lua`     | thread mode, list order for `]t` / `]u`                      |
| `signs.lua`      | anchors and signs in code buffers                            |
| `health.lua`     | `:checkhealth review_notes`                                  |
| `compose.lua`    | the composer float                                           |
| `init.lua`       | setup, commands, public API (thin)                           |

- A verb lives only in `actions`; UIs bind keys to it.
- Every change goes through `review.edit`, which notifies the listeners
  (signs, sidebar); nothing refreshes by hand.
- `store` and `merge` have no Neovim dependencies, so most logic is tested
  as plain Lua; a fake backend script covers the rest.

## Agent integration

[`extras/pi/review-notes.ts`](extras/pi/review-notes.ts) reads the same
notes file. `/review` adds proposed threads (and on a peer's MR first
re-checks my threads the author answered); `/fixup` handles the threads
that are its turn with `fixup!` commits and proposed replies, holding the
resolve with the reply, and records the `fixup` checkpoint. Everything it
writes is proposed, so running it at any time, even during a pull, is safe.
