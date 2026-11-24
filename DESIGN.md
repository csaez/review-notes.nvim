# review-notes.nvim v2: design

Status: implemented on this branch (the README is the user documentation). Backward compatibility is not a
goal: the file format, commands, keymaps and backend contract may all change.

## Problems with v1

1. Comments are hidden. A sign in the gutter, then a float to read. Reading
   threads is the main activity of a review.
2. Sync is scary. `sync` pulls and then pushes, so a sync meant to read a
   peer's comments can send my notes (and an agent's) as a side effect.
3. State is spread over too many concepts: `[new]`, `[draft]`, `[resolved]`,
   `[id:]`, a `> ` cache, "unsent" replies, hold-backs.
4. General (whole MR) comments are bolted on: no line, special file position,
   a separate code path in the float, the picker and sync.
5. One 1.3k line `init.lua` holds everything.

## Principles

- **Reading never writes to the remote.** Only `publish` does, and it shows
  what it will send first.
- **Everything is a thread.** A thread has an anchor, a status and a list of
  comments. General comments are threads with the anchor `change`; there is no
  other kind of thing.
- **Content is right there in review mode, out of the way otherwise.** One
  toggle.
- **The notes file is for humans and agents.** Plain markdown, greppable,
  safe to hand-edit. Machine state lives elsewhere.
- **Fits the existing workflow.** `<leader>fd` picker for the changed files,
  gitsigns for hunks. The plugin adds threads to that, it does not replace
  any of it.

## Concepts

### Thread

| Field    | Meaning                                                              |
| -------- | -------------------------------------------------------------------- |
| anchor   | `change` (whole MR), `path` (whole file), `path:N`, `path:N-M`       |
| status   | `open` or `resolved`                                                 |
| comments | ordered list; each has author, body, and a source (see below)        |
| remote   | the remote thread id, once the thread exists there                   |

### Comment source

Each comment is exactly one of:

- **remote**: exists on the remote, read only here. Rewritten by pull.
- **local**: written here, not published. Editable and deletable.
- **proposed**: a local comment written by a tool (pi). It is not published
  until I approve it. This replaces `[draft]`.

A thread has at most one local or proposed comment at the end (my reply).
A new thread is a thread whose first comment is local. That is the whole
model of "unsent": a thread with a trailing local comment, or a status change
not published yet (`resolved` locally differs from the remote status).

### Unread

A thread is unread when it has a remote comment by someone else that I have
not seen. "Seen" is stored in the sidecar, set when the thread is expanded or
opened, or marked by key. Unread is only a highlight and a counter; it never
blocks anything.

## Commands

| Command            | Effect                                                         |
| ------------------ | -------------------------------------------------------------- |
| `:Review`          | toggle review mode for the current review (show / hide threads) |
| `:Review pull`     | fetch remote threads and merge. Never sends anything.          |
| `:Review publish`  | show a summary of what will be sent, confirm, send, then pull  |
| `:Review list`     | the picker (see below)                                         |
| `:Review approve`  | approve proposed comments (cursor thread, or `!` for all)      |
| `:Review open`     | open the notes file                                            |

Suggested keys (the plugin sets none): `<leader>rr` pull, `<leader>rp`
publish, `<leader>rv` toggle view, `<leader>rn` new thread, `<leader>rN` new
general thread, `<leader>rl` list, `]r` / `[r` next / previous unread.

`pull` is cheap and safe, so it can also run later on opening a reviewed file and
on `FocusGained` (not in the first version). Because it never sends,
running it in the middle of a peer or pi adding comments is always fine.

## Safe pull (the "scare" fix)

Pull is a three-way merge with strict rules:

1. Remote comments are replaced by the remote's version. New remote threads
   are added.
2. Local and proposed comments are never touched by pull.
3. A thread deleted on the remote that has local content is kept and marked
   `orphan`; it is published as a new thread if I choose to.
4. A remote thread resolved by someone else becomes `resolved` plus unread,
   and is shown as "resolved by @bob" until I look at it.
5. If the file changed on disk while pulling (pi wrote to it), the merge is
   redone on the new content. Writes are atomic (temp file and rename), and
   guarded by a version number in the sidecar.

## Safe publish

1. Pull first (rule above). If this brought in unread comments on a thread
   that has a local reply, that thread is listed in the summary as "changed
   since you wrote this", and is not sent unless confirmed per thread.
   Everything else is not blocked by unread state.
2. The summary lists: new threads, replies, resolves and reopens, and
   proposed comments that are not approved (skipped, shown dimmed).
3. After confirm: create everything as remote drafts (when the backend has
   drafts), then submit exactly the ids created, which sends one
   notification. A failure part way deletes what was created, so retrying
   cannot post twice.
4. Pull again. Published local comments become remote comments.

## Display

Review mode on, for each thread in a buffer:

- **Collapsed** (default): one virtual line under the anchor, for example
  `  3 comments, @alice: why 30s?` with a highlight for unread, unsent,
  proposed and resolved. A sign marks the anchor range (a range gets a line
  highlight on its first and last line).
- **Expanded**: all comments as virtual lines under the anchor, wrapped to the
  window, the local comment last and visually distinct.
- `<CR>` on the anchor line (or a configurable key) expands or collapses the
  thread under the cursor. `zR`-like "expand all / collapse all" is one more
  key. Expanding marks the thread as seen.
