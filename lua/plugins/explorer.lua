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
        -- cwd にルートを固定しない。開いたファイルに追従させる（下記参照）
        bind_to_cwd = false,
        -- 現在のバッファのファイルをツリー内で展開・ハイライトして追従する
        follow_current_file = { enabled = true, leave_dirs_open = false },
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
