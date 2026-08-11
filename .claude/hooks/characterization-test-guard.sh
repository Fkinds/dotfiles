#!/usr/bin/env bash
# PreToolUse (Write) hook. characterization-test-writer サブエージェント専用。
# 特性テストは tests/ 配下にしか書かない。それ以外への書き込みを拒否する。
#
# 本文の指示だけでは、親セッションが acceptEdits / auto のとき素通りするため、
# ここで機構的に止める。判定できないときは通す(この hook は保険であって唯一の防壁ではない)。

file_path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

[ -z "$file_path" ] && exit 0

case "$file_path" in
*/tests/* | */test/* | tests/* | test/*)
  exit 0
  ;;
esac

jq -nc --arg p "$file_path" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: (
        "characterization-test-writer は tests/ 配下にしか書き込めません(拒否したパス: " + $p + ")。"
        + "実装コードの変更が必要だと判断した場合は、書き込まずに報告へ回してください。"
      )
    }
  }' 2>/dev/null || true

exit 0
