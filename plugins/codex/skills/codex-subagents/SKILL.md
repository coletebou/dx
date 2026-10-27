---
name: codex-subagents
description: Use when an agent needs to spawn or drive OpenAI Codex CLI sessions as subagents via tmux — fanning out parallel reviews or research (default shape: one window split into N interactive panes), running one-shot codex exec tasks, adapting that pane-fleet pattern to Claude when Codex is unavailable, or when input to a Codex TUI is failing (multi-line prompts submitting early, Enter after a paste not registering, message seemingly ignored while Codex is working).
---

# Codex Subagents via tmux

## Overview

Any agent with tmux access can orchestrate Codex CLI subagents. Two shapes:

1. **Interactive pane fleet (default for parallel fan-out)** — one new tmux
   window named after the task, split into N panes (typically 4, tiled), one
   interactive `codex` TUI per pane, per-pane briefings buffer-pasted in.
   Human-visible, steerable mid-flight, all in one window.
2. **One-shot `codex exec`** — headless, for a single bounded task whose
   result is a file/report; use `--output-last-message <file>`.

Results come back through files the subagent writes; progress comes from
`capture-pane`. Works agent-to-agent and parent-agnostic: the orchestrator
can be any model/harness (Claude Code running Opus or Fable, another Codex,
etc.) — the briefing template below adapts.

## Model, effort, and auth policy

- Model: ALWAYS `-m gpt-5.6-sol`. Pass it explicitly even though it is usually the default.
- Effort: default subagents to `-c 'model_reasoning_effort="medium"'`; escalate to `high` only for genuinely hard verify/review tasks. Levels: low, medium, high, xhigh, max, ultra (availability varies by model). In an interactive session `/model` changes both.
- Auth: profiles (e.g. `-p bedrock`) are a per-box decision — check session memory / user rules for the current box before adding one. When in doubt, omit the profile and use codex's default stored auth.
- Do not edit `~/.codex/config.toml` to set subagent defaults — per-invocation flags only, so the user's global config stays untouched.

## If Codex CLI is unavailable

Do not let the orchestration shape depend on a single binary. If `codex` is
missing, unauthenticated, or cannot reach an allowed model, report the failure
plainly and do not silently install software, rewrite auth, or edit the user's
Codex configuration.

For parallel interactive work, preserve the same default layout with four
tiled tmux panes but launch fresh Claude Code sessions instead, normally using
an available Sonnet model. Launch reviewers with an enforceable read-only
permission boundary, for example `claude --model sonnet --permission-mode
plan`; do not use a wrapper that injects `--dangerously-skip-permissions`.
Inspect the actual launch command when unsure, and treat the fallback as
unavailable if the local Claude harness cannot enforce that boundary. Exact
auth and provider remain a per-box decision. Keep every other invariant from
this skill:

- assign one independent, bounded scope per pane;
- brief reviewers as read-only unless the user separately authorized edits;
- buffer-paste multi-line prompts and verify that each composer submitted;
- monitor with `capture-pane`, collect every report, and verify findings in the
  primary agent before cleanup;
- keep all commits, pushes, deploys, approvals, and other mutations with the
  primary agent.

Call these fallback workers Claude reviewers, not Codex subagents, and state
which model actually ran. If neither Codex nor an alternate reviewer is
available, continue single-agent only when safe and disclose that no
independent review was obtained.

## Interactive pane-fleet fan-out (the "4-pane" procedure)

The Codex pane procedure has been verified end-to-end in practice. Substitute
your session name for `<sess>`; independently validate any alternate-model
fallback on the current machine before relying on it.

1. **Write each subagent's briefing to a file first** (see Briefing template
   below). Never try to quote multi-line prompts inline through send-keys.

2. **Create the window and split it tiled.** Target the window while creating
   panes so the commands do not depend on `pane-base-index`, then read the real
   pane indexes back instead of assuming `.0`:

   ```bash
   tmux new-window -t <sess> -n <task-name> -c <repo>
   tmux split-window -h -t <sess>:<task-name> -c <repo>
   tmux split-window -v -t <sess>:<task-name> -c <repo>
   tmux split-window -v -t <sess>:<task-name> -c <repo>
   tmux select-layout -t <sess>:<task-name> tiled
   tmux list-panes -t <sess>:<task-name> -F '#{pane_index}: #{pane_width}x#{pane_height}'
   ```

   Small panes (e.g. 26x21 on a narrow terminal) are fine — the TUI runs
   regardless, it just renders cramped.

3. **Start interactive codex in every pane** (read-only for reviewers):

   ```bash
   for p in $(tmux list-panes -t <sess>:<task-name> -F '#{pane_index}'); do
     tmux send-keys -t <sess>:<task-name>.$p \
       "codex -m gpt-5.6-sol -c 'model_reasoning_effort=\"high\"' -s read-only" Enter
   done
   sleep 8   # TUI load; confirm with capture-pane before pasting
   ```

4. **Buffer-paste each pane its briefing, then submit:**

   ```bash
   tmux load-buffer -b bh <briefing-file>
   tmux paste-buffer -p -b bh -t <sess>:<task-name>.$p
   sleep 1
   tmux send-keys -t <sess>:<task-name>.$p Enter
   ```

5. **Verify every pane actually submitted** — capture and look for a
   `Working (…s` status line. A pane whose composer still holds the pasted
   text needs another Enter (known gotcha).

