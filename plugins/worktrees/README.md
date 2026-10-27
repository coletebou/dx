# worktrees

Run agents side by side in git worktrees, and keep branches tidy while you do.

| Skill | What it does | CLI |
|---|---|---|
| `parallel-worktrees` | Spawns N Claude Code or Codex sessions, each in its own worktree and tmux window with a pre-loaded prompt, plus a merged append-only log. `pw status` flags panes waiting on a human; `pw broadcast` sends one prompt to every Claude pane, and never types into a waiting prompt. | `pw`, `pw-append` |
| `contract-fanout` | Coordinates one multi-slice issue across worktree workers: disjoint file ownership, versioned contracts posted before anyone builds, paired review at a pinned SHA, verified findings routed back, gated relays. | uses `autoreview-pair` (the `review` component) |
| `stack-branches` | Starts a branch from the default branch with a profile's WIP branches octopus-merged on top. | `stack-branches` |
| `stack-claude` | Carries local agent tooling (CLAUDE.md, `.claude/`, skills) on the current branch as one `[REMOVE-BEFORE-MR]` commit, and strips it again. | `stack-claude` |

## Install

```text
/plugin marketplace add coletebou/dx
/plugin install worktrees@dx
```

The CLIs are in this plugin's `bin/`, which Claude Code puts on the Bash tool's `PATH` while the
plugin is enabled. `pw` creates worktrees through `wt-helper` (`scripts/wt-helper` in this repo,
the primitive behind the `wt` shell function), so from a clone run `./install.sh --with worktrees`:
it links `wt-helper`, the CLIs and the skills.

## Requirements

git, bash, tmux, and `claude` or `codex` for the agents. `stack-branches` needs jq, and fzf for
its interactive pickers. Every script runs on macOS's stock bash 3.2.
