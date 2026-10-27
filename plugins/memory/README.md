# memory

Skills for agent memory that keeps itself current: what a session learned is captured, what it
left open is tracked, and what proves durable is promoted.

| Skill | What it does | CLI |
|---|---|---|
| `reflect` | End-of-session retrospective: reviews the session, writes durable learnings to auto-memory, updates the right repo's rules and docs, proposes skill and hook improvements, and records open follow-ups as rows in the reflections store. | `reflections` |
| `dreaming` | Nightly consolidation in three phases (light, REM, deep) over the analyzer's output: promotes durable candidates into `MEMORY.md` and keeps a narrative diary (`DREAMS.md`). Opt-in per repo. | `dream`, `dream-prep` |
| `session-analyzer` | Scans past transcripts for unfinished work, corrections that recur, and memory candidates, per project and per machine. | `session-analyzer` |

## Install

```text
/plugin marketplace add coletebou/dx
/plugin install memory@dx
```

The skills drive CLIs that live in the dotfiles part of this repo (`scripts/`), next to the hooks
that feed the same store (the session reflector, the load-memory and reflections-context hooks). From
a clone, `./install.sh --with memory` links the CLIs into `~/.local/bin` and the skills into
`~/.claude/skills`, and `./install.sh --with schedules` adds the nightly `dream-prep` + `dream sweep`.

The memory itself (memory files, reflections, diaries, analysis output) is data, not code: keep it
in a private repository. This repo's `.gitignore` keeps it out of a fork. The design, the config
files and the data boundary (`MEMORY_BOUNDARY_CMD`, which keeps chosen sessions away from every
model call) are in [`docs/memory/README.md`](../../docs/memory/README.md).

## Requirements

Python 3 with SQLite FTS5, jq, the `claude` CLI for the model passes, and bash 4.4 or newer for
`session-analyzer` (on macOS, Homebrew's bash).
