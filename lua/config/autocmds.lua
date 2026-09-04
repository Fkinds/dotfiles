-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- lua-language-server の locale ローダーのクラッシュ修正を起動時に冪等適用する。
-- Mason 再インストールで消えるため設定側で永続化（詳細は util/lua_ls_locale_patch.lua）。
vim.api.nvim_create_autocmd("VimEnter", {
  group = vim.api.nvim_create_augroup("lua_ls_locale_patch", { clear = true }),
  once = true,
  callback = function()
    require("util.lua_ls_locale_patch").apply()
  end,
})

-- 登録プロジェクト（util/project_root.lua）の root にツリーを追従させる。
-- 開いたファイルがいずれかの登録プロジェクト配下なら、その root に neo-tree を切り替える。
-- neo-tree が既に開いている時だけ動かす（閉じている時に勝手に開かない）。
vim.api.nvim_create_autocmd("BufEnter", {
  group = vim.api.nvim_create_augroup("neotree_project_root", { clear = true }),
  callback = function(args)
    -- neo-tree 未ロードなら何もしない（強制ロードして起動を遅くしない）
    if not package.loaded["neo-tree.sources.manager"] then
      return
    end
    local file = vim.api.nvim_buf_get_name(args.buf)
    if file == "" or vim.bo[args.buf].buftype ~= "" then
      return
    end
    local root = require("util.project_root").find(file)
    if not root then
      return
    end
    local manager = require("neo-tree.sources.manager")
    local state = manager.get_state("filesystem")
    -- ツリーが開いている時だけ追従させる
    if not state or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
      return
    end
    -- 既に同じ root を表示中なら何もしない（チラつき防止）
    if state.path and vim.fs.normalize(state.path) == root then
      return
    end
    require("neo-tree.command").execute({
      action = "show", -- フォーカスは奪わない
      source = "filesystem",
      dir = root,
      reveal_file = file, -- ルート切替後に当該ファイルを展開・ハイライト
    })
  end,
})

-- cwd 変更（neo-tree のナビゲーション含む）で statusline を
-- 即時再描画し、neo-tree の表示中ディレクトリと lualine の表示をズレさせない。
vim.api.nvim_create_autocmd("DirChanged", {
  group = vim.api.nvim_create_augroup("refresh_lualine_on_dirchanged", { clear = true }),
  callback = function()
    local ok, lualine = pcall(require, "lualine")
    if ok then
      lualine.refresh()
    end
  end,
})

-- fugitive での git 操作（pull / merge / switch など）のあと、リモートで消えた
-- ブランチをローカルからも掃除する。git には他ブランチを消す hook がないので
-- fugitive の完了イベントに乗せる。消すものが無ければ無言（詳細は util/git_sweep.lua）。
vim.api.nvim_create_autocmd("User", {
  pattern = "FugitiveChanged",
  group = vim.api.nvim_create_augroup("git_sweep_after_fugitive", { clear = true }),
  callback = function()
    require("util.git_sweep").sweep({ quiet = true })
  end,
})

-- ウィンドウ境界の線を、フロートの枠と同じ色に揃える。
-- 既定の WinSeparator は Normal の背景より暗く（tokyonight-moon なら
-- fg=#1b1d2b に対して bg=#222436）、fillchars で二重線を指定しても線が
-- 引かれて見えない。配色側が「枠に使う色」として定義している FloatBorder
-- から借りるので、colorscheme を変えても破綻しない（tokyonight なら青）。
-- 配色の適用でハイライトは初期化されるため、切り替えのたびに掛け直す。
local function sync_border_hl()
  local accent = vim.api.nvim_get_hl(0, { name = "FloatBorder", link = false }).fg
    or vim.api.nvim_get_hl(0, { name = "Special", link = false }).fg
  if not accent then
    return
  end
  vim.api.nvim_set_hl(0, "WinSeparator", { fg = accent })
  -- neo-tree は winhighlight で WinSeparator を自前の名前に差し替えるため個別に要る
  vim.api.nvim_set_hl(0, "NeoTreeWinSeparator", { link = "WinSeparator" })
end

-- 配色の適用は autocmds.lua が読まれたあとに走り、ColorScheme のハンドラ内で
-- 設定しても配色側の nvim_set_hl に上書きされる。vim.schedule で一段遅らせて、
-- 適用処理が終わりきってから掛ける。
local function schedule_sync()
  vim.schedule(sync_border_hl)
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("mechanical_borders", { clear = true }),
  callback = schedule_sync,
})

schedule_sync()
