-- ファイルアイコンを絵文字路線で全体的にオシャレに統一する。
-- LazyVim は mini.icons を使う（nvim-web-devicons は mock 経由）。
-- lualine の filetype アイコンは filetype カテゴリ、neo-tree / picker は
-- extension / file カテゴリを引くため、同じ見た目になるよう各カテゴリを揃えて上書きする。
--
-- 追加・変更したい時は下の表に1行足すだけ。glyph と hl(色) を渡す。
-- hl は mini.icons 標準の MiniIcons<Color> 群（Red/Green/Blue/Yellow/Cyan/
-- Azure/Orange/Purple/Grey）から選ぶ。絵文字自体に色があるため hl は補助的。

---@param glyph string
---@param hl string
---@return { glyph: string, hl: string }
local function icon(glyph, hl)
  return { glyph = glyph, hl = hl }
end

-- 言語: filetype と主要拡張子の両方を同じアイコンに揃える。
-- { filetype, { ext, ... }, glyph, hl }
local languages = {
  { "python", { "py", "pyi" }, "🐍", "MiniIconsYellow" },
  { "lua", { "lua" }, "📜", "MiniIconsAzure" },
  { "rust", { "rs" }, "🦀", "MiniIconsOrange" },
  { "go", { "go" }, "🐹", "MiniIconsCyan" },
  { "ruby", { "rb" }, "💎", "MiniIconsRed" },
  { "typescript", { "ts" }, "📘", "MiniIconsBlue" },
  { "javascript", { "js", "mjs", "cjs" }, "📒", "MiniIconsYellow" },
  { "tsx", { "tsx" }, "⚛️", "MiniIconsCyan" },
  { "jsx", { "jsx" }, "⚛️", "MiniIconsYellow" },
  { "html", { "html", "htm" }, "🌐", "MiniIconsOrange" },
  { "css", { "css" }, "🎨", "MiniIconsBlue" },
  { "scss", { "scss", "sass" }, "🎨", "MiniIconsRed" },
  { "vim", { "vim" }, "💚", "MiniIconsGreen" },
  { "sh", { "sh", "bash", "zsh", "fish" }, "🐚", "MiniIconsGreen" },
  { "sql", { "sql" }, "🗃️", "MiniIconsBlue" },
  { "markdown", { "md", "mdx" }, "📝", "MiniIconsGrey" },
}

-- 拡張子のみ（設定 / データ系）。
local extensions = {
  json = icon("📦", "MiniIconsYellow"),
  jsonc = icon("📦", "MiniIconsYellow"),
  toml = icon("⚙️", "MiniIconsGrey"),
  yaml = icon("📑", "MiniIconsPurple"),
  yml = icon("📑", "MiniIconsPurple"),
  ini = icon("⚙️", "MiniIconsGrey"),
  conf = icon("⚙️", "MiniIconsGrey"),
  cfg = icon("⚙️", "MiniIconsGrey"),
  env = icon("🔐", "MiniIconsYellow"),
  xml = icon("📰", "MiniIconsOrange"),
  csv = icon("📊", "MiniIconsGreen"),
  tsv = icon("📊", "MiniIconsGreen"),
  txt = icon("📄", "MiniIconsGrey"),
  pdf = icon("📕", "MiniIconsRed"),
  png = icon("🖼️", "MiniIconsPurple"),
  jpg = icon("🖼️", "MiniIconsPurple"),
  jpeg = icon("🖼️", "MiniIconsPurple"),
  svg = icon("🖼️", "MiniIconsYellow"),
  gif = icon("🖼️", "MiniIconsCyan"),
  zip = icon("🗜️", "MiniIconsGrey"),
  tar = icon("🗜️", "MiniIconsGrey"),
  gz = icon("🗜️", "MiniIconsGrey"),
  log = icon("📜", "MiniIconsGrey"),
}

-- ファイル名で一意に決まるもの（特別扱い）。
local files = {
  [".gitignore"] = icon("🌿", "MiniIconsOrange"),
  [".gitattributes"] = icon("🌿", "MiniIconsOrange"),
  [".gitconfig"] = icon("🌿", "MiniIconsOrange"),
  [".env"] = icon("🔐", "MiniIconsYellow"),
  ["README.md"] = icon("📖", "MiniIconsBlue"),
  ["LICENSE"] = icon("⚖️", "MiniIconsGrey"),
  ["Dockerfile"] = icon("🐳", "MiniIconsCyan"),
  ["docker-compose.yml"] = icon("🐳", "MiniIconsCyan"),
  ["docker-compose.yaml"] = icon("🐳", "MiniIconsCyan"),
  ["Makefile"] = icon("🔨", "MiniIconsOrange"),
  ["package.json"] = icon("📦", "MiniIconsRed"),
  ["pyproject.toml"] = icon("🐍", "MiniIconsYellow"),
  ["tsconfig.json"] = icon("📘", "MiniIconsBlue"),
  ["lazy-lock.json"] = icon("🔒", "MiniIconsGrey"),
}

-- filetype（dockerfile など拡張子を持たないもの含む）。
local filetype = {
  dockerfile = icon("🐳", "MiniIconsCyan"),
  gitcommit = icon("🌿", "MiniIconsGreen"),
  text = icon("📄", "MiniIconsGrey"),
}

-- languages 表を filetype / extension の各カテゴリへ展開する。
for _, lang in ipairs(languages) do
  local ft, exts, glyph, hl = lang[1], lang[2], lang[3], lang[4]
  filetype[ft] = icon(glyph, hl)
  for _, ext in ipairs(exts) do
    extensions[ext] = icon(glyph, hl)
  end
end

return {
  "nvim-mini/mini.icons",
  optional = true,
  opts = {
    filetype = filetype,
    extension = extensions,
    file = files,
  },
}
