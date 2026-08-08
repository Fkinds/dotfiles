#!/usr/bin/env bash
# 起動中の Claude Code セッションを 1 画面に一覧する。Ghostty のタブを 1 枚使って常駐させる。
#
# 要対応 / 稼働中 / 待機 の 3 セクションに分け、1 セッションを最大 3 行で出す。
#   名前行: グリフ + リポジトリ名(状態によらず同じ明るさ)
#   メタ行: 状態 / ブランチ / 経過 / セッション ID(状態の色が乗る)
#   活動行: 使っているサブエージェントと /スキル(何も無ければ出さない)
#
# 固定幅の列を持たないので、Ghostty の全幅でも nvim の 40 桁サイドバーでも折り返さない。
# 溢れる文字列は削ってよいものから順に切る。
#
# 状態は .claude/hooks/agent-state.sh が ~/.claude/agent-state/ に書く。活動行は
# セッションの transcript(JSONL)から Agent / Task / Skill の tool_use を拾う。どちらも
# 読むだけで、Claude Code には一切干渉しない。
#
#   agent-dashboard.sh          1 秒ごとに再描画して常駐する
#   agent-dashboard.sh --once   1 回だけ描画して終了する(動作確認向け)
set -u

STATE_DIR="$HOME/.claude/agent-state"
STALE_SEC=28800  # 8 時間更新のないものは異常終了とみなして消す
FALLBACK_COLS=68 # tput が幅を返さないとき(パイプ経由など)の想定幅

C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_RED=$'\033[1;31m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_HEAD=$'\033[1m'
C_NAME=$'\033[1m'     # 名前行。状態の色はグリフとメタ行に乗せ、名前は明るさを一定に保つ
C_SEC=$'\033[2m'      # セクション見出し
C_ACT=$'\033[2;37m'   # 活動行(サブエージェント稼働なし)
C_ACT_RUN=$'\033[36m' # 活動行(サブエージェント稼働中)

# 状態名 → 並び順 / セクション / ラベル / ラベルの表示幅 / グリフ。
# 並び順が小さいほど上に出す(要対応を最優先)。全角ラベルは printf の桁指定と表示幅が
# 合わないため、幅を数値で持って自分で詰める(column も ANSI も全角幅を数え違える)。
# グリフは色が出ない環境でも読めるよう、状態ごとに形を変える。
meta() {
  case "$1" in
  blocked) printf '0\t要対応\t承認待ち\t8\t◉' ;;
  attention) printf '1\t要対応\t要対応\t6\t◉' ;;
  working) printf '2\t稼働中\t処理中\t6\t●' ;;
  done) printf '3\t稼働中\t完了\t4\t●' ;;
  *) printf '4\t待機\t待機\t4\t○' ;;
  esac
}

paint() {
  case "$1" in
  blocked) printf '%s' "$C_RED" ;;
  attention) printf '%s' "$C_YELLOW" ;;
  working) printf '%s' "$C_CYAN" ;;
  done) printf '%s' "$C_GREEN" ;;
  *) printf '%s' "$C_DIM" ;;
  esac
}

sec_width() {
  case "$1" in
  待機) printf '4' ;;
  *) printf '6' ;;
  esac
}

# 表示幅で切り詰める。リポジトリ名とブランチ名は ASCII 前提の近似で数える。
# 末尾の … は曖昧幅だが、Ghostty は既定で半角に倒すのでここでは 1 桁として扱う。
trim() {
  local s=$1 max=$2
  if [ "$max" -lt 1 ]; then
    printf ''
  elif [ "${#s}" -gt "$max" ]; then
    printf '%s…' "${s:0:$((max - 1))}"
  else
    printf '%s' "$s"
  fi
}

elapsed() {
  local s=$1
  if [ "$s" -lt 60 ]; then
    printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%dm' "$((s / 60))"
  else
    printf '%dh%02dm' "$((s / 3600))" "$(((s % 3600) / 60))"
  fi
}

