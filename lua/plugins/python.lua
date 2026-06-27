-- Python用の設定
-- pyrightは自動で.venvを検出します
return {
  -- pyrightの設定
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        pyright = {
          settings = {
            python = {
              venvPath = ".",
              venv = ".venv",
            },
          },
        },
      },
    },
  },
}
