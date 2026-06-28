return {
  {
    "akinsho/toggleterm.nvim",
    version = "*",
    cmd = { "Docker", "Aws", "Cdk", "ToggleTerm" },
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

      -- CLI を float ターミナルで実行するユーザーコマンドを登録する。
      -- 例: :Docker compose up -d --build / :Aws s3 ls / :Cdk deploy
      -- プロジェクトルートで走らせ、ログを読めるよう終了後も開いたままにする。
      local function register_cli(name, bin)
        vim.api.nvim_create_user_command(name, function(o)
          local root = vim.fs.root(0, { "docker-compose.yml", "compose.yml", "pyproject.toml", ".git" })
            or vim.fn.getcwd()
          require("toggleterm.terminal").Terminal:new({
            cmd = bin .. " " .. o.args,
            dir = root,
            direction = "float",
            close_on_exit = false,
          }):toggle()
        end, { nargs = "+", desc = "Run " .. bin .. " in a toggleterm float" })
      end

      register_cli("Docker", "docker")
      register_cli("Aws", "aws")
      register_cli("Cdk", "cdk")
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
