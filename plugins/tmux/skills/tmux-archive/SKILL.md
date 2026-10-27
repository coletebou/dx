---
name: tmux-archive
description: Snapshot every pane in every window in every tmux session to disk, organized by session/window with auto-detected filenames and a cross-referenced manifest. Use when the user says "capture all tmux panes", "archive my tmux state", "snapshot sessions", "back up my panes", "dump tmux to disk", "tmux snapshot", or invokes `/tmux-archive`. Links each pane to its Claude Code transcript when detectable.
---

# tmux-archive skill

## When to use
The user wants a durable record of what's in every tmux pane right now — before a reboot, before killing a session, for a daily work-journal, or to hand off context to another reviewer.

## What to do

1. Run the bundled capture script (in the plugin's `bin/`, on the Bash tool's `PATH`):
   ```bash
   tmux-archive [flags]
   ```

2. Report the archive path to the user. Default:
   `~/.claude/skill-data/tmux-archive/archives/<YYYYMMDD-HHMMSS>/`

3. Flags:
   - `--session <name>` — only this session (repeatable)
   - `--no-transcripts` — skip linking Claude transcripts
   - `--scrollback <N>` — capture last N lines instead of whole buffer (default: whole buffer, `-S -`)
   - `--dry-run` — print what would be written, don't write anything
   - `--out <dir>` — write to a different root
   - `--latest` — also update `<root>/latest` symlink to point at this run

## Output layout

```
<archive-root>/<timestamp>/
├── manifest.json                              # machine-readable index
├── README.md                                  # human-readable index
├── <session>/
│   └── <window_index>-<window_name>/
│       ├── <pane_index>-<cmd>-<pwd-basename>.txt   # captured pane content
│       └── <pane_index>-transcript.jsonl           # symlink to Claude jsonl (if detected)
└── ...
```

## Content detection

For each pane, the script extracts signals from the captured text:
- `error_keyword_count` — lines matching `ERROR`, `Traceback`, `FAIL`, `error:` or `fatal:`
  (any case)
- `test_summary` — the last `N passed, N failed` (or `N errors`) run in the
  pytest/jest output, if visible; empty otherwise
- `claude_transcript` — the path of the Claude `.jsonl` linked for the pane's
  cwd (the agent's own one when an agent matched, else the newest); empty when
  there is none or transcripts were not included

These land in `manifest.json` per-pane, next to `line_count`, `size_bytes` and
the pane's `pane_command` and `pane_path`. README.md summarizes.

## Claude agent integration

If `claude` is on `$PATH`, the script calls `claude agents --json` once and
matches each tmux pane to a live agent by walking the pane's process subtree
(via `pgrep -P`) for any pid in the agent list. When matched, each pane
record gets:

- `agent_pid` — Claude process pid
- `agent_session_id` — the agent's session id (its transcript is
  `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`)
- `agent_status` — `busy` / `idle` / other
- `agent_name` — agent's display name (when set)
- `agent_kind` — `interactive` etc.
- `agent_started_at` — epoch millis

The manifest also includes `agents` (the full snapshot) and
`unmatched_agents` (any agent whose pid wasn't in any pane subtree —
typically backgrounded or detached). The README surfaces busy/idle counts
in the header and an Agent column per pane.

When an agent match exists, the symlinked transcript is the authoritative
`<sessionId>.jsonl` rather than the newest jsonl in the cwd. This is
important on a machine where many sessions accumulate in one cwd.

## Safety

- Read-only — never writes to tmux, never kills sessions.
- Files written with the user's umask.
- If the archive dir exists, it's not overwritten — the script appends a suffix.

## Gotchas

- `capture-pane` only sees what's in tmux's scrollback buffer (default 2000 lines). For true lossless logs, the script prefers Claude `.jsonl` transcripts when available.
- Panes with binary output (curses apps, less, vim) will capture the current screen state, which may look like gibberish. That's expected.
- When pane content contains the capture command itself (because you just ran the script), the tail of the capture will echo it — not a bug.
