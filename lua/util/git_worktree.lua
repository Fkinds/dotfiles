-- git worktree の一覧・切替・作成・削除。
--
-- 置き場所は `<メイン worktree の親>/<リポジトリ名>-worktrees/<ブランチ名の最後の要素>`。
-- 例: ~/Work/myapp で feat/foo を作ると ~/Work/myapp-worktrees/foo。
--
-- 「切替」は nvim の cwd をその worktree へ移すこと。開いているファイルと同じ相対パスが
-- 切替先にもあれば開き直し、neo-tree は BufEnter の追従（config/autocmds.lua）に任せる。
-- 対応するファイルが無いときだけ、開いている neo-tree を直接切替先へ向ける。
--
-- 削除は `git worktree remove`（--force なし）に限る。未コミットの変更や untracked が
-- 残っていれば git が拒否するので、その判断は手動に委ねる。ブランチは消さない。
local Snacks = require("snacks")

local M = {}

local TITLE = "git worktree"

---@class util.git_worktree.Worktree
---@field path string 実パス（symlink を解決済み）
---@field head? string
---@field branch? string refs/heads/ を除いた名前。detached なら nil
---@field main boolean 先頭に列挙されるメインの worktree
---@field bare? boolean

---@param args string[]
---@param cwd string
---@return vim.SystemCompleted
local function git(args, cwd)
  return vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
end

-- git が返すパスと vim の cwd は /tmp と /private/tmp のようにずれうるので、実パスで比べる
---@param path string
---@return string
local function realpath(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

---@param path string
---@param dir string
---@return boolean
local function is_under(path, dir)
  return path:sub(1, #dir + 1) == dir .. "/"
end

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = TITLE })
end

-- cwd が属する worktree のルート
---@return string|nil root, string|nil err
local function current_root()
  local res = git({ "rev-parse", "--show-toplevel" }, assert(vim.uv.cwd()))
  if res.code ~= 0 then
    return nil, res.stderr
  end
  return realpath(vim.trim(res.stdout or ""))
end

