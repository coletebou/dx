---
name: stack-claude
description: Squash a "claude tooling" branch (CLAUDE.md, .claude/, skills, hooks) onto the CURRENT branch as one "[REMOVE-BEFORE-MR]" commit for local dev ergonomics. Variant of /stack-branches that always operates on HEAD, never creates a new branch. Use when the user says "stack claude onto this branch", "put the claude refactor on top of HEAD", "add my claude tooling as a removable commit", or invokes `/stack-claude`. Also handles `stack-claude unstack` to remove the commit before opening an MR, and `stack-claude status` to check. Advisory marker only — run unstack before pushing.
---

# stack-claude skill

## When to use

The user wants their local claude tooling present on a feature branch for dev ergonomics, but NOT in the eventual MR. Common triggers:

- "stack claude onto this branch"
- "add the claude refactor on top of my current branch"
- "put the claude tooling here as a removable commit"
- "/stack-claude"
- "unstack claude" / "remove the claude commit" / "/stack-claude unstack"
- "is claude stacked on this branch?" / "/stack-claude status"

Do NOT use for creating a new branch from the default branch with WIP stacked on it — that's `/stack-branches`. The trigger is always "onto the CURRENT branch (never creates a new branch)."

## Difference from `/stack-branches`

| Dimension | stack-branches | stack-claude |
|---|---|---|
| Target branch | Creates NEW branch | Always HEAD (current branch) |
| Base | `origin/HEAD` (the default branch) | Whatever the current branch is |
| Merge style | Octopus (preserves commit graph) | Squash (one flat commit) |
| Number of source branches | N (from profile) | 1 (the claude branch, passed via -b) |
| Commit subject | `stack(profile): branch1 + branch2` | `chore: claude tooling stack [REMOVE-BEFORE-MR]` |
| Intent | Start new work with WIP integrated | Carry tooling locally, strip before pushing |

## What the tool provides

`stack-claude`, in this plugin's `bin/`, which Claude Code puts on the Bash tool's `PATH` while the plugin is enabled (`install.sh --with worktrees` also links it into `~/.local/bin`).

```bash
stack-claude -b <branch>       # squash <branch> onto HEAD
stack-claude unstack           # reset HEAD to before the stack commit
stack-claude status            # show whether HEAD carries a [REMOVE-BEFORE-MR] commit
stack-claude help
```

Env vars:
- `STACK_CLAUDE_BRANCH` — default branch to squash (no built-in default; `-b` or this env var is required)
- `STACK_CLAUDE_REMOTE` — remote name (default `origin`)
- `STACK_CLAUDE_NO_FETCH=1` — skip the pre-merge `git fetch`

## How it works

1. Fetches `origin` (unless `STACK_CLAUDE_NO_FETCH=1`)
2. Refuses to run if the top commit already has the `[REMOVE-BEFORE-MR]` marker
3. Requires a clean working tree (untracked files are fine); it never discards a change
4. Records the pre-stack SHA in `.git/stack-claude-head` for deterministic unstack
5. `git merge --squash <branch>` stages the combined diff without creating a merge commit
6. Commits as a single conventional-commits commit: `chore: claude tooling stack [REMOVE-BEFORE-MR]`
7. `unstack` (which also needs a clean tree) resets to the recorded pre-stack SHA (or `HEAD^` if marker is at top and the recorded SHA is stale/unreachable)

## How to run it inside Claude

### Plain "/stack-claude"

If the user hasn't set `STACK_CLAUDE_BRANCH` and there's no obvious default, ASK which branch they want to stack. Do not guess an issue-numbered branch, since those rot.

```bash
cd <repo> && stack-claude -b origin/<branch>
```

### "unstack claude" / "remove before MR"

```bash
cd <repo> && stack-claude unstack
```

### "is claude stacked here?"

```bash
cd <repo> && stack-claude status
```

## Before pushing / opening a PR or MR

The marker is **advisory only** — no hook enforces it. Before `git push`, `gh pr create` or `glab mr create`, run `stack-claude unstack` to strip the commit.

Do NOT push on the user's behalf without explicit authorization. If the user asks to ship and the stack is still in place, stop and remind them to unstack first.

## Conflict handling

Squash merges can conflict. If that happens:

- Script exits with code 2 and records the pre-stack SHA anyway, so a later `unstack` still works after manual resolution.
- Fix the conflicts, stage, then commit with the marker:
  ```bash
  git commit -m "chore: claude tooling stack [REMOVE-BEFORE-MR]"
  ```
- Or abort: `git reset --merge`.

Report conflicting files back to the user. Don't auto-resolve.

## Safety rules

- **Never force-push** on the user's behalf without explicit confirmation
- Script refuses to stack onto detached HEAD, onto the claude branch itself, or when a marker commit is already at HEAD
- `.git/stack-claude-head` is per-worktree (`git rev-parse --git-dir` returns the linked worktree's private dir), so parallel stacking across worktrees doesn't collide

## Common workflows

**"Stack claude onto my current branch":**
```bash
cd ~/code/myapp && stack-claude -b origin/<the-branch-you-keep-tooling-on>
```

**"I'm about to open a PR":**
```bash
cd ~/code/myapp && stack-claude unstack
```

**"Check if claude is stacked here":**
```bash
cd ~/code/myapp && stack-claude status
```

## Installation

- As a plugin: `/plugin install worktrees@dx` (the CLI comes with it, in the plugin's `bin/`).
- From a clone: `install.sh --with worktrees` links the skill into `~/.claude/skills/` and
  `plugins/worktrees/bin/stack-claude` into `~/.local/bin/`.
