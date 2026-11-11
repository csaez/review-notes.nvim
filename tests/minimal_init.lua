-- Minimal runtime for the specs: this plugin plus plenary, nothing else.
local plenary = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.runtimepath:prepend(plenary)
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
vim.cmd("runtime plugin/plenary.vim")
