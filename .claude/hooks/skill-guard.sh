#!/usr/bin/env bash
# PreToolUse (Write|Edit) hook.
# SKILL.md を編集しようとしたときだけ、skill-authoring / skill-review への参照を
# モデルのコンテキストへ注入する。それ以外は何もしない。
# 失敗しても編集を止めないよう、常に exit 0 で抜ける。

file_path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

case "$file_path" in
*/SKILL.md)
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
