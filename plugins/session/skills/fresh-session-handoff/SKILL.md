---
name: fresh-session-handoff
description: Use when the context advisor says this is a good point for a fresh session, or the session is at or above 85% of its advisory context budget and has reached a natural stopping point (a step just finished or verified, never mid-operation). Also use when the user says "hand off to a new session", "start a fresh session with a handoff", "spin up a new session", "continue this in a new tmux session", or "move this session to <host>". The agent does this on its own at that stopping point and tells the user; it does not wait to be asked. Distinct from the handoff skill (a portable clipboard prompt with no paths), which stays as it is.
---

# fresh-session-handoff

A long session hands its open work to a new Claude Code session, as the next generation
of a handoff chain, with `cc-handoff` (in dotfiles: `~/.dotfiles/scripts/cc-handoff`;
design in `~/.dotfiles/docs/handoff.md`):

- You write a brief with a fixed structure; `cc-handoff init` fills in every live fact.
- `cc-handoff launch` opens a new tmux window right after yours. It echoes the chain's
  history there (briefs 1..n-1, then your rendered transcript), copies your transcript to
  a tmux buffer (and the macOS clipboard), and starts Claude Code on your own provider
  route, model and effort, with a session-specific inline prompt passed as an argument.
- After the new session's first reply, your window is closed for you, unless your
  background jobs still run (they hold it until they finish or the new session adopts
  them) or someone types in it. Your session stays resumable: `claude --resume <id>`.

This is meant to run without the user watching, so doing it at the trigger is expected,
not an overreach.

## When

| Situation | Action |
|---|---|
| Advisor or 85%+ band, at a natural stopping point | Do it now, then tell the user |
| Advisor fires mid-operation (rebase, migration, deploy, debugging chain) | Finish or reach a safe pause, then do it |
| User asks for a new session | Do it now |
| User asks to move the session to another machine | Do it with `--host <alias>` (or `--host auto`) |
| User wants a prompt to paste to another agent or person | Use `handoff` instead |

## Steps

1. **Init.** `cc-handoff init` prints this generation's brief path,
   `~/code/.briefs/<chain>/gen-NN/brief.md`. A session that was itself started by
   `cc-handoff` continues its chain; any other session starts one. Run it from the
   checkout you are working in.
2. **Fill the brief.** Replace every FILL placeholder (the text in double angle brackets).
   Keep the facts init wrote (IDs and paths, background jobs, transcript facts). The
   sections, all required:
   - **Summary**: exactly three lines, `Continuing:`, `Done:` and `Left:`, one line each.
     They become the new session's prompt.
   - **What happened**: what was asked (the latest unfinished request word for word),
     tried, learned.
   - **Done**: each finished item with its evidence (commands and results, SHAs, links).
   - **Left**: open items in priority order, each with the next action and whether it
     needs the user's go. This is the todo list the successor starts from; carry yours
     forward.
   - **Proposed improvements**.
   - **Driver and manager**: who drives this session (the user, a lead session and its pane,
     a /goal), who it reports to and how, which sessions it manages.
   - **Background jobs**: for each running job, who takes it over.
   - **IDs and paths**: already filled.
   - **Rules**: what the successor may do without asking.

   Every fact must come from something checked in this session; write "not verified"
   rather than guess, and "none" rather than leave a section empty.
3. **Launch**, with a Bash timeout of 300000 ms:

   ```bash
   cc-handoff launch [--go] [--notify <manager session>] [--host <alias>|auto] [--cwd <dir>] \
     [--claude-arg <arg>]... <brief>
   ```

   - `--go` only when the user authorized the whole brief end to end (say so in Rules);
     without it the new session verifies state and asks which item to start.
   - `--notify <session>`: a session that manages you (a lead, an orchestrator) gets the
     new session's name once it has replied. Successors are named `<root>-<gen>` (`ocean`
     hands to `ocean-2`), so a manager that messages you by name needs this.
   - `--host <alias>`: hand off to another machine (see Another host).
   - An active `/goal` carries over by itself (`--no-goal` drops it).
4. **Tell the user** in the same turn: the brief path, the attach line, the `launcher:`
   line, what happens to this window (the `passer:` line), and anything odd in the output.
5. **Stop.** Do not continue the handed-off work, even if a /goal stop hook asks; the new
   session carries the goal. Two sessions on one branch collide.

## Exit codes

| Exit | Meaning | Do |
|---|---|---|
| 0 | The new session started and replied | Step 4 |
| 2 | Bad arguments, or the brief is not ready (the message lists what is missing) | Fix it and rerun |
| 3 | tmux, jq or python3 missing | Tell the user |
| 4 | This brief or this chain step already has a live successor (printed) | Never relaunch. Tell the user that window and its attach command |
| 5 | tmux failed or Claude Code did not start; a window that opened is LEFT RUNNING | Never relaunch. Tell the user the window and the error |
| 7 | The new session started but had not replied yet; it is LEFT RUNNING and your window stays until it replies | Tell the user to look at it; do not relaunch |
| 8 | No launcher here reproduces this session's provider route | Nothing started. Rerun with the launcher the user names for this route (`FSH_LAUNCH_CMD=<launcher>`, or map it in `FSH_LAUNCHERS`); otherwise ask which to use. Never move a session to another provider route on your own: a restricted route's data must not leave it |
| 9 | The `--host` preflight failed (unreachable, other identity, missing tools, untrusted or missing working dir, a root target without `IS_SANDBOX=1`) | Nothing started. Tell the user what the message names |

`cc-handoff launch --print <brief>` shows the plan (window, launcher line, summary) and
touches nothing.

## Launcher

