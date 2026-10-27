# dotsync: one dotfiles checkout, every machine

`dotsync` keeps a dotfiles checkout in sync across your machines. One run on any machine:

1. commits what changed there, after a [gitleaks](https://github.com/gitleaks/gitleaks) scan of
   the change (no gitleaks, no commit);
2. pulls (fetch, then rebase onto the upstream), keeping your commits if the rebase conflicts;
3. pushes, after a second scan of every commit it is about to publish, retrying when another
   machine pushed first;
4. reruns `install.sh` when the pull changed something it installs;
5. then runs `dotsync --local` on each of your other machines over ssh, in parallel, each bounded
   by a timeout. A machine whose identity differs from this one's is never touched.

Each machine also publishes a small heartbeat, so `dotsync status` on any machine shows when
every machine last synced and how it went. A timer (systemd or launchd) can run the local half
every hour, and skips while you, or an agent, are editing the checkout.

It works on macOS and Linux (bash 3.2 or newer, git, Python 3, gitleaks, OpenSSH), with any git
host you can push to. It never installs or enrolls anything on the network: peers are ssh
aliases you already use.

## Setup for two machines in five steps

Say `box-a` and `box-b` are ssh aliases that reach your two machines (`~/.ssh/config`, or
[Tailscale](infra/tailscale.md) names). Your dotfiles live in a repository both can push to,
for example a private fork of this one.

1. **Clone and install on each machine.** The `sync` component puts `dotsync`, `dotsync-doctor`
   and `dotsync-commit-message` in `~/.local/bin`; `shell` writes `~/.df-profile`, which names the
   machine and its identity (`identities/<name>/`).

   ```bash
   git clone git@example.com:you/dotfiles.git ~/.dotfiles
   ~/.dotfiles/install.sh --with shell,git,sync --identity example   # same identity on both
   ```

2. **Install gitleaks on each machine** (`brew install gitleaks`, or a release binary). dotsync
   refuses to commit or push without it.

3. **Check that each can reach the other non-interactively.** dotsync uses `ssh -o BatchMode=yes`,
   so a key (or Tailscale SSH) must work without a prompt:

   ```bash
   ssh -o BatchMode=yes box-b true && echo reachable    # on box-a, and the other way round
   ```

4. **List the peers.** On box-a, `~/.config/dotsync/peers` holds `box-b`; on box-b it holds
   `box-a` (or put one list in the repository, below). `dotsync peers` shows what it found.

5. **Sync.** On box-a: `dotsync --wait`. It commits box-a's changes, pushes them, and runs box-b's
   own dotsync, which pulls them. `dotsync status` then lists both machines. Optionally, add the
   hourly timer: `./install.sh --with schedules` (it installs the dotsync job only on a machine
   with the sync component).

Without `--wait`, a manual run returns as soon as this machine is pushed, and the peers update
in the background: `dotsync status` shows that fan-out's result, and a desktop notification says
when one went wrong.

## Everyday commands

```bash
dotsync                  # sync this machine, then the peers in the background
dotsync --wait           # ... and wait for them (their outcome decides the exit status)
dotsync --local          # this machine only
dotsync --host box-b     # this machine, then box-b only (waits; an unreachable box-b fails)
dotsync --pull-only      # never commit or push here; just pull (a machine that only receives)
dotsync --dry-run        # what a run would do, with no network and no writes (--json too)
dotsync status           # pause, timer, last fan-out, and every machine's heartbeat
dotsync status --refresh # fetch the heartbeats first
dotsync peers            # the peers it would contact, and where each comes from
dotsync doctor           # a bounded, read-only diagnosis (--json)
dotsync pause            # unattended runs (timers, runs a peer starts) skip until...
dotsync resume
```

Exit status: 0 success (including a run that deferred, or left an unreachable laptop for later);
1 a failure (the result line names the phase: `secret-scan`, `git-rebase`, `git-push`,
`install`, `peer-sync`, a hook...); 2 a usage error; 3 a peer that did not reach the commit it was
sent (`stale-config`); 75 another dotsync holds the lock.

## The peers

Peers come from configuration, never from a built-in list:

- **The peers file**, `~/.config/dotsync/peers` (`DOTSYNC_PEERS_FILE` moves it): one ssh alias
  per line, then optionally the identity and the role that machine runs, `-` for unknown. `#`
  starts a comment.

  ```text
  # alias     identity   role
  box-b
  build-01    example    server
  work-lap    work       local     # another identity: listed, never synced from here
  ```

- **The repository's list**, `identities/<identity>/dotsync-peers`, the same format. It travels
  with the checkout, so one list serves every machine of that identity (each skips itself).
- **The tailnet, opt-in.** With `DOTSYNC_TAILSCALE_TAG=tag:dotfiles`, the online machines of
  your tailnet carrying that tag join the candidates (contacted as `ssh <HostName>`). Phones,
  Windows hosts and machines shared from another tailnet never qualify. A tagged machine that
  turns out not to be a dotfiles peer is reported, not counted as a failure.
- **`--host`** replaces all of the above for one run.

The identity column only pre-filters. Before anything runs on a peer, dotsync reads that peer's
`~/.df-profile` over ssh, as data (never sourced): a peer whose `DF_IDENTITY` differs is skipped,
a peer whose identity cannot be read is refused, and a peer that turns out to be this machine is
skipped. The command sent to the peer checks the identity again on the receiving side, so a
profile changed in between still never gets synced. `--host` does not override any of this.

`DOTSYNC_EXCLUDE_HOSTS="box-c box-d"` leaves machines out of every run.

## Hooks

Executables in `~/.config/dotsync/hooks/<stage>.d/` (`DOTSYNC_HOOKS_DIR` moves the root) run in
name order, from the checkout, each bounded by `DOTSYNC_HOOK_TIMEOUT` (120 s). They never inherit
dotsync's lock, and a hook directory or hook that another user can write is refused. Names
ending in `~`, `.disabled` or `.sample`, and non-executable files, are skipped.

| Stage | Runs | A failure |
|---|---|---|
| `pre-commit.d` | before dotsync stages anything | stops the run: nothing is committed or pushed |
| `post-pull.d` | after the pull and the `install.sh` rerun (also when nothing new arrived) | fails the run, after everything else is done |
| `post-sync.d` | at the end, after the peers (for a background fan-out, in the background) | fails the run |

A deferred run (paused, or someone editing) runs no hooks. Hooks see `DOTFILES_DIR`,
`DOTSYNC_HOOK`, `DOTSYNC_HOST`, `DOTSYNC_IDENTITY`, `DOTSYNC_SCHEDULED`, `DOTSYNC_PEER`,
`DOTSYNC_START_HEAD` and `DOTSYNC_END_HEAD` (the pull moved the checkout when they differ), and in
post-sync `DOTSYNC_RESULT`. Examples:

```sh
#!/bin/sh
# pre-commit.d/10-drop-tool-drift: a tool rewrites its own config file; never commit that drift.
git restore --source=HEAD --staged --worktree -- .config/sometool/state.toml 2>/dev/null || true
```

```sh
#!/bin/sh
# post-pull.d/20-update-plugins: keep another checkout current (fast-forward only).
[ "$DOTSYNC_START_HEAD" = "$DOTSYNC_END_HEAD" ] && exit 0
git -C "$HOME/code/my-plugins" pull --ff-only --quiet
```

```sh
#!/bin/sh
# post-sync.d/90-brew-drift: on a Mac timer run, note what the Brewfile and the machine disagree on.
[ "$DOTSYNC_SCHEDULED" = 1 ] && [ -f Brewfile ] || exit 0
brew bundle check --file=Brewfile >"${XDG_STATE_HOME:-$HOME/.local/state}/brew-drift.txt" 2>&1 || true
```

## Commit messages

An automatic commit's subject names the machine and the top-level areas it touched:
`chore(sync): box-a update base, scripts`. That is the default, and it needs nothing.

With a provider configured, `dotsync-commit-message` asks a model to describe the change instead
(`chore(sync): box-a: add a git alias for amending without an edit`), and before a push it
rewords this machine's unpublished commits that still carry a generic subject. Published history
is never rewritten. A slow, failing or missing provider never blocks a sync: the generic subject
stays (the timeout is `DOTSYNC_COMMIT_MESSAGE_TIMEOUT`, 20 s), and a transport failure pauses
model calls for ten minutes. A command provider runs in a process group of its own: on its
timeout, or when dotsync stops the helper, that whole group goes (TERM, then KILL two seconds
later), so an agent it started never keeps working, or billing, after the call.

| `DOTSYNC_COMMIT_MESSAGE_PROVIDER` | What it calls | Credential |
|---|---|---|
| `off` (the default) | nothing | none |
| `command` (or just set `DOTSYNC_COMMIT_MESSAGE_CMD`) | your command, through `sh`: the prompt on stdin; it prints `{"subject": ..., "details": [...]}` or a plain subject line, with optional `- ` detail lines | whatever it uses |
| `anthropic` | the Anthropic Messages API | `ANTHROPIC_API_KEY` |
| `bedrock` | Amazon Bedrock Runtime | `AWS_BEARER_TOKEN_BEDROCK` (a Bedrock API key) |

```bash
# ~/.config/dotsync/config (literal KEY=value lines; the environment wins)

# The Anthropic API (the default model is claude-haiku-5-5):
DOTSYNC_COMMIT_MESSAGE_PROVIDER=anthropic

# Amazon Bedrock (the default model is us.anthropic.claude-haiku-5-5, region AWS_REGION or us-east-1):
DOTSYNC_COMMIT_MESSAGE_PROVIDER=bedrock
DOTSYNC_COMMIT_MESSAGE_REGION=us-west-2

# Any command that reads a prompt and prints a message, such as a headless agent:
DOTSYNC_COMMIT_MESSAGE_CMD=claude -p --model haiku
```

`DOTSYNC_COMMIT_MESSAGE_MODEL` overrides the model and `DOTSYNC_COMMIT_MESSAGE_ENDPOINT` the URL.
Credentials come only from the environment, never from a command line or a log. A timer does not
read your shell's secrets, so for timers name a file holding the key in
`DOTSYNC_COMMIT_MESSAGE_ENV_FILE`: only that one key is read from it.

What a provider sees: file names, line counts and trimmed diff excerpts, with the content of
secret-like files (keys, `.env` files, credentials, vaults) withheld and credential shapes
redacted from every excerpt before it leaves the machine. The change has already passed the
gitleaks scan. The prompt treats the diff as data, and a reply is cut to one subject line and
at most four detail lines. `<state>/commit-message.log` records each outcome, never content.

## Unattended runs: the timer, pause, and the activity guard

`./install.sh --with sync,schedules` installs `dotsync --local --scheduled` as a systemd user
timer (hourly) or a launchd agent (every 30 minutes). Each machine's timer syncs only that
machine; the fan-out happens when you run dotsync by hand.

A timer run, and a run another machine starts over ssh, never commit, rebase or push while:

- `dotsync pause` is on (`dotsync resume` ends it; `status` warns when a pause is a day old);
- a file with uncommitted changes was modified in the last `DOTSYNC_QUIET_MINUTES` (10):
  someone is mid-edit, and an automatic commit would cut the edit in half;
- a Claude Code or Codex session working in the checkout wrote its transcript in the last
  `DOTSYNC_SESSION_MINUTES` (30): a rebase would change files under the agent.

Such a run defers: it changes nothing, records `deferred` in its heartbeat, and the next clean
run syncs. A peer that defers shows as incomplete in the fan-out, not as a failure. A dotsync you
run yourself skips the guard. Zero minutes turns a check off.

## Status, heartbeats and doctor

Every run writes this machine's heartbeat (`<state>/heartbeat.json`: when, the result and the
failed phase if any, the commit, how many commits were pulled and pushed, incomplete peers) and
publishes it as `refs/dotsync/heartbeats/<machine>` on the remote: one force-pushed commit per
machine, outside every branch, so it never races another machine and never adds history. dotsync
adds the matching fetch refspec to the remote, so every fetch brings the other machines' heartbeats.
`dotsync status` lists them; a machine silent for `DOTSYNC_STALE_HOURS` (24) is marked `STALE`.
A heartbeat is self-reported: it shows that a machine stopped syncing, not that a sync did the
right thing. `DOTSYNC_HEARTBEAT_PUSH=0` keeps it local.