6. **Watch for completion without blocking**: poll in a background loop —
   all panes idle = no pane's recent capture contains `Working (`:

   ```bash
   for i in $(seq 1 90); do
     sleep 20; busy=0
     for p in $(tmux list-panes -t <sess>:<task-name> -F '#{pane_index}'); do
       tmux capture-pane -pt <sess>:<task-name>.$p -S -6 | grep -q 'Working (' && busy=$((busy+1))
     done
     [ "$busy" -eq 0 ] && { echo "all panes idle"; break; }
   done
   ```

7. **Collect every report before cleanup.** Prefer the files named in the
   briefings. A read-only reviewer may be unable to create one; in that case,
   capture enough pane history to preserve its complete final reply (for
   example `tmux capture-pane -p -S -1000 -t <pane>`) and save it from the
   orchestrator. Never grant write access merely to produce a report. Verify
   findings yourself, then `tmux kill-window` — killing the window kills all
   four Codex sessions with it.

## Briefing the subagent (parent-agnostic)

Open every briefing with a short preamble that tells Codex who is driving it
and how its answer will be used — this measurably improves report shape and
keeps the subagent from re-doing orchestration work. Adapt the bracketed
parts to whoever the parent actually is (Opus, Fable, another Codex — never
hardcode one):

```
You are a Codex CLI subagent in a tmux pane, spawned and monitored by an
orchestrating agent ([model/harness, e.g. "Claude Code running Opus 4.8"]),
working on behalf of its user. The orchestrator will read your report,
verify claims against the code itself, and synthesize across parallel
subagents — so:
- Your reply is a report to another agent, not prose for a human.
- Cite exact file:line for every claim; distinguish facts, inferences,
  gaps, and mark anything unverified as (UNVERIFIED).
- Stay inside your assigned scope; other subagents own the rest.
- You are read-only: do not modify files, git state, or external services.
- Write your complete final report to <report-file> as well as replying,
  so the result survives the pane.
```

Then the task body: repo context (point at CLAUDE.md), exact scope, what to
find in priority order, and the required output format.

Second-opinion framing (borrowed from the fable-second-opinion skill, works
for any parent): the subagent is another reviewer, not an authority. The
orchestrator reports subagent conclusions distinctly from its own, grounds
disagreements in primary evidence, and never treats "a subagent said so" as
verification. If a subagent requests approval for a state-changing action,
do not grant it unless the user separately authorized it. Never include
secrets or credentials in briefings or pane captures.

## Quick reference

| Task | Command |
|---|---|
| New subagent window | `tmux new-window -t <sess> -n <task-name>` |
| One-shot task | `codex exec -m gpt-5.6-sol -c 'model_reasoning_effort="medium"' -s read-only --output-last-message <file> - < <briefing>` |
| Interactive session | `codex -m gpt-5.6-sol -c 'model_reasoning_effort="medium"'` |
| Multi-line prompt | `tmux load-buffer -b b <file>` → `tmux paste-buffer -p -b b -t <pane>` → `tmux send-keys -t <pane> Enter` |
| Check progress | `tmux capture-pane -pt <pane> -S -60` |
| Busy test | recent capture contains `Working (` |
| Liveness | `tmux list-panes -t <win> -F '#{pane_pid} #{pane_dead}'` plus `ps -o pid,etime,command` |
| Cleanup | `tmux kill-window -t <win>` after collecting output |

## Gotchas (each observed in practice)

- Raw `send-keys` with embedded newlines submits on every newline — always buffer-paste multi-line prompts (`paste-buffer -p` = bracketed paste).
- The Enter after a paste sometimes does not register. Verify with `capture-pane`; if the composer still holds the pasted content, send Enter again.
- `send-keys` payloads cap around 12k characters; buffer paste has no such limit.
- `pane-base-index` may be 1, not 0 — a `.0` target then fails with "can't find pane". Read indexes back with `list-panes`.
- **Window indexes are not stable identities.** tmux renumbers windows (a close, a `move-window`, `renumber-windows on`), so `<sess>:5` can point at a different session minutes later — a message once landed in the wrong agent this way. Before any `send-keys` to a numbered target, confirm you have the right pane: match on `#{pane_current_path}`, the running command, or a recent `capture-pane`, or address by the stable `#{pane_id}` (`%N`, from `list-panes -F '#{pane_id} #{pane_current_path}'`) instead of `sess:index`.
- The composer shows ghost placeholder text (e.g. "Find and fix a bug in @") — that is a hint, not typed input; pasting is safe.
- While Codex is mid-turn, a submitted message shows "Messages to be submitted after next tool call" and delivers at the next step boundary. Tab queues it for after the whole turn instead.
- `kill-window` takes every codex session in it down instantly — collect reports first.
- With `-s read-only`, a subagent asked to write a report file may hit an approval prompt; never approve that write merely for reporting. Require the full reply in the TUI and preserve it with `capture-pane`.

## Hygiene

- Name windows after their task (`review-3390`, `bug-hunt`) so humans scanning tmux can tell what is running.
- Subagents that mutate files get their own git worktree; read-only reviewers can share a checkout.
- Ask subagents to write findings to files when their sandbox permits it; for read-only reviewers, capture the complete final TUI reply before cleanup because pane scrollback is lossy.
- The orchestrator keeps commits, pushes, merges, and deploys to itself; subagents research, review, and report.

## Docs

- Model selection: https://developers.openai.com/codex/models
- Configuration: https://developers.openai.com/codex/config-basic
