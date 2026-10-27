---
name: disk-reclaim
description: Diagnose disk usage and reclaim space on a Mac or an SSH-reachable Linux dev host. Use for disk-full errors, storage audits, or cleanup requests. Starts with a bounded read-only survey, protects active development and services, and verifies actual filesystem capacity gained.
---

# Disk reclaim

Get useful candidates quickly, free real capacity, and keep the machine usable.
The common case is a workstation with live agents, browsers, and development
work. Start locally unless the user names another host, and never clean a
machine other than the one the user means.

## Start here

1. Read `CLAUDE_MACHINE` (or `DF_MACHINE`) to identify the machine when it is
   set; use `uname -s` for OS detection, not host identity. Confirm a named SSH
   target with a small probe using `BatchMode=yes` and `ConnectTimeout=5`.
2. Distinguish **audit** ("what's using space") from **cleanup** ("free space",
   "remove safe caches"). An audit stays read-only. Carry forward explicit
   cleanup approvals, including numbered candidates; do not ask again for the
   same scope. Improving this skill does not authorize cleaning the host.
3. Run the bundled survey. Set `SKILL` to this skill's directory first
   (`SKILL=${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/disk-reclaim}`; a Codex
   install lives under `~/.codex/skills/`):

   ```bash
   python3 "$SKILL/scripts/survey.py"
   # Structured output for a candidate ledger:
   python3 "$SKILL/scripts/survey.py" --format json
   # On an SSH host, with nothing installed there (the survey is one stdlib file):
   ssh -o BatchMode=yes -o ConnectTimeout=5 <host> 'python3 - --format json' < "$SKILL/scripts/survey.py"
   ```

   Choose one format, not two duplicate scans. The helper uses Python's standard
   library, performs no cleanup or configuration writes, and requires no install.
   It samples `df`, then measures likely caches, runtimes, and VM storage with
   **two workers, a 20-second command budget, and a 3-second per-path timeout**.
   Timeouts, permission errors, and leaf symlinks remain visible as unknowns;
   resolved destinations reveal parent symlinks. Nested targets defer the parent
   scan so the same tree is not walked twice.
   It does **not** decide that a path is safe or inspect running processes.

   If Python is unavailable, don't install tooling onto a full disk: use `df`
   and sequential, narrowly targeted native `du -skx` commands instead. On macOS
   pin `/bin/df` and `/usr/bin/du` to avoid Homebrew GNU/BSD flag surprises.
4. Return the first useful findings immediately, then investigate only the
   largest promising candidates. Retry a specific unresolved path with:

   ```bash
   python3 "$SKILL/scripts/survey.py" --path "$HOME/Library/Caches/Homebrew/downloads" --timeout 10 --budget 12
   ```

`--path` is repeatable and **replaces** the default list. A timed-out directory
is unmeasured, not empty. The survey is a shortlist, not a whole-disk inventory;
custom package-cache locations and other users require targeted follow-up.
OS-level uninterruptible I/O can exceed a subprocess timeout; avoid disconnected
network mounts and do not promise a hard real-time deadline.

## Choose the next work by evidence

| Situation | Next move |
|---|---|
| Under ~2 GiB available, or a write/install fails | Establish capacity/inodes, inspect one promising authorized cache, reclaim a small batch, then continue. Avoid large scans, synthetic clone experiments, downloads, and new installations. |
| Ordinary cleanup | Favor large idle download caches with low rebuild cost. A practical working target on a busy Mac is 15–20 GiB free unless the user gives another target; this does not expand deletion scope. |
| "What's using everything?" | Expand by category: developer trees, app support, system/temp storage, personal files, and other users. Scan one selected subtree at a time, not every root concurrently. |
| `du` falls but free capacity barely rises | Investigate shared extents/snapshots, Trash wrappers, deleted-open files, VM discard, or concurrent writers. Don't respond by deleting more source trees. |
| Free space falls while nothing is being written (macOS) | Check `sysctl vm.swapusage`. Swap files share the APFS container, grow under memory pressure from heavy jobs (renders, encodes, many agents), and `du` cannot see them. They shrink only as pressure falls: lower concurrency or quit idle heavy apps, and hold new heavy jobs until free space recovers. |

No initial recursive `du` of `/`, every home directory, `$HOME`, or all of `~/code`.
Avoid nested/overlapping scans and don't sum their sizes. Use at most two disk
walkers; lower that to one if the Mac is busy. Run the baseline before scanners
or cleanup start, so their load is not mistaken for the original problem.

