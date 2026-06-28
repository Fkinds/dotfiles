-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- lua-language-server の locale ローダーのクラッシュ修正を起動時に冪等適用する。
-- Mason 再インストールで消えるため設定側で永続化（詳細は util/lua_ls_locale_patch.lua）。
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("lua_ls_locale_patch", { clear = true }),
  once = true,
  callback = function()
    require("util.lua_ls_locale_patch").apply()
  end,
})
