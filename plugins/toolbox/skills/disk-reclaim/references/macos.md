# macOS cleanup details

Use only the section that matches the measured candidate. The first pass is the
bounded survey in `scripts/survey.py`; these are targeted follow-ups.

## Capacity, APFS, and unexplained usage

```bash
/bin/df -kP "$HOME"
/bin/df -i "$HOME"
/bin/df -kP /System/Volumes/Data
```

`$HOME` may be on another disk. Measure the pressured mount, then compare the same
one after cleanup. APFS volumes share container capacity; the sealed system
volume, Data volume, container totals, and Storage UI use different accounting.
Do not add their totals or treat System Data as a deletable directory.

`du -skx` reports directory blocks, not exclusive ownership or predicted reclaim.
Clones and snapshots can keep extents alive; sparse-file logical size can exceed
allocated blocks. There is no fixed APFS overcount factor. `nlink=1` proves
neither orphanhood nor exclusive physical allocation. `du -A` is an apparent-size
mode on BSD, not a test for clone sharing. Don't create large test files on a
disk-full host just to demonstrate this.

When directory sizes and capacity disagree, selectively inspect:

```bash
diskutil apfs list
tmutil listlocalsnapshots /
diskutil apfs listSnapshots /System/Volumes/Data
# Can be expensive; bound it and interpret visibility/permission failures.
lsof -nP +L1
```

Time Machine local snapshots are normally managed by macOS and can count as
available space. Listing them does not establish a problem or authorize deletion.
Don't remove the sealed OS snapshot, disable backups, or thin backups as a default
cleanup step. For deleted-open files, identify the owning service; a restart
requires suitable task scope and health verification, not an automatic kill.

If other accounts explain the gap, list account/home names and visible per-user
process metadata first. Measure a named home only when the scope calls for it.
Permission denied means **inaccessible**, not empty. Do not blanket-sudo the
survey or inspect another account's private files to fill a report cell.

## Package caches and installed tools

Verify effective locations; the survey uses common defaults and environment hints,
not every possible configuration. Prefer cheap location queries such as
`npm config get cache`, `uv cache dir`, `bun pm cache`, and `pnpm store path`
when installed. Don't invoke Corepack in a way that downloads a missing manager.

| Candidate | Action after confirming idle use and authorized scope |
|---|---|
| Homebrew downloads | Use `HOMEBREW_NO_AUTO_UPDATE=1 brew cleanup -n` to inspect scope first. Native cleanup can affect old installed kegs as well as downloads; restrict to the requested cache scope. If downloads remain large, inspect that exact directory instead of assuming cleanup emptied it. |
| npm content cache | Inspect `_cacache` separately from `_npx`. Use verified native cache-clean semantics or a targeted approved contents deletion. Never clear during an npm install. |
| Bun / uv / pip caches | Use the installed tool's cache cleanup (`bun pm cache rm`, `uv cache clean`, `python3 -m pip cache purge`) only after verifying location and idle use. These are regenerable, but not zero risk during builds. |
| `_npx`, Playwright, MongoDB/Codex runtime caches | These may be executable installations for live MCP/test processes. Check argv, cwd, executable mappings, and selected open files. Age alone is insufficient. |
| Old Codex / Node tool releases | Resolve the running executable, `current` symlinks, and which installer or config manager owns them. Preserve current, running, and needed rollback versions. A cache cleanup request does not authorize removing installed runtimes. |
| pnpm stores, including temp or old `vN` directories | Verify the effective store and live installs; prefer `pnpm store prune` for its supported scope. Old versions require separate investigation. A zero hardlink count is not a safe-delete test. |

Deleting one name for a hardlinked file does **not** break its other hardlinks.
pnpm may also clone or copy files, and symlink layouts differ. Do not claim that
temporary-store deletion necessarily destroys `node_modules`, or that a store is
universally safe because it is a cache. A running store server also constrains
`pnpm store prune`; consult the installed version's behavior.

If a temporary store actually recurs, trace effective config and the invoking
wrapper. Preserve existing keys and use the installed pnpm version's supported
configuration. Never overwrite an entire config with `printf > rc`, run
`pnpm setup` to rewrite managed shell files, or assume a future npm behavior.
Change the managing config's source only if fixing the recurrence is within the task scope.

## Xcode, worktrees, and developer data

- **DerivedData**: high yield when no Xcode/Swift build, indexing, test, or preview
  uses the selected project. Prefer one idle project's directory to the whole tree.
- **Archives**: potentially irreplaceable builds and dSYMs; inventory separately,
  preserve unless the user explicitly selects them for removal.
- **Simulator devices/runtimes and DeviceSupport**: inspect `xcrun simctl list`
  and installed tooling only if Xcode exists. Booted devices and device data are
  live/persistent state. Even `simctl delete unavailable` removes device data;
  show that scope before seeking any needed approval. Prefer Xcode's supported
  runtime management over manually deleting platform directories.
- **Worktree dependencies**: inspect a selected repository/worktree after the
  cheap caches. Confirm lockfile-based reproducibility, custom/link dependencies,
  agent/tmux paths, and active watchers. Dependency deletion needs its own scope;
  keep source and `.git`. Never pipe an entire `~/code` find into deletion.
