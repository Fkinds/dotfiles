-- lua-language-server の locale ローダーのクラッシュを修正するパッチ。
--
-- 背景:
--   3.16.4 同梱の locale/*/meta.lua には `utf8.offset[55]` のような数値添字の
--   エントリがある。これを読む script/locale-loader.lua の mergeKey は `k:sub(1,1)`
--   を呼ぶため、k が数値だと "attempt to index a number value" でクラッシュし、
--   Lua の補完・診断が効かなくなる。
--
--   Mason のパッケージ内ファイルは dotfiles に含まれず再インストールで戻るため、
--   起動時に冪等パッチを当てて永続化する（数値キーを tostring で文字列化する1行）。
--
-- 上流で修正されたバージョンに上げれば不要になる。
local M = {}

local function loader_path()
  return vim.fn.stdpath("data")
    .. "/mason/packages/lua-language-server/libexec/script/locale-loader.lua"
end

-- 既にパッチ済み / 未インストール / 既に上流修正済みなら何もしない。
function M.apply()
  local path = loader_path()
  local file = io.open(path, "r")
  if not file then
    return
  end
  local content = file:read("*a")
  file:close()

  -- 既にパッチ適用済み
  if content:find("k = tostring(k)", 1, true) then
    return
  end
  -- パッチ対象の脆弱な行が無い（バージョン差異 / 上流修正済み）
  local anchor = "    if k:sub(1, 1):match '%w' then"
  if not content:find(anchor, 1, true) then
    return
  end

  local patched = content:gsub(
    "(    if not key then\n        return k\n    end\n)",
    "%1    k = tostring(k)\n",
    1
  )
  if patched == content then
    return
  end

  local out = io.open(path, "w")
  if not out then
    return
  end
  out:write(patched)
  out:close()
  vim.notify("Patched lua-language-server locale-loader (numeric key fix)", vim.log.levels.INFO)
end

return M
