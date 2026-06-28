-- コマンドラインを中央ポップアップではなく、従来どおり画面最下部に表示する。
-- さらに「:」コマンドライン先頭に「Python アイコン + uv の Python バージョン」を
-- プレフィックスとして表示する（色付けはしない）。
--
-- noice は cmdline format の icon を毎レンダリングで config から読み直すため、
-- icon 文字列を更新するだけで動的なプレフィックスになる。プロジェクトや作業ディレクトリが
-- 変わるタイミング（DirChanged / BufEnter）でのみ再計算すれば十分。
local python_version = require("util.python_version")

-- 「:」cmdline 先頭に出すプレフィックス文字列を組み立てる。
-- 表示するのは Python アイコン + uv のバージョンのみ。
-- Python バージョンを判定できないプロジェクトでは nil を返し、プレフィックスを出さない。
local function cmdline_prefix()
  local version = python_version.get()
  if version == "" then
    return nil
  end
  return " 󰌠 " .. version .. " "
end

-- 現在の状態に合わせて noice の cmdline icon を更新する。
local function refresh_cmdline_prefix()
  local ok, config = pcall(require, "noice.config")
  if not ok then
    return
  end
  local format = config.options.cmdline and config.options.cmdline.format
  if format and format.cmdline then
    format.cmdline.icon = cmdline_prefix()
  end
end

return {
  "folke/noice.nvim",
  opts = function(_, opts)
    opts.cmdline = opts.cmdline or {}
    opts.cmdline.view = "cmdline"
    opts.cmdline.format = opts.cmdline.format or {}
    -- デフォルトの「:」format を引き継ぎつつ、初期 icon にプレフィックスを設定する
    opts.cmdline.format.cmdline = vim.tbl_extend("force", {
      pattern = "^:",
      lang = "vim",
    }, opts.cmdline.format.cmdline or {}, { icon = cmdline_prefix() })

    vim.api.nvim_create_autocmd({ "DirChanged", "BufEnter" }, {
      group = vim.api.nvim_create_augroup("noice_cmdline_prefix", { clear = true }),
      callback = refresh_cmdline_prefix,
    })
  end,
}
