---
name: dreaming
description: Background memory consolidation in three phases (light, REM, deep), modeled on OpenClaw's dreaming. Reads session-analyzer output and the existing MEMORY.md, promotes durable candidates into MEMORY.md, and keeps a narrative Dream Diary (DREAMS.md). Use when the user says "/dreaming", "dream sweep", "dream now", "show me the dream diary", "consolidate memory", or when reviewing what dreaming has learned recently. Opt-in per repo; a schedule runs it nightly once installed, and it also runs on demand.
---

# dreaming

Three-phase memory consolidation, an independent implementation of the design OpenClaw
describes for its memory-core dreaming (credited in `NOTICE.md`).

| Phase | Writes | Purpose |
|---|---|---|
| Light | `.dreams/light/<date>.md` + a Dream Diary fragment | Stage candidates |
| REM   | `.dreams/rem/<date>.md` + a Dream Diary fragment   | Extract themes, tensions |
| Deep  | `MEMORY.md` (promotions) + a Dream Diary fragment  | Promote durable memories |

Only Deep writes to `MEMORY.md`. Light and REM observe and reflect.

## When to use

- The user says "/dreaming", "dream sweep", "dream now", "consolidate memory".
- The user asks "what has dreaming been learning", "show me the dream diary".
- Opting a repo in or out.
- Nightly, from the schedule that `install.sh --with schedules` installs (a LaunchAgent on
  macOS, a systemd user timer on Linux), which runs `dream-prep` and then `dream sweep`.

## Commands

The `dream` CLI is `scripts/dream` in this repo (`install.sh --with memory` puts it on `PATH`).

```
dream status                    enabled repos, diary counts, which host dreams
dream sweep [repo]              full light -> REM -> deep pass (hub hosts only)
dream now                       alias for sweep
dream light|rem|deep            run one phase
dream diary [repo]              page DREAMS.md
dream enable <repo>             opt in
dream disable <repo>            opt out
dream help
```

A repo is a shortname from `claude/memory-homes.conf` (template:
`claude/memory-homes.conf.example`), which maps it to its memory home: the synced directory
Claude Code loads as its auto-memory.

## Inputs

- `<memory home>/.analysis/[<host>/]*`: from `session-analyzer` (one subdirectory per
  machine, so a hub consolidates every machine's sessions).
- `<memory home>/MEMORY.md`: existing durable memory (the dedup target).
- `<memory home>/.dreams/<earlier phase>/<date>.md`: from the same sweep.

## Outputs

- `<memory home>/.dreams/<phase>/<date>.md`: machine-readable phase reports.
- `<memory home>/DREAMS.md`: the narrative Dream Diary, for humans. Older entries rotate into
  `DREAMS-archive-<year>.md`.
- `<memory home>/MEMORY.md`: appended only by the deep phase, at most `deep_max_promotions`
  entries per sweep, within Claude Code's load limits for the file.

## Config

`claude/dreaming.conf` (or `$DREAMCONF`; template `claude/dreaming.conf.example`):

- `enabled_repos`: the opted-in repo shortnames. Empty by default; `dream enable` edits it.
- `dream_machines`: the hub gate. Only these hosts run the promoting phases, so a single writer
  rewrites `MEMORY.md` and machines never race through the sync. Empty means every machine
  dreams, which is fine with one machine.
- `light_model`, `rem_model`, `deep_model`, `dreaming_model`: per-phase models, as aliases
  (`haiku`, `sonnet`) or provider ids that `claude-consolidate` routes (Bedrock is optional).
- The deep-phase gate: `deep_min_score`, `deep_max_promotions`, `deep_min_held_nights`,
  `deep_max_persistence_promotions`.

Every model call goes through `claude-consolidate`, which honors the data boundary
(`MEMORY_BOUNDARY_CMD`, see `scripts/lib/memory-boundary.sh`): a transcript or memory file the
boundary restricts never reaches a model.

## Cost

Each sweep is three `claude -p` calls per enabled repo (light, REM, deep). With small models
that is a fraction of a cent per repo per night. Dreaming is opt-in per repo to keep it so.

## Related

- `session-analyzer` stages the inputs; `dream-prep` runs it, gated to the dreamer hosts.
- `reflect`: the end-of-session retrospective, which reads the same memory.
- The memory design: `docs/memory/README.md`.

## What this skill does NOT do

- No UI. `dream diary` is the only read path.
- No grounded historical backfill lane (an optional OpenClaw feature).
- No per-subagent workspaces. One repo, one memory pool.
- No silent fallback when a model is unavailable: it is logged and visible.