## Protect active work before selecting deletions

Take one process/session snapshot, then resolve paths only for relevant PIDs:

```bash
ps -axo pid,ppid,user,comm
tmux list-panes -a -F '#{session_name}:#{window_index} #{pane_current_command} #{pane_current_path}'
# Substitute the shortlisted PIDs; bound this command using the available runner.
lsof -nP -a -p <pid1,pid2> -d cwd,txt -F pfn
```

- Inspect arguments locally when needed to locate a script/MCP package; avoid
  copying raw arguments, environments, or full container inspections into reports.
- Combine cwd/executable/open-file evidence with the relevant repository's
  `git worktree list --porcelain`. A cwd check alone misses script paths and
  executable mappings. A missing process match does not prove a path unused.
- Protect active `_npx`/Playwright/Context7 installs, browser code-sign clones,
  current and running tool versions, source trees, agent transcripts/memory,
  credentials, Docker volumes, live VM disks, and other users' data.
- Treat cache cleanup during an install, build, update, or model load as unsafe.
  Re-check selected paths immediately before each cleanup batch. If work starts
  using them, skip them; don't kill a process or unload a supervisor to make space.
- Normalize selected paths and check ancestor/descendant relationships against
  protected paths. Use literal paths/argument arrays, not regex exclude lists or
  whitespace-delimited delete manifests. A symlink, permission gap, or unresolved
  owner is a reason to inspect further, not permission to delete.

## Execute small, attributable batches

Use [macOS details](references/macos.md) for a Mac: APFS, Xcode, temp clones,
package stores, and Colima. Use [Linux/SSH details](references/linux.md) only for
those hosts, including worktree and clone sprawl (`scripts/wt-classify.sh`). Read
the relevant section, not every reference by default.

Keep a compact ledger: **target → measured size → active-use evidence → action
and approval scope → actual free-space delta**. Rank by likely physical gain,
confidence it is disposable, and reinstall/I/O cost; size alone is insufficient.

Prefer package-native cleanup with a verified cache location and installed-version
semantics. For a targeted deletion, show the exact contents/path scope first and
use the environment's approved mechanism. Never replace a rejected deletion with
another tool or syntax to bypass a safety control. Moving to same-volume Trash
does not reclaim capacity; emptying Trash is a separate, explicitly scoped action.

Existing authorization for safe caches covers verified idle, regenerable caches.
It does not cover personal files, application uninstalls, source/worktree removal,
backup/snapshot removal, model weights, tool/runtime removal, other-user data,
or VM/container volumes. Present concrete candidates and consequences if such
additional scope is needed. Honor prior approval instead of inserting new gates.
Relocating idle directories to a roomier volume behind a symlink is often the
largest non-destructive lever; it needs the same explicit scope as removal.
Capture minimal recovery information for approved data removal; metadata alone
is not a backup. Never dump container environment variables into recovery notes.

## Prove the result and stop at the right point

- Compare `df -kP` on the **same target filesystem** immediately before and after
  each meaningful batch. On macOS inspect `$HOME` and, when appropriate,
  `/System/Volumes/Data`; on Linux inspect the mount actually under pressure.
- Use `du` as directory-usage evidence, **not predicted reclaim**. APFS clones,
  hardlinks, snapshots, compression, and sparse files prevent a reliable conversion
  factor. Docker's reclaimable figure concerns the guest, not host APFS capacity.
- If a writer is active or a result is surprising, take one short follow-up sample
  after scanners exit. No mandatory three-sample sleep loop or continuous polling.
  Attribute busy-host deltas as observed net changes, not exact deletion savings.
- Verify the protected processes/services still work using their existing health
  checks. If the original install failed, retry it only within the user's scope
  and check remaining capacity afterward.
- Stop once the requested headroom is achieved, the audit is answered, or the
  remaining candidates need new scope. If capacity is still critical, name the
  next concrete decision; don't quietly widen cleanup.

Report: **available before → after (observed net gain)**, a short action ledger,
the significant active/data-heavy candidates retained, and any incomplete probes.
Do not claim timeouts are empty, deletion of apparent bytes is physical reclaim,
or a remote host was cleaned when its probe failed. No unsolicited fleet sweep.
Fix a proven recurring leak at its owning configuration only within the task's
scope; a setting that a config manager owns is fixed in its source, preserving
other keys.
