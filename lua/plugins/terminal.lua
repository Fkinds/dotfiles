return {
  {
    "akinsho/toggleterm.nvim",
    version = "*",
    opts = {
      size = 20,
      open_mapping = [[<C-\>]],
      direction = "horizontal", -- horizontal, vertical, float, tab
      shell = vim.o.shell,
    },
    config = function(_, opts)
      require("toggleterm").setup(opts)
      -- ターミナルモードからEscでnormal modeに戻る
      vim.keymap.set("t", "<Esc><Esc>", [[<C-\><C-n>]], { desc = "Exit terminal mode" })
    end,
    keys = {
      { "<leader>tt", "<cmd>ToggleTerm direction=horizontal<cr>", desc = "Terminal (horizontal)" },
      { "<leader>tf", "<cmd>ToggleTerm direction=float<cr>", desc = "Terminal (float)" },
      { "<leader>tv", "<cmd>ToggleTerm direction=vertical size=80<cr>", desc = "Terminal (vertical)" },
      {
        "<leader>cu",
        function()
          -- uv: ruff format -> ruff check -> ty check を一括実行。
          -- pyproject.toml のあるルートで走らせ、format による変更を反映するため
          -- 終了後に checktime でバッファを再読込する。
          local root = vim.fs.root(0, { "pyproject.toml", ".git" }) or vim.fn.getcwd()
          local Terminal = require("toggleterm.terminal").Terminal
          Terminal:new({
            cmd = "uv run ruff format && uv run ruff check && uv run ty check",
            dir = root,
            direction = "horizontal",
            close_on_exit = false, -- 結果を読めるよう開いたままにする
            on_exit = function()
              vim.schedule(function()
                vim.cmd("checktime")
              end)
            end,
          }):toggle()
        end,
        desc = "uv: format + check + ty",
      },
    },
  },
}
