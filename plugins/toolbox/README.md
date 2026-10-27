# toolbox

Skills for the upkeep a machine full of agents needs: disk space that runs out, and a backlog
that forgets what already shipped.

| Skill | What it does | Runs |
|---|---|---|
| `disk-reclaim` | Diagnoses a full disk on a Mac or an SSH-reachable Linux host. A bounded, read-only survey (two workers, a shared time budget, per-path timeouts) measures the usual caches, runtimes and VM disks; the skill then protects anything in active use and frees space in small batches, proving each one with `df` on the same filesystem. Also classifies git worktrees and clones (dirty, unpushed, live in a tmux pane) before any of them is moved or removed. | `scripts/survey.py` (Python 3, stdlib only), `scripts/wt-classify.sh` |
| `shipped-but-open` | Lists open GitLab issues assigned to you that already have a merged MR, split into STRONG (the MR came from the issue's branch or closes it with a closing keyword) and WEAK (it only mentions the issue). Read-only: every call is a GET; closing stays a separate, approved step. | `scripts/sweep.sh` (glab, jq) |

Both scripts run on a remote host without installing anything there:
`ssh <host> 'python3 - --format json' < scripts/survey.py`, `ssh <host> 'bash -s' < scripts/wt-classify.sh`.

## Install

```text
/plugin marketplace add coletebou/dx
/plugin install toolbox@dx
```

From a clone, `./install.sh --with toolbox` links the skills into `~/.claude/skills`.

## Requirements

Python 3 for the disk survey (no packages); bash, git and optionally tmux for `wt-classify.sh`.
[glab](https://gitlab.com/gitlab-org/cli), authenticated, and jq for `shipped-but-open`. The
shell scripts use no bash 4 features, for macOS's stock bash 3.2.

## Also recommended

- [`show-me`](https://github.com/humanlayer/skills/tree/main/plugins/show-me) by Dex Horthy
  ([humanlayer/skills](https://github.com/humanlayer/skills), MIT): explains the topic at hand
  visually, with small diagrams, code-shape sketches and focused HTML pages. Install it from its
  own marketplace; it is not copied here.
