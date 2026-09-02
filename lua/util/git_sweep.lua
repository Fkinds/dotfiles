-- リモートで消えたブランチ（upstream が gone）を、ローカルからも削除するヘルパ。
--
-- PR がマージされてリモート側のブランチが削除されると、手元には追跡先を失った
-- ブランチだけが残る。git には post-fetch / post-merge 後に「他ブランチを掃除する」
-- 仕組みがないので、fetch のキーマップと FugitiveChanged から明示的に呼ぶ
-- （lua/config/keymaps.lua と lua/config/autocmds.lua）。
--
-- 削除は `git branch -d`（マージ済みのみ）に限る。squash merge されたブランチは
-- マージ扱いにならず -d では消えないが、ここで -D に落とすと push し忘れた
-- コミットごと消える。消えなかったものは名前を通知して手動判断に委ねる。
local M = {}

local TITLE = "git sweep"

---@param opts? { cwd?: string }
---@return string
local function resolve_cwd(opts)
  return (opts and opts.cwd) or assert(vim.uv.cwd())
end

---@param args string[]
---@param cwd string
---@return vim.SystemCompleted
local function git(args, cwd)
  return vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
end

-- upstream が gone なローカルブランチ名。現在のブランチは対象外。
---@param cwd string
---@return string[]|nil names, string|nil err
local function gone_branches(cwd)
  local refs = git({ "for-each-ref", "--format=%(refname:short)\t%(upstream:track)", "refs/heads" }, cwd)
  if refs.code ~= 0 then
    return nil, refs.stderr
  end

  -- detached HEAD なら空文字。その場合はどのブランチも除外されない
  local current = vim.trim(git({ "branch", "--show-current" }, cwd).stdout or "")

  local names = {}
  for line in (refs.stdout or ""):gmatch("[^\n]+") do
    local name, track = line:match("^([^\t]*)\t(.*)$")
    if name and name ~= "" and name ~= current and track:find("[gone]", 1, true) then
      names[#names + 1] = name
    end
  end
  return names
end

-- gone なブランチを削除する。
-- quiet = true のときは、削除するものが無ければ何も通知しない（autocmd 用）。
---@param opts? { cwd?: string, quiet?: boolean }
function M.sweep(opts)
  local quiet = opts and opts.quiet
  local cwd = resolve_cwd(opts)

  local targets, err = gone_branches(cwd)
  if not targets then
    if not quiet then
      vim.notify("ブランチを列挙できません\n" .. (err or ""), vim.log.levels.ERROR, { title = TITLE })
    end
    return
  end
  if #targets == 0 then
    if not quiet then
      vim.notify("リモートで消えたブランチはありません", vim.log.levels.INFO, { title = TITLE })
    end
    return
  end

  local deleted, unmerged = {}, {}
  for _, name in ipairs(targets) do
    if git({ "branch", "-d", name }, cwd).code == 0 then
      deleted[#deleted + 1] = name
    else
      unmerged[#unmerged + 1] = name
    end
  end

  if #deleted > 0 then
    vim.notify("削除: " .. table.concat(deleted, ", "), vim.log.levels.INFO, { title = TITLE })
  end
  if #unmerged > 0 then
    vim.notify(
      "未マージなので残しました: "
        .. table.concat(unmerged, ", ")
        .. "\nsquash merge 済みだと確認できているなら git branch -D <name>",
      vim.log.levels.WARN,
      { title = TITLE }
    )
  end
end

-- `git fetch --prune` してから sweep する。fetch はネットワークを待つので非同期。
---@param opts? { cwd?: string }
function M.fetch_and_sweep(opts)
  local cwd = resolve_cwd(opts)
  vim.system({ "git", "fetch", "--prune" }, { cwd = cwd, text = true }, function(done)
    vim.schedule(function()
      if done.code ~= 0 then
        vim.notify(
          "git fetch --prune に失敗しました\n" .. (done.stderr or ""),
          vim.log.levels.ERROR,
          { title = TITLE }
        )
        return
      end
      M.sweep({ cwd = cwd })
    end)
  end)
end

return M
