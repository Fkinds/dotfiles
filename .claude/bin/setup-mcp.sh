#!/usr/bin/env bash
# Claude Code に user スコープの MCP サーバーを登録する。何度流してもよい(登録し直す)。
#
# MCP の設定は ~/.claude.json に入り、このリポジトリの symlink 管理には乗らないので、
# 新しいマシンではこれを流して揃える。
#
# このリポジトリは public なので、トークンはここにも ~/.claude.json にも書かない。
# 接続のたびに headersHelper が gh のトークンを取りに行く。
#
# AWS のプロファイル名も社内のシステム名なので書かない。実行時に渡す。
#   AWS_MCP_PROFILE=<dev のプロファイル> setup-mcp.sh
set -euo pipefail

: "${AWS_MCP_PROFILE:?AWS_MCP_PROFILE に dev のプロファイル名を渡す(本番は渡さない)}"

add() {
  local name=$1 json=$2
  claude mcp remove --scope user "$name" >/dev/null 2>&1 || true
  claude mcp add-json --scope user "$name" "$json"
}

# GitHub 公式のリモート MCP。gh で有効なアカウントの権限で動く(要 gh auth login)。
add github '{
  "type": "http",
  "url": "https://api.githubcopilot.com/mcp/",
  "headersHelper": "gh auth token | jq -Rc \"{Authorization: (\\\"Bearer \\\" + .)}\""
}'

# AWS 公式ドキュメントの検索と閲覧。認証情報は使わない。
add aws-docs '{
  "type": "stdio",
  "command": "uvx",
  "args": ["awslabs.aws-documentation-mcp-server@latest"],
  "env": {"FASTMCP_LOG_LEVEL": "ERROR"}
}'

# AWS CLI 相当の操作。user スコープで全プロジェクトから呼べるので、dev のプロファイルに
# 固定し、読み取り系の操作に限る。本番のプロファイルを渡さないこと。
add aws-api "$(jq -n --arg profile "$AWS_MCP_PROFILE" '{
  type: "stdio",
  command: "uvx",
  args: ["awslabs.aws-api-mcp-server@latest"],
  env: {
    AWS_API_MCP_PROFILE_NAME: $profile,
    AWS_REGION: "ap-northeast-1",
    READ_OPERATIONS_ONLY: "true"
  }
}')"
