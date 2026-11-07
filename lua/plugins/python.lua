return {
  -- uv プロジェクトの Python バージョンを lualine に表示する。
  -- 判定ロジックは noice の cmdline プレフィックスと共有する（lua/util/python_version.lua）。
  {
    "nvim-lualine/lualine.nvim",
    optional = true,
    opts = function(_, opts)
      local python_version = require("util.python_version").get

      table.insert(opts.sections.lualine_x, 1, {
        python_version,
        icon = "󰌠",
        cond = function()
          return vim.bo.filetype == "python" and python_version() ~= ""
        end,
      })
    end,
  },
  -- ty の LSP を止める（理由は config/options.lua の vim.g.lazyvim_python_lsp のコメント）。
  -- lang.python extra が切り替えるのは pyright / basedpyright / ruff だけで、
  -- Mason に入っている ty は mason-lspconfig が自動で有効にしてしまうため。
  -- CLI の `uv run ty check`（<leader>cu）はこの設定と関係なく使える。
  {
    "neovim/nvim-lspconfig",
    opts = { servers = { ty = { enabled = false } } },
  },
}
