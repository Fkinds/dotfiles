-- uv プロジェクトの Python バージョンを判定する共有ユーティリティ。
-- lualine と noice の cmdline プレフィックスの両方から利用する（DRY）。
--
-- venv を有効化していなくても、pyproject.toml のあるルートから判定する。
-- バージョンの取得元（優先順）:
--   1. 有効な $VIRTUAL_ENV/pyvenv.cfg（activate or venv-selector 済みのとき）
--   2. <project>/.venv/pyvenv.cfg（uv が作る venv）
--   3. <project>/.python-version（uv がピン留めするファイル）
-- いずれも python を起動せずファイルを読むだけなので軽量。結果はパス単位でキャッシュ。
local M = {}

local cache = {}

local function read_pyvenv_version(venv_dir)
  local file = io.open(venv_dir .. "/pyvenv.cfg", "r")
  if not file then
    return nil
  end
  -- 標準 venv は `version = X`、uv / virtualenv は `version_info = X` を書く
  local version
  for line in file:lines() do
    version = line:match("^%s*version_info%s*=%s*(.+)$") or line:match("^%s*version%s*=%s*(.+)$")
    if version then
      break
    end
  end
  file:close()
  return version and vim.trim(version) or nil
end

local function read_python_version_file(root)
  local file = io.open(root .. "/.python-version", "r")
  if not file then
    return nil
  end
  local line = file:read("*l")
  file:close()
  return line and vim.trim(line) ~= "" and vim.trim(line) or nil
end

-- 現在のバッファ（または cwd）が属するプロジェクトの Python バージョンを返す。
-- 判定できない場合は空文字列を返す。
function M.get()
  local root = vim.fs.root(0, { "pyproject.toml", ".python-version", ".git" })
  local key = root or vim.env.VIRTUAL_ENV or ""
  if cache[key] == nil then
    local version = false
    if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
      version = read_pyvenv_version(vim.env.VIRTUAL_ENV) or version
    end
    if not version and root then
      version = read_pyvenv_version(root .. "/.venv") or read_python_version_file(root) or version
    end
    cache[key] = version
  end
  return cache[key] or ""
end

return M
