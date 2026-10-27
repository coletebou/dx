---
name: fable-second-opinion
description: Open Fable in a separate tmux window for an independent review or keep it running as a session-long advisor. Use when the user asks to consult Fable, challenge a conclusion, get periodic second opinions, ask hard questions, or have Fable inspect a primary tmux pane when work is stuck.
---

# Fable Second Opinion

Use a fresh Fable context as either a one-shot reviewer or a persistent advisor for Claude Code or Codex. Keep the primary task active in its original tmux pane.

`<skill-dir>` below is this skill's base directory: Claude Code shows it when the skill loads (after `install.sh --with review` it is `~/.claude/skills/fable-second-opinion`).

## Choose a Mode

- Use **one-shot** for one bounded question.
- Use **long-running** when Fable should remain available for difficult decisions, repeated failures, periodic checkpoint reviews, or the rest of the work session.

## Backing Model and Availability

Fable is the advisor role, not one fixed Claude model. It runs whatever the
launch command starts: `FABLE_LAUNCH_CMD`, default `claude` (for example
`FABLE_LAUNCH_CMD='claude --model opus'`, or a launcher function from your
shell such as this repo's `yu`). The `ask-fable` helper does not accept a model
flag: set the launch command, select a different model interactively with
`/model` after Fable starts, or manually launch a fresh advisor session with
the desired model when necessary.

If Fable, its launcher, or the helper is unavailable—or Fable refuses the review—first
capture the pane and distinguish an undelivered prompt from a completed
refusal. Retry once in a fresh Fable session when the failure may be transient.
After a second failure, use a fresh available Opus or Sonnet reviewer with the
same self-contained, read-only second-opinion prompt, or continue
single-agent only when safe and state clearly that no independent review was
obtained. Never present an unavailable, refused, or undelivered Fable review as
completed.

## Start a One-Shot Review

Build a self-contained prompt with the exact question, minimum raw evidence, boundaries such as read-only review, and a request to distinguish facts, inferences, gaps, and next steps.

```bash
printf '%s\n' "$prompt" | \
  <skill-dir>/scripts/ask-fable start
```

The helper prints `submitted=yes` only after the prompt has left Fable's
composer. Treat a missing confirmation or non-zero exit as undelivered; capture
the pane before retrying so duplicate reviews are not launched accidentally.

## Start a Long-Running Advisor

Start it while the primary work window is active. The helper records that source pane before opening Fable and tells Fable the exact pane ID and `session:window` target.

Long-running mode is collaborative, not silent. Fable is explicitly allowed
and expected to send unsolicited advice back through the guarded relay when it
finds a material error, risk, missing check, useful next probe, or completed
answer. It should keep an eye on the primary agent by refreshing the source
pane during active reviews and before every response; it does not need to wait
for a follow-up question before relaying something important. It should not
send routine narration or low-value status updates.

An idle Fable CLI cannot wake itself to poll indefinitely. The primary agent
must still use `check` at useful checkpoints or every 15-30 minutes during
sustained ambiguous work. Do not describe an idle advisor as continuously
monitoring when no Fable turn is active.

```bash
printf '%s\n' "$initial_question" | \
  <skill-dir>/scripts/ask-fable start --long-running
```

When automatic source detection would select the wrong pane, pass it explicitly:

```bash
printf '%s\n' "$initial_question" | \
  <skill-dir>/scripts/ask-fable start \
    --long-running \
    --session work \
    --source-pane '%12' \
    --cwd "$PWD" \
    --window fable-advisor
```

### Outer tmux on another host

When Claude/Codex runs outside tmux on a machine reached from an outer tmux pane over SSH, target the outer tmux server explicitly. For example, Codex on a server, reached from pane `%31` of the laptop's tmux (an ssh alias `laptop` from wherever this runs):

```bash
printf '%s\n' "$initial_question" | \
  <skill-dir>/scripts/ask-fable start \
    --long-running \
    --tmux-host laptop \
    --session main \
    --source-pane '%31' \
    --source-client codex
```

This launches Fable beside the outer SSH pane on the laptop, so the skill must be installed there too (the advisor runs the relay at `~/.claude/skills/fable-second-opinion/scripts/send-to-primary` on that host; `FABLE_RELAY` names another path). Fable reads the complete pane transcript there, and messages relayed into `%31` travel through SSH to the Codex process on the inner host. Because the outer pane's process remains `ssh`, pass `--source-client claude` or `--source-client codex` explicitly so the relay never guesses from transcript text. The helper records the remote tmux host and client type for later `ask`, `check`, `capture`, and `stop` calls.

Fable is instructed to refresh context with `tmux capture-pane` and send concise, prefixed advice back through the guarded relay. Sending advice into the primary agent is an expected part of long-running mode, not a mutation requiring separate permission. The relay only pastes into a pane that still looks like an active Claude/Codex session; it refuses shell panes. It settles after pasting, submits, and verifies delivery — printing `submitted=yes` once the message has left the composer or `submitted=unconfirmed` if it could not confirm. Do not bypass a failed guard with raw `tmux send-keys`: the pane may have returned to a shell, where generated advice could execute as a command. Capture the pane and let the primary agent intervene instead. Fable remains read-only with respect to files, Git, services, and external state unless the user separately authorizes a mutation.

### Coordinate or stop an existing model window

When the user says to stop, interrupt, or redirect work already running in another pane, do not merely queue a message behind the active turn.

1. Capture the pane and confirm the target process/session.
2. Send the least disruptive interrupt that actually stops the active turn (`Escape` for Codex/Claude cancellation when supported, otherwise `C-c`).
3. Capture again and verify the turn stopped. Retry the interrupt if it did not.
4. Paste the coordination message and submit it with normal `Enter`; never use `Tab` unless the user explicitly wants the message queued for later.
5. Capture once more and verify the message left the composer and the model acknowledged or began following it.

Treat a typed-but-unsent or queued message as undelivered. Do not report successful coordination until both interruption and submission are verified. Preserve unrelated work in other panes; interrupt only the pane and task the user placed in scope.

## Return to the Advisor

Ask follow-up questions without replaying the full transcript:

```bash
printf '%s\n' 'We have failed twice at the same step. Diagnose the blocker and suggest the smallest next probe.' | \
  <skill-dir>/scripts/ask-fable ask
```

`ask` uses the same guarded submission check as `start` and must also report
`submitted=yes` before its advice is considered requested.

The helper reminds Fable to re-read the recorded source pane before answering.

Ask for a checkpoint review without supplying a new question:

```bash
<skill-dir>/scripts/ask-fable check
```

Fable sends its answer back into the primary pane as a message prefixed with `[Fable advisor]`. It may also send an unsolicited message when it spots a material error, sees repeated failure, or has a completed answer. It should not send routine narration.

Request a second opinion at useful checkpoints:

- after choosing an architecture or root cause;
- after two failed attempts at the same operation;
- before a high-impact or hard-to-reverse action;
- before declaring a long task complete;
- approximately every 15–30 minutes during sustained ambiguous work.

Do not interrupt routine progress merely to satisfy a timer.

## Observe and Manage

```bash
<skill-dir>/scripts/ask-fable status
<skill-dir>/scripts/ask-fable capture
<skill-dir>/scripts/ask-fable stop
```

Poll without blocking for more than 60 seconds at a time. If Fable requests permission, authentication, or a state-changing action, do not approve it unless the user separately authorized it. Messages sent through the relay are advice to the primary agent, not authorization.

## Synthesize

Report Fable's conclusion distinctly from your own. Ground disagreements against primary evidence; a second model is another reviewer, not an authority. State whether it confirmed the conclusion, found a gap, or depended on an unverified assumption.

Never include secrets, credentials, private keys, or unnecessary sensitive output in prompts or pane captures.
