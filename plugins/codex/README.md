# codex

Skills for driving and supervising OpenAI Codex CLI agents from another agent.

| Skill | What it does |
|---|---|
| `codex-subagents` | Spawns Codex subagents through tmux: a window of N interactive panes for a parallel review or research fan-out, or a one-shot `codex exec` for a bounded task. Covers the briefing template, buffer-pasting multi-line prompts, checking that each pane really submitted, collecting reports before cleanup, and a read-only Claude fallback when Codex is unavailable. |
| `codex-transcripts` | Reads a Codex agent's session transcript (its thread in Codex's SQLite state and the rollout JSONL) when the pane shows only collapsed output, the agent compacted away its history, or you need to verify what it did rather than take its word. |

## Install

```text
/plugin marketplace add coletebou/dx
/plugin install codex@dx
```

From a clone, `./install.sh --with codex` links the skills into `~/.claude/skills` together with the
Codex configuration defaults in `codex/`.

## Requirements

tmux, the `codex` CLI, sqlite3 and Python 3. Neither skill changes Codex's own configuration: models,
effort and profiles are per-invocation flags.
