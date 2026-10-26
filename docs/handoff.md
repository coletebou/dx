# Handoff chains (cc-handoff)

A long Claude Code session hands its open work to a fresh session in a new tmux window,
as one generation of a chain. `scripts/cc-handoff` (bash) drives tmux, ssh and the
launchers; `scripts/lib/cc_handoff.py` keeps the chain records, renders transcripts,
builds the prompt and closes the passer. Agents reach it through the
`fresh-session-handoff` skill (the context advisor tells them when).

```bash
cc-handoff init                       # chain + this generation's brief skeleton; prints its path
$EDITOR <brief>                       # replace every FILL placeholder
cc-handoff launch [--go] [<brief>]    # open the successor, close this window after its first reply
cc-handoff launch --host <alias>      # ... on another host (ssh + tmux there)
cc-handoff launch --host auto         # ... where fleet-place puts a claude-session (else here)
cc-handoff status [<chain dir>]       # one line per generation
cc-handoff adopt --all | <job id>...  # successor: take over the passer's background jobs
cc-handoff keep                       # passer: never close this window
cc-handoff jobs                       # this session's background jobs, as the watcher sees them
cc-handoff render <transcript.jsonl> [-o <file>]   # a transcript, rendered and redacted
```

## The flow

1. `init` (run by the passer, inside its Claude session) finds or starts the chain. A
   session the launcher started is already marked with its chain and generation
   (`~/.claude/state/handoff-chain/<session id>.json`); otherwise it starts a new chain
   at `~/code/.briefs/<repo>-handoff-<YYYYMMDD>[-HHMM]/` with itself as generation 1. It
   writes `gen-NN/brief.md`: the fixed sections, with the live facts already filled in.
2. The agent fills the brief. `launch` refuses one with a FILL placeholder left, an empty
   section or a missing Summary line (exit 2, nothing started).
3. `launch` renders the passer's transcript next to its brief, gives the successor a fresh
   session id (`claude --session-id`), writes its inline prompt, marks it for the
   statusline, opens a window right after the passer's (in the passer's tmux session)
   whose command is `cc-handoff successor-run`, flags the passer, and starts the watcher.
4. The new window prints the chain's linear history, copies the passer's rendered
   transcript to a tmux buffer (and the macOS or Windows clipboard), scrolls that into
   the history, then starts Claude Code through the launcher for the passer's route (plain
   `claude`, or a launcher such as `yu` or `yuma` run by a login `zsh -lic` the way a person
   would; see The launcher) with the prompt as an argument. Nothing is typed into the pane. When Claude exits, the window drops to a
   login shell.
