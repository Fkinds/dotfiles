-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Ensure ~/.local/bin is in PATH for uv and other tools
vim.env.PATH = vim.env.HOME .. "/.local/bin:" .. vim.env.PATH

-- Python: pyright ではなく ty（Astral 製、ruff と同じエコシステム）を LSP/型チェッカーに使う
-- lang.python extra がこの値を読み、pyright を無効化して ty + ruff に切り替える
vim.g.lazyvim_python_lsp = "ty"

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