The new session runs on the same provider route as this one, so a Mantle or Bedrock
session never hands off to the Claude subscription. cc-handoff reads the route from its
environment the way Claude Code does (the first `CLAUDE_CODE_USE_*` flag set to 1, true,
yes or on wins):

| This session | Launcher |
|---|---|
| A route `FSH_LAUNCHERS` names (`route=command` words; default `mantle=yuma`) | that command |
| The route plain `claude` starts on this machine | `FSH_DEFAULT_LAUNCHER`, default `claude` |
| Anything else | none: exit 8 |

It prints `launcher: <name>, because ...` and pins this session's model (its
`ANTHROPIC_DEFAULT_OPUS_MODEL`, else the `opus` alias) and effort. Flags that shape this
session (`--strict-mcp-config`, `--mcp-config`, `--add-dir`, `--plugin-dir`) carry over on
this machine; `--claude-arg <arg>` (repeatable) adds more.
`FSH_LAUNCH_CMD=<launcher>` replaces the pick (the model then defaults to the `opus`
alias); `FSH_MODEL` and `FSH_EFFORT` pin those. A successor started with plain `claude`
skips permission checks only when this session's own command line did
(`--dangerously-skip-permissions`); `FSH_BYPASS=1|0` overrides. Details:
`~/.dotfiles/docs/handoff.md`, The launcher.

## Background jobs

init lists this session's live jobs in the brief: Bash commands run in the background (and
still running) and background agents or workflows its transcript never saw finish. Say
who takes over each one. While any still runs, your window stays open (statusline `⤳ HELD
(jobs)`), and the new session's prompt asks it to adopt them. The new session runs
`cc-handoff adopt --all` (or job ids) once it has restarted or taken over what it needs.
Jobs that finish on their own release the hold too. If you started a long job on purpose
for the new session to watch, prefer restarting it there to keeping this window alive.

## In the new session

The prompt says it is only a summary and was written by the tool, not typed by a person.
Read the brief in full, then check it against the end of the previous session's rendered
transcript (path in the prompt; it is also echoed in the terminal above you for the user)
and trust the transcript where they disagree. Rebuild your todo list from the brief's Left
section, tell the sessions in Driver and manager your new session name, adopt the jobs
the prompt mentions, then do what the prompt's last line says. Your statusline shows
`⤷N`, your generation in the chain.

## Another host

`--host <alias>` (an ssh alias) moves the work: the chain and your raw transcript are
copied there, the window opens in that machine's `handoffs` tmux session, and your window
here closes after the new session replies there. `--host auto` asks a `fleet-place` command, when one is on PATH, for the
least-loaded eligible machine and stays here when it gives none (`--away` excludes this
machine). The target needs synced dotfiles, tmux, zsh, claude, python3 and jq, the same
identity (work and personal never cross), and a working directory Claude Code trusts
there. A path under your home maps to the target's home; `--cwd <dir>` names another one
on the target. A box whose credentials come from an instance role should get
`FSH_LAUNCH_CMD=claude`, so no token is ever copied.

- Carried flags stay behind: their paths belong to this machine. Pass the target's own,
  e.g. `--claude-arg --strict-mcp-config --claude-arg --mcp-config --claude-arg <its file>`.
- A target that runs Claude Code as root needs `FSH_SUCCESSOR_ENV=IS_SANDBOX=1` in front of
  the launch (bypass mode refuses root without it); preflight stops with exit 9 otherwise.
  This session's own `IS_SANDBOX` only counts for a successor on this same machine.
- `FSH_SUCCESSOR_ENV` takes `NAME=value` words with plain values, each name once. It is
  recorded in the chain and travels with it: never pass credentials this way.
- The copy there belongs to the target's user, in an owner-only directory; the raw
  transcript in it (`gen-NN/session.jsonl.gz`, not redacted) is readable by that user only.

## The handed-off flag

| Where | Shows |
|---|---|
| Statusline, this session | `⤳ HANDOFF? → <target>` while launching, `⤳ HANDED OFF → <target>` once the new session started, `⤳ HELD (jobs) → <target>` while jobs keep the window open |
| tmux | a red `⤳` badge on this window and `🔴⤳` in the tab title |
| Context advisor | stops urging another handoff for this session |

A user who keeps working here after the handoff is fine: typing in this window keeps it
open. Do not launch a second handoff unless they ask. `cc-handoff keep` keeps the window
open for good.

## Rationalizations

| Thought | Reality |
|---|---|
| "The advisor only says to consider it; I'll suggest it to the user." | The handoff is meant to run on its own. Suggesting without doing is the failure this skill fixes. |
| "1M window, compaction is far off, 87% is not urgent." | The advisory budget is the threshold on purpose: quality and usage limits degrade long before compaction. |
| "The summary lines are enough; the brief can stay thin." | The successor is told the summary is not enough and reads the brief. A thin brief is a lost handoff. |
| "I'll type the prompt into the new pane with tmux send-keys." | Never. cc-handoff passes it as an argument; long text through send-keys breaks on quotes, newlines and `$`. |
| "My background watcher can die with this window." | It holds the window open, and the new session adopts it. Say in the brief what it does and who takes it over. |
| "The new window opened, so I'll close mine myself." | Never kill windows, sessions or the tmux server. The watcher closes this window, by its pane id, once the new session replied and no job holds it. |
| "The user wants the open items done, so the new session can open the PR or merge." | PRs, MRs, merges, branch deletes, force-pushes and comments need the user's go, in the new session too, unless the Rules say otherwise. |
| "Handoffs launch `claude`, so I'll set `FSH_LAUNCH_CMD=claude`." | `claude` starts this machine's default route, not necessarily this session's. Override only on exit 8, for an instance-role box, or when the user names a route. |
| "The /goal hook says keep going, so I'll keep working here." | The goal went to the new session. Answer the hook in one line: handed off. |
