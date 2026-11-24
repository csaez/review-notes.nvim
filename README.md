# review-notes.nvim

Code review notes for Neovim that live in a plain text file, not in your code,
and sync with the threads of a code review on a remote (a merge request, a
pull request) through a backend you plug in.

You write notes in the editor while you read the code. They show up as signs
in the gutter and move with the code as you edit. When you are ready, one
command sends them to the remote and brings back everyone else's replies.
Because the notes are just a text file, scripts and coding agents can read and
answer them too.

The plugin itself only talks to the remote through command lines you
configure. A ready-made GitLab backend, `git-lab`, and an extension for the
pi coding agent ship as optional [extras](#extras).

```
src/http.cpp:88: timeout must cover connect, not only read
src/http.cpp:120: [id:abc123] [new] @alice: why 30s?
  > @bob: +1
  matches the studio default
```

## Features

- **Notes outside the code.** No markers in your sources and nothing to clean
  up before a commit. Each branch gets its own notes file,
  `.git/review/<branch>.txt`.
- **Notes follow the code.** Each note is anchored with an extmark while you
  edit. Saving the file writes the new line numbers back to the notes file.
- **A float to write and read.** A note opens in a markdown buffer: the
  conversation at the top, your turn at the bottom. Save it with `:w`.
- **Two-way sync.** New notes become threads, your replies are posted, and
  resolving or reopening a thread carries over. Threads started in the
  browser come in too.
- **Safe to resync.** Every push pulls first, so a reply posted in the browser
  in the meantime is flagged `[new]` and that thread is held back until you
  have read it. With a backend that queues drafts, only the drafts the push
  created are published, so a review you started in the browser stays
  pending.
- **Shows what waits for you.** Entries changed by someone else are tagged
  `[new]` (by a pull, or by an agent's round) until you reply, resolve or mark
  them read. `jump_new` steps through them across the whole review.
- **Drafts.** `[draft]` keeps a note local until you approve it. This is handy
  for notes written by a tool that you want to check first.
- **Works outside git too.** Any other file, such as a markdown draft, gets a
  local review in a sibling `<file>.notes`.
- **Pluggable backend.** All remote work goes through command lines you
  configure, following a small JSON contract. Notes work fully offline
  without one.
- **Bring your own picker.** `items()` returns the notes ready for any picker.
  A complete snacks.nvim source is shown below.

## Requirements

- Neovim 0.10 or newer
- git
- A [Nerd Font](https://www.nerdfonts.com/), for the default sign icons (see
  [Signs and highlights](#signs-and-highlights) to change them)
- To sync: a backend (see [Configuration](#configuration)), such as the
  [git-lab extra](#git-lab) for GitLab

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "csaez/review-notes.nvim",
  lazy = false, -- notes are drawn when files open, so load at startup
  opts = {},
  keys = {
    { "<leader>rn", function() require("review_notes").add() end, mode = { "n", "x" }, desc = "Review: note at cursor" },
    { "<leader>rN", function() require("review_notes").add_general() end, desc = "Review: note on the whole change" },
    { "<leader>ro", function() require("review_notes").open() end, desc = "Review: open the notes file" },
    { "<leader>rr", function() require("review_notes").sync() end, desc = "Review: sync with the remote" },
    { "]r", function() require("review_notes").jump_new(1) end, desc = "Review: next [new] note" },
    { "[r", function() require("review_notes").jump_new(-1) end, desc = "Review: previous [new] note" },
  },
}
```

The plugin sets no global keymaps. You need to call `setup()`; lazy.nvim does
this for you through `opts`.

To sync, set up a backend: for GitLab, install the [git-lab extra](#git-lab)
(the default configuration calls it), or configure your own. Run
`:checkhealth review_notes` to check that git and the backend commands are
found.

## Quick start

1. Check out the branch under review and open a file.
2. Put the cursor on a line (or select a range) and press `<leader>rn`. Write
   the note, then save it with `:w` and close the float with `q`.
3. Press `<leader>rr` (`:Review sync`). After you confirm, your notes become
   threads on the remote.
4. Later, sync again. Replies come in flagged `[new]`. Press `]r` to go
   through them, answer with `<leader>rn`, and sync.

## Usage

### The note float

`add()` opens the note on the cursor line, or starts a new one on the line or
the visual selection. The float is a markdown buffer: the thread so far at the
top, and your turn below the `---` line. Your turn is the whole note until
someone answers it, and after that your reply.

| Key              | Action                                         |
| ---------------- | ---------------------------------------------- |
| `:w`             | save into the notes file                       |
| `q`              | close (unsaved text is kept for next time)     |
| `<localleader>x` | resolve / reopen                               |
| `<localleader>p` | toggle draft                                   |
| `<localleader>r` | mark read (clears `[new]`)                     |
| `<localleader>d` | delete (only notes that were never sent)       |
| `]n` / `[n`      | next / previous note, with the code following  |
| `gd`             | go to the code                                 |

The keys are in `require("review_notes").keys`. The float size is
`require("review_notes.note").size` (0.8 of the editor each way by default).
To change where it is placed, override `require("review_notes.note").float`.

### General and file notes

`add_general()` starts a note on the whole change; on GitLab it becomes an
overview thread (a thread with no location, for other backends). General notes sit at the top of the notes file. Any prose you
write there by hand is a general note too. `add_general(true)` starts a note
on the whole current file (`path:0`), which is shown on its first line.

### Commands

| Command          | What it does                                                         |
| ---------------- | -------------------------------------------------------------------- |
| `:Review sync`   | pull, then send what is ready (asks first); quiet when nothing to send |
| `:Review push`   | the same, but says so when there is nothing to send                  |
| `:Review pull`   | bring the remote threads in                                          |
| `:Review clean`  | drop resolved entries that have nothing left to send                 |

### Lua API

| Function                         | Description                                          |
| -------------------------------- | ---------------------------------------------------- |
| `add()`                          | open or start the note at the cursor / selection     |
| `add_general(file?)`             | note on the whole change, or on the current file     |
| `open()`                         | open the notes file in a split, to edit by hand      |
| `jump(dir)`                      | next / previous note in the buffer                   |
| `jump_new(dir)`                  | next / previous `[new]` note across the review       |
| `toggle_resolved()`              | resolve or reopen the note under the cursor          |
| `toggle_pending()`               | toggle draft on the note under the cursor            |
| `sync()`, `push()`, `pull()`, `clean()` | same as the commands                          |
| `status()`                       | statusline component                                 |
| `items(buf)`, `open_item(item)`, `goto_item(item)`, `item_action(item, action)` | picker support |

## How syncing works

The remote is the source of truth for threads. Your side is what you have not
sent yet.

- **Pull** rewrites each known thread's cached comments (the `> ` lines) and
  its resolved state, and adds threads that are new on the remote. Your
  unsent lines are kept, and so is a resolve or reopen you have not sent. A
  thread deleted on the remote is dropped, unless it holds unsent text of
  yours; then it stays and you get a warning. Pull keeps the file sorted:
  general notes first, then by path and line.
- **Push** pulls first, then shows what it would send and asks you to
  confirm. It creates new threads, posts replies and changes resolved state.
  Anything tagged `[new]` is held back until you have read it, so you never
  reply to or resolve a thread over a comment you have not seen.
- **Drafts.** With a backend that has `submit` (git-lab does), new threads
  and replies are queued as drafts and published together, which sends one
  notification. Only the drafts that push created are published. If
  publishing fails, the ones left over are deleted, so retrying cannot post
  twice.
- **Who did what.** When the backend tells the plugin which comments are
  yours (git-lab does), your own comments never flag a thread, even ones you
  wrote in the browser, and a thread resolved by someone else comes in as
  `[resolved] [new]`: a claim to check. Your first resolve toggle accepts it.
- **Line numbers.** Notes on known threads keep their lines, since those
  follow your edits. A thread takes the remote's location only when the file
  had it plainly wrong (another file, or no location).

## The notes file

The format is plain text, so you can edit it by hand, grep it and diff it.

```
main concern is the connect timeout                           general note
[id:ghi789] [new] @alice: please add a changelog entry        general thread
  > @bob: +1

src/http.cpp:88: timeout must cover connect, not only read    new note
src/http.cpp:90: [draft] maybe a leak here?                   never sent
src/http.cpp:120-124: [id:abc123] [new] @alice: why 30s?      remote thread, on a range
  > @bob: +1                                                  remote (cache)
  matches the studio default                                  my reply, not sent yet
src/http.cpp:50: [resolved] [id:def456] @alice: typo          resolved
  > (resolved)                                                remote state
src/http.cpp:0: [id:jkl012] @bob: split this file             whole file
```

- An unindented line starts an entry. Indented lines belong to it.
- `path:line:` or `path:first-last:` puts the note on code. `path:0:` puts it
  on the whole file. With no location, it is a general note.
- After the location come the tags, in this order: `[resolved]`, `[draft]`,
  `[id:X]` (the remote thread), `[new]`.
- `> ` lines are a cache of the remote thread, rewritten on every pull. Other
  indented lines are yours.
- Lines starting with `#` are comments.

Paths are relative to the repository root. The full grammar is documented at
the top of [`lua/review_notes/notes.lua`](lua/review_notes/notes.lua).

## Configuration

`setup()` takes these options. The defaults are shown; the default `backend`
calls the [git-lab extra](#git-lab), so replace it to use another remote:

```lua
require("review_notes").setup({
  -- Watch the notes files that are shown, so changes made outside Neovim
  -- (a script, an agent, the backend) show up right away.
  watch = true,
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

Any tool that follows this contract works (GitHub, Gerrit, a mock):

| Operation              | Input                          | Output on stdout                     |
| ---------------------- | ------------------------------ | ------------------------------------ |
| `threads`              |                                | JSON list of threads (see below)     |
| `add`                  | `{path}`, `{line}`, text on stdin | `{"id": ...}`                     |
| `general`              | text on stdin                  | `{"id": ...}`                        |
| `reply`                | `{thread}`, text on stdin      | `{"id": ...}`                        |
| `resolve`, `unresolve` | `{thread}`                     |                                      |
| `submit` (optional)    | `{ids}`, comma-separated       | `{"published": [...]}`, also when it fails part way |
| `discard` (optional)   | `{ids}`                        |                                      |

A thread looks like this:

```json
{
  "id": "abc123",
  "path": "src/http.cpp",
  "line": 124,
  "start_line": 120,
  "resolved": false,
  "resolvable": true,
  "resolved_by": null,
  "resolved_by_me": false,
  "comments": [{ "author": "alice", "body": "why 30s?", "mine": false }]
}
```

- `path` is `null` for a thread on the whole change, and `line` is `0` for a
  thread on a whole file. Lines refer to the files on disk.
- `start_line`, `resolvable`, `resolved_by`, `resolved_by_me` and `mine` are
  optional. Without `mine`, the plugin cannot tell your comments apart, so it
  flags nothing right after a push.
- Without `submit`, each note is published as soon as it is sent.

## Picker

The plugin has no picker of its own. `require("review_notes").items(buf)`
returns the notes of the buffer's review. Each item has:

- `file`, `line`, `end_line`
- `icon`, `hl`, `summary`, `summary_hl`
- `general`: the note is about the whole change, and `file` is the notes file
- `thread`: the conversation as markdown lines, for a preview (decorate it
  with `require("review_notes.thread").decorate`)
- `text`: searchable text (kind, state, path and note)

To act on the chosen item:

- `open_item(item)` opens the note float, with its code in the current window.
- `goto_item(item)` only goes to the code (for a general note, the notes file).
- `item_action(item, "resolve" | "draft" | "read")` acts without leaving the
  picker. Refresh its items afterwards.

<details>
<summary>A snacks.nvim source</summary>

```lua
-- in your snacks.nvim opts
picker = {
  sources = {
    review_notes = {
      title = "Review notes",
      finder = function(_, ctx)
        local items = require("review_notes").items(ctx.filter.current_buf)
        for _, item in ipairs(items) do
          item.pos, item.end_pos = { item.line, 0 }, { item.end_line, 0 }
        end
        return items
      end,
      format = function(item, picker)
        local ret = { { item.icon .. " ", item.hl } }
        if item.general then
          table.insert(ret, { "whole change  ", "SnacksPickerDir" })
        else
          vim.list_extend(ret, Snacks.picker.format.filename(item, picker))
        end
        table.insert(ret, { item.summary, item.summary_hl })
        return ret
      end,
      preview = function(ctx)
        ctx.preview:reset()
        local lines = ctx.item.thread or {}
        ctx.preview:set_lines(lines)
        ctx.preview:highlight({ ft = "markdown" })
        local view = require("review_notes.thread")
        view.decorate(ctx.preview.win.buf, lines)
        view.style(ctx.preview.win.win)
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
        review_read = function(picker, item)
          if item then require("review_notes").item_action(item, "read") end
          picker:find()
        end,
      },
      win = {
        input = {
          keys = {
            ["<a-r>"] = { "review_resolve", mode = { "n", "i" }, desc = "resolve / reopen" },
            ["<a-m>"] = { "review_read", mode = { "n", "i" }, desc = "mark read" },
          },
        },
      },
    },
  },
},
```

Open it with `Snacks.picker.review_notes()`.

</details>

## Statusline

`require("review_notes").status()` returns, for the current review, the open
entries in each state (new, note, thread, draft) and how many things a push
would send. It only reads cached counts, so it is cheap to call on every
redraw. For example, with lualine:

```lua
sections = {
  lualine_x = { function() return require("review_notes").status() end },
}
```

## Signs and highlights

Icons and highlight groups are in `require("review_notes").style`. Each kind
(`note`, `thread`, `draft`, `new`, `send`, `resolved`) has an `icon` and an
`hl`. The highlight groups are defined with `default = true`, so your
colorscheme or config can override them:

`ReviewNote`, `ReviewThread`, `ReviewDraft`, `ReviewNew`, `ReviewSend`,
`ReviewResolved`, `ReviewText`.

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
git-lab mr target                # the target branch of the current MR
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

- `/review [request]` reviews the code and adds its findings as `[draft]`
  notes for you to approve.
- `/fixup [scope]` addresses the open notes. Notes on code become `fixup!`
  commits, handled notes are resolved with a reply, and unclear ones get a
  question instead of a chat round-trip.

Entries pi adds or changes are tagged `[new]`, so after a round you see what
to look at. To install it, link or copy it into `~/.pi/agent/extensions/`.

## Development

```sh
make test
```

The tests need [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). They
look for it in lazy.nvim's data directory; set `PLENARY=/path/to/plenary.nvim`
to use another copy. The specs run against a fake backend in
`tests/fixtures/backend.sh`, so they never touch GitLab.
