return {
  {
    "coder/claudecode.nvim",
    opts = {
      terminal = {
        split_side = "right", -- Claude は右カラムに出す
        split_width_percentage = 0.5, -- エディタと同じ幅（既定は 0.30）
        -- 起動時の cwd を ~/Work 固定ではなく「今いるバッファのプロジェクトルート」にする。
        -- マーカーは toggleterm の register_cli (terminal.lua) と揃えている。
        -- ctx.file_dir = 起動時に開いていたファイルのディレクトリ / ctx.cwd = nvim の getcwd。
        -- 注意: cwd は ClaudeCode 起動(spawn)時に一度だけ確定する。別プロジェクトで
        -- 開き直したいときは :ClaudeCodeStop してから再度 <leader>ac で起動する。
        cwd_provider = function(ctx)
          local start = (ctx and (ctx.file_dir or ctx.cwd)) or vim.fn.getcwd()
          return vim.fs.root(start, { "docker-compose.yml", "compose.yml", "pyproject.toml", ".git" })
            or start
        end,
      },
    },
    cmd = {
      "ClaudeCode",
      "ClaudeCodeSend",
      "ClaudeCodeFocus",
      "ClaudeCodeStart",
      "ClaudeCodeStop",
    },
    keys = {
      { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude Code" },
      { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude Code" },
    },
  },
}
