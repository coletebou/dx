# Agent memory

Agents forget everything between sessions unless something writes it down. This repo has
four pieces that do, at different speeds, all on top of the memory directory Claude Code
already loads (its auto-memory: `MEMORY.md` plus topic files).

| Piece | When it runs | What it writes |
|---|---|---|
| **reflections** (`scripts/reflections`) | whenever an agent or a person records something | append-only rows: actions, questions, decisions, learnings, handoffs, each searchable and closable |
| **session reflector** (`base/claude/session_reflector.py`) | in the background at 20/40/60/80% of a session's context budget, before compaction and at session end | reflection rows for that session, reconciled with the open ones |
| **session-analyzer** (`scripts/session-analyzer`) | nightly, through `dream-prep` | `.analysis/`: unfinished work, recurring corrections, memory candidates |
| **dreaming** (`scripts/dream`) | nightly, after the analyzer | promotions into `MEMORY.md`, and a narrative diary, `DREAMS.md` |

The `reflect` skill is the human-paced version: an end-of-session retrospective that reconciles
all of the above by hand. The `load-memory` hook shows a repo's handoff and open items at the start
of every session, and `reflections-context-hook.sh` does the same for Codex.

## Where the data lives

Memory is data, not code. Keep it in a **private** repository; this repo's `.gitignore` keeps it
out of a fork.

Each repo has a **memory home**: the directory Claude Code loads as its auto-memory. Register it in
`claude/memory-homes.conf` (template: `claude/memory-homes.conf.example`):

```text
<repo shortname>   <memory dir>
webapp             ~/.dotfiles/identities/<you>/claude/memory/webapp
```

Put the memory dirs inside your private dotfiles tree and the path is the same on every machine,
so one file serves them all. Point Claude Code at it with `autoMemoryDirectory` in the repo's
`.claude/settings.local.json`. Inside a memory home:

```text
MEMORY.md                  the index Claude Code loads (dreaming keeps it under its limits)
<topic>.md                 memory files
reflections/<host>.jsonl   reflection rows, one file per machine, so syncs never conflict
.analysis/<host>/          session-analyzer output, per machine
.dreams/<phase>/<date>.md  dreaming's phase reports
DREAMS.md                  the dream diary
```

The search index, `~/.local/state/agent-reflections/index.sqlite` (SQLite FTS5), is derived and
rebuilt on demand. `reflections search` spans the rows, every memory home's files, Codex's
`~/.codex/memories/MEMORY.md` and the analyzer's reports.

The analyzer reads transcripts from `~/.claude/projects/<encoded cwd>/`, a path that differs per
user and machine, so it has its own map: `claude/memory-canonicals.conf` (one row per repo and
machine). Dreaming's opt-in, models and thresholds are in `claude/dreaming.conf`; its hub gate
(`dream_machines`) keeps a single machine promoting into `MEMORY.md`, so two machines never rewrite
it at once.

## The data boundary

Some sessions must never reach a model or the memory tree: a restricted model route, a client's
data, anything a contract says stays put. Set `MEMORY_BOUNDARY_CMD` to a command that answers
"is this restricted?" for one file:

| Exit | Meaning |
|---|---|
| `0` | restricted: keep it out |
| `1` | fine: go ahead |
| anything else | restricted: a check that is missing, crashes or times out fails closed |

It runs through `sh -c` with `MEMORY_BOUNDARY_TOOL` (`reflector`, `consolidate`, `session-analyzer`
or `context-advisor`), `MEMORY_BOUNDARY_PATH` (the transcript, or the prompt or input about to go to
a model) and, when known, `MEMORY_BOUNDARY_SESSION` and `MEMORY_BOUNDARY_TRIGGER`. It is cut off
after `MEMORY_BOUNDARY_TIMEOUT` seconds (default 20). Unset, nothing is restricted. The reflector,
the analyzer and `claude-consolidate` (the one helper every model call goes through) all ask it, per
file, before reading or sending anything; `scripts/lib/memory-boundary.sh` is the shared
implementation, with examples. The context advisor asks it too before it sends conversation excerpts
to Jev, and a restricted session gets its advice without them.

## Models

Every model call goes through `claude-consolidate`, which runs `claude -p` with a short prompt and
returns the answer. Models are aliases (`haiku`, `sonnet`) by default, so they follow your normal
Claude Code login; provider ids work too (Bedrock is optional, see [docs/infra/aws.md](../infra/aws.md)).
The knobs: `CLAUDE_CONSOLIDATE_MODEL`, the reflector's `REFLECTOR_*_MODEL`, dreaming's per-phase
models. Nothing here calls a model without one of these tools being run or scheduled.

## Search by meaning

The tools here search by keyword (FTS5) and need nothing else. For search by meaning,
[Drover](https://github.com/coletebou/drover) indexes the same reflections and memory with local
embeddings (`web/core/search/`, set up with `web/bin/drover-embed-setup`), entirely on your machine.

## Setting it up

1. `./install.sh --with memory,claude` (the hooks come with `claude`).
2. Copy the three `claude/*.conf.example` files to `claude/*.conf` and fill in your repos.
3. Optional: `./install.sh --with schedules` for the nightly analyzer and dream sweep, and
   `dream enable <repo>` to opt a repo into dreaming.

The tests: `scripts/tests/reflections.test.py`, `session-reflector.test.py`,
`session-analyzer.test.py`, `dream.test.py`, `dream-held-nights.test.py`,
`claude-consolidate.test.py`, `load-memory-hook.test.sh`.
