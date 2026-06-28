-- neo-tree の filesystem ソースが現在表示しているルートディレクトリを返す。
-- 表示中のルートは state.path。bind_to_cwd = true のため cwd と同期するが、
-- neo-tree はウィンドウ/タブローカルの cwd を見る（getcwd(winid, tabnr)）ため、
-- グローバル cwd ではなく neo-tree 自身の get_cwd でフォールバックする。
local M = {}

---@return string
function M.path()
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
  path = path or vim.fn.getcwd() or ""
  if path == "" then
    return ""
  end
  -- フルパスは長いので ~ 表記に短縮する
  return vim.fn.fnamemodify(path, ":~")
end

return M
