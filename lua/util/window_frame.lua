-- 画面の外周に計器パネル風の枠を描く。
--
-- 上辺にはファイル名のラベルを刻む（╔═┤ window_frame.lua ├════）。
--
-- Neovim には通常ウィンドウを枠で囲む機能がなく（枠を持てるのは float だけ）、
-- fillchars の区切り線も隣り合うウィンドウの間にしか引かれない。そのため
-- 画面の端に接する辺には線が出ない。辺ごとに借りる場所が違う。
--
--   上端 … winbar。端に接するウィンドウの 1 行目。線とラベルを描く
--   左端 … statuscolumn。行番号の左に 1 列足す。ただしバッファ末尾より下の行では
--          statuscolumn が評価されないので、そこは fillchars の eob で埋める
--   右端 … 幅 1 の空ウィンドウ。行番号・サイン・折りたたみはどれも左側の機能で、
--          右側には行ごとに文字を出す場所がない。そこで右端に空のウィンドウを
--          立てて、その左境界に fillchars の区切り線を引かせる。線を描くのは
--          あくまで区切り線で、このウィンドウは場所取りに徹する
--          （ウィンドウの中身を線にすると、区切り線と並んで二重になる）
--   下端 … lualine。最下行は statusline が占めていて空きがない（cmdheight=0）。
--          statusline の左右端に縦線を足して枠の下辺に見せる。
--          plugins/lualine.lua を参照
--
-- 線は画面の端に接するウィンドウにだけ引く。全ウィンドウに引くと、内側で
-- 区切り線と重なって線が二重になる。
--
-- 四隅のうち右上の角（╗）だけは出せない。右辺の線は場所取りウィンドウとの
-- 区切り線が描いていて、区切り線は列ごと・全行で同じ文字になる。winbar が
-- 書けるのはその 1 列手前までなので、角を置く場所がない。上辺の ═ を区切り線の
-- ║ に突き当てて終える。残る 3 つは、左上が winbar の 1 文字目、
-- 左下と右下が lualine の両端（plugins/lualine.lua）。
local M = {}

local HL = "%#WinSeparator#"
local VERT = HL .. "║%*"

-- winbar / statuscolumn は statusline と同じ式で、評価のたびに描画対象の
-- ウィンドウ id が vim.g.statusline_winid に入る。
local WINBAR = "%!v:lua.require'util.window_frame'.winbar()"
local STATUSCOLUMN = "%!v:lua.require'util.window_frame'.statuscolumn()"

-- 右端の場所取りウィンドウの印。bufferline やウィンドウピッカーに実ウィンドウと
-- 間違われないよう、buflisted を落としたうえで filetype でも見分けられるようにする。
local EDGE_FT = "window_frame_edge"

-- 左端に接するウィンドウ。statuscolumn は 1 行ごとに評価されるので、
-- 位置の判定は refresh 側で済ませて、ここでは引くだけにする。
local at_left = {} ---@type table<integer, true>

-- 右端の場所取りウィンドウ。タブごとにレイアウトが別なので 1 タブ 1 枚持つ。
local edge_wins = {} ---@type table<integer, integer>
local edge_buf ---@type integer?

