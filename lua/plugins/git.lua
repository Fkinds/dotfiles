-- vim-fugitive: ノーマルモードの : から Git コマンドを直接叩けるようにする。
-- 例: :Git, :Git status, :Git commit, :Git push, :Git blame, :Git log
-- cmd 指定により、これらのコマンドが呼ばれた時に遅延ロードされる。
-- 実際のキーマップは lua/config/keymaps.lua の "Git keymaps" 節で定義している。
return {
  "tpope/vim-fugitive",
  cmd = { "Git", "G", "Gdiffsplit", "Gread", "Gwrite", "Gedit", "Gblame", "GBrowse" },
}
