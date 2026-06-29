# 💤 LazyVim

A starter template for [LazyVim](https://github.com/LazyVim/LazyVim).
Refer to the [documentation](https://lazyvim.github.io/installation) to get started.

## Claude Code statusline

Powerline-style statusline for Claude Code (`dir  branch  python`). Requires a
Nerd Font / Powerline font for the glyphs (`  🐍`). Inside a Neovim `:terminal`
it syncs the directory with nvim's cwd via `$NVIM`.

Install:

```bash
cp .claude/statusline.sh ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```
