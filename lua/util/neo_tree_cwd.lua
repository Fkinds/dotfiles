-- neo-tree の filesystem ソースが現在表示しているルートディレクトリを返す。
-- 表示中のルートは state.path。bind_to_cwd = true のため cwd と同期するが、
-- neo-tree はウィンドウ/タブローカルの cwd を見る（getcwd(winid, tabnr)）ため、
-- グローバル cwd ではなく neo-tree 自身の get_cwd でフォールバックする。
local M = {}

-- 表示中ルートの生の絶対パスを返す（~ 短縮なし）。相対パス計算の基準に使う。
-- 取得できない場合はグローバル cwd、それも無ければ空文字列。
---@return string
function M.root()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  local path
  if ok then
    local state = manager.get_state("filesystem")
    if state then
      -- 表示中ルートを最優先。未設定なら neo-tree のローカル cwd 解決に委譲する。
      path = state.path
      if not path or path == "" then
        path = manager.get_cwd(state)
      end
    end
  end
  return path or vim.fn.getcwd() or ""
end

---@return string
function M.path()
  local path = M.root()
  if path == "" then
    return ""
  end
  -- フルパスは長いので ~ 表記に短縮する
  return vim.fn.fnamemodify(path, ":~")
end

return M
