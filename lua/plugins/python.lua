-- uv プロジェクトの Python バージョンを lualine に表示する。
-- 判定ロジックは noice の cmdline プレフィックスと共有する（lua/util/python_version.lua）。
return {
  "nvim-lualine/lualine.nvim",
  optional = true,
  opts = function(_, opts)
    local python_version = require("util.python_version").get

    table.insert(opts.sections.lualine_x, 1, {
      python_version,
      icon = "󰌠",
      cond = function()
        return vim.bo.filetype == "python" and python_version() ~= ""
      end,
    })
  end,
}
