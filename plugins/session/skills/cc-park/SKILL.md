---
name: cc-park
description: Park idle Claude Code sessions that sit in tmux panes, to free memory without losing the window. Claude exits through /exit (stopping its Playwright MCP, pyright and tsserver helpers); the pane then shows the session's last screen as plain text, with the exact resume command typed (not run) at the prompt below, so Enter brings the conversation back. A session that had finished (its last reply asks nothing and waits on nothing, and Drover agrees) gets its window closed instead, with its resume command kept in `cc-park status`. An optional LaunchAgent (macOS) or systemd user timer (Linux) autoparks sessions idle 6 h or more every 30 minutes. Use when the machine is out of memory or swap is full, when there are dozens of old sessions open, or when the user says "park my idle sessions", "free up memory from old claude sessions", "close idle sessions but keep the windows", "close the windows of finished sessions", "what's parked", "what got closed", "resume a parked session", "autopark", "stop autoparking", "keep this session from being parked", or "keep this window open".
---

# cc-park

An idle Claude Code session is not free. Measured on a Mac in October 2026, each one
held about 300 MB itself plus about 260 MB of Playwright MCP servers from the moment it
started, and once it had edited a .ts or .py file, a TypeScript server (700 MB on
average for a large monorepo, up to 4 GB) and pyright (about 200 MB). None of those stop
until the session exits. 47 sessions idle for more than a day held about 40 GB.

Parking keeps what is useful about leaving a session open (the tmux window, its
name, the scrollback, one keypress to continue) and drops the processes. It costs
no extra tokens after an hour idle: the prompt cache lasts at most an hour, so a
session idle longer than that starts cold whether it is resumed or continued.

## Commands

```bash
cc-park list                 # read-only: what would be parked or closed, and why the rest are skipped
cc-park park                 # park every session idle for 6 h or more; close the finished ones' windows
cc-park park --idle 24       # a different threshold
cc-park park --no-close      # park finished sessions in place too
cc-park park --only 12345,handoffs:7.1,%42   # pids, tmux targets or pane ids
cc-park status               # parked and closed sessions, their resume commands, which were resumed
cc-park auto status          # is autopark on, is its LaunchAgent / systemd timer loaded, its last runs
cc-park auto off             # pause autopark on this machine (`cc-park auto on` undoes it)
tmux set -p @cc-park-keep on # keep this pane's session out of bulk parking (-w for the window)
tmux set -p @cc-park-close off  # park it in place even when finished (-w window, -gw every window)
```

The default threshold, 6 h, is `IDLE_HOURS` in the script, the same for `list`, `park` and the
scheduled run.

To resume, go to the pane and press Enter. The typed command is
`cd <dir> && claude <original flags> --resume <session id>`. For a session whose window was
closed, run the command `cc-park status` shows for it, in any window.

## What a parked pane shows

The session's last screen, as plain text, so a parked window still says what it was
doing:

```text
── last screen before cc-park parked this session ──
⏺ The rollout is still waiting on your sign-off.
✻ Brewed for 12s · done Thursday 1:20 PM
── parked Thu 05:09, last active Wed 18:26 · press Enter to resume ──

@laptop webapp on  master
❯ cd /home/you/code/webapp && claude --dangerously-skip-permissions --resume 3dca2a62-…
```

That is the conversation part of the screen captured just before /exit: everything above
Claude's input box, cut to fit the pane with the prompt below it. cc-park clears the pane
first (tmux's `scroll-on-clear` moves Claude's final frame into the scrollback), writes
the text to the pane's tty, so it is output and never reaches the shell's input or
history, then sends Ctrl-C, so the shell draws a fresh prompt below it, and types the
resume command there. The whole screen with 400 lines of history is kept in
`~/.local/state/cc-park/screens/<session id>.txt`.

## Closing the windows of finished sessions

A session that had finished does not need its window kept: cc-park parks it, then closes the
window instead of leaving the last screen and a typed resume command in it. Its screen is saved
and its resume command goes into the ledger exactly as for a parked pane, so `cc-park status`
lists it as `closed (done)`, with the command and the saved screen:

```text
closed (done) handoffs:7.1     repo-17                    2026-10-26T20:21:17Z  cd /home/you/code/webapp && claude --dangerously-skip-permissions --resume 2fe7d41b-…
              last screen: /home/you/.local/state/cc-park/screens/2fe7d41b-….txt
```

