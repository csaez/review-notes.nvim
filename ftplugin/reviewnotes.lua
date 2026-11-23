-- Entries are one logical line plus indented continuations. Hard wrapping
-- (textwidth) would break a long note into an unindented line, which the
-- parser reads as a general note of its own, so wrap on screen only.
vim.bo.textwidth = 0
vim.wo[0][0].wrap = true
vim.wo[0][0].linebreak = true
