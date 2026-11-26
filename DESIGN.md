# review-notes.nvim: design

This document describes the design as it is now; it is kept current, not a
history.
The README is the user documentation. Backward compatibility of commands,
keymaps and options is not a goal; the notes file format stays.

## Principles

- **Reading never writes to the remote.** Only `publish` does, and it shows
  what it will send first.
- **Everything is a thread.** A thread has an anchor, a status and a list of
  comments. Comments on the whole change are threads with the anchor
  `change`; there is no other kind of thing.
- **The review lives in a sidebar.** One window on the right lists the
  review and shows one thread at a time. The plugin never takes a code
  window's place; code buffers only get signs.
- **Keys belong to a context.** The plugin sets no global keys, but its own
  buffers (the sidebar, the composer) have their own, short ones. A verb has
  the same key everywhere it applies.
- **The notes file is for humans and agents.** Plain markdown, greppable,
  safe to hand-edit. Machine state lives elsewhere.
- **Fits the existing workflow.** gitsigns for hunks and the review diff,
  a picker to fuzzy-find. The sidebar links to them (changed files, diff
  base) through hooks; it does not replace them.

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
  until I approve it.

A thread has at most one local or proposed comment at the end (my reply).
A new thread is a thread whose first comment is local. That is the whole
model of "unsent": a thread with a trailing local comment, or a status change
not published yet (`resolved` locally differs from the remote status).

### Unread

A thread is unread when it has a remote comment by someone else that I have
not seen, or someone else resolved it and I have not looked since. "Seen" is
stored in the sidecar, set when the thread is shown in the sidebar, or
marked by key in the list. Unread is only a highlight and a counter; it
never blocks anything.

## Safe pull

Pull is a three-way merge with strict rules:

1. Remote comments are replaced by the remote's version. New remote threads
   are added.
2. Local and proposed comments are never touched by pull.
3. A thread deleted on the remote that has local content is kept and marked
   `orphan`; it is published as a new thread if I choose to.
4. A remote thread resolved by someone else becomes `resolved` plus unread,
   and is shown as "resolved by @bob" until I look at it.
5. If the file changed on disk while pulling (pi wrote to it), the merge is
   redone on the new content. Writes are atomic (temp file and rename).

Pull is explicit (`p` in the list, `:Review pull`) and also automatic: on
`FocusGained` (the review of the current buffer) and on entering the list,
when the last pull (or failed attempt) is older than `auto_pull` seconds
(default 60; false turns it off). Pull is safe, so running it unasked is
fine; it reports only new or changed threads, warns once when it starts
failing, and waits while the notes file has unsaved edits in a buffer.

## Safe publish

Publish is always explicit.

1. Pull first (rules above). If this brought in unread comments on a thread
   that has a local reply, that thread is listed in the summary as "changed
   since you wrote this", and is not sent unless confirmed. Everything else
   is not blocked by unread state.
2. The summary lists: new threads, replies, resolves and reopens, and
   proposed comments that are not approved (skipped). While a thread has a
   proposed comment, its status change is held too, so approving is one
   step.
3. After confirm: create everything as remote drafts (when the backend has
   drafts), then submit exactly the ids created, which sends one
   notification. What submit did not publish is discarded, so retrying
   cannot post twice.
4. Resolves and reopens go after the submit (publishing a reply reopens a
   thread on GitLab).
5. Pull again. Published local comments become remote comments.

## The sidebar

