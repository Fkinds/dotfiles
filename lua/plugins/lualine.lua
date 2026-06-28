-- ファイルパス表示をパンくず風（フォルダアイコン＋シェブロン区切り）に差し替える。
-- LazyVim の lualine_c は { root_dir, diagnostics, filetype-icon, pretty_path } の順で、
-- pretty_path は 4 番目。後続スペックの insert は末尾追加のため index 4 は安定。
return {
  "nvim-lualine/lualine.nvim",
  optional = true,
  opts = function(_, opts)
    local breadcrumb = require("util.pretty_breadcrumb").pretty_breadcrumb
    local c = opts.sections and opts.sections.lualine_c
    if c and c[4] then
      c[4] = { breadcrumb() }
    end

    -- neo-tree が表示中のディレクトリを右側に常時表示する
    if opts.sections and opts.sections.lualine_x then
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return require("util.neo_tree_cwd").path()
        end,
        icon = "󰉋",
        color = { fg = "#7aa2f7" },
      })
    end
  end,
}
