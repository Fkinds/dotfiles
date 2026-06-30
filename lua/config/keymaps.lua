-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- マウスクリックを無効化（キーボード操作に集中）
for _, click in ipairs({ "<LeftMouse>", "<2-LeftMouse>", "<3-LeftMouse>", "<4-LeftMouse>" }) do
  vim.keymap.set({ "n", "i", "v" }, click, "<nop>")
end

-- ───────────────────────────────────────────────────────────────────
-- Git keymaps (vim-fugitive ベース)
-- ───────────────────────────────────────────────────────────────────
local map = function(lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { desc = desc, silent = true })
end

-- Claude にコミットメッセージを生成させてコミットする。
-- staged diff を `claude` CLI に渡して生成 → fugitive のコミットバッファに
-- 差し込み、内容を確認・編集してから :wq で確定する。
local function ai_commit()
  if vim.fn.systemlist({ "git", "rev-parse", "--is-inside-work-tree" }) and vim.v.shell_error ~= 0 then
    return vim.notify("git リポジトリではありません", vim.log.levels.ERROR)
  end
  local staged = vim.fn.systemlist({ "git", "diff", "--cached", "--name-only" })
  if vim.v.shell_error ~= 0 then
    return vim.notify("git diff に失敗しました", vim.log.levels.ERROR)
  end
  if #staged == 0 then
    return vim.notify(
      "ステージ済みの変更がありません（先に <leader>ga / <leader>gA）",
      vim.log.levels.WARN
    )
  end

  vim.notify("Claude がコミットメッセージを生成中…", vim.log.levels.INFO)
  local diff = table.concat(vim.fn.systemlist({ "git", "diff", "--cached" }), "\n")
  local prompt = table.concat({
    "stdin に渡された git の staged diff に対する簡潔なコミットメッセージを生成してください。",
    "Conventional Commits 形式（feat:, fix:, refactor:, docs:, chore: など）。",
    "1行目に50字程度の要約。必要なら空行を挟んで本文。",
    "出力はコミットメッセージ本文のみ。前置き・コードブロック・引用符は付けないこと。",
  }, "\n")

  vim.system({ "claude", "-p", prompt }, { text = true, stdin = diff }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return vim.notify("claude 生成失敗: " .. (res.stderr or ""), vim.log.levels.ERROR)
      end
      local msg = vim.trim(res.stdout or "")
      if msg == "" then
        return vim.notify("空のメッセージが返りました", vim.log.levels.WARN)
      end
      local tmp = vim.fn.tempname()
      vim.fn.writefile(vim.split(msg, "\n"), tmp)
      -- -e で生成メッセージを編集可能な状態でコミットバッファを開く（:wq で確定）
      vim.cmd("Git commit -e -F " .. vim.fn.fnameescape(tmp))
    end)
  end)
end

map("<leader>gs", "<cmd>Git<cr>", "Git status (fugitive)")
map("<leader>gl", "<cmd>Git log --oneline<cr>", "Git log --oneline")
map("<leader>gz", "<cmd>Git stash<cr>", "Git stash")
map("<leader>ga", "<cmd>Git add .<cr>", "Git add .")
map("<leader>gA", "<cmd>Git add --all<cr>", "Git add --all")
map("<leader>gp", "<cmd>Git push origin HEAD<cr>", "Git push origin HEAD")
map("<leader>gP", "<cmd>Git push --force-with-lease<cr>", "Git push --force-with-lease")
map("<leader>gc", ai_commit, "Git commit (Claude 生成メッセージ)")
map("<leader>gx", "<cmd>Git commit --fixup HEAD<cr>", "Git commit --fixup HEAD")
map("<leader>gr", "<cmd>Git rebase -i --autosquash origin/main<cr>", "Git rebase -i --autosquash origin/main")
map("<leader>gf", "<cmd>Git fetch<cr>", "Git fetch")

-- ブランチ切替: snacks のブランチ picker で選んで switch
map("<leader>gw", function()
  require("snacks").picker.git_branches()
end, "Git switch (branch picker)")

-- 新規ブランチ作成して切替: git switch -c <name>
map("<leader>gW", function()
  vim.ui.input({ prompt = "新規ブランチ名: " }, function(name)
    if not name or name == "" then
      return
    end
    vim.cmd("Git switch -c " .. vim.fn.fnameescape(name))
  end)
end, "Git switch -c (new branch)")
