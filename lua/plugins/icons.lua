-- Python のアイコンをオシャレなヘビ 🐍 にする。
-- LazyVim は mini.icons を使う（nvim-web-devicons は mock 経由）。
-- lualine の filetype アイコンは filetype カテゴリ、neo-tree / picker は extension /
-- file カテゴリを引くため、両方を上書きして表示を揃える。
local snake = { glyph = "🐍", hl = "MiniIconsYellow" }

return {
  "nvim-mini/mini.icons",
  optional = true,
  opts = {
    filetype = {
      python = snake,
    },
    extension = {
      py = snake,
      pyi = snake,
    },
  },
}