# 下段の折り返しを避けるため実際の端末幅に合わせる。tput は tty でないと失敗する。
term_cols() {
  local c
  c=$(tput cols 2>/dev/null)
  case "$c" in
  '' | *[!0-9]*) c=$FALLBACK_COLS ;;
  esac
  # 固定幅の列を持たないので下限は低くてよい。24 桁あればメタ行が 1 行に収まる。
  [ "$c" -lt 24 ] && c=24
  printf '%s' "$c"
}

# 全セッション分の下段を一括で作る。`session_id \t 稼働中(0|1) \t 本文` の TSV。
# セッションごとに python を起動すると 1 秒ごとの再描画に間に合わないため、まとめて処理する。
#
# transcript は数 MB になり末尾だけ読むと取りこぼすので、全部読んだ結果を
# ~/.claude/cache/agent-dashboard.json に持ち、次回は増えたバイトだけ読む。
activity() {
  python3 - "$STATE_DIR" "$1" <<'PY'
import glob
import json
import os
import sys
import time

state_dir = sys.argv[1]
max_width = int(sys.argv[2])

PROJECTS = os.path.expanduser('~/.claude/projects')
CACHE = os.path.expanduser('~/.claude/cache/agent-dashboard.json')
MAX_ITEMS = 3    # 下段に並べる名前の上限
KEEP = 20        # キャッシュに残す履歴の件数
RUNNING_SEC = 20 # サブエージェントの transcript がこの秒数内に更新されていたら稼働中とみなす


def transcript_path(session_id, hinted):
    if hinted and os.path.exists(hinted):
        return hinted
    # hook が transcript_path を書く前に始まったセッションもあるので session_id から探す。
    # worktree 用に 1 段深く置かれることがあるため 2 パターン見る。
    for pattern in ('*/%s.jsonl', '*/*/%s.jsonl'):
        found = glob.glob(os.path.join(PROJECTS, pattern % session_id))
        if found:
            return max(found, key=os.path.getmtime)
    return None


def blank():
    # offset: 次に読み始めるバイト位置。pending: tool_result がまだ返っていない呼び出し。
    return {'offset': 0, 'pending': [], 'agents': [], 'skills': []}


def consume(entry, text):
    """transcript の新しい部分を読んで entry を更新する。"""
    pending, agents, skills = entry['pending'], entry['agents'], entry['skills']
    for line in text.splitlines():
        # tool_use_id は生の行に文字列として現れるので、照合は部分一致で足りる。
        # 大半の行はここで捨てられ、JSON 化するのはツール呼び出しの行だけになる。
        if pending and '"tool_result"' in line:
            entry['pending'] = pending = [p for p in pending if p[0] not in line]
        if '"tool_use"' not in line:
            continue
        if not ('"Agent"' in line or '"Task"' in line or '"Skill"' in line):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        blocks = (record.get('message') or {}).get('content')
        if not isinstance(blocks, list):
            continue
        for block in blocks:
            if not isinstance(block, dict) or block.get('type') != 'tool_use':
                continue
            name = block.get('name')
            params = block.get('input') or {}
            if name in ('Agent', 'Task'):
                # subagent_type 省略時は general-purpose に落ちる。
                kind = params.get('subagent_type') or 'general-purpose'
                agents.append(kind)
                del agents[:-KEEP]
                pending.append([block.get('id'), kind])
            elif name == 'Skill' and params.get('skill'):
                skills.append(params['skill'])
                del skills[:-KEEP]


def refresh(path, entry):
    """increment 分だけ読み進める。ファイルが作り直されていたら最初から読む。"""
    if not isinstance(entry, dict) or set(entry) != set(blank()):
        entry = blank()
    with open(path, 'rb') as fh:
        size = os.fstat(fh.fileno()).st_size
        if entry['offset'] > size:
            entry = blank()
        if entry['offset'] == size:
            return entry
        fh.seek(entry['offset'])
        chunk = fh.read()
    end = chunk.rfind(b'\n')
    if end < 0:
        return entry  # 書き込み途中の行しかないので次の描画に回す
    consume(entry, chunk[:end].decode('utf-8', 'replace'))
    entry['offset'] += end + 1
    return entry


def subagent_running(session_id):
    """バックグラウンドのサブエージェントは tool_result が即返るので mtime で見る。"""
    now = time.time()
    for path in glob.glob(os.path.join(PROJECTS, '*', session_id, 'subagents', '*.jsonl')):
        try:
            if now - os.path.getmtime(path) <= RUNNING_SEC:
                return True
        except OSError:
            pass
    return False


def tally(names):
    """出現順を保ったまま重複を畳んで `name x2` にする。"""
    ordered = []
    for name in names:
        for i, (existing, count) in enumerate(ordered):
            if existing == name:
                ordered[i] = (existing, count + 1)
                break
        else:
            ordered.append((name, 1))
    return [n if c == 1 else '%s x%d' % (n, c) for n, c in ordered[:MAX_ITEMS]]


def latest_unique(names):
    """新しい順に重複を落として並べる。"""
    seen, ordered = set(), []
    for name in reversed(names):
        if name not in seen:
            seen.add(name)
            ordered.append(name)
    return ordered[:MAX_ITEMS]


try:
    with open(CACHE, encoding='utf-8') as fh:
        cache = json.load(fh)
    if not isinstance(cache, dict):
        cache = {}
except (OSError, ValueError):
    cache = {}

# 終了したセッションのぶんは書き戻さないので、キャッシュは勝手に縮む。
fresh = {}

for state_file in sorted(glob.glob(os.path.join(state_dir, '*.json'))):
    try:
        with open(state_file, encoding='utf-8') as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        continue  # 状態ファイルの書き換え途中に当たっただけなので次の描画で拾える
    session_id = state.get('session_id')
    if not session_id:
        continue

    running, items = 0, []
    path = transcript_path(session_id, state.get('transcript_path'))
    if path:
        try:
            entry = refresh(path, cache.get(path))
        except OSError:
            entry = blank()
        fresh[path] = entry
        pending = [name for _, name in entry['pending']]
        items = tally(pending) if pending else latest_unique(entry['agents'])
        # スキルは頭に / を付けてサブエージェントと見分ける(呼び出し表記と同じ形)。
        items = items + ['/' + name for name in latest_unique(entry['skills'])]
        running = 1 if pending or subagent_running(session_id) else 0

    # 名前はどれも ASCII のスラグなので、表示幅は文字数で数えて足りる。
    body = ', '.join(items)
    if len(body) > max_width:
        body = body[:max_width - 1] + '…'
    print('%s\t%d\t%s' % (session_id, running, body))

try:
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(fresh, fh)
    os.replace(tmp, CACHE)
except OSError:
    pass  # キャッシュが書けなくても次回まるごと読み直すだけで済む
PY
}

