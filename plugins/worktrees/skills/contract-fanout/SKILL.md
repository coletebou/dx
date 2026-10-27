---
name: contract-fanout
description: Coordinate one multi-slice issue across N worktree workers that build against versioned contracts agreed in advance. The coordinator splits the issue into slices with disjoint file ownership, writes the briefs, posts contract-first JSON contracts (vX.Y) as issue comments, spawns one worker per slice, reviews each pushed slice with two independent engines at a pinned SHA, verifies every finding before routing it to the owning worker, gates the result, and relays gated, review-clean slices to a release coordinator, keeping STATUS.md, PR-NOTES.md and the owner's decision list current. Use when the user says "fan out this issue to workers", "contract-first", "post the contract before anyone builds", "review and relay worker branches", "coordinate N slices", "run the coordinator loop", "review each slice and send findings back", or "relay ready slices to the release coordinator". Repo-agnostic. Not for single-slice work (run autoreview directly).
---

# Contract fan-out skill

One coordinator, N workers, one issue. Workers build slices against contracts posted
before implementation; the coordinator reviews, routes findings, gates and relays. The
loop below was first run by hand about eight times in one session (for example an issue
split into server, web and native slices).

The coordinator never writes slice code. It owns the briefs, contracts, reviews, routing,
gates, relays and bookkeeping. Workers own their branches.

## When not to use

