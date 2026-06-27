return {
  -- snacks explorerを無効化
  {
    "folke/snacks.nvim",
    opts = {
      explorer = { enabled = false },
    },
  },
  -- neo-treeを有効化
  {
    "nvim-neo-tree/neo-tree.nvim",
    opts = {
      filesystem = {
        bind_to_cwd = true,
        follow_current_file = { enabled = true },
        filtered_items = {
          visible = true,         -- 隠しファイルを表示
          hide_dotfiles = false,  -- .ファイルを隠さない
          hide_gitignored = false,
        },
      },
      window = {
        mappings = {
          ["<cr>"] = "open",
          ["o"] = "open",
          ["l"] = "open",
        },
      },
    },
  },
}