# $1: 各行の本文に使える桁数(左インデントと右余白を引いたもの)
collect() {
  local avail=$1
  local now acts f status cwd ts sid age prio section label lw glyph repo branch el run act used metaline
  now=$(date +%s)
  acts=$(activity "$avail")
  shopt -s nullglob
  for f in "$STATE_DIR"/*.json; do
    IFS=$'\t' read -r status cwd ts sid < <(
      jq -r '[.status // "idle", .cwd // "", .ts // 0, .session_id // ""] | @tsv' "$f" 2>/dev/null
    )
    [ -z "${sid:-}" ] && continue

    age=$((now - ts))
    if [ "$age" -gt "$STALE_SEC" ]; then
      rm -f "$f"
      continue
    fi

    IFS=$'\t' read -r prio section label lw glyph < <(meta "$status")

    repo=$(basename "${cwd:-?}")
    # macOS に timeout(1) は無いので直接呼ぶ。branch --show-current はローカル参照のみで完結する。
    branch=$(git -C "$cwd" branch --show-current 2>/dev/null)
    [ -z "$branch" ] && branch='-'
    el=$(elapsed "$age")

    # メタ行は「状態 · ブランチ · 経過 · ID」。区切り " · " は 3 桁。入り切らないときは
    # まず ID を落とし、それでも溢れるならブランチを削る(状態と経過は削ると読めなくなる)。
    used=$((lw + 3 + 3 + ${#el} + 3 + 8))
    if [ $((used + ${#branch})) -le "$avail" ]; then
      metaline="$label · $branch · $el · ${sid:0:8}"
    else
      metaline="$label · $(trim "$branch" $((avail - lw - 3 - 3 - ${#el}))) · $el"
    fi

    unset run act
    IFS=$'\t' read -r run act < <(
      printf '%s\n' "$acts" | awk -F'\t' -v s="$sid" '$1 == s { print $2 "\t" $3; exit }'
    )

    # 先頭の prio は並べ替え専用。描画時に落とす。
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$prio" "$section" "$glyph" "$status" "$(trim "$repo" "$avail")" \
      "$metaline" "${run:-0}" "${act:-}"
  done
  shopt -u nullglob
}

render() {
  local cols avail rows count section body n pad glyph status repo metaline run act
  cols=$(term_cols)
  avail=$((cols - 3)) # 左インデント 2 桁と右端の余白 1 桁を引く
  [ "$avail" -lt 20 ] && avail=20

  rows=$(collect "$avail" | sort -t$'\t' -k1,1 -k5,5 | cut -f2-)
  count=$(printf '%s' "$rows" | grep -c . || true)

  pad=$((cols - 6 - ${#count} - 1)) # agents は 6 桁
  [ "$pad" -lt 1 ] && pad=1
  printf '%sagents%s%*s%s%s%s\n' "$C_HEAD" "$C_RESET" "$pad" '' "$C_DIM" "$count" "$C_RESET"
  # 「時刻 + 更新 1s + 終了 Ctrl-C」で 30 桁。入らない幅では時刻だけにする。
  if [ "$cols" -ge 30 ]; then
    printf '%s\n' "${C_DIM}$(date '+%H:%M:%S')  更新 1s  終了 Ctrl-C${C_RESET}"
  else
    printf '%s\n' "${C_DIM}$(date '+%H:%M:%S')${C_RESET}"
  fi

  if [ "$count" -eq 0 ]; then
    printf '\n%s\n' "${C_DIM}起動中のセッションはありません${C_RESET}"
    return
  fi

  # セクション順は固定。該当セッションが無いセクションは見出しごと出さない。
  for section in 要対応 稼働中 待機; do
    body=$(awk -F'\t' -v s="$section" '$1 == s' <<<"$rows")
    n=$(printf '%s' "$body" | grep -c . || true)
    [ "$n" -eq 0 ] && continue

    pad=$((cols - 1 - $(sec_width "$section") - ${#n} - 1)) # ▍が 1 桁、右端に 1 桁空ける
    [ "$pad" -lt 1 ] && pad=1
    printf '\n%s▍%s%*s%s%s\n' "$C_SEC" "$section" "$pad" '' "$n" "$C_RESET"

    while IFS=$'\t' read -r _ glyph status repo metaline run act; do
      [ -z "$repo" ] && continue
      printf '%s%s%s %s%s%s\n' "$(paint "$status")" "$glyph" "$C_RESET" "$C_NAME" "$repo" "$C_RESET"
      printf '  %s%s%s\n' "$(paint "$status")" "$metaline" "$C_RESET"
      if [ -n "$act" ]; then
        if [ "$run" = "1" ]; then
          printf '  %s%s%s\n' "$C_ACT_RUN" "$act" "$C_RESET"
        else
          printf '  %s%s%s\n' "$C_ACT" "$act" "$C_RESET"
        fi
      fi
    done <<<"$body"
  done
}

if [ "${1:-}" = "--once" ]; then
  render
  exit 0
fi

printf '\033]0;agents\007' # Ghostty のタブ名を agents にする
printf '\033[?25l'         # カーソルを隠す
trap 'printf "\033[?25h\n"; exit 0' INT TERM EXIT

while true; do
  out=$(render)
  printf '\033[H\033[2J%s\n' "$out" # 描画してから一括で置き換え、ちらつきを抑える
  sleep 1
done
