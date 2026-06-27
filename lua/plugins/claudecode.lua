return {
  {
    "coder/claudecode.nvim",
    opts = {
      terminal = {
        split_width_percentage = 0.5, -- エディタと同じ幅（既定は 0.30）
      },
    },
    cmd = { "ClaudeCode", "ClaudeCodeSend", "ClaudeCodeFocus", "ClaudeCodeStart", "ClaudeCodeStop" },
    keys = {
      { "<leader>ac", "<cmd>ClaudeCode<cr>", desc = "Toggle Claude Code" },
      { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send to Claude Code" },
    },
  },
}
