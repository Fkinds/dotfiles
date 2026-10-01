-- 作業ツリーの変更を `git restore` で破棄するヘルパ。ファイルを選ぶか、全部か。
--
-- 対象は `git restore` の既定どおり「作業ツリー側の変更」だけで、index は触らない。
-- したがってステージ済みの変更は残り、untracked のファイルは消えない。
-- 競合中のパスは restore が拒否するので、最初から候補に出さない。
--
-- snacks の git_status picker にも <c-r> の restore があるが、ステージ済みや
-- untracked も並ぶうえ、ステージ済みのあるファイルではプレビューが index 側の
-- 差分になる。捨てる中身を見てから破棄したいので、候補とプレビューを作業ツリー側に
-- 揃えた picker を持つ。
--
-- パスは --literal-pathspecs で渡す。`*` や `[` を含むファイル名を glob として
-- 解釈させず、選んだファイル以外を巻き込まないため。
local Snacks = require("snacks")

local M = {}

local TITLE = "git restore"

---@class util.git_restore.Change
---@field status string git status --porcelain の XY 形式（作業ツリー側なので X は空白）
---@field file string リポジトリのルートからの相対パス

---@param cwd string
---@return string|nil root, string|nil err
local function git_root(cwd)
  local res = vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = cwd, text = true }):wait()
  if res.code ~= 0 then
    return nil, res.stderr
  end
  return vim.trim(res.stdout or "")
end

-- 作業ツリー側に変更がある追跡済みファイル。-z でないと日本語のパスがクォートされる。
---@param root string
---@return util.git_restore.Change[]|nil changes, string|nil err
local function worktree_changes(root)
  local res = vim
    .system({ "git", "diff", "--name-status", "-z", "--no-renames", "--diff-filter=MDT" }, { cwd = root, text = true })
    :wait()
  if res.code ~= 0 then
    return nil, res.stderr
  end
  -- 出力は "M\0path\0D\0path\0..." の繰り返し
  local fields = vim.split(res.stdout or "", "\0", { plain = true, trimempty = true })
  local changes = {}
  for i = 1, #fields - 1, 2 do
    changes[#changes + 1] = { status = " " .. fields[i], file = fields[i + 1] }
  end
  return changes
end

-- 確認してから restore する。files は root からの相対パス。
---@param root string
---@param files string[]
---@param on_done? fun()
local function confirm_restore(root, files, on_done)
  local msg = #files == 1 and ("`%s` の変更を破棄しますか？"):format(files[1])
    or ("%d ファイルの変更を破棄しますか？"):format(#files)
  Snacks.picker.util.confirm(msg, function()
    local cmd = vim.list_extend({ "git", "--literal-pathspecs", "restore", "--" }, files)
    Snacks.picker.util.cmd(cmd, function()
      vim.notify(("%d ファイルを restore しました"):format(#files), vim.log.levels.INFO, { title = TITLE })
      vim.cmd.checktime()
      if on_done then
        on_done()
      end
    end, { cwd = root })
  end)
end

-- 一覧と破棄の前処理。変更が無ければ通知して nil を返す。
---@return string|nil root, util.git_restore.Change[]|nil changes
local function prepare()
  local root, err = git_root(assert(vim.uv.cwd()))
  if not root then
    vim.notify("git リポジトリではありません\n" .. (err or ""), vim.log.levels.ERROR, { title = TITLE })
    return
  end
  local changes, list_err = worktree_changes(root)
  if not changes then
    vim.notify("変更を列挙できません\n" .. (list_err or ""), vim.log.levels.ERROR, { title = TITLE })
    return
  end
  if #changes == 0 then
    vim.notify("作業ツリーに破棄できる変更はありません", vim.log.levels.INFO, { title = TITLE })
    return
  end
  return root, changes
end

-- picker で選んだファイルを restore する。<Tab> で複数選択、<c-a> で全選択。
function M.pick()
  local root, changes = prepare()
  if not root or not changes then
    return
  end

  local items = {}
  for _, c in ipairs(changes) do
    items[#items + 1] = { text = c.file, file = c.file, status = c.status, cwd = root }
  end

  Snacks.picker.pick({
    title = "Git restore",
    items = items,
    format = "git_status",
    -- restore が捨てるのは作業ツリー側なので、index との差分を見せる
    preview = function(ctx)
      local cmd = { "git", "--no-pager", "--literal-pathspecs", "diff", "--", ctx.item.file }
      Snacks.picker.preview.cmd(cmd, ctx, { ft = "diff" })
    end,
    confirm = function(picker)
      local selected = picker:selected({ fallback = true })
      if #selected == 0 then
        return
      end
      local files = vim.tbl_map(function(item)
        return item.file
      end, selected)
      confirm_restore(root, files, function()
        picker:close()
      end)
    end,
  })
end

-- 作業ツリー側の変更をすべて restore する。
-- `git restore .` ではなく確認に出したファイルだけを渡し、確認後に増えた変更は巻き込まない。
function M.all()
  local root, changes = prepare()
  if not root or not changes then
    return
  end
  local files = vim.tbl_map(function(c)
    return c.file
  end, changes)
  confirm_restore(root, files)
end

return M
