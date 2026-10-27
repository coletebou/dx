# Parallel work

Many sessions at once is where most of the speed comes from and where most of the damage comes
from: two writers on one file, a build that starves every other session on the box, a successor
that starts while its predecessor is still typing. This page is how this setup keeps the speed.

## Pick the axis

| The work | Run it as | Why |
|---|---|---|
| Read-only research, audits, drafts the coordinator picks from, independent reviewers on one diff | in-session subagents, launched in one message so they run together | one working tree, nothing to merge, no setup |
| Writers that would touch the same files, `node_modules`, `dist/`, a Compose project or migrations | one git worktree per writer ([`parallel-worktrees`](../../plugins/worktrees/skills/parallel-worktrees/SKILL.md)) | hard isolation: own branch, own files, own build state |
| Worktrees whose slices are big enough to split again | both: each worktree session runs its own subagents | parallel inside each lane |
| One issue split into slices that depend on each other's interfaces | [`contract-fanout`](../../plugins/worktrees/skills/contract-fanout/SKILL.md) | contracts first, then workers, with review and relay |

Cap routine fan-out at about three children per coordinator, so the coordinator stays on the
critical path and available to the owner. Give each child a fresh, complete brief: scope, the
safety rules, the output you want back, and "do the work yourself, do not delegate it again".

## Worktrees: `wt` and `pw`

- **One worktree, by hand:** `wt <branch>` (a shell function in `base/aliases.sh` over
  `scripts/wt-helper`) creates or attaches a worktree, nested inside the repo at
  `<repo>/.claude/worktrees/<branch>` (git-ignored). `wt-helper --help` lists the layout levers
  (`WT_BASE_DIR`, `WT_LAYOUT`, the repo's `worktree.baseDirectory`).
- **N sessions at once:** `pw launch <manifest.tsv>`, one row per lane
  (`tag<TAB>branch<TAB>@/abs/path/prompt.md`). Each lane gets a worktree, a tmux window and a
  session with its prompt; window 0 follows a merged log that every lane appends its summary to
  (each prompt ends with the skill's footer, which `pw validate <manifest>` checks for). `--test`
  uses sandboxed names.
- **Watching them:** `pw status <session>` names each pane's state and exits 2 when one waits on
  a permission prompt or a workflow confirmation; nothing proceeds until a human answers those.
  `pw log` follows the merged log. `pw teardown <manifest>` removes only what that manifest made.
- **Compose:** each worktree needs its own `COMPOSE_PROJECT_NAME` (`pw` writes it to `.envrc` and
  the window), or `docker compose up` in the worktree attaches to the main checkout's project and
  runs the main checkout's code.

## Disjoint ownership and contracts

- **Every file has one owner.** Name each lane's files or directories in its brief. A shared file
  gets one owner; the others ask the coordinator for changes, and the coordinator routes them.
- **Interfaces are agreed before anyone builds.** When one lane consumes what another produces (an
  API and the client that calls it), post a versioned contract (`Contract <name> v1.0`: shapes,
  errors, flags, which lane owns each side) where both owners can accept it. A change is a new
  version posted next to the old one with what changed and why; an accepted version is never
  edited. Briefs name the exact version.
- **Workers merge the default branch into theirs; they do not rebase a published branch.** A
  rewrite of a published branch is announced first, backed up to a ref, pushed with
  `--force-with-lease`, and re-gated.

## Load discipline

A dozen sessions on one machine share its CPU, memory and disk. Before anything heavy (a full test
suite, a type check, a build, a container start, an install):

- **Check the load:** `uptime`, and the memory headroom. On an oversubscribed box, send the job to
  CI or a runner queue, or wait.
- **Check for the same job already running, by exact process name** (`pgrep -x <name>`).
  `pgrep -f "<pattern>"` also matches the command line of every peer session's own polling loop,
  so two careful sessions end up waiting on each other forever.
- **A failure under load is no result.** A test that times out or fails only in a slow run gets
  rerun alone before anyone investigates it. A job the harness stopped for memory is reported, not
  restarted into the same pressure.
- **Budget disk** before a fan-out: each worktree with its dependencies installed can take
  gigabytes. Skip the install for lanes that only write docs.

## Shared trees

Some trees are shared by design (a dotfiles checkout, a memory directory that every session
writes to). In one:

- **Never amend, rebase or reset.** Between two of your commands a peer may commit; your amend
  then rewrites the peer's commit. Commit only your own files (`git add <files> && git commit`), and
  when an operation depends on HEAD being yours, check `git log -1` in the same command.
- **Re-read a file in the same step that edits it**, and treat an edit whose anchor is gone as
  "someone else moved it", not as a bug to force through.
- **Judge each step by its effect, not its exit status.** In a chained command, a heredoc-fed
  interpreter that fails does not always stop the chain; a `git commit` can exit non-zero on a stale
  lock after the commit landed. Check that HEAD moved, that the inserted text is there, that a
  reply returned an id before resolving the thread it answers.
- **Validate before you overwrite.** `jq ... > out && mv out config.json` replaces a config with an
  empty file the day jq exits 0 with nothing. Check the size (or parse the result) between the
  transform and the move.

## Taking over

A handoff file, a pasted transcript or a brief means the work *could* continue elsewhere, not that
its author stopped. Before acting on one:

1. Check whether the original session is alive: its transcript's modification time, the session
   list, a message to it.
2. If it is alive, agree a split with it in one exchange and write it in a claims file
   (responsibility, owner, state). One writer per shared directory.
3. Gate the irreversible step on the peer's explicit message, not on its going idle.

## Watching other sessions

- **Read the transcript, not the pane.** A terminal UI collapses tool output; a pane that looks
  idle may be mid-command. Every session writes its full transcript (Claude Code's are under
  `~/.claude/projects/`; the [`codex-transcripts`](../../plugins/codex/skills/codex-transcripts/SKILL.md)
  skill finds and reads Codex's), or just ask the session.
- **Never type into a pane that waits on a human.** A permission or confirmation prompt has an
  option preselected, and the Enter that ends a broadcast approves it. `pw broadcast` skips those
  panes on purpose.
- **After an unattended launch, look again a few minutes later.** A session can sit at a
  confirmation prompt for an hour with no error.

## Moving a lane to another machine

When a machine runs out of room, a lane can move. Make its state legible; do not clean it up:

- Start nothing new; let running agents finish their current edit and stop.
- Confirm nothing writes to the tree any more.
- Write a handoff file at the worktree root (untracked): branch, `git rev-parse HEAD`,
  `git status --short --branch`, untracked directories, scratch paths **outside** the repo (these do
  not move with the worktree), running jobs and their ids, pending items in order, hazards.
- Reply that it is ready and stop. Do not delete, transfer or relaunch anything yourself; whoever
  moves it starts exactly one successor.
