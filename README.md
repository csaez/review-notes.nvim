# review-notes.nvim

Code review for Neovim that lives in a plain text file, not in your code. The
threads of a review (yours, your peers', an agent's) show up right under the
code they are about, and one file ties them to the merge request on the
remote.

Reading never sends anything. You pull to see what changed, write comments
locally, and publish when you are ready. Because the notes are a markdown
file, scripts and coding agents can read and answer them too.

```
  src/http.cpp
  88   auto t = connect_timeout;
       3 comments, @bob: matches the studio default  [unsent]
  120  return read(fd, buf, n);
```

## Features

- **Threads under the code.** In review mode each thread is a line under its
  anchor, `<CR>` expands it into the conversation. One toggle hides all of it
  when you want to focus on the code.
- **One kind of thread.** Comments on a line, a range, a file or the whole
  change are all threads. The ones on the whole change (and on a file) sit in
  a labelled header above line 1.
- **Pull is safe.** It never sends anything and never touches your text, so it
  is fine to run in the middle of a peer or an agent adding comments.
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
  lines back. Works next to gitsigns, diff pickers and hunk previews: it is
  only extmarks.
- **Pluggable backend.** All remote work goes through command lines you
  configure. A GitLab one ships as an extra.

## Requirements

- Neovim 0.10 or newer
- git
- A [Nerd Font](https://www.nerdfonts.com/), for the default icons
- To sync: a backend, such as the [git-lab extra](#git-lab)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "csaez/review-notes.nvim",
  lazy = false, -- threads are drawn when files open, so load at startup
  opts = {},
  keys = {
    { "<leader>rv", function() require("review_notes").toggle() end, desc = "Review: show / hide threads" },
    { "<leader>rn", function() require("review_notes").add() end, mode = { "n", "x" }, desc = "Review: reply or new thread" },
    { "<leader>rN", function() require("review_notes").add_general() end, desc = "Review: thread on the whole change" },
    { "<leader>rg", function() require("review_notes").reply_general() end, desc = "Review: reply in the header" },
    { "<leader>rl", function() require("review_notes").list() end, desc = "Review: list threads" },
    { "<leader>rr", function() require("review_notes").pull() end, desc = "Review: pull from the remote" },
    { "<leader>rp", function() require("review_notes").publish() end, desc = "Review: publish" },
    { "<leader>rx", function() require("review_notes").toggle_resolved() end, desc = "Review: resolve / reopen" },
    { "<leader>ra", function() require("review_notes").approve() end, desc = "Review: approve proposed" },
    { "<leader>rt", function() require("review_notes").thread() end, desc = "Review: thread in the panel" },
    { "]r", function() require("review_notes").jump_unread(1) end, desc = "Review: next unread" },
    { "[r", function() require("review_notes").jump_unread(-1) end, desc = "Review: previous unread" },
  },
}
```

The plugin sets no global keymaps. Binding `<CR>` globally is too greedy for
most setups: use `<leader>re` or similar instead. `:checkhealth review_notes`
checks that git and the backend commands are found.

## Quick start

1. Check out the branch under review and open a file.
2. `<leader>rr` pulls the threads of the merge request. They appear under
   their code; `<leader>rv` hides them.
3. On a line (or a visual selection) press `<leader>rn`, write, save with
   `<C-s>`. On a thread, the same key replies.
4. `<leader>rp` shows what will be sent and, once you confirm, sends it.

## Usage

### Reading

In review mode a thread is one line under its last anchor line, with an icon
for its most urgent state: unread, proposed, not published, open, resolved.
`toggle_expand()` (on the anchor line) opens the conversation, which also
marks it as seen. `toggle_expand_all()` does it for every thread.

Threads on the whole change or on a whole file are in a header above line 1,
labelled `change` or `file <name>`, so they are never confused with a thread
on line 1 (those are drawn below it). `toggle_expand(true)` opens the header
from anywhere in the buffer, `reply_general()` answers in it.

### The thread panel

`thread()` shows the thread at the cursor in a panel on the right (a menu
when there are several; on line 1 the change threads count too). Pickers
open it with `open_item(item)`, and `jump_unread(dir)` goes through it. It
is one window, reused, and it follows: showing a thread marks it seen and
shows its code (range highlighted) in the window you came from. The panel
redraws when the notes change, so a pull or pi writing shows up live.

| Key        | In the panel                                          |
| ---------- | ----------------------------------------------------- |
| `r`        | reply, or edit my reply not published yet             |
| `x`        | resolve / reopen; accepts a resolve by someone else   |
| `a`        | approve the proposed comment                          |
| `d`        | discard my unpublished text (asks for a new thread, which goes entirely) |
| `]t` `[t`  | next / previous thread (the picker's order)           |
| `]u` `[u`  | next / previous unread                                |
| `o`        | go to the code                                        |
| `q`        | close                                                 |
| `g?`       | help                                                  |

### Writing

`add()` opens a small float: on a thread it is your reply, elsewhere a new
thread on the line or the selected lines. `<C-s>` or `:w` saves it into the
notes file (nothing is sent), `q` closes. Saving again edits your pending
comment; saving it empty removes it. `add_general()` starts a thread on the
whole change, `add_general(true)` on the current file.

| Function                | Does                                                   |
| ----------------------- | ------------------------------------------------------ |
| `toggle_resolved()`     | resolve or reopen (sent by publish); on a thread someone else resolved it first accepts it |
| `mark_read()`           | mark the thread as seen                                |
| `approve(all?)`         | approve proposed comments of the thread (or all)       |
| `discard()`             | delete the unpublished part of the thread (mine, proposed, an unsent resolve); a thread never published is removed entirely |
| `discard_proposed()`    | delete every proposed (tool) comment, threads it started included |
| `jump(dir)`             | next / previous thread in the buffer                   |
| `jump_unread(dir)`      | next / previous unread thread across the review        |

### Commands

| Command            | What it does                                              |
| ------------------ | --------------------------------------------------------- |
| `:Review`          | toggle review mode                                        |
| `:Review pull`     | bring the remote threads in; never sends                  |
| `:Review publish`  | pull, show what would be sent, confirm, send, pull        |
| `:Review list`     | the threads in the quickfix list                          |
| `:Review approve [all]` | approve proposed comments                            |
| `:Review discard [proposed]` | delete the unpublished part of the thread, or every proposed comment |
| `:Review expand`   | expand or collapse every thread                           |
| `:Review thread`   | the thread at the cursor in the panel                     |
| `:Review open`     | open the notes file                                       |

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
  visible = true, -- start in review mode
  signs = true,   -- gutter marks on the anchors
  watch = true,   -- redraw when a notes file changes (an agent, a pull)
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

## Picker

The plugin has no picker of its own. `require("review_notes").items(buf)`
returns every thread of the buffer's review, urgent first, as one kind of row
(the change threads are rows like any other). Each item has `file`, `line`,
`end_line`, `kind` (`change`, `file` or `line`), `anchor`, `state`, `icon`,
`hl`, `tags`, `summary`, `thread` (the conversation as markdown lines, for a
preview) and `text` (searchable). A thread on a directory (a submodule's
pointer change) points at its heading in the notes file instead.

- `open_item(item)` shows the thread in the panel and its code in the
  current window, and marks it seen.
- `goto_item(item)` only goes there.
- `item_action(item, "resolve" | "read" | "approve" | "discard")` acts without leaving
  the picker. Refresh its items afterwards.

<details>
<summary>A snacks.nvim source</summary>

```lua
picker = {
  sources = {
    review_notes = {
      title = "Review threads",
      finder = function(_, ctx)
        local items = require("review_notes").items(ctx.filter.current_buf)
        for _, item in ipairs(items) do
          item.pos, item.end_pos = { item.line, 0 }, { item.end_line, 0 }
        end
        return items
      end,
      format = function(item, picker)
        local ret = { { item.icon .. " ", item.hl } }
        if item.kind == "change" then
          table.insert(ret, { "change  ", "SnacksPickerDir" })
        else
          vim.list_extend(ret, Snacks.picker.format.filename(item, picker))
        end
        for _, tag in ipairs(item.tags) do
          table.insert(ret, { "[" .. tag .. "] ", "SnacksPickerComment" })
        end
        table.insert(ret, { item.summary, "ReviewText" })
        return ret
      end,
      preview = function(ctx)
        ctx.preview:reset()
        ctx.preview:set_lines(ctx.item.thread)
        ctx.preview:highlight({ ft = "markdown" })
      end,
      confirm = function(picker, item)
        picker:close()
        if item then require("review_notes").open_item(item) end
      end,
      actions = {
        review_resolve = function(picker, item)
          if item then require("review_notes").item_action(item, "resolve") end
          picker:find()
        end,
        review_approve = function(picker, item)
          if item then require("review_notes").item_action(item, "approve") end
          picker:find()
        end,
      },
      win = {
        input = {
          keys = {
            ["<a-r>"] = { "review_resolve", mode = { "n", "i" }, desc = "resolve / reopen" },
            ["<a-a>"] = { "review_approve", mode = { "n", "i" }, desc = "approve proposed" },
          },
        },
      },
    },
  },
},
```

</details>

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
`ReviewProposed`, `ReviewUnsent`, `ReviewOpen`, `ReviewResolved`, `ReviewBar`,
`ReviewAuthor`, `ReviewMine`, `ReviewText`, `ReviewHeader`.

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
(`approve`, or `approve all`), so a round of pi is safe at any time. To
install it, link or copy it into `~/.pi/agent/extensions/`.

## Development

```sh
make test
```

The tests need [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). They
look for it in lazy.nvim's data directory; set `PLENARY=/path/to/plenary.nvim`
to use another copy. The specs run against a fake backend in
`tests/fixtures/backend.sh`, so they never touch GitLab.