`dotsync doctor` checks this machine without the network: the branch and its upstream, cached
ahead/behind counts, a git operation in progress, the pause, the lock, whether the installed
dotsync is this checkout's, gitleaks and ssh, the peers file, the hooks, the config file, the
commit-message provider (whether its credential is set, never its value), and the latest
heartbeat and timing record. It prints no file contents, and exit 0 means the report was made.

## Safety properties

- **No secret is committed or pushed by dotsync.** Every automatic commit passes a gitleaks
  scan of the staged change, and every push a scan of the commits it publishes, including ones
  made by hand with hooks skipped. A finding, a scanner error, or a missing gitleaks refuses; the
  change stays in your working tree, unstaged, and the scanner's output (which holds the value)
  is never printed. Ignored files are never staged, and staged content that an ignore rule
  matches, an unmerged path, or a conflict marker refuses the commit too.
- **A push goes only where the scan looked.** dotsync pushes to the branch's upstream by name
  (`git push <remote> HEAD:<branch>`), and scans what that destination's branch lacks, as its
  own `ls-remote` reports it (all of history when it has no such branch). A branch whose pushes
  git would route elsewhere (`branch.<b>.pushRemote` or `remote.pushDefault` naming another
  remote, a `pushurl` or `pushInsteadOf` rule, a remote with several URLs) is refused, with the
  reason: such a push could publish commits the upstream already had, old secrets included,
  without a scan.
