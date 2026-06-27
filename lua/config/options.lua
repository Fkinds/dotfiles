-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Ensure ~/.local/bin is in PATH for uv and other tools
vim.env.PATH = vim.env.HOME .. "/.local/bin:" .. vim.env.PATH
