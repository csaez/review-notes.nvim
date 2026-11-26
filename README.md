# review-notes.nvim

Code review for Neovim that lives in a plain text file, not in your code. The
threads of a review (yours, your peers', an agent's) are in one place, a
sidebar next to your code, and one file ties them to the merge request on the
remote.

Reading never sends anything. You pull to see what changed, write comments
locally, and publish when you are ready. Because the notes are a markdown
file, scripts and coding agents can read and answer them too.

```
 118 |   client.timeout = 30;            | Review  feature/timeouts
 119 |                                   | !123 -> main  Timeouts for the client
 120 |   // the studio default           | 1 unread  1 proposed  4 open
 121 | ! connect(host, port);            | pulled 3 min ago
 122 |                                   |
 123 | * read(sock, buf);                | ! Unread (1)
 124 |                                   |   src/http.cpp:120-124  @alice: why 30s?
                                         | * Proposed (1)
                                         |   src/http.cpp:88  me (proposed): conn...
```

`<CR>` on a row turns the sidebar into the thread, with its code on the left;
`-` goes back to the list.

## Features

- **A sidebar for the review.** `:Review` opens a window on the right that
  lists every thread by urgency (unread, proposed, not published, open,
  resolved) and holds the review-wide actions: pull, publish, approve all,
  the merge request. It never takes your code's window.
- **One thread at a time.** `<CR>` shows a thread in the sidebar, with its
  code next to it. Reply, resolve, approve, discard and move on with one key
  each.
- **Signs in the code.** A mark on each anchor, nothing else in your buffers.
- **One kind of thread.** Comments on a line, a range, a file or the whole
  change are all threads, and all work the same way.
- **Pull is safe.** It never sends anything and never touches your text, so it
  is fine to run in the middle of a peer or an agent adding comments. It also
  runs on its own, quietly, when Neovim gets focus or you open the list and
  the last pull is over a minute old (`auto_pull`).
- **Publish is one deliberate step.** It shows what it will send, asks, and
  sends new threads, replies and resolves in one go (one notification, only
  what it created).
- **Agents propose, you approve.** What a tool writes is a proposed comment:
  never published until you approve it.
- **Unread is a highlight, not a gate.** Threads with comments you have not
  seen are marked, and `]r` goes through them.
- **Notes outside the code.** No markers in your sources. Each branch has its
  own file, `.git/review/<branch>.md`. Any other file gets a sibling
  `<file>.review.md`, local only.
- **Follows your edits.** Anchors move with the code, saving writes the new
  lines back. Works next to gitsigns, diff pickers and hunk previews.
- **Pluggable backend.** All remote work goes through command lines you
  configure. A GitLab one ships as an extra.

## Requirements