- **A conflict loses nothing.** A rebase that conflicts is aborted: your commits stay on this
  machine, unpushed, the tree clean, and the run fails at `git-rebase`. Uncommitted changes that
  conflict while being put back after the pull stay in `git stash list`.
- **Another identity is never written to**, as described under [The peers](#the-peers).
- **Nothing runs under an agent or a mid-edit** in unattended runs (the guard above).
- **Every wait is bounded.** Git network calls (`DOTSYNC_GIT_TIMEOUT`, 120 s), each peer
  (`DOTSYNC_PEER_TIMEOUT`, 180 s by hand, 600 s from a timer), its ssh connection
  (`DOTSYNC_SSH_TIMEOUT`, 5 s by hand, 15 s unattended), hooks and the commit-message call each
  have a ceiling; a timeout kills the whole process tree. On a Mac without GNU `timeout`, a
  Python fallback does the same, and a ceiling that cannot be enforced refuses to run.
- **One run at a time.** A per-user kernel lock (`${XDG_RUNTIME_DIR:-~/.local/state}/dotsync/lock`)
  serializes runs; a busy one waits `DOTSYNC_LOCK_WAIT` (5 s), then exits 75 without syncing. A
  background fan-out keeps the lock until it ends. Peers, hooks and `install.sh` never inherit
  it, so a hung peer cannot hold it once its timeout fires. The lock file or its directory, if
  another user can reach them, is refused.
- **An update to dotsync itself is safe.** The whole run is parsed before it starts, so a pull
  that replaces `scripts/dotsync` finishes on the code it started with, and the next run uses
  the new one.
- **Profiles and config are data.** `~/.df-profile` and `~/.config/dotsync/config` are parsed as
  literal `KEY=value` lines, never sourced; the config file and the hooks must be owned by you
  and writable only by you.

## Configuration

Settings come from the environment, else `~/.config/dotsync/config` (literal `KEY=value` lines,
`export` and quotes allowed, only `DOTSYNC_*` keys). A systemd drop-in
(`systemctl --user edit dotsync`) or the launchd plist can set them for the timer too.

| Setting | Default | Effect |
|---|---|---|
| `DOTFILES_DIR` | the checkout dotsync runs from, else `~/.dotfiles` | the checkout to sync |
| `DOTSYNC_PEERS_FILE` | `~/.config/dotsync/peers` | the peers file |
| `DOTSYNC_HOOKS_DIR` | `~/.config/dotsync/hooks` | the hooks root |
| `DOTSYNC_STATE_DIR` | `${XDG_STATE_HOME:-~/.local/state}/dotsync` | heartbeat, logs, pause |
| `DOTSYNC_TAILSCALE_TAG` | unset | add online tailnet machines with this tag |
| `DOTSYNC_EXCLUDE_HOSTS` | unset | machines no run contacts |
| `DOTSYNC_REMOTE_DOTSYNC` | `$HOME/.local/bin/dotsync` | where a peer's dotsync is |
| `DOTSYNC_WAIT`, `DOTSYNC_PULL_ONLY` | `0` | `1` is `--wait`, `--pull-only` |
| `DOTSYNC_QUIET_MINUTES`, `DOTSYNC_SESSION_MINUTES` | `10`, `30` | the activity guard |
| `DOTSYNC_PEER_TIMEOUT`, `DOTSYNC_SSH_TIMEOUT`, `DOTSYNC_GIT_TIMEOUT` | see above | ceilings |
| `DOTSYNC_HOOK_TIMEOUT`, `DOTSYNC_LOCK_WAIT`, `DOTSYNC_LOCK_FILE` | `120`, `5`, see above | hooks, lock |
| `DOTSYNC_INSTALL_CMD` | `./install.sh --installed` | what reruns after a pull |
| `DOTSYNC_INSTALL_TRIGGER`, `DOTSYNC_INSTALL_IGNORE` | install.sh, base/, roles/, identities/, scripts/, plugins/, systemd/, launchagents/, claude/, the shell entry points; minus tests and docs | which changed paths rerun it (extended regexes) |
| `DOTSYNC_NO_INSTALL` | `0` | `1` never reruns it |
| `DOTSYNC_HEARTBEAT_PUSH`, `DOTSYNC_NOTIFY`, `DOTSYNC_SSH_MUX` | `1` | `0` keeps heartbeats local, silences notifications, stops sharing one ssh connection for the run's git calls |
| `DOTSYNC_COMMIT_MESSAGE_*` | provider off | see [Commit messages](#commit-messages) |

`install.sh --installed` reruns the components this machine installed (each real install run
records them in `~/.local/state/dx/components`) that are safe to rerun unattended, the ones that
only link and generate files from the checkout: shell, git, tmux, claude, codex, session,
worktrees, memory, review, sync, toolbox, ghostty, vscode, brew and music-video. It never reruns
node-tools (npm ci over the network), schedules (it loads and enables jobs), github-kit (it needs
`--target` and writes into another repository) or manager (a one-time choice): they stay
recorded, the run names them, and `./install.sh --with <name>` reruns one by hand. In your own
dotfiles repository without that installer, set `DOTSYNC_INSTALL_CMD` to whatever applies your
config, or `DOTSYNC_NO_INSTALL=1`.

Logs, in the state directory: `dotsync-timing.log` (each run's phases and durations),
`last-run.log` (the latest peer or one-line run), `peer-<host>.log`, `install.log`, `fanout.log`,
`commit-message.log`.

## Troubleshooting

- **`gitleaks found a potential secret`**: run the command dotsync prints to see the finding
  (redacted). Remove the secret, or, for a false positive, add its fingerprint to the
  repository's `.gitleaksignore`.
- **`refusing to push: ... pushRemote` (or `pushDefault`, `another URL`, `several URLs`)**: this
  branch publishes somewhere other than its upstream. Make that destination the upstream
  (`git branch --set-upstream-to <remote>/<branch>`), or remove the routing; dotsync never pushes
  past a scan of a different repository.
- **`the rebase onto origin/master conflicted`**: your commits are kept. Resolve it the git way
  (`git pull --rebase`, fix, `git rebase --continue`), then rerun dotsync.
- **A peer is `unreachable (ssh rc=255)`**: `ssh -o BatchMode=yes <alias> true` must succeed
  without a prompt. The peer log in the state directory has ssh's own message.
- **A peer is `skipped (identity ...)` or `identity not verified`**: compare `DF_IDENTITY` in each
  machine's `~/.df-profile` (`install.sh --with shell --identity <name>` writes it).
- **A peer `timed out`**: its own run continues there; look at that machine's
  `dotsync-timing.log`, or raise `DOTSYNC_PEER_TIMEOUT`.
- **`busy (another dotsync holds the lock)`**: a run is in progress (often the background fan-out
  of the previous manual run: `dotsync status`). Never delete the lock file.
- **The timer never syncs**: `dotsync status` shows whether it is paused, and the heartbeat says
  `deferred` with the reason in the timer's log (an old uncommitted edit counts once it is older
  than `DOTSYNC_QUIET_MINUTES`).
- **`stale-config` from a peer**: it is on another branch, or its branch does not contain the
  commit; `dotsync doctor` on that peer shows the branch and upstream.
- Anything else: `dotsync doctor`, then `dotsync --verbose --local` for git's own output.

## Tests

```bash
bash scripts/tests/dotsync.test.sh                 # a real fleet of throwaway machines (needs gitleaks)
python3 scripts/tests/dotsync-runtime.test.py      # the pieces, and full local runs
python3 scripts/tests/dotsync-config.test.py       # config, peers, hooks, the activity guard, heartbeats
python3 scripts/tests/dotsync-doctor.test.py
python3 scripts/tests/dotsync-commit-message.test.py
bash scripts/tests/dotsync-push-retry.test.sh
bash scripts/tests/dotsync-rebase-race.test.sh
```

`dotsync.test.sh` builds a bare origin and several machines, each a throwaway HOME with a clone of
this checkout and the sync component installed by the real `install.sh`, and a fake `ssh` that
runs a peer's command in that peer's HOME. It checks that one run on box-a carries a change to
box-b and reruns its installer, that both heartbeats appear in `dotsync status`, pause and resume,
the activity guard, that a peer of another identity is never written to, that a secret-shaped
change (and a hand-made commit holding one) is never pushed, that conflicting edits stop cleanly
on both sides, that a hung peer is cut off and the lock released, and that a pull replacing
dotsync itself finishes on the old code.
