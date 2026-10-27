---
name: codex-transcripts
description: Read what a Codex CLI agent is actually doing by querying its session transcript instead of scraping the tmux pane. Use when supervising or coordinating with a Codex agent running in another tmux window/pane, when pane output shows truncation markers like "… +66 lines (ctrl + t to view transcript)", when you need a Codex agent's full tool output/reasoning, or before reporting on another agent's progress. Also covers locating the active thread, tailing live, and reading a compacted agent's pre-compaction history.
---

# Reading Codex Session Transcripts

## Why this exists

When a Codex CLI agent runs in a tmux pane, `tmux capture-pane` gives you the
**rendered** view, and the TUI collapses tool output:

```
… +66 lines (ctrl + t to view transcript)
```

Those lines were never in the pane, so no amount of `-S -2000` scrollback
recovers them. That is fine for a glance — "is it working, is it stuck" — but
it is a poor basis for asserting *what* an agent is doing. A `cd /opt/foo` in a
truncated command reads as "it is working on foo" when it may only have been
borrowing that directory's `node_modules`.

Codex writes a complete JSONL transcript of every session: full tool inputs,
outputs, and reasoning, readable without interrupting the agent.

## Pick the right tool

This skill is one option, not the default. In rough order of cost:

1. **Glance at the pane** — fine for liveness, progress, whether it is blocked.
2. **Query ground truth directly** — usually the strongest signal and often
   cheapest. If the question is "did the rollout land", ask Docker/systemd/git,
   not the agent's narration of them.
3. **Ask the agent** — it knows its own intent and plan better than any
   artifact does, and a one-line question is cheap. Prefer this when the
   question is "what are you doing / how long", especially if you are about to
   act on the answer.
4. **Read the transcript** — when you need detail the pane truncated, when the
   agent is mid-task and you would rather not interrupt, when you need history
   it compacted away, or when you want to verify rather than take its word.

Reaching for 4 first is usually the expensive way to learn something 2 or 3
would have told you faster.

## Locate the active session

Codex tracks threads in SQLite. `threads.rollout_path` points at the transcript.

```bash
sqlite3 "file:$HOME/.codex/state_5.sqlite?mode=ro" \
  "select rollout_path, git_branch, cwd,
          datetime(updated_at_ms/1000,'unixepoch','localtime') as updated
   from threads
   where cwd like '%<repo>%'
   order by updated_at_ms desc limit 5;"
```

**Always use `?mode=ro`.** The DB is open in WAL mode by a live process; a
read-only handle avoids lock contention and cannot corrupt an active session.

The `state_N.sqlite` suffix is a schema version and increments across Codex
releases. If `state_5` is absent, discover the current one:

```bash
lsof -p "$(pgrep -x codex | head -1)" 2>/dev/null | grep -oE '/[^ ]*state_[0-9]+\.sqlite' | head -1
# or
ls ~/.codex/state_*.sqlite
```

Transcripts also live at a predictable path if you would rather glob:
`~/.codex/sessions/YYYY/MM/DD/rollout-<ISO8601>-<thread-uuid>.jsonl`

Sibling DBs: `logs_N.sqlite` is Codex's internal tracing log (level/target/
module_path — application debug output, **not** the conversation) and
`goals_N.sqlite` holds `/goal` state.

## Read it

One JSON object per line: `{timestamp, type, payload}`. The interesting field is
`payload.type`:

| payload.type | What it holds |
|---|---|
| `agent_message`, `message` | assistant-visible text |
| `reasoning` | chain of thought |
| `custom_tool_call` / `_output` | full tool input and output, uncollapsed |
| `function_call` / `_output` | function-style tool calls |
| `patch_apply_end` | file edits applied |
| `context_compacted` | a compaction happened here |
| `token_count` | usage, incl. rate limits |
| `sub_agent_activity`, `task_started`, `task_complete` | subagent lifecycle |

Last few substantive messages:

```bash
python3 - "$F" <<'PY'
import sys, json
msgs = []
for line in open(sys.argv[1]):
    try: d = json.loads(line)
    except: continue
    p = d.get('payload', {})
    if p.get('type') in ('agent_message', 'message'):
        c = p.get('content') or p.get('text') or ''
        if isinstance(c, list):
            c = ' '.join(str(x.get('text','')) for x in c if isinstance(x, dict))
        c = str(c).strip()
        if len(c) > 60:
            msgs.append((d.get('timestamp','')[11:16], c))
for ts, c in msgs[-5:]:
    print(f"--- {ts} ---\n{c[:800]}\n")
PY
```

Survey what a session contains before targeting a query:

```bash
python3 -c "
import sys,json,collections
c=collections.Counter()
for l in open(sys.argv[1]):
    try: c[json.loads(l).get('payload',{}).get('type','?')]+=1
    except: pass
print(dict(c))" "$F"
```

## Notes

- **Compaction**: `context_compacted` entries mark where the agent lost context.
  The transcript keeps everything, so it is the way to recover what an agent
  knew before compacting — useful for re-anchoring it on state it dropped.
- **Size**: multi-hour sessions reach 5 MB / 1400+ records. Filter by
  `payload.type` and tail; do not read whole files into context.
- **Tail live**: `tail -f "$F" | python3 …` works; the file is appended to in
  real time.
- **Claude Code sessions** are the analogous artifact at
  `~/.claude/projects/<path-encoded-cwd>/<session-uuid>.jsonl`. Same idea,
  different layout — and note a Codex agent's transcript is NOT there, which is
  the usual reason a search comes up empty.

## When NOT to use this

Reading a peer's transcript is supervision, not collaboration. If you need the
agent to *do* something, message it (`tmux send-keys`) — do not infer intent
from its transcript and act unilaterally. Use this to report accurately, to
avoid duplicating its work, and to hand back state it lost in a compaction.

To spawn or drive Codex subagents rather than observe them, see the
`codex-subagents` skill.
