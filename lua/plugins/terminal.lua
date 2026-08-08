-- Claude Code エージェント一覧(.claude/bin/agent-dashboard.sh)をサイドバーで開閉する。
-- 常駐プロセスなので使い回すが、Ctrl-C でジョブごと終わらせたら作り直す。
-- 死んだターミナルを toggle しても再起動しないため。
local dashboard = nil

-- 幅は explorer(<leader>e / neo-tree)と揃える。狭い画面では画面幅の半分までに抑える。
-- 注意: 上段は「状態 8 + リポジトリ 16 + ブランチ 24 + 経過 6 + ID 8 + 区切り」で約 66 桁あり、
-- この幅では折り返して表が崩れる。下段(agent / skill)は端末幅に合わせて側が切り詰める。
local DASHBOARD_WIDTH = 40

local function dashboard_size()
  return math.min(DASHBOARD_WIDTH, math.floor(vim.o.columns * 0.5))
end

local function toggle_dashboard()
  -- jobwait の 0 タイムアウトは、実行中なら -1、無効な id なら -3 を返す。
  if dashboard and vim.fn.jobwait({ dashboard.job_id or -1 }, 0)[1] ~= -1 then
    dashboard = nil
  end
  dashboard = dashboard
    or require("toggleterm.terminal").Terminal:new({
      cmd = vim.fn.expand("~/.claude/bin/agent-dashboard.sh"),
      direction = "vertical",
      close_on_exit = true, -- Ctrl-C したらそのまま閉じる
      hidden = true,
      on_open = function(term)
        -- toggleterm の vertical は botright vsplit 固定で splitright を見ないため、
        -- 右カラムに出る。開いたあと自分で左端へ移し、崩れた幅を測り直す。
        if vim.api.nvim_get_current_win() == term.window then
          vim.cmd("wincmd H")
        end
        vim.api.nvim_win_set_width(term.window, dashboard_size())
        -- 他ウィンドウの開閉で幅が変わらないよう固定し、表が折り返さないようにする。
        vim.wo[term.window].winfixwidth = true
        vim.wo[term.window].wrap = false
      end,
    })
  dashboard:toggle(dashboard_size())
end

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
      { "<leader>ad", toggle_dashboard, desc = "Claude エージェント一覧" },
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
