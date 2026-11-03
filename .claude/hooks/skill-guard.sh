#!/usr/bin/env bash
# PreToolUse (Write|Edit) hook.
# SKILL.md を編集しようとしたときだけ、skill-authoring / skill-review への参照を
# モデルのコンテキストへ注入する。それ以外は何もしない。
# 注入はセッションごとに最初の 1 回だけ。前に注入した文は文脈に残っている。
# 失敗しても編集を止めないよう、常に exit 0 で抜ける。

input=$(cat)
file_path=$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null || true)
session_id=$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null || true)

case "$file_path" in
*/SKILL.md)
  # session_id が取れないときは、従来どおり毎回注入する
  if [ -n "$session_id" ]; then
    marker="${TMPDIR:-/tmp}/claude-skill-guard/$session_id"
    [ -e "$marker" ] && exit 0
    mkdir -p "${marker%/*}" 2>/dev/null && : >"$marker" 2>/dev/null
  fi
  jq -nc '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: (
          "SKILL.md を編集しようとしています。skill-authoring スキルに従ってください。"
          + "frontmatter は name / description / license / compatibility / metadata / allowed-tools の6つのみ"
          + "(user-invocable などを足すと claude.ai / Skills API への配布時にハードエラーになる)。"
          + "description は三人称で What と When を書き、ユーザーが実際に口にする語をトリガーに入れる"
          + "(1スキルあたり1536文字で切り詰め)。allowed-tools は最小限に。本文は500行以下。"
          + "一連の編集が終わったら skill-review で点検してください。"
        )
      }
    }' 2>/dev/null || true
  ;;
esac

exit 0