-- ラベルに出す名前。
-- ファイルを開いていないバッファ（neo-tree・ターミナルなど）は、バッファ名が
-- 内部の識別子（neo-tree filesystem [1] や term://…//123:zsh）で読めないので
-- filetype を使う。help はバッファ名がそのまま見出しになるので名前側を採る。
local function label(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local buftype = vim.bo[buf].buftype
  local text
  if buftype == "" or buftype == "help" then
    local name = vim.api.nvim_buf_get_name(buf)
    text = name ~= "" and vim.fn.fnamemodify(name, ":t") or ""
  end
  if not text or text == "" then
    text = vim.bo[buf].filetype
  end
  if text == "" then
    text = buftype ~= "" and buftype or "no name"
  end
  if vim.bo[buf].modified then
    text = text .. " ●"
  end
  return text
end

-- 上端の横線。ウィンドウ幅（垂直区切り線の列は含まない）ぶん埋め、
-- ファイル名のラベルを刻む。左端に接するウィンドウだけ角（╔）から始める。
--
--   ╔═┤ window_frame.lua ├══════════
--
-- 見ているウィンドウのラベルだけ明るくして、どれが手元かを枠の側でも示す。
function M.winbar()
  local win = vim.g.statusline_winid
  if not win or not vim.api.nvim_win_is_valid(win) then
    return ""
  end
  local width = vim.api.nvim_win_get_width(win)
  local lead = at_left[win] and "╔═" or "═"
  -- ラベルの飾り（┤ ├ と前後の空白）と角が食う幅
  local frame = vim.fn.strdisplaywidth(lead) + vim.fn.strdisplaywidth("┤  ├")

  -- ラベルを置く余地が無いほど狭いウィンドウでは線だけ引く。
  local room = width - frame
  if room < 4 then
    return HL .. lead .. string.rep("═", math.max(width - vim.fn.strdisplaywidth(lead), 0))
  end

  -- 入りきらない名前は頭を削って末尾（拡張子の側）を残す。日本語のファイル名が
  -- あるので、文字数ではなく表示幅で詰める。… のぶん 1 幅を空ける。
  local text = label(win)
  local chars = vim.fn.strchars(text)
  if vim.fn.strdisplaywidth(text) > room then
    local keep = chars
    while keep > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, chars - keep)) > room - 1 do
      keep = keep - 1
    end
    text = "…" .. vim.fn.strcharpart(text, chars - keep)
  end

  local name_hl = win == vim.api.nvim_get_current_win() and "%#Normal#" or "%#Comment#"
  local tail = width - frame - vim.fn.strdisplaywidth(text)
  return table.concat({
    HL,
    lead,
    "┤ ",
    name_hl,
    text,
    HL,
    " ├",
    string.rep("═", math.max(tail, 0)),
  })
end

-- 左端の縦線。行番号・サイン・折りたたみは LazyVim（snacks）が組んだものを
-- そのまま使い、その左に線を足すだけにする。
function M.statuscolumn()
  local prefix = at_left[vim.g.statusline_winid] and VERT or ""
  return prefix .. LazyVim.statuscolumn()
end

