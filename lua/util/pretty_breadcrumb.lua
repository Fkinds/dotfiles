-- lualine 用のパンくず風ファイルパス。
-- LazyVim の pretty_path をベースに、ディレクトリをフォルダアイコン＋シェブロンで
-- 区切って表示する。dir はくすませ、ファイル名だけ強調する。
--
-- 例: 󰉋 python_template  .pre-commit-config.yaml
-- 階層が length を超えたら parts[1]  …  tail に省略する。
local M = {}

local folder_icon = "󰉋 "
local chevron = "  " -- 前後パディング付きのシェブロン

---@param opts? { length?: number, modified_hl?: string, directory_hl?: string, filename_hl?: string, modified_sign?: string, readonly_icon?: string }
function M.pretty_breadcrumb(opts)
  opts = vim.tbl_extend("force", {
    length = 3,
    modified_hl = "MatchParen",
    directory_hl = "Comment",
    filename_hl = "Bold",
    modified_sign = " ",
    readonly_icon = " 󰌾 ",
  }, opts or {})

  return function(self)
    local path = vim.fn.expand("%:p") --[[@as string]]
    if path == "" then
      return ""
    end

    path = LazyVim.norm(path)
    local root = LazyVim.root.get({ normalize = true })
    local cwd = LazyVim.root.cwd()
    local norm_path = path

    -- cwd / root からの相対パスにする（pretty_path と同じ優先順）
    if norm_path:find(cwd, 1, true) == 1 then
      path = path:sub(#cwd + 2)
    elseif norm_path:find(root, 1, true) == 1 then
      path = path:sub(#root + 2)
    end

    local parts = vim.split(path, "[\\/]")
    if opts.length > 0 and #parts > opts.length then
      parts = { parts[1], "…", unpack(parts, #parts - opts.length + 2, #parts) }
    end

    local fmt = LazyVim.lualine.format

    -- ファイル名: 変更時は modified_hl、通常は filename_hl で強調
    local file = parts[#parts]
    if vim.bo.modified then
      file = fmt(self, file .. opts.modified_sign, opts.modified_hl)
    else
      file = fmt(self, file, opts.filename_hl)
    end

    local out
    if #parts > 1 then
      local dirs = {}
      for i = 1, #parts - 1 do
        dirs[i] = parts[i]
      end
      local sep = fmt(self, chevron, opts.directory_hl)
      local crumb = fmt(self, folder_icon .. table.concat(dirs, chevron), opts.directory_hl)
      out = crumb .. sep .. file
    else
      out = file
    end

    if vim.bo.readonly then
      out = out .. fmt(self, opts.readonly_icon, opts.modified_hl)
    end
    return out
  end
end

return M
