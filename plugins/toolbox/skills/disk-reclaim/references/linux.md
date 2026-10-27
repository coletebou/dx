# Linux and remote hosts

Keep these paths out of a Mac's opening scan. Use the same read-only survey on
the selected host when it has Python 3: piped over SSH, it needs no install there.
Remote commands must expand `$HOME`, `TMPDIR`, and machine identity **remotely**.
Don't accidentally run a local cleanup after an SSH failure.

## Establish the pressured filesystem

```bash
df -kP "$HOME" / /tmp
df -i "$HOME" /
findmnt -T "$HOME"
```

Measure a separately mounted `/var`, Docker root, or data volume if that's the
one filling up. Use `docker info --format '{{.DockerRootDir}}'` only after
confirming endpoint/context ownership. Don't assume the root disk owns every
large tree. A sandboxed or managed workspace may grant no root, sudo or Docker
access at all; work within what the account can reach.

Inventory session/process/worktree ownership as in the main skill. To keep SSH
fast, send a small coherent read-only batch, use a connection timeout, and bound
individual probes. Report unreachable hosts and incomplete probes as such.
Follow the user's selected host list; don't turn one cleanup into a fleet sweep.

## High-yield candidates

- User package/download caches: verify the effective path and concurrent package
  operations, then prefer native cleanup with the selected scope.
- APT/DNF package caches: inspect installed manager and storage first; native
  cleanup may need already-authorized privilege. Do not blindly sweep `/var/cache`.
- Journals: `journalctl --disk-usage` is cheap. Retention changes or vacuuming
  remove diagnostic history; choose size/time scope from the task and incident
  needs. Don't truncate logs of a live service or change retention as a side effect.
- Docker images/build caches: verify daemon endpoint, inventory containers and
  volumes, and select bounded cleanup. Preserve data volumes and active builds;
  `system prune --volumes` is not safe-cache shorthand.
- Dependency/worktree trees: inspect only after cheaper candidates. Protect source,
  `.git`, active agents, custom dependencies, and lockfiles; separately scope any
  dependency removal. Rebuild costs can exceed the benefit.

## When deletions do not restore capacity

1. Check whether earlier deletions went to the trash (`trash-put`, `trash`, or an `rm`
   wrapper). Trashed data stays in `~/.local/share/Trash` on the same filesystem.
   Measure exact Trash entries; purging them needs the selected removal scope.
2. Inspect deleted-open files using bounded `lsof -nP +L1`. Identify the owner and
   coordinate a permitted graceful restart; don't kill every matching process.
3. Check filesystem type, snapshots/reflinks, reserved blocks, and mount ownership.
   Even on ext4, open files and hardlinks can prevent the expected gain. Do not
   change filesystem reservations as an incidental cleanup action.
4. Check active writers. One short second sample can separate a failed cleanup
   from rapid regrowth; don't add a persistent polling job.

Moving caches to another device is relocation, not deletion. Verify destination
mount, capacity, persistence, and permissions, plus same-filesystem hardlink needs.
Do not relocate live caches or put durable projects on an ephemeral scratch volume.
Preserve the original configuration and change managed settings in their source;
only perform relocation when that scope is authorized.

## Worktree and clone sprawl

On a dev host that runs many agents, the root disk often fills from git worktrees and clones
under `~/code` (each with its own `node_modules` and build output), not from Docker. Classify
before touching anything:

```bash
bash "$SKILL/scripts/wt-classify.sh" [DIR...]              # default ~/code
ssh <host> 'bash -s' < "$SKILL/scripts/wt-classify.sh"      # nothing installed on the host
```

It prints one row per checkout directly under each DIR, and per worktree nested in a
checkout's `.claude/worktrees/`: kind, branch, dirty count, unpushed count, whether HEAD is on
a remote, days since the last commit, and `live` when a process's working directory or a tmux
pane is inside it. Never move or delete a live checkout.

- **Clean, HEAD on a remote, idle**: a candidate for removal within the selected scope. For a
  worktree, run `git worktree remove <path>` from its main repository (no `--force`; list
  `git status --porcelain --ignored` first, because removal deletes ignored files such as
  `.env` and local databases). A trash command frees nothing on the same filesystem.
- **Dirty or unpushed, idle**: relocate rather than delete, as its own scope: move it to a
  roomier volume, run `git worktree repair <newpath>` for a worktree, and leave a symlink at
  the old path so references still resolve. A cross-device move of a multi-gigabyte worktree
  takes minutes; move one at a time and measure `df` after each.
- Afterwards `git worktree prune` in the main repository drops stale entries;
  `git worktree list --porcelain` is the full inventory, including worktrees outside `~/code`.
- Cheap wins alongside: `journalctl --disk-usage` and a scoped vacuum, rotated logs under
  `/var/log`, `~/.cache/huggingface` when no process has it open, spare `rustup` toolchains and
  Node versions, stale `tmp_pack_*` under `.git/objects/pack` from interrupted fetches.
- When Docker's data root is the pressured volume, prefer `docker builder prune` and pruning
  anonymous volumes of stopped test stacks, after inventory; never `image prune -a` while a
  stack runs.
- A clean, pushed clone the user works in is still their working copy: leave it unless they
  name it.