- Neovim 0.10 or newer
- git
- A [Nerd Font](https://www.nerdfonts.com/), for the default icons
- To sync: a backend, such as the [git-lab extra](#git-lab)
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for the finder

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "csaez/review-notes.nvim",
  lazy = false, -- signs are drawn when files open, so load at startup
  opts = {},
  keys = {
    { "<leader>rr", function() require("review_notes").toggle() end, desc = "Review: sidebar" },
    { "<leader>rt", function() require("review_notes").thread() end, desc = "Review: thread here" },
    { "<leader>rn", function() require("review_notes").new() end, mode = { "n", "x" }, desc = "Review: new thread" },
    { "<leader>rN", function() require("review_notes").new_change() end, desc = "Review: new thread on the change" },
    { "<leader>rf", function() require("review_notes.snacks").open() end, desc = "Review: find threads" },
    { "]r", function() require("review_notes").next(1) end, desc = "Review: next thread (unread first)" },
    { "[r", function() require("review_notes").next(-1) end, desc = "Review: previous thread" },
  },
}
```

The plugin sets no global keymaps; its own buffers (the sidebar's list and
thread, the composer) have their own keys. The sidebar shows the ones that
apply in its bottom bar, and `?` lists them all.
`:checkhealth review_notes` checks that git and the backend commands are found.

## Quick start

1. Check out the branch under review and open a file.
2. `<leader>rr` opens the sidebar on the list, which pulls the threads of the
   merge request (`p` pulls again any time).
3. `<CR>` on a thread shows it in the sidebar, with its code in the window on
   the left. `r` replies, `x` resolves, `]t` moves to the next one, `-` goes
   back to the list.
4. In the code, `<leader>rn` on a line (or a visual selection) starts a new
   thread: write, save with `<C-s>`.
5. Back in the list, `P` shows what will be sent and, once you confirm, sends it.

## Usage

### The sidebar

`:Review` (or `toggle()`) opens a window on the right of the tab and moves
there. Pressed again it goes back one level: from a thread to the list, from
the list it closes the sidebar. It shows either the list of the review or
one thread, and redraws when the notes change, so a pull or an agent writing
shows up live. Code always goes to the code window, the last window you were
in on a file (a new one when the sidebar is alone); nothing opens a file in
the sidebar.

### List mode

The branch, the merge request and the counts, then the threads in sections
by urgency, each a fold (`<Tab>`; Resolved starts folded). Long paths are cut
from the left to fit.

| Key       | Does                                                         |
| --------- | ------------------------------------------------------------ |
| `<CR>`    | show the thread (the sidebar switches to it, its code follows) |
| `o`       | the same, and go to the code                                 |
| `r`       | reply, or edit my reply not published yet                    |
| `x`       | resolve / reopen; accepts a resolve by someone else          |
| `a`       | approve proposed comments                                    |
| `d`       | discard unpublished text (asks before deleting new threads)  |
| `R`       | mark read                                                    |
| `p`       | pull (sends nothing)                                         |
| `P`       | publish: summary, confirm, send                              |
| `n`       | new thread on the whole change                               |
| `A` / `D` | approve / discard every proposed comment                     |
| `m`       | merge request actions (see [Configuration](#configuration))  |
| `f`       | changed files (your function, see Configuration)             |
| `e`       | edit the notes file (in the code window)                     |
| `q`       | close the sidebar                                            |
| `?`       | every key, to read or run (see below)                        |

`x`, `a`, `d` and `R` also take a visual selection: `Vjjx` resolves three
threads.

### Thread mode

One thread. Showing it marks it seen and shows its code (range highlighted)
in the code window; threads on the whole change are threads like any other
here. The bottom bar shows where you are in the list (`2 unread  3 of 19`).

| Key        | Does                                                  |
| ---------- | ----------------------------------------------------- |
| `r`        | reply (the composer opens in the sidebar)             |
| `x`        | resolve / reopen                                      |
| `a`        | approve the proposed comment                          |
| `d`        | discard my unpublished text (asks for a new thread, which goes entirely) |
| `]t` `[t`  | next / previous thread (the list's order)             |
| `]u` `[u`  | next / previous unread                                |
| `o`        | go to the code                                        |
| `-`, `<BS>`| back to the list, on this thread                      |
| `q`        | close the sidebar                                     |
| `?`        | every key, to read or run (see below)                 |

### Finding the keys

As in lazygit, the bottom bar lists the common keys while the cursor is in
the sidebar, and only those that apply to the thread at hand: `a approve`
appears on a thread with a proposed comment, `R read` on an unread one, and
`x` says whether it resolves or reopens. It is the sidebar's `statusline`,
so with a global status line (`laststatus=3`) it takes over the bottom bar
while the sidebar has the focus. Keys are highlighted with `ReviewKey`.

A statusline plugin must leave the sidebar's filetypes alone, or it draws
over the bar. For lualine (the winbar entry keeps the sidebar without a top
bar, if you use one):

```lua
options = {
  disabled_filetypes = {
    statusline = { "reviewlist", "reviewthread" },
    winbar = { "reviewlist", "reviewthread" },
  },
}
```

`?` (or `g?`) opens every key of the mode, grouped. It stays open until
`q` or `<Esc>`. Press a key there, or `<CR>` on its row, to run it on the
thread under the cursor; `/` filters the list.

### In the code

Each thread on a line or range has a sign: a bar down the range, the icon of
its most urgent state on the last line. `signs = false` hides them.

| Function        | Does                                                         |
| --------------- | ------------------------------------------------------------ |
| `thread()`      | the thread at the cursor in the sidebar (a menu if several)  |
| `new()`         | new thread on the line or the visual range, even where one is |
| `new_change()`  | new thread on the whole change                               |
| `next(dir)`     | next / previous unread thread across the review; with nothing unread, the next thread in the buffer |

The composer is a small markdown float: `<C-s>` or `:w` saves into the notes
file (nothing is sent), `q` closes. Saving again edits your pending comment;
saving it empty removes it.

### Commands

| Command            | What it does                                              |
| ------------------ | --------------------------------------------------------- |
| `:Review`          | the sidebar: open, back to the list, close                |
| `:Review pull`     | bring the remote threads in; never sends                  |
| `:Review publish`  | pull, show what would be sent, confirm, send, pull        |
| `:Review thread`   | the thread at the cursor in the sidebar                   |
| `:Review edit`     | the notes file                                            |

## How syncing works

The remote is the source of truth for the conversation. Your side is what you
have not published.

- **Pull** replaces each known thread's remote comments, adds new threads and
  updates resolved state. Your local and proposed comments, and a resolve or
  reopen you have not published, are never touched. A thread deleted on the
  remote that holds your text stays, marked `orphan`, and publishes as a new
  thread. A thread resolved by someone else comes in as "resolved by @name"
  until you look at it.
- **Publish** pulls first, lists what it would send and asks. A reply you
  wrote on a thread that has since got unread comments is flagged in the list
  and you can skip those. Unread never blocks anything else. With a backend
  that has `submit` (git-lab does) everything is queued as drafts and
  published together, only the drafts created here; if publishing fails the
  leftovers are deleted, so retrying cannot post twice.
- **Proposed** comments are not sent, and neither is the resolve of a thread
  while it has one, so approving takes a single step.
- **Line numbers.** Anchors keep the lines you see, which follow your edits.
  A thread takes the remote's location only when yours is plainly wrong
  (another file, or no line at all). A thread whose lines were deleted stays
  on the nearest line, marked `moved`.

## The notes file

Markdown, so you can edit it by hand, grep it and diff it. Writes are atomic
and redone if another process (an agent) wrote at the same time.

```markdown
# Review of feature/timeouts

## change {id=ghi789}
status: open

### @alice {id=11}
please add a changelog entry

### me (local)
done, see the next push

## src/http.cpp:120-124 {id=abc123}
status: resolved

### @alice {id=12}
why 30s?

### me (proposed)
Matches the studio default, I added a comment above the constant.
```

- `## <anchor> {attrs}` starts a thread. The anchor is `change`, `path`,
  `path:N` or `path:N-M`. Paths are relative to the repository root. `id=` is
  the remote thread; none means it is new.
- `status: open|resolved` follows. A difference with the remote's status
  (kept in the sidecar) is a resolve or reopen not published yet.
- `### @author` is a remote comment (`mine` marks my own), `### me (local)`
  is mine and not published, `### me (proposed)` is a tool's, waiting for
  approval. Body lines that start with `#` are written with a leading `\`.
- Plain text under a `##` heading with no `###` is read as one local
  comment, so a hand-written thread works.
- `<branch>.json` next to it keeps the remote ids and what you have seen. It
  is safe to delete: everything shows as unread afterwards.

The full grammar is at the top of
[`lua/review_notes/store.lua`](lua/review_notes/store.lua).

## Configuration

```lua
require("review_notes").setup({
  signs = true,   -- gutter marks on the anchors
  watch = true,   -- redraw when a notes file changes (an agent, a pull)
  -- Pull in the background on focus and on entering the list, when the last
  -- pull is older than this many seconds; quiet unless threads came in.
  -- false: only `p` / `:Review pull`.
  auto_pull = 60,
  -- Command lines run in the repository root. {path}, {line}, {thread} and
  -- {ids} are filled in. Text goes on stdin; structured output comes back as
  -- JSON on stdout.
  backend = {
    threads   = { "git-lab", "comment", "list", "--json" },
    add       = { "git-lab", "comment", "add", "--draft", "--json", "{path}:{line}", "-" },
    general   = { "git-lab", "comment", "add", "--draft", "--json", "-" },
    reply     = { "git-lab", "comment", "reply", "--draft", "--json", "{thread}", "-" },
    resolve   = { "git-lab", "comment", "resolve", "{thread}" },
    unresolve = { "git-lab", "comment", "unresolve", "{thread}" },
    submit    = { "git-lab", "review", "submit", "--only", "{ids}", "--json" },
    discard   = { "git-lab", "review", "discard", "--only", "{ids}" },
  },
  -- The merge request in the list (false: none). `info` prints JSON with
  -- ref, title, url, target; `actions` are under `m`. A `cmd` runs in the
  -- repository root with {url}, {ref}, {target} filled in from `info`, and
  -- {input} asked for first (left out with the option before it if empty).
  mr = {
    info = { "git-lab", "mr", "info", "--json" },
    actions = {
      { key = "a", desc = "approve the MR (optional comment)", cmd = { "git-lab", "mr", "approve", "-m", "{input}" } },
      { key = "o", desc = "open in the browser", fn = function(mr) vim.ui.open(mr.url) end },
    },
  },
  -- `f` in the list: the changed files, with your picker. Not set by default.
  files = function(review)
    Snacks.picker.git_diff({ base = review.mr and review.mr.target })
  end,
})
```

### Writing your own backend

| Operation              | Input                          | Output on stdout                     |
| ---------------------- | ------------------------------ | ------------------------------------ |
| `threads`              |                                | JSON list of threads (see below)     |
| `add`                  | `{path}`, `{line}`, text on stdin | `{"id": ...}`                     |
| `general`              | text on stdin                  | `{"id": ...}`                        |
| `reply`                | `{thread}`, text on stdin      | `{"id": ...}`                        |
| `resolve`, `unresolve` | `{thread}`                     |                                      |
| `submit` (optional)    | `{ids}`, comma-separated       | `{"published": [...]}`, also when it fails part way |
| `discard` (optional)   | `{ids}`                        |                                      |

```json
{
  "id": "abc123",
  "path": "src/http.cpp",
  "line": 124,
  "start_line": 120,
  "resolved": false,
  "resolved_by": null,
  "resolved_by_me": false,
  "comments": [{ "id": "12", "author": "alice", "body": "why 30s?", "mine": false }]
}
```

- `path` is `null` for a thread on the whole change, `line` is `0` for a whole
  file. Lines refer to the files on disk.
- Comment `id`s are what unread tracking uses: without them every pull shows
  the thread as unread. `mine` keeps your own comments from counting as
  unread. `start_line`, `resolved_by` and `resolved_by_me` are optional.
- Without `submit`, each comment is published as soon as it is sent.

## Finder

`require("review_notes.snacks")` is a [snacks.nvim](https://github.com/folke/snacks.nvim)
source to jump to a thread of the current review from anywhere. It searches
the whole conversation, not only the last comment. `open()` opens it; to list
it among your pickers, register `source`:

```lua
picker = { sources = { review_notes = require("review_notes.snacks").source } }
```

`<CR>` shows the thread in the sidebar, `<a-o>` goes to the code. Acting on
threads is the sidebar's job, so there are no other keys.

For another picker, `require("review_notes").items(buf)` returns every thread
of the buffer's review, urgent first. Each item has `file`, `line`,
`end_line`, `kind` (`change`, `file` or `line`), `anchor`, `state`, `icon`,
`hl`, `tags`, `who`, `summary`, `thread` (the conversation as markdown lines,
for a preview) and `text` (searchable: the anchor, tags and every comment). Threads with no code (the whole
change, a directory such as a submodule) point at their heading in the notes
file.

- `open_item(item)` shows the thread in the sidebar and its code in the code
  window, and marks it seen.
- `goto_item(item)` does the same and goes to the code (`o` in the list,
  `<a-o>` in the finder).
- `item_action(item, "resolve" | "read" | "approve" | "discard")` acts without
  leaving your picker. Refresh its items afterwards.

## Statusline

`require("review_notes").status()` returns the unread, proposed and
not-published counts of the current review. It reads cached counts, so it is
cheap on every redraw:

```lua
sections = { lualine_x = { function() return require("review_notes").status() end } }
```

## Icons and highlights

Icons and groups are in `require("review_notes").style`, one per state
(`unread`, `proposed`, `unsent`, `open`, `resolved`). The groups are defined
with `default = true`, so your colorscheme can override them: `ReviewUnread`,
`ReviewProposed`, `ReviewUnsent`, `ReviewOpen`, `ReviewResolved`,
`ReviewAuthor`, `ReviewMine`, `ReviewText`, `ReviewRange` (the code of the
thread in the sidebar), `ReviewKey` (keys in the hint bar).

## Extras

Optional companions in [`extras/`](extras). The plugin works without them:
nothing in `lua/` loads or requires them, and each is installed by hand.

### git-lab

[`extras/git-lab`](extras/git-lab) is a single-file Python script (3.10 or
newer, no dependencies) for GitLab merge request work from the command line.
The plugin's default backend configuration calls it, and it also works on its
own:

```sh
git-lab mr list                  # open MRs of this repository
git-lab mr checkout '!123'       # check out an MR (also group/project!123, URL)
git-lab mr target                # the target branch of the current MR (cached)
git-lab mr target --refresh      # ask GitLab again, updating the cache
git-lab mr approve -m "LGTM"
git-lab mr info --json           # the current MR: ref, title, url, target
git-lab comment list             # threads, with lines mapped to the files on disk
git-lab comment add src/a.c:12 "why?"
git-lab review submit            # publish pending draft comments
```

It finds the project from the `origin` remote and the merge request from the
current branch. Set `GITLAB_HOST` to override the host. Run `git-lab --help`
for everything.

`mr list` prints one MR per line, starting with its reference, so a picker
works as a one-liner (`--recursive` includes submodules):

```sh
git-lab mr checkout "$(git-lab mr list --recursive | fzf | cut -f1)"
```

To install it, put it on your `PATH` and give it a token with `api` scope:

```sh
ln -s ~/.local/share/nvim/lazy/review-notes.nvim/extras/git-lab ~/.local/bin/git-lab
export GITLAB_TOKEN=...
```

### pi extension

[`extras/pi/review-notes.ts`](extras/pi/review-notes.ts) is an extension for
the [pi](https://github.com/earendil-works/pi) coding agent. It works on the
same notes files:

- `/review [request]` reviews the code and adds its findings as proposed
  comments for you to approve.
- `/fixup [scope]` goes through the open threads where pi has not spoken
  last, most severe first, and treats each by the tag it was filed with:
  - `FIX`: must be done. If it cannot be, the reply says why and the thread
    stays open.
  - `CHECK`: verified first; a real problem is fixed, otherwise the reply
    gives the evidence.
  - `CONSIDER`, `NIT`: optional. Done when clearly better and cheap,
    otherwise declined with a reason.
  - `QUESTION`: answered from the code.
  - No tag (a peer's comment, or yours): a request, done unless unclear.

  Threads on code become `fixup!` commits. Each handled thread gets a
  proposed reply, and is resolved when fixed, verified or declined; one that
  needs your decision stays open.

pi acts on its own findings without waiting for approval: approval is only
the gate before something goes to the merge request. Everything pi writes is
a `### me (proposed)` comment, which publish never sends until you approve it
(`a` in the sidebar, `A` in the list for all), so a round of pi is safe at
any time. To
install it, link or copy it into `~/.pi/agent/extensions/`.

## Development

```sh
make test
```

The tests need [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). They
look for it in lazy.nvim's data directory; set `PLENARY=/path/to/plenary.nvim`
to use another copy. The specs run against a fake backend in
`tests/fixtures/backend.sh`, so they never touch GitLab.
