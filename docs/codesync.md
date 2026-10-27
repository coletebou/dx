# codesync: every repository, every machine

`codesync` keeps every Git repository under `~/code` in step with its origin, on this machine
and then on your other machines, uncommitted work included: what you were in the middle of on
one machine is waiting on the next. One run:

1. goes through each repository under `~/code`: commits uncommitted work as a temporary WIP
   commit, pulls what origin has, pushes, and turns its own WIP commit back into uncommitted
   changes;
2. then runs `codesync --local --peer` on each of your other machines over ssh, one after
   another, each bounded by a timeout. A machine whose identity differs from this one's is never
   touched;
3. finally runs `dotsync --local` when [dotsync](dotsync.md) is installed (on a peer,
   `dotsync --local --peer`, so that machine's pause and editing guard hold).

Nothing is committed or pushed without a [gitleaks](https://github.com/gitleaks/gitleaks) scan:
not uncommitted files, not commits you made by hand. It only syncs clones that already exist (it
never clones), only on a branch, and only when the clone's `origin` matches
`CODESYNC_REMOTE_MATCH` (default: `github\.com`). It works on macOS and Linux with bash 3.2 or
newer, git, gitleaks, awk and OpenSSH. Nothing schedules it: it runs when you run it.

## Setup for two machines

Say `box-a` and `box-b` are ssh aliases that reach your two machines (`~/.ssh/config`, or
[Tailscale](infra/tailscale.md) names), and both have the same repositories cloned under `~/code`.

1. **Install on each machine.** `shell` writes `~/.df-profile`, which names the machine and its
   identity; `sync` links `codesync` into `~/.local/bin`.

   ```bash
   ~/.dotfiles/install.sh --with shell,git,sync --identity example   # same identity on both
   ```

   Install gitleaks too (`brew install gitleaks`, or a release binary): without it codesync
   still pulls, but commits and pushes nothing.

2. **Check that each reaches the other without a prompt.** codesync uses
   `ssh -o BatchMode=yes`, so a key (or Tailscale SSH) must work non-interactively, and the
   other machine's `codesync` must be on its PATH (or in `~/.local/bin`, which codesync adds):

   ```bash
   ssh -o BatchMode=yes box-b 'PATH="$PATH:$HOME/.local/bin" command -v codesync'   # on box-a
   ```

3. **List the peers.** On box-a, `~/.config/codesync/peers` holds `box-b`; on box-b it holds
   `box-a`. If you use dotsync, its `~/.config/dotsync/peers` already serves (below).
   `codesync --peers` shows what it found.

4. **Try it.** `codesync --dry-run` says what it would do and changes nothing. Then
   `codesync` on box-a: box-a's work goes up, and box-b's own codesync pulls it.

## Everyday commands

```bash
codesync                  # this machine's repositories, then each peer's
codesync --local          # this machine only (also what a peer runs)
codesync --host box-b     # this machine, then box-b only (repeatable; box-b must be reached)
codesync --dry-run        # what it would do; changes nothing, contacts no peer
codesync --verbose        # every step, and each peer's whole output
codesync --peers          # the peers it would contact, where each comes from, which it skips
```

On a single machine, `codesync --local` is the whole tool: every repository committed, pulled
and pushed, your work in progress included, with nothing else to set up.

## What happens to one repository

For a clone on a branch whose origin matches, and with no merge, rebase, cherry-pick, revert,
`git am` or bisect in progress and no unmerged path (that one is left alone and reported: staging
would mark its conflicts resolved, markers and all):

1. **Uncommitted changes become a WIP commit.** Staged, unstaged and untracked files (minus what
   `.gitignore` excludes) are staged and scanned with `gitleaks git --pre-commit --staged`. A
   finding, a scanner error or no gitleaks at all unstages them again and stops there. Otherwise
   they go into one commit, subject `WIP: codesync <date> <time>`, with a
   `Codesync-Machine: <machine>` trailer naming the machine that made it (`DF_MACHINE` from
   `~/.df-profile`, else the short hostname). The scan is codesync's own, so it holds where a
   repository's own hooks (husky, lefthook) would skip yours.
2. **What origin has and it lacks is pulled**: one fetch, then a rebase onto exactly the tip
   that fetch brought, so its commits go on top.
3. **It pushes**, unless it is level with that tip: first `gitleaks git` scans every commit the
   push would publish (one you made by hand with hooks skipped too), then a real commit is pushed
   normally and a WIP commit is force-pushed under the rules below.
4. **Its own WIP commit is unwrapped again**: a soft reset puts the changes back in the working
   tree, uncommitted (staged versus unstaged is not kept). The commit stays on origin.

So the remote always holds your latest work, and your working tree looks as you left it.

### When another machine pulls a WIP commit

A machine with nothing uncommitted that pulls another machine's WIP commit turns it into a real
commit, `sync: apply codesync changes` (the same files on the same parent), and pushes that. The
machine that made the WIP finds, on its next run, that its uncommitted changes are already in
that commit, and ends with a clean tree. In other words: **work in progress becomes a commit once
a second machine picks it up.** Rename or squash those commits before you share a branch, if you
care how its history reads.

Two more cases:

- **A second run before anyone pulled.** The remote's WIP is this machine's own (its trailer
  says so) and nothing was built on it, so the new WIP, made from the same working tree, replaces
  it.
- **Both machines have uncommitted work in the same repository.** The second machine integrates
  the first's WIP when its own changes are only new files, and stacks its own WIP on top (the
  first WIP then stays in the history). When its changes touch files git already tracks, it
  refuses: `WIP-vs-WIP rebase conflicted; refusing to drop remote WIP`. Its changes stay
  uncommitted; see [Troubleshooting](#troubleshooting).

Work you discard on a machine after codesync pushed it as a WIP comes back on that machine's next
run (as `sync: apply codesync changes`): codesync never drops a WIP from the remote except to
replace it with a newer one from the same machine. Reset it by hand if you meant to throw it away.

### The force-push rules

- Only a WIP commit, or a history rebased over a remote WIP, is ever force-pushed.
- Only when the remote's base is in ours: the remote's tip, or its parent when the tip is itself
  a WIP, must be our base or an ancestor of it. Otherwise: `Remote has commits you don't have!`,
  and nothing is pushed.
- Always with a lease on the exact tip codesync fetched and checked,
  `--force-with-lease=refs/heads/<branch>:<sha>`, so a commit another machine pushed after that
  fetch makes the push fail instead of disappearing. (A bare `--force-with-lease` would compare
  with `origin/<branch>` at push time, which an editor's background fetch can have moved to that
  very commit.)
- A WIP on a branch with a single commit is never force-pushed (there is no base to check).
- Before it force-pushes, a tag `codesync-backup-<time>` marks the remote tip it replaces; every
  unwrap first tags the WIP as `codesync-unwrap-<time>`. After a repository syncs, it keeps the
  newest five tags of each kind and any younger than seven days, and deletes the rest. The tags
  stay local (they are never pushed).

### A repository it cannot sync

The run goes on to the next repository, reports the failure, and exits 1. The repository is left
with your changes uncommitted, never in the middle of a rebase:

| What happened | What codesync does |
|---|---|
| `left alone: a merge is in progress` (or a rebase, cherry-pick, revert, `git am`, bisect, or unmerged paths) | nothing at all: finish or abort it, then rerun |
| `fetch failed` | nothing (network, credentials, or a branch that is not on origin yet) |
| `gitleaks found a potential secret`, or `gitleaks is required` | unstages again, commits nothing; the files stay as they were |
| the WIP commit was refused (a pre-commit hook, an index lock) | unstages again; the changes stay as they were |
| `pull failed; resolve it by hand` (a conflict) | aborts the rebase and unwraps its WIP: your files hold your version, no conflict markers |
| `refusing to push` (the outgoing scan) | pushes nothing and unwraps its WIP |
| `push failed` (the lease, a hook, a rejection) | unwraps its WIP; anything it pulled stays |

Credentials a URL carries (a user and token before the `@` of an `https://` remote) never reach
its output: in its own lines and in git's, they read `https://***@host/...`.

### Which directories count

- every directory directly under `CODE_DIR` (default `~/code`);
- with `CODESYNC_NESTED_DIRS=oss`, also every directory under `~/code/oss` (a `:`-separated
  list, relative to `CODE_DIR` or absolute);
- with `CODESYNC_EXTRA_DIRS=~/notes:~/work/site`, those repositories too.

A directory is skipped (and counted as skipped) when it is not a clone (a `.git` directory: a
linked worktree or a submodule is skipped), when its `origin` does not match
`CODESYNC_REMOTE_MATCH`, or when HEAD is detached. `--verbose` names each skip and why.

## The peers

Peers come from configuration, never from a built-in list. The first of these that applies is
the whole list:

1. `--host NAME` (repeatable): just those;
2. `CODESYNC_PEERS_FILE`, when set;
3. `~/.config/codesync/peers`, when it exists;
4. dotsync's lists: `~/.config/dotsync/peers` (`DOTSYNC_PEERS_FILE` moves it) plus
   `~/.dotfiles/identities/<identity>/dotsync-peers`. So with [dotsync](dotsync.md) set up,
   codesync needs no list of its own; a `~/.config/codesync/peers` overrides it, for example to
   leave a machine out.

The format is dotsync's: one ssh alias per line, optionally followed by the identity that machine
runs (and its role, which codesync ignores); `-` means unknown and `#` starts a comment.

```text
# ~/.config/codesync/peers
box-b                 # a laptop
box-c   example       # listed identity: a pre-filter only
```

A name must look like an ssh alias (letters, digits, `.`, `_`, `-`; not starting with `-`), so
nothing in the file can become an ssh option. The file, like the config file, must be yours and
writable only by you, or codesync ignores it. Names are deduplicated without regard to case.

### Identity: a peer of another identity is never written to

`~/.df-profile` names each machine's identity (`DF_IDENTITY`, written by `install.sh`). codesync:

- reads this machine's from `~/.df-profile` (an ambient `DF_IDENTITY` never overrides an
  installed profile), and with none known syncs no peer at all;
- skips a peer whose listed identity differs, without connecting;
- sends each peer a small `sh` script, on standard input, that reads the peer's own
  `~/.df-profile` and refuses (exit 77) unless it names the same identity. Only then does it run
  the peer's codesync. Profiles are read as literal `KEY=value` lines, never sourced: a line that
  would run a command reads as no identity, and the peer refuses.

A peer that is this machine (its alias is this machine's name, or its `DF_MACHINE` is this one's)
is skipped.

### What runs on a peer

```text
ssh -o ConnectTimeout=$CODESYNC_SSH_TIMEOUT -o BatchMode=yes <peer> sh -s   < the script
```

The script checks the identity, then runs `codesync --local --peer` from the peer's PATH, with
`~/.local/bin` (where `install.sh` links it) added at the end; `CODESYNC_REMOTE_CMD` names another
command. The peer reads its own `~/.config/codesync/config`: nothing of this machine's
environment travels. `--local` means the peer syncs its repositories and stops; it never fans out
further. `--peer` says nobody is at that machine: its dotsync step runs as `dotsync --local
--peer`, so while that machine is paused (`dotsync pause`) or someone (or an agent) is editing its
dotfiles, its dotsync defers instead of committing, rebasing and pushing.

Each peer is cut off after `CODESYNC_PEER_TIMEOUT` seconds (default 300), with GNU `timeout` (or
`gtimeout`) when there is one and a built-in watchdog otherwise, and the run goes on to the next.

| Outcome | Shown as | Fails the run? |
|---|---|---|
| synced | `box-b: synced` | no |
| another identity | `box-b: refused: it runs another identity; nothing there was touched` | only if named with `--host` |
| this machine | `box-b: skipped (it is this machine)` | no |
| unreachable (ssh exit 255) | `box-b: unreachable` | only if named with `--host` (a laptop asleep is normal) |
| too slow | `box-b: timed out after 300s; cut off` | yes |
| no codesync there | `box-b: codesync is not installed there` | yes |
| a repository failed there | `box-b: sync incomplete (codesync exited 1 there)` | yes |

## Configuration

Settings come from the environment, else from `~/.config/codesync/config` (`CODESYNC_CONFIG`
moves it): literal `KEY=value` lines, optionally `export `-prefixed and quoted, `~/` meaning your
home. The file is never sourced, an unknown key is named in a warning, and a file anyone else can
write is ignored.

| Setting | Default | What |
|---|---|---|
| `CODE_DIR` | `~/code` | where the repositories are |
| `CODESYNC_NESTED_DIRS` | none | directories under `CODE_DIR` whose subdirectories are repositories too, `:`-separated |
| `CODESYNC_EXTRA_DIRS` | none | more repositories anywhere, `:`-separated |
| `CODESYNC_REMOTE_MATCH` | `github\.com` | the extended regex an `origin` URL must match (`github\.com\|gitlab\.com`; tests point it at local bare repositories) |
| `CODESYNC_PEERS_FILE` | see [The peers](#the-peers) | the peers file |
| `CODESYNC_PEER_TIMEOUT` | `300` | seconds one peer may take |
| `CODESYNC_SSH_TIMEOUT` | `5` | ssh `ConnectTimeout`, in seconds |
| `CODESYNC_REMOTE_CMD` | `codesync` | the command a peer runs (a name or a path; no spaces or quotes) |
| `CODESYNC_DOTSYNC` | `auto` | `auto` runs `~/.local/bin/dotsync --local` at the end when it exists (`--local --peer` on a peer); `0` never |

```bash
# ~/.config/codesync/config
CODESYNC_NESTED_DIRS=oss
CODESYNC_EXTRA_DIRS=~/notes
CODESYNC_REMOTE_MATCH='github\.com|codeberg\.org'
```

Exit status: 0 everything synced or was skipped; 1 a repository, a peer or the dotsync step did
not sync; 2 a usage or settings error.

## Troubleshooting

- **`fetch failed`**: try `git fetch origin <branch>` in that repository. A branch that is not on
  origin yet fails here: push it once by hand (`git push -u origin <branch>`).
- **`pull failed; resolve it by hand`**: origin has commits that conflict with your uncommitted
  work. Your files are as you left them. Commit (or stash), `git pull --rebase`, resolve, rerun.
- **`WIP-vs-WIP rebase conflicted; refusing to drop remote WIP`**: two machines both had
  uncommitted changes in that repository. On this one: `git stash`, `codesync --local` (it pulls
  the other machine's work as a commit), `git stash pop`, resolve if needed, rerun.
- **`left alone: a merge is in progress`** (or another operation, or unmerged paths): finish it
  (`git merge --continue`, `git rebase --continue`, ...) or abort it, then rerun.
- **`gitleaks found a potential secret`**: something uncommitted, untracked files included, looks
  like a credential. The files are as they were, unstaged. Find it with the command codesync
  prints, then move the file out, put it in `.gitignore` (`.env`, keys: anything that must never
  leave the machine), or record a false positive in `.gitleaksignore`. The secret itself is never
  printed.
- **`gitleaks is required`**: install gitleaks; until then codesync pulls but commits and pushes
  nothing.
- **`refusing to push`**: a commit on the branch that is not on origin yet (one you made by hand,
  say) looks like it holds a credential. Rewrite it, then rerun.
- **`the WIP commit was refused (a hook?)`**: a pre-commit hook said no; its reason follows.
- **`push failed`** after `stale info`: another machine pushed between this one's fetch and push.
  Rerun.
- **`Remote has commits you don't have!`**: pull by hand (`git pull --rebase`), then rerun.
- **`box-b: unreachable`**: `ssh -o BatchMode=yes box-b true` must succeed without a prompt.
- **`box-b: timed out after 300s; cut off`**: raise `CODESYNC_PEER_TIMEOUT`. A peer cut off in
  the middle keeps its own WIP commit; its next run pushes and unwraps it.
- **`box-b: refused: it runs another identity`**: by design. Check `DF_IDENTITY` in each
  machine's `~/.df-profile` (`codesync --peers` shows this machine's).
- **A commit you do not want**: every force-push and unwrap left a `codesync-backup-*` or
  `codesync-unwrap-*` tag in that clone (`git tag --list 'codesync-*'`); `git reset` to one.

## Tests

```bash
bash scripts/tests/codesync.test.sh
```

Every machine in it is a throwaway HOME with clones of local bare repositories, reached through a
fake `ssh` that maps `box-b` (and three more aliases) to "run this with HOME=<that machine's
home>" and refuses any other name. It proves the two-machine round trip, the second run, the
identity refusal, the guarded force-push (a racing push, the same race after a background fetch,
and the ancestry check), a dirty peer, a conflict and a refused commit left with the changes
uncommitted, unfinished merges, cherry-picks, `git am`, bisects and unmerged paths left alone,
the secret scan (an untracked secret, a hand-made commit, no gitleaks), redacted URLs, a hung
peer cut off at the timeout, the peers file, the profile parser, the config file, dry runs, and
the dotsync step, including a paused peer whose real dotsync defers. It needs gitleaks, and skips
without it.