Run that command in any window to bring the conversation back; `status` then shows it `resumed`.

Finished means all of the following, and anything unclear parks the session in place as before:

- It passes every parking check below, so which sessions get parked does not change.
- Its last turn ended with a reply (`stop_reason` `end_turn`): not interrupted, not an API error,
  no tool call or AskUserQuestion still waiting for its result, and no slash command output or
  stop-hook feedback after it.
- That final reply (the text after the turn's last tool result) has no question mark outside code
  and links, and none of the waiting words in `WAITING` ("waiting", "needs your", "your yes",
  "let me know", "if you want", "I'll", "next steps", and so on). Set `CC_PARK_OWNER` to your
  name (comma-separated for several) and a reply that names you counts as waiting too: replies
  often address the owner by name ("Waiting on Alex", "Alex's call").
- [Drover](https://github.com/coletebou/drover) agrees: `drover op sessions.lastReply` returns
  `ask.kind` `finished` for this session id, with its text. No drover CLI, an error, a timeout, or
  an answer about another session parks it in place. Drover alone is not enough: it counts a reply
  as finished unless its last line ends in "?", and a reply like "Waiting on Alex. Everything left
  needs his yes: ..." passed it.

Against 484 real transcripts from October 2026, 83 passed, and reading them all, every one was a
handoff, a report or an answer; none asked or waited on anything, though a few left the owner a step.

The window must also hold nothing else:

- the pane is the only pane in its window (a split window is parked in place, its layout untouched);
- the window is not linked into another tmux session, and is not the last window of its session
  (closing that would end the session, which other tools open new windows in);
- nothing else runs in the pane: no other job of its shell, nothing else on its terminal;
- neither `@cc-park-keep` nor `@cc-park-close off` is set on the pane or window.

These window checks run again after claude has exited, just before the pane is killed. If the
user switched to it meanwhile, or a process is still in the pane after five seconds, it is parked
in place instead. Closing is `tmux kill-pane` on that one pane, which takes its window with it.

- **Keep a window:** `tmux set -p @cc-park-close off` in the pane, `-w` for the whole window, or
  `tmux set -gw @cc-park-close off` for every window on that tmux server (put it in tmux.conf to
  keep it). The session is still parked; only its window stays.
- **One run:** `cc-park park --no-close` (or `list` / `auto --no-close`).

`cc-park list` says which applies to each session it would park: `park, then close its window:
finished`, or `park; window stays: <why>`.

## Autopark

`launchagents/com.cc-park-auto.plist` (macOS) and `systemd/user/cc-park-auto.timer` (Linux) run
`cc-park auto` every 30 minutes (`install.sh --with schedules` installs and loads the one for this
OS). It parks the sessions that have been idle
for 6 hours or more (`IDLE_HOURS` in the script) and pass every check below, and closes the
windows of the finished ones as described above; it never types into a busy, dialog or
half-typed session, the pane on screen, or a pane in copy mode. Its output goes to
`~/.local/state/logs/cc-park-auto.log`, one `== <time>` line per run, and every park attempt
is in the ledger as before.

- **Pause it on one machine:** `cc-park auto off`. That is a flag file
  (`~/.local/state/cc-park/auto.off`), so reinstalls do not undo it.
- **Keep one session live:** `tmux set -p @cc-park-keep on` in its pane, or `-w` for
  the whole window. Bulk parking (`park` and `auto`) skips it; naming it with `--only`
  still parks it.
- One park run at a time: a manual `park` during an autopark run (or the other way
  round) exits 75 instead of typing into the same panes twice.

Run `cc-park list` first and read the skip reasons. Parking the pane you are
looking at is refused, so run it from a pane you are not parking.

To restart sessions after a config change that needs a new process (settings `env`,
plugin skills, agents), park with `--idle 1` and press Enter in each pane. An hour
idle means the prompt cache is already cold, so the restart costs nothing extra.
Hooks and most settings reload in a running session and need no restart.

## What it refuses to park, and why

| Skip | Why |
|---|---|
| status `busy`, `shell`, or activity within `--idle` hours | still working. Activity is the newest transcript entry (main and subagent transcripts) or the status change, never file mtime: live sessions' transcripts get their mtime bumped with no new entries |
| `Waiting for N background agent(s)` on screen | its turn ended but an agent it started is still working; /exit would only move the conversation to the background (seen 2026-10-18) |
| a cron job, a pending wakeup, a monitor in the last 48 h | `/loop`, `CronCreate` and `ScheduleWakeup` live in the claude process and die with it |
| a child process that is not an MCP or language-server helper | a background shell, a test run, a browser |
| a dialog, a busy spinner, or unsent text in the prompt | Enter would answer someone else's question; unsent text would be lost |
| the pane on screen in an attached client | do not pull a session out from under the user |
| the pane is in copy mode | keys sent to it drive copy mode, so `/exit` would start a search |
| its window has `synchronize-panes` on | tmux copies every key sent to one pane into all of them, so `/exit`, Ctrl-C and the resume command would reach every pane in the window |
| `@cc-park-keep` set on the pane or window | someone asked for it to stay live; `--only` still parks it |
| a launch flag it does not know | `ps` loses quoting, so only known flags are replayed; anything else is resumed by hand |
| a `--settings` file that no longer exists | the resume command would fail |
| no `<id>.jsonl` (the session never got a prompt) | nothing to resume: `--resume` prints "No conversation found" |
| activity after the run started | a run that parks several sessions takes minutes; a session the user went back to meanwhile is no longer idle, and what was read about its last turn may be out of date |

The initial prompt on the original command line (`claude --model opus "You are the
orchestrator ..."`) is dropped from the resume command, because replaying it would
send it again.

The pane checks (on screen, copy mode, synchronized, kept) and the activity check run again
just before each session gets its first key, because a run that parks several sessions takes
minutes and you may switch to a queued pane meanwhile.

## Traps it handles (learned the hard way)

- **`tmux respawn-pane` with no command re-runs the pane's original command.** For a
  pane created as `tmux new-window 'claude ... "brief"'`, that started a fresh
  session that began executing the brief (2026-10-14; interrupted after 30 s, read-only
  commands only). The respawn always names the shell: `exec $SHELL -l`.
- **Panes launched through a wrapper** (`zsh -lic "... claude ..."`) die with claude like
  panes where claude is the root process; both get `remain-on-exit` before /exit and
  a respawned shell after. A pane that went dead for any other reason is respawned too.
- **Claude's exit hint prints the session id**, so "the id is on screen" does not prove
  the command was typed. The check is that the prompt ends with the whole command,
  joining lines the shell wrapped.
- **A named session's input box** shows its name in the top border (`─── name ─`).
- **The last-screen markers** start with only two `─` and end in `──`, so they can never
  pass for Claude's input-box rules or a shell prompt when cc-park waits for the prompt
  that Ctrl-C brings back.
- **tmux 3.8 answers `display -p -t %N` for a pane that no longer exists with exit 0 and
  every field empty**, so "is the pane still there" checks that its id comes back. A dead
  pane (`remain-on-exit`) prints an empty `#{pane_pid}`; one such pane anywhere on the
  server used to make every `list` and autopark run fail on `int('')`.

## Limits

- Environment prefixes on the original launch (`FOO=1 claude ...`) are not replayed; the
  resumed process gets the pane shell's environment. Flags are replayed.
- Only Claude Code sessions in tmux. Codex sessions are not touched (`codex resume <id>` by hand).
- The MB column is `top`'s MEM on macOS (physical footprint, compressed pages included) and
  `VmRSS` + `VmSwap` from `/proc` on Linux (resident plus swapped-out pages). Both count
  a session's whole process tree: claude plus its MCP and language-server helpers.
- Ledger: `~/.local/state/cc-park/parked.jsonl` (one line per attempt; `closed: true` when
  the window was closed). The screen as it was before parking:
  `~/.local/state/cc-park/screens/<session id>.txt`.
- Windows close only where the `drover` CLI is on PATH (for the scheduled run, the PATH its
  LaunchAgent or systemd unit sets, which has `~/.local/bin`); elsewhere every session is parked
  in place. The waiting words
  are English, so a reply in another language that waits on someone without a question mark
  could still read as finished.
- The last screen is plain text: colors are dropped, and a screen captured at one pane
  width wraps again if the pane is narrower later.
- launchd and systemd see none of the shell's environment, so the scheduled run uses
  `~/.local/state/cc-park` and `~/.claude`. A shell that set `XDG_STATE_HOME` or
  `CLAUDE_CONFIG_DIR` would give manual runs a different lock, pause flag and session
  list, and `CC_PARK_OWNER` has to be set in the unit for the scheduled run to use it.

Tests: `python3 ~/.dotfiles/scripts/tests/cc-park.test.py` (CI runs them).
