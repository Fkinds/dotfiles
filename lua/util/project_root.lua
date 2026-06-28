-- 開いたファイルが属するプロジェクトの root を判定するヘルパ。
-- neo-tree の bind_to_cwd = false と組み合わせ、ルートをプロジェクト単位で追従させる。
--
-- 判定の優先順位:
--   1. M.pins に明示登録した root（最長一致）。モノレポ全体を1つの root に固定したい等の上書き用。
--   2. フォールバックで .git のあるディレクトリ（= git リポジトリのルート）を自動検出。
--      → gh / git clone したリポジトリは登録不要で自動的に root になる。
local M = {}

-- 明示的にピン留めする root（任意）。通常は空でよい。
-- 例: git リポジトリのサブディレクトリも親をまとめて1つの root にしたい場合などに使う。
M.pins = {}

-- root として扱いたくないディレクトリ。ここ（およびその配下）では追従しない。
-- 例: nvim 設定自体も git リポジトリだが、編集中にツリーを切り替えたくない。
M.excludes = {
  "~/.config/nvim",
}

---@param path string
---@return string
local function normalize(path)
  return vim.fs.normalize(vim.fn.expand(path))
end

-- ピン留めのうち path を含む最長一致の root を返す。なければ nil。
---@param path string
---@return string|nil
local function match_pin(path)
  local best
  for _, pin in ipairs(M.pins) do
    local root = normalize(pin)
    if path == root or path:sub(1, #root + 1) == root .. "/" then
      if not best or #root > #best then
        best = root
      end
    end
  end
  return best
end

-- path が属するプロジェクト root を返す。属さなければ nil。
---@param path string
---@return string|nil
function M.find(path)
  path = normalize(path)
  -- 除外ディレクトリ配下なら追従しない
  for _, exclude in ipairs(M.excludes) do
    local dir = normalize(exclude)
    if path == dir or path:sub(1, #dir + 1) == dir .. "/" then
      return nil
    end
  end
  -- 1. ピン留め優先
  local pinned = match_pin(path)
  if pinned then
    return pinned
  end
  -- 2. .git を上方向に探索（git リポジトリのルート = 自動登録）
  local git = vim.fs.root(path, ".git")
  return git and normalize(git) or nil
end

return M
