#!/usr/bin/env bash
# Claude Code セッションの状態を ~/.claude/agent-state/<session_id>.json に書き出す。
#
# 第 1 引数に状態名を取り、hook の stdin JSON から session_id / cwd を拾う。
# 状態名: blocked(承認待ち) / attention(要対応) / working(処理中) / done(応答完了)
#         idle(セッション開始直後) / end(セッションを一覧から消す)
#
# 一覧表示は .claude/bin/agent-dashboard.sh が担当する。
#
# 状態ディレクトリを ~/.claude/agents/ にしないこと。そこはサブエージェント定義の置き場。
set -u

status="${1:-idle}"
dir="$HOME/.claude/agent-state"
input=$(cat)

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$sid" ] && exit 0

path="$dir/$sid.json"

if [ "$status" = "end" ]; then
  rm -f "$path"
  exit 0
fi

mkdir -p "$dir"

# 一覧側が読んでいる最中の半端な書き込みを見ないよう、書いてから rename する。
# transcript_path は一覧側が「使用中のサブエージェント / スキル」を読むのに使う。
printf '%s' "$input" | jq -c \
  --arg status "$status" \
  --argjson ts "$(date +%s)" \
  '{session_id, status: $status, cwd: (.cwd // ""), permission_mode: (.permission_mode // ""), transcript_path: (.transcript_path // ""), ts: $ts}' \
  >"$path.tmp" 2>/dev/null && mv -f "$path.tmp" "$path"

exit 0
