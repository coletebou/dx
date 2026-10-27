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
- `install.sh --installed` reruns the components a machine installed that are safe to rerun
  unattended (each real run records them; node-tools, schedules, github-kit and manager are left
  for a run by hand).
- **codesync** (also in `sync`): every repository under `~/code` committed as WIP, pulled and
  pushed with a guarded force-with-lease, then the same on your other machines; it runs only
  when you run it.
- **bootstrap**: `curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh | bash`
  installs git, clones dx and dry-runs the installer (the real install takes `--install`);
  `--provision` sets up a fresh Ubuntu or Debian server: a timed step harness with a fast path
  for baked images, system tuning, checksum-pinned toolchains, Docker with binfmt, opt-in
  instance-store NVMe, cloud-init mode, opt-in AWS CLI, Terraform and Tailscale modules, and
  overlays of ordered phase hooks for your own extras.
- **claude-backup** (a private tarball of `~/.claude`, with an optional prune) and
  **agent-skills-sync** (a guarded updater for a skills checkout), with the `claude` component.
- **Plugins:** `toolbox` (disk-reclaim, a bounded disk survey and cleanup protocol for macOS
  and Linux; shipped-but-open, open GitLab issues whose work already merged) and `music-video`
  (an original song and its music video, end to end; vendored OFL fonts).
- **GitHub repo kit** (`github-kit/`, `./install.sh --with github-kit --target DIR`): issue
  forms, a PR template and its rules, a label set with an idempotent `gh` sync, and workflows
  for PR size and proof labels, secret scans, Claude Code, stacked-PR retargets and a
  label-gated full CI lane. This repository uses it on itself.
- **Terminal and editor:** Ghostty config and terminfo, VS Code settings and recommended
  extensions, a Brewfile, pinned global Node CLIs installed from a verified lock, and Codex
  defaults, each an install component.
- **Memory:** memory-canary (capacity and integrity checks for memory homes), a pre-push gate
  for repositories that commit memory, and codex-memory-bridge (memory shared with Codex).
- **Drover:** an example overlay for its fleet manager, and `--with manager` to use it.
- **Docs:** playbooks for a fleet over Tailscale, Cloudflare in front of self-hosted services,
  and a production VPS (`docs/infra/`); how this setup runs fleets of agents
  (`docs/workflow/`).
- **Fixes:** pw starts each agent through one short typed line (macOS dropped the end of long
  typed input, so an agent could fail to start); every CI action is pinned to a release commit,
  and a failing suite's whole output is kept as an artifact.

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
