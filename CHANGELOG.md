# Changelog

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
