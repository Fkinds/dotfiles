-- コマンドラインを中央ポップアップではなく、従来どおり画面最下部に表示する。
-- さらに「:」コマンドライン先頭に「Python アイコン + uv の Python バージョン」を
-- プレフィックスとして表示する。
--
-- noice は cmdline format の icon を毎レンダリングで config から読み直すため、
-- icon 文字列を更新するだけで動的なプレフィックスになる。プロジェクトや作業ディレクトリが
-- 変わるタイミング（DirChanged / BufEnter）でのみ再計算すれば十分。
local python_version = require("util.python_version")
local neo_tree_cwd = require("util.neo_tree_cwd")

-- noice の treesitter ハイライトをバッファ境界内にクランプするガード。
--
-- noice は cmdline / 通知のシンタックスハイライト範囲を「行末からの相対オフセット
-- （-strlen(cmd)）」などで計算するため、cmdline 先頭に icon プレフィックスを足すと
-- 列がずれ、空コマンドや再描画の過渡状態でバッファ長を超えた範囲を treesitter に
-- 渡してしまう。nvim 0.12 系の treesitter はこれを厳格に弾き、languagetree.lua の
-- "Range value out of bounds" / "Index out of bounds" を投げる。その結果「:」を
-- 押すたびに noice のエラーが出る（エラー通知の再描画でも連鎖する）。
--
-- vim シンタックスハイライト自体は残したいので、範囲をバッファ境界内へクランプして
-- から本来の highlight を呼ぶ。正しい範囲ならそのまま色付けされ、はみ出した範囲は
-- 安全に切り詰められてクラッシュしない。
local function install_highlight_guard()
  local ok, ts = pcall(require, "noice.text.treesitter")
  if not ok or ts.__range_guard then
    return
  end
  ts.__range_guard = true

  local orig = ts.highlight
  ts.highlight = function(buf, ns, range, lang)
    buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
    local ok_buf, nlines = pcall(vim.api.nvim_buf_line_count, buf)
    if ok_buf and type(range) == "table" and #range >= 4 then
      local function line_len(row)
        local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
        return line and #line or 0
      end
      local srow = math.max(0, math.min(range[1], nlines - 1))
      local erow = math.max(srow, math.min(range[3], nlines - 1))
      local scol = math.max(0, math.min(range[2], line_len(srow)))
      local ecol = math.max(scol, math.min(range[4], line_len(erow)))
      range = { srow, scol, erow, ecol }
    end
    -- 念のため pcall でも保護（クランプで取り切れない異常範囲でも落とさない）。
    pcall(orig, buf, ns, range, lang)
  end
end

-- 現在バッファのファイルパスを返す。
-- neo-tree のルート（`.` で確定したディレクトリ）配下なら、そのルート起点の
-- 相対パスに固定して表示する。例: ルート ~/Work/poker のとき
--   ~/Work/poker/backend/views.py → "./backend/views.py"
--   ルートそのもの               → "."
-- ルート外 / ルート取得失敗時は従来どおり末尾2階層（親フォルダ + ファイル名）。
-- 通常ファイル以外（neo-tree・ターミナル・無名バッファ等）は空文字列。
local function current_file_path()
  if vim.bo.buftype ~= "" then
    return ""
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" then
    return ""
  end
  name = vim.fn.fnamemodify(name, ":p") -- 絶対パスに正規化

  -- neo-tree ルート起点の相対パスに固定する。
  local root = neo_tree_cwd.root()
  if root ~= "" then
    root = vim.fn.fnamemodify(root, ":p"):gsub("/$", "") -- 末尾スラッシュを除去
    if name == root then
      return "."
    end
    local prefix = root .. "/"
    if name:sub(1, #prefix) == prefix then
      return "./" .. name:sub(#prefix + 1)
    end
  end

  -- ルート外 / 取得失敗時のフォールバック: 末尾2階層
  local tail = vim.fn.fnamemodify(name, ":t") -- checkout.py
  local parent = vim.fn.fnamemodify(name, ":h:t") -- examples
  if parent == "" or parent == "." then
    return tail
  end
  return parent .. "/" .. tail
end

-- 「:」cmdline 先頭に出すプレフィックス文字列を組み立てる。
-- 「Python アイコン + uv のバージョン」と「ファイルパス」を、それぞれ判定できたものだけ
-- スペース区切りで並べる。どちらも無いときは nil を返し、プレフィックスを出さない。
local function cmdline_prefix()
  local parts = {}
  local version = python_version.get()
  if version ~= "" then
    table.insert(parts, "󰌠 " .. version)
  end
  local path = current_file_path()
  if path ~= "" then
    table.insert(parts, path)
  end
  if #parts == 0 then
    return nil
  end
  return " " .. table.concat(parts, "  ") .. " "
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
    install_highlight_guard()

    opts.cmdline = opts.cmdline or {}
    opts.cmdline.view = "cmdline"
    opts.cmdline.format = opts.cmdline.format or {}
    -- デフォルトの「:」format（lang="vim" でシンタックスハイライト）を引き継ぎつつ、
    -- 初期 icon にプレフィックスを設定する。範囲はみ出しは install_highlight_guard で防ぐ。
    opts.cmdline.format.cmdline = vim.tbl_extend("force", {
      pattern = "^:",
      lang = "vim",
    }, opts.cmdline.format.cmdline or {}, { icon = cmdline_prefix() })

    -- CmdlineEnter: neo-tree の `.`（set_root）は bind_to_cwd=false のため cwd を
    -- 変えず DirChanged が出ない。`:` を開く直前に再計算すれば最新ルートを必ず拾える。
    vim.api.nvim_create_autocmd({ "DirChanged", "BufEnter", "CmdlineEnter" }, {
      group = vim.api.nvim_create_augroup("noice_cmdline_prefix", { clear = true }),
      callback = refresh_cmdline_prefix,
    })
  end,
}