`:Review` (or the user's `<leader>rr`) opens the sidebar: a split on the
right of the tabpage, about 72 columns (`winfixwidth`), owned by the
plugin. It has two modes, each a buffer of its own shown in the same
window:

- **list**: the whole review (`reviewnotes://review/<notes path>`,
  filetype `reviewlist`).
- **thread**: one thread (`reviewnotes://thread`, filetype `reviewthread`,
  highlighted as markdown).

The hint bar is the sidebar window's `statusline`, at the bottom like
lazygit's. With a global status line (`laststatus=3`) Neovim draws the
focused window's own `statusline`, so the bottom bar turns into the hint
bar while the cursor is in the sidebar and back when it leaves. Statusline
plugins (lualine) must exclude `reviewlist` and `reviewthread`, or they
overwrite it; excluding them from their winbar too keeps the sidebar
without a top bar.

The window has `winfixbuf` set (the plugin lifts it to switch modes), so
`:edit` and pickers that honor it never open a file in the sidebar. Window
options are set on the sidebar window only and never leak into code
windows.

`:Review` steps one level at a time, like `<Esc>` in lazygit: from a code
window it opens the sidebar in list mode and moves the cursor there; from
thread mode it goes back to the list; from the list it closes the sidebar.
`q` closes it from either mode; as the last window of the tab it leaves an
empty buffer. Both buffers redraw when the notes file or the sidecar change
(file watcher), so pi and pulls show up live.

### Finding the keys

Taken from lazygit: the keys show where they are used, and only the ones
that apply.

- **Hint bar.** Each mode's status line lists its common keys, filtered by the
  thread at hand (the one under the cursor in the list, the one shown in
  thread mode): `a approve` only with a proposed comment, `d discard` only
  with unpublished text, `R read` only when unread, `x` labelled
  `resolve`, `reopen` or `accept`. Off a thread, the list shows only its
  review-wide keys. Keys that do not fit the width are dropped from the
  end; `? keys` always stays.
- **`?` menu** (also `g?`). A float over the sidebar listing every key of
  the mode by group (Thread, Review, Move). It stays until `q`, `<Esc>` or
  `?`. Pressing a key, or `<CR>` on its row, closes it and runs the key on
  the thread under the cursor; `/` filters. It is built from the same key
  declarations as the mappings and the hint bar (`keys.lua`), so the three
  never disagree.

### The code window

The code window is the window the sidebar was last entered from, else any
normal window on a file in the tabpage. Showing a thread shows its anchor
there: the file, the cursor on the first line, the range highlighted until
the cursor leaves it. When the sidebar is the only window, a split opens on
its left for the code. Threads with no code (the change, a directory) leave
the code window alone.

### List mode

```
Review  cs/9.5/usl-composed-drop-target
!1234 -> main  Composed drop target
2 unread  1 proposed  3 not published  9 open  4 resolved
pulled 5 min ago

Unread (2)
  Editor.py:267-293  @bob: why not reuse the helper?
  change             @alice: please add a changelog entry
Proposed (1)
  UIUtils.py:213     me (proposed): Renamed, see fixup! ...
Not published (3)
  Editor.py:1217     me: this leaks the stage
  ...
Open (9)
Resolved (4)  ...
```

- Sections in urgency order, each a fold; Resolved starts folded. A thread
  is one line: anchor (path relative to the repo, `change` for the whole
  change), tags, the author and first line of the last comment. Anchors
  longer than 28 columns are cut from the left (`...tor/Editor.py:267`) and
  the summary at the window's edge; thread mode shows everything.
- The cursor starts on the first thread, so `<CR>` works at once.
- `<CR>` shows the thread under the cursor in thread mode; the code window
  follows and the cursor stays in the sidebar. `o` does the same and moves
  the cursor to the code window.
- Thread keys (below) also work on the thread under the cursor, and on a
  visual selection of threads (`x` on five lines resolves five threads).
- Review-wide keys:

| key     | action                                                        |
| ------- | ------------------------------------------------------------- |
| `p`     | pull (never sends)                                            |
| `P`     | publish: the summary, confirm, send                           |
| `n`     | new thread on the whole change                                |
| `A`     | approve every proposed comment                                |
| `D`     | discard every proposed comment                                |
| `R`     | mark read (the thread or selection under the cursor)          |
| `m`     | MR actions (hooks, see below): approve the MR, open in the browser |
| `f`     | changed files (hook: the user's diff picker)                  |
| `e`     | edit the notes file (in the code window)                      |
| `<Tab>` | fold or unfold a section                                      |
| `?`     | every key, to read or run (`g?` too)                          |

### Thread mode

```
# Editor.py:267-293
open, 2 comments, unread

### @bob  2 days ago
why not reuse the helper?

### me (not published)
it needs the stage, the helper takes a layer
```

The hint bar shows the keys that apply, and the place in the list on the
right: `r reply  x resolve  a approve  ]t next  q list  ? keys    2 unread  3 of 19`.

- Showing a thread marks it seen; `R` in the list stays for clearing many
  at once.
- `q` goes back to list mode, the cursor on that thread's row. The list is
  home: `q` there closes the sidebar.
- `]t`/`[t` and `]u`/`[u` move through the threads in list order (the order
  is kept while moving, so a thread that changes section is not skipped or
  repeated), and the list's cursor follows. In list mode `j`/`k` do that.

### Thread keys

The same in both modes; in list mode they act on the thread under the
cursor. Moving (`]t`, `]u`) is thread mode's; `q` steps back one level
(thread to list, list to closed).

| key  | action                                                       |
| ---- | ------------------------------------------------------------ |
| `r`  | reply, or edit my unpublished reply (the composer)           |
| `x`  | resolve / reopen; acknowledges "resolved by @bob" when unseen |
| `a`  | approve the proposed comment                                 |
| `d`  | discard my unpublished text (a new thread disappears)        |
| `o`  | go to the code                                               |
| `q`  | back one level: thread to list, list closes the sidebar      |
| `?`  | every key, to read or run                                    |

`x`, `a`, `d` act at once (they are local until publish); `d` asks when it
would delete a whole new thread.

### MR hooks

The MR is part of the review (approving it, its target, the diff base), so
the list is its natural place. The plugin stays forge-agnostic: the header
line and `m` come from optional config.

```lua
mr = {
  info = { "git-lab", "mr", "info", "--json" }, -- {ref, title, target, url}
  actions = {
    { key = "a", desc = "approve", cmd = { "git-lab", "mr", "approve", "-m", "{input}" } },
    { key = "o", desc = "browser", fn = function(mr) vim.ui.open(mr.url) end },
  },
}, -- the default; false for none
files = function(review) Snacks.picker.git_diff({ base = review.mr.target }) end,
```

`{input}` asks for a line of text first; empty leaves it out, with the
option before it (`-m`). Checkout of another MR stays outside: it changes
which review is current, so it belongs to a global key (`<leader>rm` in the
user config), not to the sidebar of the current one.

## Code buffers

Signs only: the anchor range gets a bar in the sign column, its last line
the state icon (unread, proposed, unsent, open, resolved). Optional
(`signs = false`). Change threads have no mark in code buffers; they are
rows in the list like any other. Anchors follow edits through extmarks and
are written back on save. A thread whose line was deleted stays on the
nearest line and is marked `moved`.

Global keys the README suggests (the plugin sets none):

| key          | action                                                   |
| ------------ | -------------------------------------------------------- |
| `<leader>rr` | the sidebar: open, back to the list, close               |
| `<leader>rt` | the thread at the cursor in the sidebar (a menu if several) |
| `<leader>rn` | new thread on the line, or the visual range              |
| `<leader>rN` | new thread on the whole change                           |
| `<leader>rf` | the finder                                               |
| `]r` / `[r`  | next / previous unread across the review (in the sidebar); with nothing unread, the next thread in the buffer |

`<leader>rn` always starts a new thread, even on a line that has one;
replies are `r` in the sidebar.

## Commands

| Command           | Effect                                               |
| ----------------- | ---------------------------------------------------- |
| `:Review`         | the sidebar: open, back to the list, close           |
| `:Review thread`  | the thread at the cursor in the sidebar              |
| `:Review pull`    | pull, for scripts and autocmds                       |
| `:Review publish` | publish (summary, confirm)                           |
| `:Review edit`    | the notes file                                       |

Everything else is a key in the sidebar, or a Lua function
(`require("review_notes").actions`).

## The finder

A way to jump to a thread from anywhere, not a place to act on threads: the
sidebar is that. The plugin ships a snacks source
(`require("review_notes.snacks").source`) so user config is one line.

- It searches the anchor, the tags and the whole conversation, not only the
  last comment, which the list cannot do.
- The preview is the thread as thread mode shows it.
- `<CR>` shows the thread in the sidebar (opening it when needed), with the
  code window following; `<a-o>` goes to the code. No other keys.

`items(buf)` stays the API for other pickers.

## Writing

The composer is a float at the bottom of the sidebar, at its width (or
under the cursor, for `<leader>rn` in code). `<C-s>` or `:w` saves, `q`
closes and keeps the text for next time. New thread on a line or range from
the code; new change thread from the list (`n`) or `<leader>rN`; reply from
the sidebar (`r`).

## Storage

Two files per review, in `.git/review/` (or beside a file outside git):

- `<branch>.md`: the notes. Humans and agents read and write it.
- `<branch>.json`: sidecar for the plugin: remote status, last-seen
  markers, line anchors. Safe to delete (seen markers reset and everything
  shows as unread).

A file outside git has its own review in a sibling `<file>.review.md`,
local only.

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

## Backend contract

All remote work goes through command lines in `backend` (see
`review_notes.Config` in `config.lua` for the exact contract), run in the
repo root with text on stdin:

- `threads` prints every thread as JSON, with a stable `id` per comment so
  unread is tracked per comment. `path = null` is a thread on the whole
  change.
- `add`, `general` and `reply` start a thread on a line, start one on the
  whole change, or reply; with drafts they queue and print the draft id.
- `submit` (optional) publishes exactly the queued `{ids}`; `discard`
  (optional) drops what submit did not publish. A backend without drafts
  leaves both out and posts in order.
- `resolve`, `unresolve` change a thread's state.

The git-lab script in `extras/` implements it for GitLab.

## Code layout

| Module            | Responsibility                                             |
| ----------------- | ---------------------------------------------------------- |
| `store.lua`       | parse and write the markdown file and the sidecar, atomic  |
| `merge.lua`       | pull merge and publish plan, pure functions, fully tested  |
| `backend.lua`     | run the commands, the JSON contract                        |
| `config.lua`      | the options                                                |
| `review.lua`      | the current review: context, items, sorting, watcher, change listeners |
| `sync.lua`        | pull and publish                                           |
| `actions.lua`     | the verbs, on items: resolve, approve, discard, reply, ... |
| `sidebar.lua`     | the sidebar window and the code window                     |
| `keys.lua`        | key declarations: mappings, hint bar, `?` menu             |
| `list.lua`        | list mode: drawing, folds, review-wide keys, MR hooks      |
| `thread.lua`      | thread mode: drawing, hint bar, thread keys, list order    |
| `signs.lua`       | anchors (extmarks) and signs in code buffers               |
| `compose.lua`     | the composer float                                         |
| `snacks.lua`      | the finder, a snacks picker source                         |
| `init.lua`        | setup, commands, public API (thin)                         |

`actions` is the one place a verb lives; the sidebar and the finder bind
keys to it. Every change goes through `review.edit`, which tells the
listeners (code signs, the sidebar), so nothing refreshes by hand.

`merge.lua` and `store.lua` have no Neovim dependencies, so most of the
logic is testable in plain Lua, and a fake backend script covers the rest.

## Pi extension

- `/review` writes `### me (proposed)` comments on new threads; it never
  touches remote comments.
- `/fixup` reads open threads, makes `fixup!` commits, and adds a proposed
  reply, resolving the thread when it is done. The resolve is held with the
  proposed reply until I approve it.
- Because proposed comments never publish without approval, running it in
  the middle of a pull from a peer is harmless.
