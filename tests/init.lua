local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:append(root)
vim.opt.rtp:append(vim.env.PLENARY or (vim.fn.stdpath("data") .. "/lazy/plenary.nvim"))
vim.cmd("runtime plugin/plenary.vim")
