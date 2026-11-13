# review-notes.nvim

Code review notes for Neovim, kept in a plain text file outside the code and
synced with a remote through command lines you configure. The default backend
is `git-lab` (dotfiles `bin/git-lab`).

- A file in a git worktree belongs to its branch's review,
  `.git/review/<branch>.txt`, synced with the backend.
- Any other file (a markdown draft, pi's plans) has its own review in a
  sibling `<file>.notes` (e.g. `doc.md.notes`), local only: no backend,
  `:Review sync` has nothing to do.

- Notes show in the gutter with their own signs, follow the code while you edit.
- Notes are written in a small markdown float under the code (`add`): `<CR>`
  or `:w` sends, `q` closes and keeps the text as a draft. On a note it edits
  my latest text: the whole note until someone answers, then my reply.
- `:Review sync` (push, then pull), `push`, `pull`, `clean`.
- Tags: `[resolved]`, `[draft]` (pending, never sent), `[id:X]` (remote
  thread), `[new]` (changed on the remote since the last pull; stays until you
  reply to the thread or resolve it).
- File format: see the header of `lua/review_notes/notes.lua`.
- Backend contract: see `M.config` in `lua/review_notes/init.lua`.

Tests: `make test` (needs plenary.nvim in lazy's data directory; set `PLENARY`
to use another location). `:checkhealth review_notes` checks that git and the backend
commands are available.

## Picker

The plugin has no picker of its own. `require("review_notes").items(buf)`
returns the notes of the buffer's review, ready for any picker: each item has `file`, `line`,
`end_line`, `icon`, `hl`, `summary`, `summary_hl` and a searchable `text`
(kind, state, path, note). Call `require("review_notes").goto_item(item)` to
jump to one.
