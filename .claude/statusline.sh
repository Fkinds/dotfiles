#!/usr/bin/env bash
# Claude Code statusline (Powerline style): repo > branch > python
# 三角区切り () と git アイコン () は Nerd Font / Powerline フォントが必要。
input=$(cat)

# Claude Code が今いるディレクトリでブランチを見る。worktree や cd での移動にも追従する。
# project_dir は起動時の場所で固定、nvim の getcwd() は claudecode.nvim の cwd_provider
# (バッファのプロジェクトルート)とずれるので、どちらも使わない。
dir=$(printf '%s' "$input" | jq -r '.workspace.current_dir // empty' 2>/dev/null)
[ -n "$dir" ] && cd "$dir" 2>/dev/null

# フルパスではなく git リポジトリ名（= toplevel の basename）だけを出す。
# git 管理外なら現在ディレクトリ名にフォールバックする。
repo_root=$(git rev-parse --show-toplevel 2>/dev/null)
name=$(basename "${repo_root:-${dir:-$PWD}}")
branch=$(git branch --show-current 2>/dev/null)

# uv が解決する Python（.python-version のピン留めも反映）。無ければ system python3 にフォールバック。
py_bin=$(uv python find 2>/dev/null)
py=$("${py_bin:-python3}" --version 2>/dev/null | awk '{print $2}')

# Powerline glyphs (Nerd Font 必須)
SEP=$''      #
FOLDER=$''   #
GIT=$''      #

# 256-color segment palette (bg / fg)
DIR_BG=24;  DIR_FG=255    # deep blue
GIT_BG=54;  GIT_FG=255    # purple
PY_BG=236;  PY_FG=255     # dark gray
RESET=$'\033[0m'

bg() { printf '\033[48;5;%sm' "$1"; }
fg() { printf '\033[38;5;%sm' "$1"; }

out=""
prev_bg=""

# Git branch segment
if [ -n "$branch" ]; then
  out+="$(bg $GIT_BG)$(fg $GIT_FG) ${GIT} ${branch} "
  prev_bg=$GIT_BG
fi

# Python segment
if [ -n "$py" ]; then
  if [ -n "$prev_bg" ]; then
    out+="$(bg $PY_BG)$(fg $prev_bg)${SEP}"
  else
    out+="$(bg $PY_BG)"
  fi
  out+="$(fg $PY_FG) 🐍 ${py} "
  prev_bg=$PY_BG
fi

# Trailing separator back to terminal background
[ -n "$prev_bg" ] && out+="${RESET}$(fg $prev_bg)${SEP}${RESET}"

printf '%s' "$out"
