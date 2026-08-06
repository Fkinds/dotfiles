-- markdown を Ghostty 上でレンダリング表示する（md-render.nvim）。
-- Kitty graphics protocol で画像・動画・Mermaid 図をターミナルに直接描画するため、
-- ブラウザプレビュー（markdown-preview.nvim 等）を使わずに nvim 内で完結する。
-- 日本語は budoux.lua により文節単位で折り返される（未導入時は文字単位にフォールバック）。
--
-- 任意依存のうち ffmpeg / ImageMagick は未導入。静止画は sips（macOS 組み込み）で処理され、
-- 動画フレーム抽出と GIF アニメーションのみ無効になる。必要なら `brew install ffmpeg imagemagick`。
-- アイコンは mini.icons、コードブロックのハイライトは nvim-treesitter を利用する（いずれも導入済み）。
return {
  {
    "delphinus/md-render.nvim",
    version = "*",
    ft = "markdown",
    dependencies = {
      { "delphinus/budoux.lua", version = "*" },
    },
    keys = {
      {
        "<leader>mm",
        "<cmd>MdRender toggle<cr>",
        ft = "markdown",
        desc = "Markdown 描画をその場で切替",
      },
      {
        "<leader>mp",
        "<Plug>(md-render-preview)",
        ft = "markdown",
        desc = "Markdown プレビュー (フロート)",
      },
      {
        "<leader>mt",
        "<Plug>(md-render-preview-tab)",
        ft = "markdown",
        desc = "Markdown プレビュー (タブ)",
      },
    },
  },
}
