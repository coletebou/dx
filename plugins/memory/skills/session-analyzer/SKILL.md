---
name: session-analyzer
description: Scan past Claude Code session transcripts for unfinished work, repeated workflow corrections, and candidate memories not yet captured. Use when the user says "analyze my sessions", "what am I missing", "what did I leave hanging", "/session-analyzer", or when starting a new day and wanting a rollup of unfinished work across projects. Writes three artifacts per project into `<memory home>/.analysis/`. Does NOT auto-promote candidates into MEMORY.md; that is a human decision (via `/reflect`) or the dreaming sweep's.
---

# session-analyzer

Reads past `.jsonl` transcripts and writes three files per project under
`<memory home>/.analysis/[<host>/]` (the memory home comes from `claude/memory-homes.conf`):

- `unfinished.md`: sessions that ended with open Task/Todo items, ended with no assistant reply
  (`ended=no-reply` for a hung prompt, `ended=killed-mid-tool-loop` when the last message is a
  tool_result), or self-flagged TODO/FIXME/revisit work in the final 10% of assistant text
  (`[tail]` lines). Sessions written to in the last 30 minutes count as live and are not
  reported as ended.
- `workflow-tips.md`: correction patterns that recur across sessions (the user said "no",
  "stop", "don't" in similar contexts), clustered by a model. The ids it cites are MESSAGE ids,
  not session ids; one long session can produce many.
- `memory-candidates.md`: durable-looking facts from user turns, deduplicated by a model
  against the existing MEMORY.md.

Transcripts are read from `~/.claude/projects/<canonical>/` AND its
`<canonical>--claude-worktrees-*/` siblings, which is where nested-worktree sessions (parallel
fan-outs) land. Hook and skill injections that arrive as user-role messages ("Stop hook
feedback:", `<task-notification>`, `<command-name>`, skill bodies) are excluded from both
extractors. Transcripts the data boundary restricts (`MEMORY_BOUNDARY_CMD`, see
`scripts/lib/memory-boundary.sh`) are never read.

The raw pre-model candidates are kept in `memory-candidates.raw.md` for forensic review.

## When to use

- The user says "/session-analyzer", "analyze my sessions", "what am I missing".
- Nightly through `dream-prep` (the schedule from `install.sh --with schedules`).
- After a long break, to catch up on what is half-done across repos.
- Before `/reflect`, to have candidates queued for promotion.

## How to use

The CLI is `scripts/session-analyzer` in this repo (`install.sh --with memory`). It needs bash
4.4 or newer (on macOS, Homebrew's bash).

```
session-analyzer                       # all repos on this machine
session-analyzer --project <canonical> # one project only (repo resolved from the conf)
session-analyzer --since YYYY-MM-DD    # custom lookback
session-analyzer --days 60             # lookback in days
session-analyzer --dry-run             # deterministic stages only; skips the model passes
                                       # and leaves workflow-tips.md / memory-candidates.md alone
session-analyzer --verbose
# A hub that collects other machines' transcripts analyzes each under its own label:
session-analyzer --transcripts-root DIR --machine HOST --host-label HOST
```

The canonical dir list comes from `claude/memory-canonicals.conf` (or
`$MEMORY_CANONICALS_CONF`; template `claude/memory-canonicals.conf.example`): one row per repo
and machine, naming the repo's transcript dir under `~/.claude/projects/`. A repo with no row
for this machine is skipped, and `--project` on such a dir writes to the legacy
`<transcript dir>/memory/.analysis/` instead of the memory home, so add the row first (take the
token from `ls ~/.claude/projects/`).

## Outputs

All live under `<memory home>/.analysis/[<host label>/]`; the legacy
`<transcript dir>/memory/.analysis/` layout is only used for repos absent from
`memory-homes.conf`. They are overwritten on every run (no state kept), so a finding that ages
out of the lookback window disappears; dreaming is what promotes durable kernels before that
happens, and earlier versions stay in the memory repo's git history.

### unfinished.md
A human-scannable list, sorted by session date.

### workflow-tips.md
Pattern clusters. Each tip is a normalized correction stem, a count, and the message ids. Use
them to file skill updates or tighten existing CLAUDE.md rules.

### memory-candidates.md
The model pass (`claude-consolidate`, model from `CLAUDE_CONSOLIDATE_MODEL`, a 600 s timeout)
compares the candidates with MEMORY.md and returns only the NEW ones, typed. It prefers
dropping to hallucinating. A human reviews this file and promotes the worthy ones with the
normal auto-memory pattern.

## What this skill does NOT do

- Does not write to MEMORY.md. Promotions are a human's, or dreaming's.
- Does not touch transcripts, only reads them.
- Does not cross the canonical-dir boundary: one run per project, which the script fans out
  automatically.
- Does not dedupe across projects. Different repos have different memory pools on purpose.

## Related

- `dreaming`: consolidates this skill's output into MEMORY.md.
- `/reflect`: the end-of-session retrospective, which uses this output when available.
- The memory design: `docs/memory/README.md`.
