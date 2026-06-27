-- コマンドラインを中央ポップアップではなく、従来どおり画面最下部に表示する
return {
  "folke/noice.nvim",
  opts = {
    cmdline = {
      view = "cmdline",
    },
  },
}
