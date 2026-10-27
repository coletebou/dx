# tmux

Housekeeping for long-running tmux servers full of agent sessions.

| Skill | What it does | CLI |
|---|---|---|
| `tmux-archive` | Captures every pane of every session to `~/.claude/skill-data/tmux-archive/archives/<time>/`, with `manifest.json` and a README: error and test-result signals per pane, the Claude Code agent running in it (from `claude agents --json`), and a link to its transcript. Read-only. | `tmux-archive` |
| `tmux-organize` | Reads a fresh archive, proposes descriptive window and session names and a regrouping as a JSON plan, and applies it only after you approve. Renames and moves only: no pane, window or process is ever killed. | `tmux-apply-plan` |

## Install

```text
/plugin marketplace add coletebou/dx
/plugin install tmux@dx
```

Both CLIs are in this plugin's `bin/`, which Claude Code puts on the Bash tool's `PATH` while the
plugin is enabled. From a clone, `./install.sh --with tmux` links them and the skills, together with
the tmux configuration itself (`base/tmux.conf`) and the scripts that resume Claude Code and Codex
sessions after a tmux-resurrect restore.

## Requirements

tmux, jq and Python 3. `tmux-apply-plan` needs bash 4 or newer: on macOS, put Homebrew's bash ahead
of `/bin/bash` on `PATH` (it stops with that advice on bash 3.2).
