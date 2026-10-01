-- snacks picker の git 操作から `git checkout` を排除し、`git switch` / `git restore` に統一する。
--
-- picker の confirm 等はアクション名（"git_checkout"）で指定されており、
-- 実行時に snacks/picker/config/init.lua の M.action が
-- `require("snacks.picker.actions")[name]` を引く。
-- したがってモジュールテーブルを差し替えれば git_branches / git_log / git_log_file など
-- 全ての picker に一括で効く。
return {
  "folke/snacks.nvim",
  optional = true,
  keys = {
    -- LazyVim 既定の stash 一覧。push の <leader>gz と "Git stash" / "Git Stash" で
    -- 並んで紛らわしいので外し、<leader>gZ に移した（lua/config/keymaps.lua）。
    { "<leader>gS", false },
  },
  opts = function(_, opts)
    local Snacks = require("snacks")
    local actions = require("snacks.picker.actions")

    -- 既定は `git checkout <branch|commit>`。ブランチ切替は switch、
    -- ファイル単位の復元は restore に分離する。
    actions.git_checkout = function(picker, item)
      picker:close()
      if not item then
        return
      end
      local what = item.branch or item.commit
      if not what then
        return Snacks.notify.warn("No branch or commit found", { title = "Snacks Picker" })
      end

      local cmd
      if item.file then
        -- switch はファイル単位の復元を扱えない
        cmd = { "git", "restore", "--source=" .. what, "--", item.file }
      elseif item.branch then
        -- remotes/origin/foo → foo を追跡ブランチとして作成して切替
        local remote_branch = item.branch:match("^remotes/[^/]+/(.+)$")
        cmd = remote_branch and { "git", "switch", "-c", remote_branch, "--track", item.branch }
          or { "git", "switch", item.branch }
      else
        cmd = { "git", "switch", "--detach", item.commit }
      end

      Snacks.picker.util.cmd(cmd, function()
        Snacks.notify((item.file and "Restore " or "Switch ") .. what, { title = "Snacks Picker" })
        vim.cmd.checktime()
      end, { cwd = item.cwd })
    end

    -- 既定は `git checkout -b <name>`。
    actions.git_branch_add = function(picker)
      Snacks.input.input({
        prompt = "New Branch Name",
        default = picker.input:get(),
      }, function(name)
        if (name or ""):match("^%s*$") then
          return
        end
        Snacks.picker.util.cmd({ "git", "branch", "--list", name }, function(data)
          if data[1] ~= "" then
            return Snacks.notify.error("Branch '" .. name .. "' already exists.", { title = "Snacks Picker" })
          end
          Snacks.picker.util.cmd({ "git", "switch", "-c", name }, function()
            Snacks.notify("Created Branch `" .. name .. "`", { title = "Snacks Picker" })
            vim.cmd.checktime()
            picker.list:set_target()
            picker.input:set("", "")
            picker:find()
          end, { cwd = picker:cwd() })
        end, { cwd = picker:cwd() })
      end)
    end

    -- 既定の git_branches は `git branch -vvl` でローカルしか列挙しない。
    -- fetch 直後のリモートブランチを候補に出すため --all を付ける。
    -- remotes/origin/foo は上の git_checkout が追跡ブランチとして作成する。
    return vim.tbl_deep_extend("force", opts or {}, {
      picker = { sources = { git_branches = { all = true } } },
    })
  end,
}
