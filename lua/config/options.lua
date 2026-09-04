-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Ensure ~/.local/bin is in PATH for uv and other tools
vim.env.PATH = vim.env.HOME .. "/.local/bin:" .. vim.env.PATH

-- Python: LSP/型チェッカーに basedpyright を使う（pyright/ty は無効化）
-- ty は Django の TextChoices（ChoicesType メタクラス）を解釈できず、
-- `State.QUEUED` を tuple[str, str] と誤検知する（astral-sh/ty#3535, open）。
-- basedpyright は django-stubs を読んで正しく enum メンバーとして解決する。
-- ※ django-stubs を含むプロジェクト venv を basedpyright が参照する必要がある。
-- lang.python extra がこの値を読み、対応する LSP に切り替える。
vim.g.lazyvim_python_lsp = "basedpyright"

local opt = vim.opt

-- 日本語: スペルチェックで CJK 文字を対象外にする（無害・snacks と非干渉）
-- ※ ambiwidth=double は snacks のフロート（通知/ピッカー）と E1512 で衝突するため使わない
opt.spelllang:append("cjk")

-- 個人の好み
opt.colorcolumn = "80"
opt.scrolloff = 10

-- プロジェクトローカル設定（repo 直下の .nvim.lua）を読み込む
-- 初回は信頼確認が出るので :trust で許可する（:h exrc / :h trust）
opt.exrc = true

-- ウィンドウ境界を二重線で描く。LazyVim が fold 用に設定済みの fillchars へ
-- 境界文字だけを足す（:h fillchars）。交差点（╬ ╣ ╠ ╦ ╩）まで指定しないと、
-- 分割が増えたときに線が繋がらず途切れて見える。
-- 線の色は config/autocmds.lua で配色に合わせて上げている。
opt.fillchars:append({
  vert = "║",
  horiz = "═",
  verthoriz = "╬",
  vertleft = "╣",
  vertright = "╠",
  horizdown = "╦",
  horizup = "╩",
})

-- 補完・ホバー・通知などフロートの枠も同じ二重線に揃える（nvim 0.11+）。
-- プラグインが border を明示している場合はそちらが優先されるので、
-- toggleterm など個別指定が要るものは各 plugins/*.lua で合わせる。
vim.o.winborder = "double"
