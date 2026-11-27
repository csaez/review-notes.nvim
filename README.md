# review-notes.nvim

Code review for Neovim that lives in a plain text file, not in your code. The
threads of a review (yours, your peers', an agent's) are in one place, a
sidebar next to your code, and one markdown file ties them to the merge
request on the remote.

Reading never sends anything. You pull to see what changed, write comments
locally, and publish when you are ready. Because the notes are markdown,
scripts and coding agents can read and answer them too.

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

## Features

- **A sidebar for the review.** Every thread by urgency (unread, proposed,
  not published, open, resolved), or one thread with its code next to it.
  It never takes your code's window; code buffers only get signs.
- **One kind of thread.** Comments on a line, a range, a file or the whole
  change all work the same way.
- **Safe pull.** Never sends, never touches your text; it also runs quietly
  on focus.
- **Deliberate publish.** Shows what it will send, asks, and sends it as one
  review (one notification).
- **Agents propose, you approve.** What a tool writes is never published
  until you approve it. Private comments are never published at all.
- **Notes outside the code.** One file per branch in the git dir, shared by
  worktrees. Anchors follow your edits.
- **Pluggable backend.** Remote work goes through command lines you
  configure; a GitLab one ships in `extras/`.

## Requirements

- Neovim 0.10+, git (2.38+ for checkpoints after a rebase)
- A [Nerd Font](https://www.nerdfonts.com/) for the default icons
- To sync: a backend, such as [git-lab](#extras)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "csaez/review-notes.nvim",
  lazy = false, -- signs are drawn when files open
  opts = {},
  keys = {
    { "<leader>rr", function() require("review_notes").toggle() end, desc = "Review: sidebar (the thread here, if any)" },
    { "<leader>rn", function() require("review_notes").new() end, mode = { "n", "x" }, desc = "Review: new thread" },
    { "<leader>rN", function() require("review_notes").new_change() end, desc = "Review: new thread on the change" },
    { "]r", function() require("review_notes").next(1) end, desc = "Review: next thread (unread first)" },
    { "[r", function() require("review_notes").next(-1) end, desc = "Review: previous thread" },
  },
}
```

The plugin sets no global keymaps. `:checkhealth review_notes` checks that
git and the backend commands are found.

## Quick start

1. Check out the branch under review and open a file.
2. `<leader>rr` opens the sidebar and pulls the merge request's threads.
3. `<CR>` on a thread shows it, with its code on the left. `r` replies, `x`
   resolves, `]t` moves on, `q` goes back (and closes from the list).
4. In the code, `<leader>rn` on a line or selection starts a thread; save
   with `<C-s>`.
5. `P` in the list shows what will be sent and sends it once you confirm.

## Usage

The sidebar's bottom bar shows the keys that apply to the thread at hand,
and `?` lists every key (press one to run it). The main ones:

| Key        | Where   | Does                                                   |
| ---------- | ------- | ------------------------------------------------------ |
| `<CR>` `o` | list    | show the thread (`o`: and go to the code)              |
| `r`        | both    | reply, or edit my unpublished reply                    |
| `x`        | both    | resolve / reopen                                       |
| `a` `d`    | both    | approve the proposed comment / discard unpublished text |
| `t`        | both    | make private (never published) / public                |
| `R`        | list    | mark read                                              |
| `p` `P`    | list    | pull / publish                                         |
| `n`        | list    | new thread on the whole change                         |
| `A` `D`    | list    | approve / discard every proposed comment               |
| `m`        | list    | MR actions (see Configuration)                         |
| `e`        | list    | edit the notes file                                    |
| `]t` `]u`  | thread  | next thread / next unread (`[` for previous)           |
| `q`        | both    | back one level                                         |

Thread keys in the list take a visual selection (`Vjjx` resolves three).
Search the list with `/`. In the composer, `<C-s>` or `:w` saves (nothing is
sent), `<C-t>` switches public / private, `q` closes.

Commands: `:Review` (the sidebar), `:Review thread`, `:Review pull`,
`:Review publish`, `:Review edit`.

The bottom bar is the sidebar's `statusline`, so exclude its filetypes from
your statusline plugin. For lualine:

```lua
options = {
  disabled_filetypes = {
    statusline = { "reviewlist", "reviewthread" },
    winbar = { "reviewlist", "reviewthread" },
  },
}
```

## How syncing works

The remote is the source of truth for the conversation; your side is what
you have not published.

- **Pull** updates remote comments and statuses and adds new threads. Your
  comments and unpublished resolves are never touched. It runs on its own
  when the last pull is older than `auto_pull` seconds; offline, it retries
  quietly and the list says so.
- **Publish** pulls first, lists what it would send (flagging replies to
  threads that changed meanwhile, a peer's approval, a checkout that differs
  from the MR's head) and asks. Retrying after a failure cannot post twice.
- **Proposed** comments are sent only once approved; **private** ones never.
- **Checkpoints.** My last publish and the agent's last fixup are recorded
  as diff bases ("what changed since"), replayed past a rebase; `bases()`
  in the API hands them to your own diff.

Details: [DESIGN.md](DESIGN.md).

## The notes file

`.git/review/<branch>.md` (in the main checkout's git dir), or
`<file>.review.md` beside a file outside git:

```markdown
# Review of feature/timeouts

## src/http.cpp:120-124 {id=abc123}
status: open

### @alice {id=12}
why 30s?

### me (proposed)
Matches the studio default, I added a comment above the constant.
```

Comments are `### @author` (remote), `### me (local)` (not published yet),
`### me (private)` (never published) or `### me (proposed)` (a tool's,
waiting for approval). Edit it by hand freely. The full grammar is at the
top of [`store.lua`](lua/review_notes/store.lua). The `<branch>.json` beside
it is safe to delete (everything shows as unread).

## Configuration

```lua
require("review_notes").setup({
  signs = true,    -- signs on the anchors
  watch = true,    -- redraw when the notes change on disk
  auto_pull = 60,  -- seconds between background pulls; false: manual only
  timeout = 30,    -- seconds before a backend command counts as offline
  backend = { ... }, -- command lines; defaults call git-lab
  mr = { ... },      -- MR header and `m` actions; false: none
})
```

Defaults and the backend contract (operations, JSON, exit statuses) are in
[`config.lua`](lua/review_notes/config.lua): write your own backend for
another forge from it.

**API.** `require("review_notes")` also offers `items(buf)` (every thread,
for your own picker), `open_item`, `goto_item`, `item_action`,
`bases(target)` (the MR target and the checkpoints, as revs to diff
against), and `status()`, a cheap statusline component. Icons and highlight groups
(`ReviewUnread`, `ReviewKey`, ...) are in `.style`, defined with
`default = true` so colorschemes can override them. See
[`init.lua`](lua/review_notes/init.lua).

## Extras

Optional, installed by hand; nothing in `lua/` requires them.

- **[`extras/git-lab`](extras/git-lab)**: a dependency-free Python 3.10+
  script for GitLab MRs, and the default backend. Put it on your `PATH`
  with `GITLAB_TOKEN` (`api` scope) set; `git-lab --help` lists its
  commands (`mr list`, `mr checkout`, `mr approve`, `comment list`, ...).
- **[`extras/pi/review-notes.ts`](extras/pi/review-notes.ts)**: a
  [pi](https://github.com/earendil-works/pi) extension. `/review` adds
  findings as proposed comments; `/fixup` answers the threads waiting on it
  (its own findings included: approval only gates publishing) with
  `fixup!` commits and proposed replies, on your own branch only.
  Link it into `~/.pi/agent/extensions/`.

## Development

```sh
make test   # needs plenary.nvim; PLENARY=/path overrides the lazy.nvim copy
```

The specs use a fake backend (`tests/fixtures/backend.sh`), never GitLab.
