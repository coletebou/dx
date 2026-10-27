---
name: stack-branches
description: Create a fresh working branch from the default branch (origin/HEAD) with pinned WIP branches stacked on top (octopus merge). Use when the user says "stack branches", "new branch with X + Y on it", "start a branch with my WIP", "create branch with my pinned branches", or "/stack-branches". Wraps the stack-branches CLI in this plugin's bin/ — supports profiles so the user can keep multiple sets of "branches I want integrated into every new branch" (e.g. one for tooling WIP, another for a specific feature stack). Profiles persist to ~/.config/stack-branches/profiles.d/.
---

# stack-branches skill

## When to use

The user wants to create a new working branch that's based on the default branch BUT also has one or more in-flight branches merged into it. Common trigger cases:

- "create a new branch from main with my lint + claude-md changes on top"
- "start a branch for issue 1234 but stack my usual WIP on it"
- "stack branches wip-foo onto a new branch called bar"
- "make a new branch with the usual pinned stuff"
- "/stack-branches" / "run stack-branches"

Also use for managing profile configs: "add a new stack profile", "remove the wip-branches profile", "show my stacking profiles".

## What the tool provides

`stack-branches`, in this plugin's `bin/`, which Claude Code puts on the Bash tool's `PATH` while the plugin is enabled (`install.sh --with worktrees` also links it into `~/.local/bin`). It reads JSON profiles from `~/.config/stack-branches/profiles.d/<name>.json`. Each profile is a list of branches + a description.

Core commands:

```bash
stack-branches                              # fuzzy-pick profile, prompt for new-branch name
stack-branches -p <profile> -n <name>       # fully non-interactive
stack-branches -p <profile> <name>          # positional name shorthand

stack-branches profiles list
stack-branches profiles show <name>
stack-branches profiles add [<name>]        # fzf multi-select branches + prompt for name + desc
stack-branches profiles remove [<name>]     # fzf-picks if no name
stack-branches profiles edit [<name>]       # $EDITOR on the JSON
```

Env vars (rarely needed):
- `STACK_BRANCHES_BASE` — base branch (default `origin/HEAD`, the remote's default branch)
- `STACK_BRANCHES_REMOTE` — remote name (default `origin`)
- `STACK_BRANCHES_NO_FETCH=1` — skip `git fetch` (offline / already-fresh)
- `STACK_BRANCHES_CONFIG` — override config dir

## How to run it inside Claude

**Two modes**: interactive shell (use the CLI directly, fzf works) vs agent/non-TTY (fzf doesn't render — you must pass flags or fall back to conversation).

### Mode A — User is in terminal, you just pass through

If the user says `/stack-branches` with no other context, run the bare command and let fzf handle the UI:

```bash
cd ~/code/myapp && stack-branches
```

### Mode B — You're piloting it from chat (no TTY)

fzf won't render. You must pass `-p` and `-n` explicitly. Steps:

1. `stack-branches profiles list` — see what's available.
2. Ask the user which profile (or use the one they named).
3. Ask for the new branch name (or derive it from an issue number they mentioned).
4. Run `stack-branches -p <profile> -n <name>`.

### Creating a profile in non-TTY mode

`stack-branches profiles add` is fzf-driven. When running from chat:

1. Ask the user for a profile name (`[a-zA-Z0-9_-]+`).
2. Ask which branches should be in it — list candidates with `git branch -r | grep -v HEAD | head -40`.
3. Ask for an optional description.
4. Write the JSON directly (simpler than simulating fzf):

```bash
mkdir -p ~/.config/stack-branches/profiles.d
cat > ~/.config/stack-branches/profiles.d/<name>.json <<EOF
{
  "name": "<name>",
  "description": "<desc>",
  "branches": [
    "origin/branch-1",
    "origin/branch-2"
  ],
  "created": "$(date -Iseconds)"
}
EOF
```

## Conflict handling

If octopus merge fails, the script falls back to sequential merges and stops at the first conflict, leaving the branch partially merged. Clear exit paths:

- **Resolve in place**: fix the conflict, `git merge --continue`, then keep merging if more branches remain (re-run the script with `STACK_BRANCHES_NO_FETCH=1` if already fetched).
- **Abandon cleanly**: `git merge --abort && git switch - && git branch -D <new-branch-name>`.

Report the conflict details back to the user — which branch, which files. Don't try to auto-resolve unless the user explicitly asks.

## Safety rules

- **Never force-push** branches created by this skill. They're throwaway WIP stacks; losing one is cheap, breaking the default branch is not.
- **Don't stack onto anything other than the default branch without explicit user confirmation.** The base is configurable via `STACK_BRANCHES_BASE` but changing it silently is surprising.
- **Working tree must be clean.** The script enforces this (untracked files are fine) and never discards a change, but warn the user if they have uncommitted changes before running.
- **Don't run across repos.** The script operates on the current repo's `origin/HEAD` — make sure you `cd` to the right repo first.

## Common workflows

**"Start issue 123 with my usual WIP":**
```bash
cd ~/code/myapp
stack-branches -p wip-branches -n 123-my-work
```

**"Create a profile called 'tooling' with the local-dev-claude-tooling branch":**
```bash
cat > ~/.config/stack-branches/profiles.d/tooling.json <<'EOF'
{
  "name": "tooling",
  "description": "Local claude-tooling WIP",
  "branches": ["local-dev-claude-tooling"],
  "created": "2026-05-11"
}
EOF
stack-branches profiles show tooling
```

**"Which branches does my 'wip-branches' profile contain?":**
```bash
stack-branches profiles show wip-branches
```

**"Remove the old-feature profile":**
```bash
stack-branches profiles remove old-feature
```
