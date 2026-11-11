# review-notes.nvim

Code review notes for Neovim, kept in a plain text file outside the code
(`.git/review/<branch>.txt`) and synced with a remote through command lines
you configure. The default backend is `git-lab` (dotfiles `bin/git-lab`).

- Notes show in the gutter with their own signs, follow the code while you edit.
- `:Review sync` (push, then pull), `push`, `pull`, `clean`, `seen`.
- Tags: `[resolved]`, `[draft]` (pending, never sent), `[id:X]` (remote
  thread), `[new]` (changed on the remote since the last pull).
- File format: see the header of `lua/review_notes/notes.lua`.
- Backend contract: see `M.config` in `lua/review_notes/init.lua`.

Tests: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests {minimal_init='tests/minimal_init.lua'}"`
(needs plenary.nvim in lazy's data directory).

## Picker

`:lua require("review_notes").pick()` lists the notes with `vim.ui.select`. To
use another picker, set `picker = function(items, open) ... end` in `setup()`:
`items` carry `file`, `line`, `end_line`, `icon`, `hl`, `summary` and a
searchable `text` (kind, state, path, note); call `open(item)` to jump to one.
