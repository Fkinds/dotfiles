-- 保存したときに mypy を走らせ、結果を診断としてバッファに出す（nvim-lint は LazyVim に同梱）。
-- 対象は mypy を dev 依存に入れたプロジェクトだけ。使っていないプロジェクトで走らせても、
-- スタブの無いライブラリの import エラーが並ぶだけなので。
-- 厳しさはプロジェクトの [tool.mypy] に従う。--strict で見たいときは <leader>ct（terminal.lua）。

-- file を含む uv プロジェクトのルートを返す。.venv に mypy が無ければ nil。
local function mypy_root(file)
  local root = vim.fs.root(file, { "pyproject.toml" })
  if root and vim.uv.fs_stat(root .. "/.venv/bin/mypy") then
    return root
  end
  return nil
end

return {
  "mfussenegger/nvim-lint",
  opts = {
    linters_by_ft = { python = { "mypy" } },
    linters = {
      mypy = {
        -- mypy はディスク上のファイルを読むので、未保存の変更があると行番号がずれる。
        -- LazyVim は InsertLeave でも lint を起動するため、保存済みのときだけ走らせる。
        condition = function(ctx)
          return not vim.bo.modified and mypy_root(ctx.filename) ~= nil
        end,
        -- ルートで実行して [tool.mypy] を読ませる。nvim の cwd がルートとずれても
        -- nvim-lint がファイルを照合できるよう、絶対パスで出力させる。
        -- lint のたびに環境を書き換えないよう --no-sync を付ける。
        cmd = "uv",
        prepend_args = {
          "run",
          "--no-sync",
          "--directory",
          function()
            return mypy_root(vim.api.nvim_buf_get_name(0))
          end,
          "mypy",
          "--show-absolute-path",
        },
      },
    },
  },
}