- **Whole-worktree removal** (its own scope): inspect the repository, not the
  folder around it. Agent tools nest worktrees one level down
  (`~/.codex/worktrees/<name>/<repo>`); `git status` on `<name>` fails, and with
  stderr hidden that reads as clean. Inside the worktree, require an empty
  `git status --porcelain`, confirm a detached HEAD is reachable from a branch or
  remote (`git for-each-ref --contains HEAD refs/heads refs/remotes`), then run
  `git worktree remove` from the main repository, never with `--force`. That
  status check ignores `.gitignore`d files, and `git worktree remove` deletes
  them silently (`.env`, local databases, build output). List them with
  `git status --porcelain --ignored` and include anything that is not a
  regenerable build artifact in the approved scope, or copy it out first.
- **Relocation to a roomier volume** (its own scope; nothing is deleted): move an
  idle directory to an external or overflow volume and leave a symlink at the old
  path. Check open files first (`lsof +D`, bounded). For a repository, list
  `git worktree list` before and after the move. Absolute worktree links keep
  resolving through the symlink, but relative links (`worktree.useRelativePaths`)
  resolve from the new physical location and break, as does a moved directory
  that is itself a linked worktree (`.git` is a file). Any entry that turns
  `prunable` or a worktree whose `git status` fails needs `git worktree repair`.
  Move one directory at a time and measure `df` after each.
- **Model weights / Hugging Face / Ollama**: potentially large downloads or local
  work. Inventory only by default and check running model users and ownership.
- **Agent state**: `.claude/projects`, `.codex/sessions`, memory, and worktree
  metadata are history, not disposable caches. Preserve retention settings.

Millions of small dependency files can be a poor first target: unlinking adds
watcher and metadata I/O, while APFS sharing may yield little physical space.
Use inode counts to diagnose exhaustion, not as a proxy for reclaimed bytes.

## Temp clones, browser caches, and personal files

Locate the current user's roots with `getconf DARWIN_USER_TEMP_DIR` and
`getconf DARWIN_USER_CACHE_DIR`. Inspect immediate children first; code-sign
clones may be in an adjacent `X` directory. Don't traverse all of
`/private/var/folders` as the opening move, and don't delete a whole hashed root.

A `com.google.Chrome.code_sign_clone` or Codex clone can be the executable used
by the current session. Resolve its processes and open mappings before proposing
removal. Use `lsof +D` only on a shortlisted small tree with a timeout; don't
recursively scan every dependency tree. A partial or timed-out lsof is inconclusive.
Mounted installer images and download directories may still be open; inspect
`hdiutil info` for the selected installer before detaching or deleting it.

Do not clear whole browser cache namespaces while the browser is live. Prefer
the application's own supported mechanism when that app's cleanup is authorized.
Downloads, Documents, Photos, iCloud/CloudStorage, Messages, MobileSync backups,
and Trash are user data; avoid opening/downloading cloud placeholders merely to
measure local usage. Never remove `/private/var/vm` swap files or system databases.

## Docker, Colima, Lima

First check whether tools and instances exist. An unavailable Docker daemon is
not evidence of an unused VM. Don't start or restart a VM just to inspect it.

1. Inspect `colima list`, effective `COLIMA_HOME`, `LIMA_HOME`, `DOCKER_HOST`,
   `DOCKER_CONTEXT`, and `docker context ls` as relevant. Confirm the endpoint
   and profile refer to the requested machine; the active context can be remote.
   Use an explicit confirmed context for subsequent Docker commands.
2. On that endpoint, inspect `docker --context <context> ps -a`,
   `docker --context <context> system df`, and `docker --context <context> volume ls`.
   If recovery metadata is needed, select names, IDs, and mounts with formatting;
   do not dump `docker inspect` environments.
3. Select eligible image/build-cache scope after checking active builds and
   rebuild cost. Image prune's default is narrower than `-a`; build-cache prune
   can be filtered by age. Do not silently choose blanket `-af`, `system prune`,
   or `--volumes`. Named volumes, stopped containers, and VM disks may hold data.
4. Guest cleanup and host recovery are distinct. For the confirmed running
   Colima profile, inspect `colima ssh --help` for profile selection and run
   `colima ssh -- sudo fstrim -a` (default-profile example) within authorized
   cleanup scope. This can release backing storage without stopping the VM.
   Verify host `df`; discarded-byte output and a guest RECLAIMABLE value are not
   proof of the host delta. Don't change another profile or the global context.
5. If a large disk remains under `~/.colima/_lima/_disks/<profile>/datadisk`,
   reconcile registry, configured storage roots, file handles, VM processes,
   services, and backup needs. Missing Lima registry entries do not prove it is
   disposable. Orphan disks are candidates for separately authorized recovery or
   deletion, not automatic cache cleanup. Never remove a live backing image.

Sparse images can release allocated host blocks while retaining the same logical
length. Do not promise trimming always works for every VM backend, or claim that
it never works. Never use zero-fill/compaction experiments on a nearly full host.

Primary references for version-sensitive behavior:
[Colima storage recovery](https://colima.run/docs/faq/#how-can-disk-space-be-recovered),
[Docker prune scopes](https://docs.docker.com/engine/manage-resources/pruning/),
[pnpm store](https://pnpm.io/cli/store),
[Time Machine local snapshots](https://support.apple.com/en-us/102154).
