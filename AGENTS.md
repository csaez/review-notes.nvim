# AGENTS.md

Neovim plugin (Lua) for code review kept in a markdown notes file, plus two
optional extras: a GitLab backend (`extras/git-lab`, Python) and a pi agent
extension (`extras/pi/review-notes.ts`).

## Read first

- [DESIGN.md](DESIGN.md): the model, the invariants (safe pull, safe
  publish), the module layout. Read before changing behavior.
- [WORKFLOWS.md](WORKFLOWS.md): the workflows the plugin serves and the known
  gaps. Check a change against them.
- The module header comments in `lua/review_notes/*.lua` say what each
  module owns; exact contracts live in code:
  - notes file grammar: top of `store.lua`
  - backend contract (operations, JSON, exit statuses): `config.lua`
  - keys of the sidebar: declarations in `list.lua` / `thread.lua`, bound
    and drawn by `keys.lua`

## Invariants (do not break)

- Pull never sends anything and never touches local, proposed or private
  comments, or unpublished status changes.
- Publish is explicit, shows its plan, and submits exactly the drafts it
  created; a retry must not post twice.
- Private threads and comments never reach the backend.
- The notes file format stays compatible (agents and humans write it);
  commands, keymaps and options may change freely.
- No global keymaps. The sidebar never shows a code buffer.
- `store.lua` and `merge.lua` stay free of Neovim APIs (pure, unit tested).
- A verb is implemented once in `actions.lua`; every change goes through
  `review.edit` so listeners refresh. Don't refresh UIs by hand.
- Only `backend.lua` spawns backend commands; nothing in `lua/` requires
  `extras/`.

## Build and test

```sh
make test   # plenary.nvim, headless; PLENARY=/path to override
```

Specs are in `tests/*_spec.lua` and use the fake backend
`tests/fixtures/backend.sh` (never GitLab). Add a spec for behavior changes:
pure logic in `merge_spec` / `store_spec`, end-to-end in `flow_spec`.

Lua types are LuaLS annotations (`.emmyrc.json`); keep them on new
functions. `extras/git-lab` must stay a single file with no dependencies
beyond the Python 3.10 standard library.

## Docs

- DESIGN.md describes the design as it is now, not a history: update it in
  the same change when a principle, rule or module responsibility changes.
  Leave detail (keys, formats, options) to the code and README.
- README.md is user documentation: keep it short; link to code for
  contracts.
- WORKFLOWS.md: update the steps and gaps when a change closes or opens one.
- The pi extension mirrors parts of the model (comment sources, whose turn,
  notes path); change both sides together.
