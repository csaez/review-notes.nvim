-- Sibling notes of files outside git (`doc.md.notes`), see init.lua.
vim.filetype.add({ extension = { notes = "reviewnotes" } })

-- Thread buffers (compose float, picker panel) are markdown to treesitter.
vim.treesitter.language.register("markdown", "reviewthread")
