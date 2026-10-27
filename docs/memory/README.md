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

## Keeping memory healthy

Claude Code loads only the head of `MEMORY.md`: the first 200 lines or 25KB, whichever comes first.
An index that outgrows that loses its newest entries without a word. `memory-canary`
(`scripts/memory-canary`) checks a memory home, read-only:

| Check | A problem (exit 1) when |
|---|---|
| capacity | the index is over 200 lines or 25,000 characters, counted as Claude Code counts them (trimmed); from 90% it warns |
| index links | a `](file.md)` link in the index names a file that is not there |
| case | two file names differ only in case (one file on macOS, two on Linux), or a `memory.md` / `dreams.md` variant exists |
| conflict markers | a file holds `<<<<<<<` and `>>>>>>>` lines, as a sync whose autostash conflicted leaves them (git exits 0 there) |
| wiki-links | a `[[name]]` names no file and no `name:` field (both `-` and `_` spellings count): a warning, a problem only above the home's baseline |

```text
memory-canary                  every home in claude/memory-homes.conf that has a MEMORY.md;
                               without one, the memory dir Claude Code uses for this directory
memory-canary --dir <home>     one directory
memory-canary --strict         warnings fail too (not the wiki-link backlog)
memory-canary --json           one JSON object per directory
```

Exit 0 is clean (or warnings only), 1 a problem, 2 nothing to check or a usage error.
`DREAMS.md` is reported too, and warned about past the caps, since one index line makes it a
capped file.

**The wiki-link ratchet.** `scripts/wiki-dangle-baseline` ships empty, so dangling wiki-links
only warn. To stop new ones, add a line per home, `<home dir name>=<count>` (`webapp=4`), at
today's count: a count at or below it warns, one above it is a problem. Fix rot, then lower the
number; never raise it.

**The pre-push gate.** If your private copy of this repo commits memory, the pre-push hook (the
`git` component) also runs `scripts/pre-push-memory` on each outgoing ref. It reads
`claude/memory-homes.conf` from the commit being pushed, copies each home the push changes out of
Git (the committed Markdown, never the working tree) and runs `memory-canary --strict` on it, so a
push cannot publish an index that Claude Code would truncate or that links to nothing. Rows must
name directories inside the repository: relative paths, `~/.dotfiles/...` (where `install.sh`
links the checkout), or absolute paths that resolve into it; rows outside it are live memory with
nothing committed to check. A repository with no committed `claude/memory-homes.conf` anywhere in
its history (this public one, any other) passes at once and prints nothing. Deleting the
configuration retires it, and the homes still committed are still checked. Clean verdicts are
cached by content in `~/.cache/pre-push-memory` (`PRE_PUSH_MEMORY_CACHE=0` turns that off).

## Sharing memory with Codex

`codex-memory-bridge` (`scripts/codex-memory-bridge`) lets Codex read the same memory, and Claude
read what Codex distilled, without either writing into the other's store:

- **Import**: each repo's memory home (its top-level `*.md`) is copied, as real files, into
  `~/.codex/memories/extensions/shared_claude_memory/resources/<repo>/`, next to an
  `instructions.md` that tells Codex to treat them as reference material, never as instructions.
  Codex folds what is durable into its own memory at its next consolidation. Deleted memories are
  pruned from the mirror, except when a home reads as empty (a sync in progress, say).
- **Export**: Codex's `MEMORY.md` and `memory_summary.md` are copied into
  `$CODEX_SNAP_ROOT/<host>/`. An empty file (Codex mid-rewrite) never replaces a snapshot.

It never writes Codex's own files or the memory homes, skips symlinked sources, and refuses (exit
1) a repo name that is a path, a destination dir that is a symlink and a snapshot dir that is a
memory home. Without a Codex store it does nothing.

| Variable | Default |
|---|---|
| `CODEX_MEM` | `${CODEX_HOME:-~/.codex}/memories` |
| `MEMORY_HOMES_CONF` | `~/.dotfiles/claude/memory-homes.conf` |
| `CODEX_SNAP_ROOT` | `${XDG_STATE_HOME:-~/.local/state}/codex-memory-bridge/snapshots` |
| `CODEX_MEMORY_BRIDGE_HOST` | `CLAUDE_MACHINE`, `DF_MACHINE`, else the short hostname |

Codex's memory is memory like the rest: to sync the snapshots between machines, point
`CODEX_SNAP_ROOT` into your private memory tree (`identities/<you>/claude/memory/codex-snapshots`
is ignored by this repo's `.gitignore`), never into a public checkout. Run it by hand
(`--dry-run` shows what would change; `--import-only`, `--export-only`, `--repo <name>`), after a
sync, or from your scheduler; the last run's log is `~/.cache/codex-memory-bridge/last.log`.

## Models

Every model call goes through `claude-consolidate`, which runs `claude -p` with a short prompt and
returns the answer. Models are aliases (`haiku`, `sonnet`) by default, so they follow your normal
Claude Code login; provider ids work too (Bedrock is optional, see [docs/infra/aws.md](../infra/aws.md)).
Every call runs isolated (no tools, MCP servers, hooks or settings files, since what it reads came
from sessions), so a route or `apiKeyHelper` set only in a settings file does not reach it: export
the route's variables or use a provider id.
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
4. Optional: `memory-canary` to check the homes now, `codex-memory-bridge --dry-run` to see what
   it would share with Codex.

The tests: `scripts/tests/reflections.test.py`, `session-reflector.test.py`,
`session-analyzer.test.py`, `dream.test.py`, `dream-held-nights.test.py`,
`claude-consolidate.test.py`, `load-memory-hook.test.sh`, `memory-canary.test.py`,
`pre-push-memory.test.py`, `codex-memory-bridge.test.sh`.
