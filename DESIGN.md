# review-notes.nvim: design

Status: v2 (model, file format, pull and publish) and v3 (the UI: a review
home and a thread panel instead of virtual lines) are implemented; the
sections below describe v3 where they differ.
The README is the user documentation. Backward compatibility of commands,
keymaps and options is not a goal; the notes file format stays.

## Problems with v2 (the UI)

1. Too many entry points with no home. About 15 global keys, a second set
   in the picker (`<a-r>`, `<a-a>`, ...), and change thread variants
   (`add_general`, `reply_general`, `toggle_expand(header)`). Nothing says
   which key works where.
2. Threads are virtual lines, and the cursor cannot stand on a virtual
   line. Every action guesses its thread from the code line under the
   cursor, and falls back to a menu when that is ambiguous (several threads
   on a line, the header). Most of the extra keys come from this.
3. The header of change threads sits above line 1, where Neovim only shows
   it when the window is scrolled into it (`topfill`). Keyboard motions
   reset that, so it needs autocmds to keep it on screen.
4. Expand and collapse state, redraws on resize, live rows for unsaved
   edits: complexity spent on drawing text into code buffers.
5. In practice the picker became the hub, though it was built as a finder:
   no review-wide actions, no summary, actions copied into user config.

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
- **The review has a home.** One buffer shows the whole review and holds
  the review-wide actions; one panel shows a thread and holds the thread
  actions. Code buffers only get signs.
- **Keys belong to a context.** The plugin sets no global keys, but its own
  buffers (home, panel, composer) have their own, short ones. A verb has the
  same key everywhere it applies (home, panel, picker).
- **The notes file is for humans and agents.** Plain markdown, greppable,
  safe to hand-edit. Machine state lives elsewhere.
- **Fits the existing workflow.** gitsigns for hunks and the review diff,
  a picker to fuzzy-find. The home links to them (changed files, diff base)
  through hooks; it does not replace them.

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
not seen. "Seen" is stored in the sidecar, set when the thread is opened in the
panel, or marked by key in the home. Unread is only a highlight and a counter; it never
blocks anything.

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

## The home

