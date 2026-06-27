-- uv プロジェクトの Python バージョンを lualine に表示する。
-- venv を有効化していなくても、pyproject.toml のあるルートから判定して表示する。
-- バージョンの取得元（優先順）:
--   1. 有効な $VIRTUAL_ENV/pyvenv.cfg（activate or venv-selector 済みのとき）
--   2. <project>/.venv/pyvenv.cfg（uv が作る venv）
--   3. <project>/.python-version（uv がピン留めするファイル）
-- いずれも python を起動せずファイルを読むだけなので軽量。結果はパス単位でキャッシュ。
return {
  "nvim-lualine/lualine.nvim",
  optional = true,
  opts = function(_, opts)
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

    local function python_version()
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

    table.insert(opts.sections.lualine_x, 1, {
      python_version,
      icon = "󰌠",
      cond = function()
        return vim.bo.filetype == "python" and python_version() ~= ""
      end,
    })
  end,
}
