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

    -- 画面の外周の枠（util/window_frame.lua）の下辺。最下行は statusline が
    -- 占めていて線を引く場所がないので、lualine の左右端を枠の角に仕立てる。
    -- 色は WinSeparator から借りるので他の 3 辺と揃う。
    --
    --   ╚═╡ NORMAL … 1:1 ╞═╝
    --
    -- ╡ ╞ の向きは外から内。枠の線が来て、そこで情報の並びが始まる。
    -- 右端は角のあとに空白を 1 つ置く。右辺の縦線は場所取りウィンドウの
    -- 区切り線なので、画面の最終列ではなくその 1 つ手前に立っている。
    local function edge(text)
      return {
        function()
          return text
        end,
        color = "WinSeparator",
        padding = 0,
        separator = "",
      }
    end
    if opts.sections then
      opts.sections.lualine_a = opts.sections.lualine_a or {}
      opts.sections.lualine_z = opts.sections.lualine_z or {}
      table.insert(opts.sections.lualine_a, 1, edge("╚═╡"))
      table.insert(opts.sections.lualine_z, edge("╞═╝ "))
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

  -- lualine.setup のあとに statusline を包んで、余白を枠の線で埋める
  -- （util/window_frame.lua）。lazy.nvim の既定の config と同じことをしてから
  -- 掛けるだけで、opts はそのまま渡る。
  config = function(_, opts)
    require("lualine").setup(opts)
    require("util.window_frame").hook_statusline()
  end,
}