- Single-slice work: just run `autoreview-pair` and fix. It is `scripts/autoreview-pair`
  in this repo (`install.sh --with review`), two runs of the `autoreview` skill's helper
  from [openclaw/agent-skills](https://github.com/openclaw/agent-skills) in parallel.
- Independent prompts with no review or relay loop: use `parallel-worktrees` alone.
- Slices that must edit the same files: re-split first; if you cannot, run them in sequence.

## Phases

### 1. Break the work down

Split the issue into child slices with **disjoint file ownership** (name the files or
directories each slice owns; shared files get one owner, others request changes through
the coordinator). Write the briefs to a coordination directory outside every worktree:

- `COMMON.md`: shared constraints, linked from every slice brief.
- `SLICE-<n>.md`: goal, owned files, contract version to build against, acceptance
  checks, required tests, the reporting format.

Workers inherit nothing, so `COMMON.md` must spell out every safety rule, including:

- No PRs and no merges. Push the branch only.
- Merge master into the branch to pick up changes; never rebase.
- The repo's formatter bans (for example "never run Prettier"; "pass the formatter only
  the exact files you edited").
- Load discipline: check `uptime` before heavy local jobs (type check, full test suite,
  builds, containers); never pile heavy jobs onto an oversubscribed box.
- Feature flags follow the owner's rollout rule. On a beta app a finished feature ships ON: a flag is a kill switch, not a launch gate.
- No production writes: no prod data, deploys, credential changes or spend.
- Report by replying with the pushed SHA and a short summary; never claim a gate you
  did not run.

### 2. Contract first

Before anyone implements a slice that crosses a team boundary (for example a server API
consumed by another team's native UI), post a versioned JSON contract as an issue
comment: `Contract <name> v1.0` with request and response shapes, error cases, flag
names, and which slice owns each side. Get the other owner's acceptance in the thread.

Every later change is a new version (`v1.1`) posted as a new comment that states what
changed and why; never edit an accepted comment. Briefs name the exact version, and
workers implement against the posted version, not the conversation. When a version
changes, tell every affected worker the new version and the delta.

### 3. Spawn

One worker per slice, writing disjoint files:

- In session: the Agent tool with `isolation: "worktree"`, one call per slice, all in
  one message so they run in parallel.
- Separate sessions: the `parallel-worktrees` skill (one tmux window per slice).

Record each worker's agent id (or session id), branch and worktree path in `STATUS.md`
as soon as it starts. A fresh session cannot message another session's in-process
agents, so a successor coordinator fixes in those worktrees directly (or asks the
session that owns them).

### 4. Review at a pinned SHA

For each pushed slice, review the exact pushed commit, never a live worktree:

```bash
git worktree add --detach <review-dir> <sha>      # new review checkout
git -C <review-dir> switch --detach <sha>         # reuse an existing one
```

Never silence `worktree add` output: a silent failure reviews the wrong tree. Confirm
`git -C <review-dir> rev-parse HEAD` equals `<sha>` before launching.

Round 1, from inside `<review-dir>`:

```bash
base=$(git merge-base origin/master <sha>)
autoreview-pair --mode branch --base "$base" --max-priority P2 --out <reviews>/<slice>/r1
```

Later rounds review only the fixes: `--mode commit --commit <fix sha>`, or branch mode
with `--base <previous reviewed tip>`. Pass a context file that summarizes earlier
rounds' fixes and declined findings (with reasons) so reviewers do not re-raise them:
`--prompt "$(cat <reviews>/<slice>/context-r<N-1>.md)"`. (`--prompt-file` only accepts
a file inside the reviewed checkout.)

Results land in the `--out` directory as `<engine>.md`, `<engine>.json`,
`<engine>.status.json` and `<engine>.rc`. Read the status and rc files for each engine,
not the wrapper's exit code: a trailing `echo` in your own command makes the background
task exit 0 whatever happened. An engine that did not finish is "no review", not clean.

### 5. Verify, then route

Verify every finding against the real code before routing it: trace the code path,
build the concrete scenario, and name the invariant it breaks. A plausible finding is
not a real one.

- **Declined**: record it in the slice's context file with the reason (not reachable,
  intended behaviour, out of scope, already handled at file:line), so later rounds do
  not re-raise it.
- **Verified**: send it to the owning worker (template below) with file and line, the
  failure scenario, the required behaviour, a required test, the constraints, and
  "reply with the SHA". Batch a round's findings into one message per worker.

A completed in-session worker is resumed with SendMessage and its agent id. Each fix
SHA gets the next review round (phase 4).

### 6. Gate

Run the repo's gates (type check, lint, tests, build) locally only when load is low;
otherwise send the SHAs to the coordinator's runner queue or CI. Record the numbers
(for example `tests 1840 pass / 0 fail / 11 skip`, `tsc clean`).

A flaky result is "no result": rerun it, never count it as a pass or a fail. Runner
gates catch what static review misses (for example TS7022 implicit-any inference cycles
that only a full type check sees), so never call a slice ready without a gate on its
exact SHA.

### 7. Relay

A slice is **READY** only when both hold for the same SHA:

1. Gated green.
2. Its last review round came back clean on both engines.

Send the release coordinator (template below) the branch, SHA, gate numbers, flags
and their defaults, the PR-NOTES section path, and any required follow-on steps (for
example "regenerate the project file after merge"). Keep two holds separate:

- `READY pending <decision>`: code is done; waiting on an owner decision (name it).
- `held for code`: a finding, gate or contract change is still open.

A new commit after READY voids it: review and gate the new SHA before relaying again.

### 8. Bookkeeping

Keep these current after every event, not at the end:

- `STATUS.md`: per slice, the branch, worker id, worktree, latest SHA, review round and
  verdict, gate result, relay state (`building`, `in review rN`, `fixing`, `gating`,
  `READY`, `READY pending <decision>`, `held for code`, `relayed`).
- `PR-NOTES.md`: one section per slice (summary, flags, test evidence, verified and not
  verified, follow-on steps) that the release coordinator can paste.
- Decisions list for the owner: numbered (D1, D2, ...), each with the options, your
  recommendation, and which slices it blocks.

## Relay message templates

Finding to worker:

```text
Slice <n> review r<N> at <sha>: <k> verified finding(s). Fix all, one commit each or one total.

1. <file>:<line> (P<1|2>)
   Scenario: <inputs and sequence that trigger it>
   Breaks: <invariant or contract field, with contract version>
   Required: <behaviour after the fix>
   Test: <test that fails before the fix and passes after>
Constraints: own files only; merge master, never rebase; flags per the owner's rollout rule; no formatter
runs beyond your edited files; check uptime before heavy jobs; push the branch, no PR.
Declined (do not fix): <finding> because <reason>.
Reply with the SHA.
```

READY to release coordinator:

```text
READY: slice <n> <title>
Branch: <branch>   SHA: <sha>   Base: master @ <merge-base sha>
Review: r<N> clean on both engines (<reviews>/<slice>/r<N>)
Gate: <type check result>, <tests pass/fail/skip>, <build result> on <sha>
Flags: <FLAG_NAME> (default ON or OFF, and why)
Contract: <name> v<X.Y>
PR notes: <path>#<section>
Follow-on: <required steps after merge, or none>
Pending: <decision id, or none>
```

## Gotchas

- **`pgrep -f "<pattern>"` matches its own shell command line**, so it always finds
  "one" process. Split the pattern so the literal never appears whole:
  `p="vite build --con""fig"; pgrep -fc "$p"`, or match the process name with `pgrep -x`.
- **A background Bash command that itself backgrounds with a nested `&` never sends a
  completion notification.** Run the reviewer in the foreground of a
  `run_in_background` call.
- **The reviews output directory must exist before you redirect a log into it**
  (`mkdir -p <reviews>/<slice>` first); otherwise the shell fails before the reviewer
  starts and the task looks finished.
- **Cross-session SendMessage can fail.** Message the peer session through
  `drover_send` with `id=<session uuid>` instead, and address it by session id once
  window or session names change.
- **Fresh-session handoff splits ownership explicitly.** The old session keeps its
  in-process workers and their branches; the new session owns STATUS.md, PR-NOTES.md
  and coordination. Write the split into STATUS.md. Never let two sessions edit the same
  file.
- **Two engines are enough for release-critical slices.** Fix only the real P1 and P2
  findings; skip extra adversarial passes unless the owner asks.