-- winhighlight の 1 項目だけを差し替える。neo-tree のように自前の winhighlight を
-- 持つウィンドウがあるので、まるごと上書きはしない。link に nil を渡すと外す。
local function set_winhl(win, group, link)
  local items = {}
  local replaced = false
  for item in tostring(vim.wo[win].winhighlight):gmatch("[^,]+") do
    if item:match("^([^:]+):") == group then
      replaced = true
      if link then
        items[#items + 1] = group .. ":" .. link
      end
    else
      items[#items + 1] = item
    end
  end
  if link and not replaced then
    items[#items + 1] = group .. ":" .. link
  end
  local value = table.concat(items, ",")
  if vim.wo[win].winhighlight ~= value then
    vim.wo[win].winhighlight = value
  end
end

local function is_edge(win)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  return vim.bo[vim.api.nvim_win_get_buf(win)].filetype == EDGE_FT
end

-- 場所取りウィンドウの中身。何も映さない空のバッファ。
local function get_edge_buf()
  if edge_buf and vim.api.nvim_buf_is_valid(edge_buf) then
    return edge_buf
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = EDGE_FT
  vim.bo[buf].modifiable = false
  edge_buf = buf
  return buf
end

-- LazyVim が winminwidth=5 を入れているので、そのままでは幅 1 にできない。
-- 幅を決める瞬間だけ下げる。
local function set_edge_width(win)
  local saved = vim.o.winminwidth
  vim.o.winminwidth = 0
  pcall(vim.api.nvim_win_set_width, win, 1)
  vim.o.winminwidth = saved
end

local function close_edge(tab)
  local win = edge_wins[tab]
  edge_wins[tab] = nil
  if win and vim.api.nvim_win_is_valid(win) then
    local saved = vim.o.eventignore
    vim.o.eventignore = "all"
    pcall(vim.api.nvim_win_close, win, true)
    vim.o.eventignore = saved
  end
end

-- 開くときに BufWinEnter などが飛ぶと、それを見ている側（neo-tree の root 追従や
-- この module 自身の refresh）が反応してしまう。イベントごと止めて開く。
-- botright は画面全体の右端に全高で開くので、どのウィンドウから呼んでも同じ場所に出る。
local function open_edge(anchor)
  local saved = vim.o.eventignore
  vim.o.eventignore = "all"
  local win
  local ok = pcall(vim.api.nvim_win_call, anchor, function()
    vim.cmd("botright vsplit")
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, get_edge_buf())
  end)
  vim.o.eventignore = saved
  if not ok or not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end

  -- 何も出さない。行番号やサインが出ると幅 1 に収まらないし、
  -- 末尾記号（eob の ~）が見えると線の外に点が並ぶ。
  local wo = vim.wo[win][0]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.colorcolumn = ""
  wo.cursorline = false
  wo.cursorcolumn = false
  wo.list = false
  wo.wrap = false
  wo.spell = false
  -- 等幅化やリサイズで潰されないようにし、他のバッファを流し込まれるのも塞ぐ
  wo.winfixwidth = true
  wo.winfixbuf = true
  -- フォーカスが外れたときだけ背景が変わると、右端の 1 列だけ色が浮く
  wo.winhighlight = "NormalNC:Normal"
  vim.api.nvim_win_call(win, function()
    vim.opt_local.fillchars:append({ eob = " " })
  end)

  set_edge_width(win)
  return win
end

-- 右端に線のウィンドウが立っている状態にする。
local function ensure_edge(tab, anchor)
  local win = edge_wins[tab]
  if win and is_edge(win) then
    -- 分割の作られ方によっては右端から外れる。そのときは畳んで立て直す。
    local right = vim.fn.win_screenpos(win)[2] + vim.api.nvim_win_get_width(win) - 1
    if right == vim.o.columns then
      set_edge_width(win)
      return win
    end
    close_edge(tab)
  end
  edge_wins[tab] = open_edge(anchor)
  return edge_wins[tab]
end

-- 線のウィンドウにカーソルが入ってしまったら実ウィンドウへ戻す。
-- <C-w> の移動やウィンドウピッカーは、こちらの都合を知らない。
function M.avoid()
  local win = vim.api.nvim_get_current_win()
  if not is_edge(win) then
    return
  end
  vim.cmd("wincmd p")
  if vim.api.nvim_get_current_win() == win then
    vim.cmd("wincmd h")
  end
end

-- 閉じようとしているのが最後の実ウィンドウなら、線のウィンドウを先に畳む。
-- 残っていると :q でウィンドウが 1 枚残り、Neovim が終わらない。
function M.close_if_last()
  local tab = vim.api.nvim_get_current_tabpage()
  local real = 0
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(win).relative == "" and not is_edge(win) then
      real = real + 1
    end
  end
  if real <= 1 then
    close_edge(tab)
  end
end

-- 終了前に畳む。セッション（persistence）に空のウィンドウが混ざるのを避ける。
function M.close_all()
  for tab in pairs(edge_wins) do
    close_edge(tab)
  end
end

-- 端に接するウィンドウを求め直す。分割・リサイズでどのウィンドウが端に来るかは
-- 変わるため、レイアウトが動くたびに走る。
function M.refresh()
  local tab = vim.api.nvim_get_current_tabpage()
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return
  end

  local function layout_wins()
    return vim.tbl_filter(function(win)
      -- float は winborder で既に枠がある（グローバルの winbar も使わない）
      return vim.api.nvim_win_get_config(win).relative == ""
    end, vim.api.nvim_tabpage_list_wins(tab))
  end

  local wins = layout_wins()
  local real = vim.tbl_filter(function(win)
    return not is_edge(win)
  end, wins)
  -- 実ウィンドウが無いなら線も要らない（残すと Neovim が終われない）
  if #real == 0 then
    close_edge(tab)
    return
  end

  ensure_edge(tab, real[1])
  wins = layout_wins()

  -- tabline（bufferline）の有無で最上段の行位置が変わるので、実測の最小値を使う。
  local top = math.huge
  for _, win in ipairs(wins) do
    top = math.min(top, vim.fn.win_screenpos(win)[1])
  end

  at_left = {}
  for _, win in ipairs(wins) do
    local pos = vim.fn.win_screenpos(win)
    if pos[2] == 1 then
      at_left[win] = true
    end
    -- winbar は window-local に掛け分ける。式が空文字を返しても winbar の行
    -- 自体は確保されてしまうので、線を引かないウィンドウでは値ごと空にする。
    -- 右端の場所取りには引かない。ここに引くと上端の線が右端の縦線より
    -- 1 列はみ出す（縦線はその左の区切り線が描いているため）。
    local winbar = (pos[1] == top and not is_edge(win)) and WINBAR or ""
    if vim.wo[win].winbar ~= winbar then
      vim.wo[win].winbar = winbar
    end

    -- バッファ末尾より下の行に statuscolumn は描かれず、左端の線がそこで切れる。
    -- その範囲は行頭に出る eob 記号（既定は ~）を線に置き換えて繋ぐ。
    -- 端でなくなったウィンドウには毎回 " " を掛け直すので、状態を覚えなくてよい。
    local left = at_left[win] or false
    vim.api.nvim_win_call(win, function()
      vim.opt_local.fillchars:append({ eob = left and "║" or " " })
    end)
    set_winhl(win, "EndOfBuffer", left and "WinSeparator" or nil)
  end

  -- statuscolumn は全ウィンドウで同じ式にして、左端かどうかは式の中で見る。
  -- ウィンドウごとに式を掛け分けると、vim.wo への代入がグローバル値まで
  -- 書き換えてしまい、内側のウィンドウにも線が残る。
  -- LazyVim が :set で入れた値は各ウィンドウのローカル値として残っているので、
  -- グローバルだけでなく既存のウィンドウにも掛け直す。
  -- 右端の線は自前の見た目を持つので触らない。
  if vim.go.statuscolumn ~= STATUSCOLUMN then
    vim.go.statuscolumn = STATUSCOLUMN
  end
  for _, win in ipairs(wins) do
    if not is_edge(win) and vim.wo[win].statuscolumn ~= STATUSCOLUMN then
      vim.wo[win].statuscolumn = STATUSCOLUMN
    end
  end
end

-- lualine が組んだ statusline の余白を、枠の線で埋める。
--
--   ╚═╡ NORMAL  main ╞═══════════════════════════════╡ 1:1  18:00 ╞═╝
--
-- lualine は左寄せと右寄せの境目に %= を置く。%= は空白でしか伸びないので、
-- 伸ばさずに測って（maxwidth=0 なら %= は 0 幅）残り幅を出し、その幅ぶんの
-- ═ に置き換える。lualine.statusline() を包むだけなので、lualine 側の
-- 更新契機や設定には手を入れない。
local hooked = false

function M.hook_statusline()
  if hooked then
    return
  end
  hooked = true

  local lualine = require("lualine")
  local inner = lualine.statusline
  lualine.statusline = function(...)
    local text = inner(...)
    if type(text) ~= "string" then
      return text
    end
    -- %= が 1 つだけのときに限る。複数あると、残りが空白で伸びて幅が合わない。
    local pos = text:find("%=", 1, true)
    if not pos or text:find("%=", pos + 2, true) then
      return text
    end

    local ok, measured = pcall(vim.api.nvim_eval_statusline, text, { maxwidth = 0, highlights = false })
    if not ok then
      return text
    end
    local width = vim.o.laststatus == 3 and vim.o.columns or vim.api.nvim_win_get_width(0)
    local fill = width - measured.width
    if fill < 1 then
      return text
    end
    return text:sub(1, pos - 1) .. HL .. string.rep("═", fill) .. text:sub(pos + 2)
  end
end

-- winbar を付けるとウィンドウの高さが変わり、その変化がまた WinResized を
-- 呼ぶ。1 回に畳んでから走らせる（値が変わらなければ何もしないので 2 巡目で
-- 止まる）。
local pending = false

function M.schedule()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    M.refresh()
  end)
end

return M