`:Review` (or the user's `<leader>rr`) opens the home: a normal buffer
(`reviewnotes://home`, filetype `reviewhome`) in the current window, like
fugitive's `:G` or neogit's status. `q` goes back to the previous buffer.
It redraws when the notes file or the sidecar change (file watcher), so pi
and pulls show up live.

```
Review  cs/9.5/usl-composed-drop-target  !1234 -> main
2 unread  1 proposed  3 unsent  9 open  4 resolved      pulled 5 min ago

Unread (2)
  > change                 @alice: please add a changelog entry
  > Editor.py:267-293      @bob: why not reuse the helper?
Proposed (1)
  > UIUtils.py:213         me (proposed): Renamed, see fixup! ...
Unsent (3)
  > Editor.py:1217-1222    me: this leaks the stage
  ...
Open (9)
Resolved (4)                                           (folded)

p pull  P publish  m MR  f files  n new  <CR> open  ? help
```

- Sections in urgency order (as the picker sorts today), each a fold;
  Resolved starts folded. A thread is one line: icon, anchor (path relative
  to the repo, `change` for the whole change), last comment.
- `<CR>` opens the thread in the panel and keeps the cursor in the home;
  `o` goes to the code in the home's window (and opens the panel). `<Tab>` toggles a section.
- Thread keys (below) also work on the thread under the cursor, and on a
  visual selection of threads (`x` on five lines resolves five threads).
- Review-wide keys:

| key | action                                                              |
| --- | ------------------------------------------------------------------- |
| `p` | pull (never sends)                                                  |
| `P` | publish: the summary, confirm, send                                 |
| `n` | new thread on the whole change                                      |
| `A` | approve every proposed comment                                      |
| `D` | discard every proposed comment                                      |
| `R` | mark read (the thread or selection under the cursor)                |
| `m` | MR actions (hooks, see below): approve the MR, open in the browser  |
| `f` | changed files (hook: the user's diff picker)                        |
| `e` | edit the notes file                                                 |
| `?` | help                                                                |

### MR hooks

The MR is part of the review (approving it, its target, the diff base), so
the home is its natural place. The plugin stays forge-agnostic: the header
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
option before it (`-m`). Checkout of
another MR stays outside: it changes which review is current, so it belongs
to a global key (`<leader>rm` in the user config), not to the home of the
current one.

## The thread panel

One thread at a time, as a real buffer (`reviewnotes://thread`, filetype
`markdown`) in a split on the right, about 70 columns, reused across
threads. A split, not a float: it stays open while moving through threads
and while reading the code next to it.

```
Editor.py:267-293            open  2 comments  unread
------------------------------------------------------
@bob  2 days ago
why not reuse the helper?

me (not published)
it needs the stage, the helper takes a layer
------------------------------------------------------
r reply  x resolve  a approve  d discard  ]t next  q close
```

- Opening a thread marks it seen. That removes "mark read" as an action;
  the home keeps it (`R`) for clearing many at once.
- The code window follows: opening a thread from the home or with `]t`
  shows its anchor in the last code window, cursor on the first line, range
  highlighted until the cursor leaves it. The panel never takes the code
  window's place.
- Change threads are threads like any other here; there is no header.
- Thread keys, the same in the panel, the home and the picker:

| key  | action                                                       |
| ---- | ------------------------------------------------------------ |
| `r`  | reply, or edit my unpublished reply (the composer)           |
| `x`  | resolve / reopen; acknowledges "resolved by @bob" when unseen |
| `a`  | approve the proposed comment                                 |
| `d`  | discard my unpublished text (a new thread disappears)        |
| `]t` | next thread, `[t` previous (home order)                      |
| `]u` | next unread, `[u` previous                                   |
| `o`  | go to the code                                               |
| `q`  | close the panel                                              |

`x`, `a`, `d` act at once (they are local until publish); `d` asks when it
would delete a whole new thread.

## Code buffers

Signs only, no virtual lines: the anchor range gets a bar in the sign
column, its last line the state icon (unread, proposed, unsent, open,
resolved). Optional (`signs = false`). No header, no expand state, no
redraw on resize. Anchors keep following edits through extmarks and are
written back on save, as in v2.

Global keys the README suggests (the plugin sets none):

| key          | action                                                   |
| ------------ | -------------------------------------------------------- |
| `<leader>rr` | the home                                                 |
| `<leader>rt` | the thread at the cursor in the panel (a menu if several) |
| `<leader>rn` | new thread on the line, or the visual range              |
| `<leader>rN` | new thread on the whole change                           |
| `<leader>rf` | the picker                                               |
| `]r` / `[r`  | next / previous unread across the review (in the panel); with nothing unread, the next thread in the buffer |

`<leader>rn` always starts a new thread, even on a line that has one;
replies are `r` in the panel. v2's `add` did both, depending on the cursor.

## Commands

| Command           | Effect                                               |
| ----------------- | ---------------------------------------------------- |
| `:Review`         | the home                                             |
| `:Review pull`    | pull, for scripts and autocmds                       |
| `:Review publish` | publish (summary, confirm)                           |
| `:Review edit`    | the notes file                                       |

Everything else is a key in the home or the panel, or a Lua function
(`require("review_notes").actions`).

## The picker

A finder, not a hub: the home is the hub. The plugin ships the snacks
source (`require("review_notes.snacks").source`) so user config is one line,
and the source binds the thread keys from `actions` as `<a-r>`, `<a-x>`,
`<a-a>`, `<a-d>`, `<a-m>` (mark read), `<a-o>` (code): the panel's letters. `<CR>` opens the panel on
the thread. `items(buf)` stays the API for other pickers. The quickfix list
(`:Review list`) is gone: the home replaces it.

## Writing

The composer is the v2 float, opened at the bottom of the panel, at its
width (or under the cursor, for `<leader>rn` in code and `r` in the home). `<C-s>` or `:w` saves, `q` closes and
keeps the text for next time. New thread on a line or range from the code;
new change thread from the home (`n`) or `<leader>rN`; reply from the
panel or the home (`r`).

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
| `config.lua`      | the options                                                |
| `review.lua`      | the current review: context, items, sorting, watcher, change listeners |
| `sync.lua`        | pull and publish                                           |
| `actions.lua`     | the verbs, on items: resolve, approve, discard, reply, ... |
| `home.lua`        | the home buffer                                            |
| `panel.lua`       | the thread panel                                           |
| `signs.lua`       | anchors (extmarks) and signs in code buffers               |
| `compose.lua`     | the composer float                                         |
| `snacks.lua`      | the snacks picker source, built on `actions`               |
| `init.lua`        | setup, commands, public API (thin)                         |

`actions` is the one place a verb lives; the home, the panel and the picker
bind keys to it. Every change goes through `review.edit`, which tells the
listeners (code signs, the home, the panel), so nothing refreshes by hand.

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

## Plan (v3), done

1. Split `init.lua`: `review.lua`, `actions.lua`, `sync.lua`, `config.lua`.
2. `panel.lua`.
3. `home.lua` on top of `actions`; `git-lab mr info --json`.
4. `signs.lua` replaces `view.lua`; the header, the expand state and their
   autocmds are gone, with `toggle`, `add`, `add_general`, `reply_general`,
   `toggle_expand*`, `approve`, `discard*`, `list`, `jump*`, `open`.
5. `snacks.lua` source, commands, README.

## Decisions

- Change threads have no header in code buffers (v2 drew one above line 1).
  They are rows in the home and threads in the panel like any other.
- The thread panel is a right split, reused, not a float.
- The home includes the MR (header line, `m` actions) through optional
  hooks; checking out another MR stays a global key.
- `pull` is explicit (`p` in the home, `:Review pull`) and also automatic:
  on `FocusGained` (the review of the current buffer) and on entering the
  home, when the last pull (or failed attempt) is older than `auto_pull`
  seconds (default 60; false turns it off). Pull is safe, so running it
  unasked is fine; it reports only new or changed threads, warns once when
  it starts failing, and waits while the notes file has unsaved edits in a
  buffer. Publish stays explicit.
- A thread whose line was deleted stays on the nearest line and is marked
  `moved`.
