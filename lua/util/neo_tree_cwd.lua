-- neo-tree の filesystem ソースが現在表示しているルートディレクトリを返す。
-- bind_to_cwd = true のため通常は cwd と一致するが、state.path を直接見ることで
-- neo-tree 上での移動にも追従する。取得できない場合は cwd にフォールバックする。
local M = {}

---@return string
function M.path()
  local ok, manager = pcall(require, "neo-tree.sources.manager")
  local path
  if ok then
    local state = manager.get_state("filesystem")
    if state and state.path then
      path = state.path
    end
  end
  path = path or vim.uv.cwd() or ""
  if path == "" then
    return ""
  end
  -- フルパスは長いので ~ 表記に短縮する
  return vim.fn.fnamemodify(path, ":~")
end

return M