- Virtual lines are plain extmarks, so gitsigns hunk previews and diff views
  are unaffected. Threads on lines outside a diff view buffer are shown in
  whatever buffer holds that file.

Review mode off: no virtual lines, only the sign if `signs = true`.

### General threads

General threads have no line, so they are shown in two places, both through
the same thread renderer:

- a **header** at the top of the first buffer of the review (or of any
  buffer, option), as virtual lines above line 1, using the same collapsed /
  expanded states as code threads;
- the list (below), as an ordinary row with the anchor `change`.

There is no special-cased float, no special file position and no separate
sync path: the anchor is just `nil` for the line and `nil` for the path.

## The list

One picker source with one row type. A row is: icon for the most urgent state,
anchor (`change`, `path`, `path:N`), tags, first line of the thread. The
preview is the rendered thread. `confirm` jumps to the anchor and expands the
thread; for `change` threads it opens the header in the current window.
`items(buf)` stays the API for other pickers. Sorting: unread first, then
proposed, then unsent, then the rest, each by path and line, `change` first.

## Writing

`new` and `reply` open a small composer (a float near the cursor, markdown,
full width of the text area). `<C-s>` or `:w` saves into the notes file, `q`
or `<Esc><Esc>` cancels (the text is kept for next time). Reply to an expanded
thread with the same key. Resolve and reopen toggle with a key, locally, and
are published with everything else.

## Storage

Two files per review, in `.git/review/` (or beside a non-git file):

- `<branch>.md`: the notes. Humans and agents read and write it.
- `<branch>.json`: sidecar for the plugin: remote ids, last-seen markers,
  file version, line anchors. Safe to delete (pull rebuilds the ids; seen
  markers reset and everything shows as unread).

### Notes file format

```markdown
# Review of feature/timeouts

## change {id=ghi789}
status: open

### @alice
please add a changelog entry

### @bob
+1

### me (local)
done, see the next push

## src/http.cpp:88 {local}
status: open

### me (local)
timeout must cover connect, not only read

## src/http.cpp:120-124 {id=abc123}
status: resolved

### @alice
why 30s?

### me (proposed)
Matches the studio default, I added a comment above the constant.
```

Rules:

- `## <anchor> {attrs}` starts a thread. Anchor is `change`, `path`,
  `path:N` or `path:N-M`. Attrs: `id=` (remote), `local` (no remote yet).
- `status: open|resolved` is the first line of the thread; the remote status
  is in the sidecar, so a difference between the two means "resolve or reopen
  is not published yet".
- `### @author` is a remote comment, `### me (local)` and
  `### me (proposed)` are mine. Body is everything up to the next heading.
  Body lines starting with `#` are escaped on write.
- Agents add a thread or a reply by appending a section with
  `### me (proposed)`, and need no other knowledge of the format. The
  plugin picks up the change through its file watcher.
- The previous format's one-line entries are gone.

## Backend contract

Mostly as before, with these changes:

- A thread's anchor is `{ "path": null }` for `change`, so `general` is not a
  separate operation: `add` takes an anchor with an optional path and line.
- `threads` returns comments with a stable `id` per comment, so unread can
  be tracked per comment and not by position.
- `publish` is one operation: it takes a JSON plan on stdin (new threads,
  replies, status changes) and returns what it created, instead of the
  plugin orchestrating a list of calls and a discard on failure. The git-lab
  script does the draft creation, the submit and the cleanup. A backend
  without drafts just posts in order.

## Code layout

| Module            | Responsibility                                             |
| ----------------- | ---------------------------------------------------------- |
| `store.lua`       | parse and write the markdown file and the sidecar, atomic  |
| `merge.lua`       | pull merge and publish plan, pure functions, fully tested  |
| `backend.lua`     | run the commands, the JSON contract                        |
| `view.lua`        | extmarks, virtual lines, signs, expand and collapse        |
| `compose.lua`     | the composer float                                         |
| `list.lua`        | items, sorting, preview, actions                           |
| `init.lua`        | setup, commands, autocmds, public API (thin)               |

`merge.lua` and `store.lua` have no Neovim dependencies, so most of the
logic is testable in plain Lua, and a fake backend script covers the rest.

## Pi extension

- `/review` writes `### me (proposed)` comments on new threads; it never
  touches remote comments.
- `/fixup` reads open threads, makes `fixup!` commits, and adds a proposed
  reply plus a resolve request (`status: resolved` on the thread). Both wait
  for my approval.
- Because proposed comments never publish without approval, running it in
  the middle of a pull from a peer is harmless.

## Plan

1. Agree on this document (format, commands, keys).
2. `store.lua` and `merge.lua` with tests, including the pull and publish
   rules above.
3. `view.lua`: collapsed and expanded display, the toggle, general header.
4. `compose.lua`, `list.lua`, commands.
5. `git-lab` `publish` and the new thread shape; update the pi extension.
6. README rewrite, remove the v1 modules.

## Decisions

- General threads: header above line 1 of every buffer in the review,
  collapsed to one line. It carries its own marker (a `change` label and
  icon, drawn above the line) so it cannot be mistaken for a thread anchored
  on line 1, which is drawn below the line.
- `pull` is explicit (`<leader>rr`). Automatic pull can come later.
- A thread whose line was deleted stays on the nearest line and is marked
  `moved`.
