# Changelog

## 0.2.0 (unreleased)

- **dotsync** (the `sync` component): keeps one dotfiles checkout in sync across your machines.
  A run commits local changes behind a gitleaks scan, pulls with a rebase that keeps your work
  on a conflict, pushes behind a second scan with retries, reruns `install.sh --installed`, then
  runs `dotsync --local` on every peer of the same identity over ssh, in parallel, each bounded
  by a timeout. Peers come from `~/.config/dotsync/peers`, an identity's list in the checkout,
  `--host`, or (opt-in) tagged tailnet machines; a peer of another identity is never written to.
  Per-machine heartbeats published as refs feed `dotsync status`; `dotsync doctor` diagnoses a
  machine read-only; `pause`/`resume` and an activity guard keep timers away from a checkout
  you or an agent are editing. Hooks (`pre-commit.d`, `post-pull.d`, `post-sync.d`), and
  described commit messages through a command, the Anthropic API or Amazon Bedrock, off by
  default. An hourly timer comes with `--with schedules`.
- `install.sh --installed` reruns the components a machine installed (each real run records them).

## 0.1.0 (2026-10-27)

The first public release.

- **Plugin marketplace** (`/plugin marketplace add coletebou/dx`) with six plugins: `session`
  (cc-park, fresh-session-handoff), `worktrees` (parallel-worktrees, contract-fanout,
  stack-branches, stack-claude), `tmux` (tmux-archive, tmux-organize), `memory` (reflect,
  dreaming, session-analyzer), `codex` (codex-subagents, codex-transcripts) and `review`
  (adversarial-review, mcp-agent-safety, fable-second-opinion).
- **Dotfiles** for zsh, git and tmux, organized by identity and role, with `install.sh`
  (per-component, `--dry-run`, backups, idempotent) and a synthetic example identity.
- **Claude Code setup:** rules, settings, hooks (context advisor, API-error recovery, session
  reflector, load-memory and more) and a statusline.
- **Agent memory:** the reflections store, the session reflector, transcript analysis and the
  dreaming sweep, behind a pluggable data boundary.
- **Session tools:** cc-handoff chains, and Claude Code and Codex resume after a tmux-resurrect
  restore.
- Test suites for the scripts, hooks and installer, and CI that runs them on Linux and macOS
  alongside ShellCheck, `zsh -n`, ruff and a secret scan of every commit.
