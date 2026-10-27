# session

Session lifecycle for Claude Code sessions that live in tmux panes.

| Skill | What it does | CLI |
|---|---|---|
| `cc-park` | Parks idle sessions to free their memory: Claude exits through `/exit`, the pane keeps the last screen as text, and the resume command waits at the prompt so Enter brings the conversation back. Finished sessions get their window closed, with the resume command kept in `cc-park status`. | `cc-park` (in this plugin's `bin/`) |
| `fresh-session-handoff` | Hands a long session to a fresh one as the next generation of a handoff chain: a written brief, a new tmux window, the old window closed once the successor answers. | `cc-handoff` (`scripts/` in this repo) |

## Install

```text
/plugin marketplace add coletebou/dx
/plugin install session@dx
```

Claude Code puts the plugin's `bin/` on the Bash tool's `PATH` while the plugin is enabled,
so `cc-park` works right away. `fresh-session-handoff` drives `cc-handoff`, which lives in the
dotfiles part of this repo: from a clone, `./install.sh --with session` links both CLIs into
`~/.local/bin` and both skills into `~/.claude/skills`.

To autopark every 30 minutes, `./install.sh --with schedules` installs a LaunchAgent (macOS)
or a systemd user timer (Linux) that runs `cc-park auto`.

## Requirements

tmux, Python 3, and for `cc-handoff` also bash, zsh and jq. The design of handoff chains is in
[`docs/handoff.md`](../../docs/handoff.md).