5. The watcher (`tmux run-shell -b`, so it is a child of the tmux server and survives
   the passer's window) waits for the successor's first reply, then closes the passer's
   window once nothing holds it (see Closing the passer).

## Chain layout

```text
~/code/.briefs/<chain>/
  chain.json             name, root (successor session names are <root>-<gen>), created
  gen-01/session.json    who ran generation 1, where, and what became of its window
  gen-01/brief.md        written by generation 1 for generation 2 (fixed structure)
  gen-01/transcript.md   generation 1's transcript, rendered and redacted, at handoff
  gen-01/watch.log       every decision the watcher made about its window
  gen-02/prompt.txt      the inline prompt generation 2 started with
  ...
```

Session names follow the chain: a passer named `ocean` hands to `ocean-2`, then
`ocean-3`. Distinct names matter because Drover resolves a name to the first live
session that has it. `--notify <session>` tells a manager the new name once the
successor has replied.

## The brief

`gen-NN/brief.md`, written by generation NN for NN+1. Every section must be present and
non-empty (`none` is fine):

| Section | What goes in it |
|---|---|
| Summary | Three lines, `Continuing:`, `Done:`, `Left:`. They are lifted into the prompt. |
| What happened | What was asked (the latest unfinished request word for word), tried, learned |
| Done | Each finished item with its evidence |
| Left | Open items in priority order with the next action and whether it needs the user's go. The todo list carries forward from here; init adds the session's last todo list when it had one. |
| Proposed improvements | What the next session or the tooling should do differently |
| Driver and manager | Who drives the session, who it reports to, which sessions it manages. init lists the first prompt, the active /goal and the sessions it messaged or launched through Drover. |
| Background jobs | init's table of live jobs, plus who adopts each |
| IDs and paths | Filled by init: chain, host, session id, raw transcript, resume command, tmux target and pane, working directory and git state, earlier generations |
| Rules | What the successor may do without asking |

## The inline prompt

About 8 lines, written by the tool, never typed:

```text
[cc-handoff] You are generation 3 (session name ocean-3) of handoff chain <chain>, continuing ocean-2
(session 303597bd, host build-box, tmux ops:4). This message was written by the handoff tool
from that session's brief, not typed by a person.
It is only a summary. The brief is the source of truth: <chain>/gen-02/brief.md
Continuing: ...
Done: ...
Left: ...
Background jobs: none were running; the previous session's window closes after your first reply.
Before acting: read the brief in full, then check it against the end of the previous session's own
transcript (<chain>/gen-02/transcript.md ...); where they disagree, trust the transcript. Build or
refresh your todo list from the brief's Left section, and tell the sessions named in its Driver and
manager section your session name (ocean-3).
Then verify the live state the brief names, summarize the open items to me and ask which to start. ...
```

`--go` (or `FSH_AUTHORIZED=1`) replaces the last line: do all of it, asking only where the
brief's Rules say to. When the passer had an active `/goal`, the prompt starts with
`/goal <that condition>` so the successor keeps working toward it (`--no-goal` drops it,
`--goal <text>` replaces it). `/goal` takes every word after it as the condition, so the
condition carried forward is cut at the `[cc-handoff]` line; otherwise it would swallow
each generation's summary.

## The echoed history

The new window prints, oldest first: brief 1 through brief n-1, then generation n's full
rendered transcript, then a footer (the brief generation n+1 reads, the rendered file,
the raw JSONL path and host, the command that resumes generation n, the tmux buffer
name). Generation n's own brief is not echoed; the new session reads it. The echo is cut
to the pane's `history-limit` minus a margin; the files are complete.

The rendered transcript holds user and assistant text in full, one line per tool call with
its result cut to one line, task notifications, messages from other sessions and
compaction marks. It leaves out thinking, hook and system-injected text and subagent
sidechains. A 10 MB, 7,000-record transcript renders to about 300 KB in under half a
second.

Claude Code's first frames can erase the visible screen of a small window, so the footer
is scrolled into the history (one pane height of newlines) before Claude starts.

## Closing the passer

The watcher closes the passer's window only when all of these hold:

- The successor has replied: its transcript has an assistant message with text or a tool
  call, not an API error. No reply within `FSH_FIRST_RESPONSE_TIMEOUT` (30 min) means
  the passer stays (`skipped`).
- No job of the passer is still running, or the successor adopted it. Jobs are its live
  Bash-tool shells (children of its claude process whose command line is a Claude Code
  shell snapshot), matched to their background task ids from the transcript, plus
  in-process tasks (background agents, workflows) the transcript never saw finish.
  While any job blocks the close, the window is `held`. The statusline shows HELD and
  the window option `@handoff_hold` is set; the successor's prompt tells it to adopt
  them. `cc-handoff adopt --all` (or job ids) releases the hold; a job that finishes
  on its own does too. After `FSH_HOLD_MAX` (12 h) the window stays for good.
- Nobody typed in the passer after the handoff (that keeps it open for them), and the
  pane still belongs to it: the window's `@handoff_src` tag is exactly
  `<pane> <session id>` and the passer's claude process runs in that pane.
- The passer's turn has ended and its transcript has been quiet for `FSH_QUIET_SECS`
  (10 s), or `FSH_QUIET_MAX` (300 s) has passed (a /goal hook can keep a passer busy).

Then it closes the window (`kill-window -t %N`, or `kill-pane -t %N` when the window has
other panes). It neither re-renders the transcript nor captures the screen at that point:
the watcher runs with the tmux server's environment, not the passer's, so it would redact
less than the launch-time render did. The session id stays resumable: `cd <dir> && claude --resume <id>`.

cc-handoff never kills a tmux server or session. The bash side refuses every kill verb;
the Python side refuses `kill-server`, `kill-session` and a chained `;`, and allows only
`kill-window` or `kill-pane` with a single explicit `%pane` target. `--no-kill` or
`FSH_KILL=0` turns closing off for one handoff; `cc-handoff keep` does it from the passer.

## The launcher

The successor runs on the passer's provider route, so a Bedrock or Mantle session never
hands off to a subscription (or the other way round). cc-handoff reads the route the way
Claude Code does (the first `CLAUDE_CODE_USE_*` flag set to 1, true, yes or on wins; a
custom `ANTHROPIC_BASE_URL` is its own route) and picks:

| Setting | Effect |
|---|---|
| `FSH_LAUNCHERS` | `route=command` words, default `mantle=yuma`. Routes: `anthropic`, `mantle`, `bedrock`, `bedrock+mantle`, `foundry`, `anthropic-aws`, `anthropic-gcp`, `vertex`, `endpoint` |
| `FSH_DEFAULT_LAUNCHER` | for a route the map does not name, when plain `claude` starts that same route on this machine (read from `~/.claude/settings.json` and the repo's `.claude/settings*.json`); default `claude` |
| `FSH_LAUNCH_CMD` | skips the detection: always this launcher (its model then defaults to the `opus` alias) |

No launcher for the route means exit 8 and nothing started. A launcher is a bare command
name: `claude` is run directly; anything else runs through a login `zsh -lic`, so zsh
functions from your profile (`yu`, `yuma` in base/aliases.sh) work.

Permissions: a successor started with plain `claude` gets `--dangerously-skip-permissions`
only when the passer's own command line had it (or `--permission-mode bypassPermissions`);
`FSH_BYPASS=1|0` overrides. A passer in bypass mode through its settings needs no flag:
the successor reads the same settings. Other launchers set their own mode.

## Status line

- `⤷N` after the machine and session id: this session is generation N (N >= 2) of its
  chain. `/clear` starts a new session id, which drops it.
- A red badge leading the line on the passer: `⤳ HANDOFF? → target` while the launch is in
  progress or failed after the window opened, `⤳ HANDED OFF → target` once the successor
  started or replied, `⤳ HELD (jobs) → target` while its jobs keep the window open.
- tmux: the passer's window gets a red `⤳` badge and a `🔴⤳` tab-title prefix.

## Another host

`--host <alias>` hands off over ssh. `--host auto` asks `fleet-place claude-session`
(`--away` adds `--exclude <this host>`) and stays here when it is missing, fails, or
answers `local` or this host. The target is checked first (exit 9 on any problem):
`cc-handoff` and tmux, zsh, claude, python3 and jq present; the same `DF_IDENTITY` (work
and personal never cross); the working directory present (a path under `$HOME` is mapped
to the target's `$HOME`, others are used as is); Claude Code trusting it (it shows its
trust dialog in an untrusted folder even in bypass mode); not this same machine with
this same briefs directory; and, when the target runs Claude Code as root, `IS_SANDBOX=1`
for the successor (bypass mode refuses root without it). Then the whole chain (briefs,
rendered transcripts, records) and the passer's raw JSONL (gzipped) are copied to the
target's `~/code/.briefs`, the window opens in the target's `handoffs` session, and the
watcher here asks the target over ssh for the reply, the adoption, and records its
decisions in the target's copy.

The copy belongs to the target's user (unpacked with `--no-same-owner`, so a root target
never keeps this host's uid), and its chain directory is owner-only (0700), like every
chain directory: the records hold the successor's environment and the user's goal. The
gzipped raw JSONL, which is not redacted, is 0600 on both hosts and removed here after
the copy.

The successor runs the launcher named by the route detection, on the target's own
settings. A box whose credentials come from an instance role should be launched with
`FSH_LAUNCH_CMD=claude` (its default route), so no token is ever copied. Carried flags stay
behind (their paths belong to this host): pass the target's own with `--claude-arg`, e.g.
`--claude-arg --strict-mcp-config --claude-arg --mcp-config --claude-arg <file there>`.

`FSH_SUCCESSOR_ENV` puts `NAME=value` words (plain values, each name once) into the
successor's environment, on any host. It is recorded in the chain and travels with it,
so give credentials to a target through its own environment, never here. This session's
own `IS_SANDBOX` carries over only to a successor on this same machine; another root
target is marked explicitly with `FSH_SUCCESSOR_ENV=IS_SANDBOX=1`.
`FSH_REMOTE_BRIEFS_DIR` and `FSH_REMOTE_CCH` override the target's briefs dir and the
path of its cc-handoff.

## Platforms

Bash 3.2 compatible (a Mac's `/bin/bash`), BSD and GNU tools alike (no `stat`, `date -d`,
`readlink -f` or `sed -i`), Python 3.8+. On a Mac the rendered transcript also goes to
`pbcopy`; under WSL to `clip.exe`. Exact argv of the passer (to carry its
`--strict-mcp-config`, `--mcp-config`, `--add-dir` and `--plugin-dir` flags) comes from
`/proc` on Linux and from `ps` elsewhere, which cannot keep values with spaces.

## Redaction

Everything rendered or echoed (transcripts, briefs, the last screen, the tmux buffer and
the clipboard copy of the transcript) is redacted. That covers credential shapes
(Anthropic, OpenAI, AWS, Bedrock, GitHub, GitLab, xAI and Slack keys, JWTs, bearer
headers, URL credentials, private keys, `name=value` where the name says secret), the
literal values in `~/.env_secrets` and in any secret-named environment variable, and
personal data: email addresses and phone numbers. SSH remotes (`git@host:`) and
no-reply addresses stay.

## Exit codes (launch)

| Code | Meaning |
|---|---|
| 0 | The successor started and replied |
| 2 | Bad arguments or an unready brief; nothing started |
| 3 | tmux, jq or python3 missing |
| 4 | This brief or chain step already has a live successor; never relaunch |
| 5 | tmux failed or Claude Code did not start; a window that opened is LEFT RUNNING |
| 7 | The successor started but had not replied within `FSH_ENGAGE_TIMEOUT` (180 s); it is LEFT RUNNING and the watcher keeps waiting |
| 8 | No launcher here reproduces this session's provider route; nothing started |
| 9 | The `--host` preflight failed; nothing started |

## Testing

```bash
sudo systemd-run --wait --pipe --collect --uid="$(id -u)" --gid="$(id -g)" -p PrivateTmp=yes \
  -E HOME="$HOME" -E PATH="$PATH" --working-directory="$PWD" -- bash scripts/tests/tmux-sandbox.test.sh
# same for scripts/tests/cc-handoff.test.sh
bash base/claude/statusline.test.sh
```

A Mac has no private `/tmp`; `sandbox-exec` is the second layer there. Its profile hides
the real socket directory (uid 501 in this example):

```
(version 1)
(allow default)
(deny file-read* file-write* (subpath "/private/tmp/tmux-501"))
(deny network-outbound (remote unix-socket (path-regex #"^/private/tmp/tmux-501/")))
```

Prove it first: inside `sandbox-exec -f prof.sb /bin/bash`, with `TMUX` unset,
`tmux -S /private/tmp/tmux-501/default list-sessions` must fail ("Operation not
permitted") while a server on a socket in a temp dir works. Then run each test as
`sandbox-exec -f prof.sb nice -n 19 taskpolicy -b /bin/bash <test>`. `/bin/ps` is refused
inside the sandbox (it is setuid), which the job scan handles (pgrep, then an unknown job
that holds the window). Where neither layer exists, `TSB_ALLOW_SHARED_TMP=1` accepts the
guards alone.

`cc-handoff.test.sh` runs whole chains against fake launchers (a fake Claude Code that
writes a real-shaped transcript and replies once) and a fake ssh that is a second host
with its own HOME and tmux server. It uses `scripts/tests/lib/tmux-sandbox.sh`, which
exists because of 2026-10-23: inside a tmux pane `$TMUX` beats `TMUX_TMPDIR`, and a
manual `TMUX_TMPDIR=<dir> tmux kill-server` killed the real server and every Claude
session on it. The sandbox unsets `TMUX`, passes `-S <socket in the test's temp dir>` on
every call, puts a guard first on PATH that refuses any other socket and any
`kill-server`, and tears down only servers it created whose sessions are all the test's.
`tmux-sandbox.test.sh` proves it against a decoy server standing in for the real one.
Both tests first refuse to run if a real tmux socket is visible.

## Why the prompt is a summary, and how its downsides are handled

| Risk | Handling |
|---|---|
| The successor anchors on the short summary and skips the brief | The prompt says it is only a summary and requires reading the brief in full before acting |
| Long text through `tmux send-keys` breaks on quotes, newlines and `$` | The prompt is a file passed as one argument through the launcher; nothing is typed |
| A passer with a degraded context writes a worse summary | The successor checks the brief against the passer's own transcript and trusts the transcript where they disagree |
| Killing the passer kills its background shells | The window closes only when no job runs or the successor adopted them; the session id stays resumable |
| Full transcripts are huge (500k+ tokens) and tmux keeps scrollback in RAM | The echo is a rendered transcript (text, one line per tool call), capped to `history-limit`; the raw JSONL path is printed |
| A successor takes the kickoff for a person's words | The prompt says the handoff tool wrote it |