---@param cwd string
---@return util.git_worktree.Worktree[]|nil worktrees, string|nil err
local function list(cwd)
  local res = git({ "worktree", "list", "--porcelain" }, cwd)
  if res.code ~= 0 then
    return nil, res.stderr
  end
  local worktrees = {} ---@type util.git_worktree.Worktree[]
  local cur ---@type util.git_worktree.Worktree?
  for _, line in ipairs(vim.split(res.stdout or "", "\n", { plain = true })) do
    local key, value = line:match("^(%S+) ?(.*)$")
    if key == "worktree" then
      cur = { path = realpath(value), main = #worktrees == 0 }
      worktrees[#worktrees + 1] = cur
    elseif cur and key == "HEAD" then
      cur.head = value
    elseif cur and key == "branch" then
      cur.branch = (value:gsub("^refs/heads/", ""))
    elseif cur and key == "bare" then
      cur.bare = true
    end
  end
  return worktrees
end

-- 開いている neo-tree を dir へ向ける。閉じていれば開かない。
---@param dir string
local function follow_tree(dir)
  if not package.loaded["neo-tree.sources.manager"] then
    return
  end
  local state = require("neo-tree.sources.manager").get_state("filesystem")
  if not state or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end
  require("neo-tree.command").execute({ action = "show", source = "filesystem", dir = dir })
end

---@param path string 切替先 worktree のルート
function M.switch(path)
  local from = current_root()
  local file = vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or ""
  vim.cmd("cd " .. vim.fn.fnameescape(path))

  local target
  if from and file ~= "" then
    local real = realpath(file)
    if is_under(real, from) then
      target = path .. "/" .. real:sub(#from + 2)
    end
  end
  if target and vim.uv.fs_stat(target) then
    vim.cmd("edit " .. vim.fn.fnameescape(target))
  else
    follow_tree(path)
  end
  notify("→ " .. vim.fn.fnamemodify(path, ":~"))
end

-- ブランチ名を聞いて worktree を作り、そこへ切り替える。
-- ローカルにあればそのブランチ、origin にだけあれば追跡ブランチを作り、
-- どちらにも無ければ今の HEAD から新しいブランチを切る（<leader>gW と同じ）。
function M.add()
  local root, err = current_root()
  if not root then
    return notify("git リポジトリではありません\n" .. (err or ""), vim.log.levels.ERROR)
  end
  local worktrees, list_err = list(root)
  if not worktrees or not worktrees[1] then
    return notify("worktree を列挙できません\n" .. (list_err or ""), vim.log.levels.ERROR)
  end
  local main = worktrees[1].path

  Snacks.input.input({ prompt = "worktree のブランチ名" }, function(name)
    name = vim.trim(name or "")
    local leaf = name:match("[^/]+$")
    if not leaf then
      return
    end
    local dir = ("%s/%s-worktrees/%s"):format(vim.fs.dirname(main), vim.fs.basename(main), leaf)

    local args
    if git({ "show-ref", "--verify", "--quiet", "refs/heads/" .. name }, root).code == 0 then
      args = { "worktree", "add", dir, name }
    elseif git({ "show-ref", "--verify", "--quiet", "refs/remotes/origin/" .. name }, root).code == 0 then
      args = { "worktree", "add", "--track", "-b", name, dir, "origin/" .. name }
    else
      args = { "worktree", "add", "-b", name, dir }
    end

    -- 大きいリポジトリだとチェックアウトに時間がかかるので非同期
    notify("作成中: " .. vim.fn.fnamemodify(dir, ":~"))
    vim.system(vim.list_extend({ "git" }, args), { cwd = root, text = true }, function(res)
      vim.schedule(function()
        if res.code ~= 0 then
          return notify("git worktree add に失敗しました\n" .. (res.stderr or ""), vim.log.levels.ERROR)
        end
        M.switch(realpath(dir))
      end)
    end)
  end)
end

---@param wt util.git_worktree.Worktree
---@param on_done fun()
local function remove(wt, on_done)
  if wt.main then
    return notify("メインの worktree は削除できません", vim.log.levels.WARN)
  end
  if wt.path == current_root() then
    return notify(
      "今いる worktree は削除できません。先に別の worktree へ切り替えてください",
      vim.log.levels.WARN
    )
  end

  local shown = vim.fn.fnamemodify(wt.path, ":~")
  Snacks.picker.util.confirm(("worktree `%s` を削除しますか？"):format(shown), function()
    Snacks.picker.util.cmd({ "git", "worktree", "remove", wt.path }, function()
      -- 消えたファイルのバッファを残すと、:w でディレクトリごと復活する。
      -- 未保存の変更があるバッファは捨てずに残す。
      Snacks.bufdelete(function(buf)
        return vim.bo[buf].buftype == ""
          and not vim.bo[buf].modified
          and is_under(vim.api.nvim_buf_get_name(buf), wt.path)
      end)
      notify(("削除: %s（ブランチ %s は残しています）"):format(shown, wt.branch or "なし"))
      on_done()
    end, { cwd = assert(current_root()) })
  end)
end

-- worktree の一覧。<CR> で切替、<c-a> で作成、<c-x> で削除（ブランチ picker と同じ配置）。
function M.pick()
  local root, err = current_root()
  if not root then
    return notify("git リポジトリではありません\n" .. (err or ""), vim.log.levels.ERROR)
  end

  Snacks.picker.pick({
    title = "Git worktree",
    finder = function()
      local worktrees, list_err = list(root)
      if not worktrees then
        notify("worktree を列挙できません\n" .. (list_err or ""), vim.log.levels.ERROR)
        return {}
      end
      local items = {}
      for _, wt in ipairs(worktrees) do
        -- bare リポジトリの本体にはチェックアウトが無いので切替先にならない
        if not wt.bare then
          items[#items + 1] = {
            text = (wt.branch or "") .. " " .. wt.path,
            wt = wt,
            cwd = wt.path,
            current = wt.path == root,
          }
        end
      end
      return items
    end,
    format = function(item)
      local a = Snacks.picker.util.align
      local wt = item.wt ---@type util.git_worktree.Worktree
      local name = wt.branch or ("(detached %s)"):format((wt.head or ""):sub(1, 7))
      return {
        { a(item.current and "" or "", 2), "SnacksPickerGitBranchCurrent" },
        { a(name, 30, { truncate = true }), wt.branch and "SnacksPickerGitBranch" or "SnacksPickerGitDetached" },
        { " " },
        { vim.fn.fnamemodify(wt.path, ":~"), "SnacksPickerDir" },
      }
    end,
    -- 切替・削除の判断に要る「未コミットの変更があるか」と「何のブランチか」を見せる
    preview = function(ctx)
      Snacks.picker.preview.cmd({
        "sh",
        "-c",
        "git -c color.ui=always status --short --branch && echo && git -c color.ui=always log --oneline --decorate -n 20",
      }, ctx)
    end,
    confirm = function(picker, item)
      picker:close()
      if item then
        M.switch(item.wt.path)
      end
    end,
    actions = {
      worktree_add = function(picker)
        picker:close()
        M.add()
      end,
      worktree_remove = function(picker, item)
        if item then
          remove(item.wt, function()
            picker:find()
          end)
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<c-a>"] = { "worktree_add", mode = { "n", "i" } },
          ["<c-x>"] = { "worktree_remove", mode = { "n", "i" } },
        },
      },
    },
  })
end

return M
