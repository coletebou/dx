# ~/.zshenv — universal; loaded for all shells (login + interactive + scripts)

# Machine identity + profile selection — written by install.sh
[[ -f ~/.df-profile ]] && source ~/.df-profile

# Machine identity must exist in every zsh mode, including non-interactive SSH.
# The fallback covers a shell started before install.sh wrote ~/.df-profile.
if [[ -z "${DF_MACHINE:-}" && -r "$HOME/.dotfiles/base/machine-id.sh" ]]; then
    source "$HOME/.dotfiles/base/machine-id.sh"
    export DF_MACHINE="$(df_machine_id)"
fi
if [[ -n "${DF_MACHINE:-}" ]]; then
    export CLAUDE_MACHINE="$DF_MACHINE"
fi
# Secrets for every zsh, not only interactive ones. Codex and other tools run
# commands with `zsh -lc` / `zsh -c`, which skip zshrc, so a `claude` launched
# from them would otherwise miss its keys; Codex also strips *TOKEN* variables
# from its tool shells, and this puts them back for every command it runs.
# ~/.env_secrets is yours, never committed: exports only, and silent (any output
# breaks scp, rsync and sftp).
[[ -r "$HOME/.env_secrets" ]] && source "$HOME/.env_secrets"
# Tag Claude Code's OTel spans, events and metrics with the machine and the
# person, for whatever collector you point OTEL_EXPORTER_OTLP_ENDPOINT at. A
# settings `env` block cannot expand variables, so this lives here.
if [[ -n "${CLAUDE_MACHINE:-}" && -z "${OTEL_RESOURCE_ATTRIBUTES:-}" ]]; then
    export OTEL_RESOURCE_ATTRIBUTES="host.name=${CLAUDE_MACHINE},enduser.id=${USER:-unknown}"
fi

# Codex Desktop's remote-SSH bootstrap starts an app-server by prepending
# CODEX_INSTALL_DIR to PATH. SSH login shells do not inherit the GUI launchd
# environment that points at codex-high-fd, so its fallback would otherwise
# select ~/.local/bin/codex (the app-managed standalone, which can lag the
# managed CLI). Keep remote app-servers on the same atomic Node-tools
# install as the foreground CLI while preserving an explicit caller override.
if [[ -x "$HOME/.npm-global/bin/codex" ]]; then
    export CODEX_INSTALL_DIR="${CODEX_INSTALL_DIR:-$HOME/.npm-global/bin}"
fi

# Raise the per-process open-file SOFT limit for every shell mode. macOS's
# launchd default is only 256 (`launchctl limit maxfiles`), and that ceiling
# flows straight down sshd → zsh → tmux → codex — nothing in that chain lifts
# it. Codex opens a burst of well over 256 files while scanning its plugin/skill
# catalog at SessionStart, so at 256 it trips EMFILE and misreports valid
# SKILL.md files as "Too many open files (os error 24)" and fails the
# SessionStart hook (steady state it settles to ~55 fds, so it only fails at
# startup/bursts).
#
# The companion codex-high-fd wrapper + com.codex-high-fd LaunchAgent cover ONLY
# GUI Desktop Codex (launchd can't source this file); the CLI/SSH/tmux path is
# covered HERE. In .zshenv (not .zshrc) so non-interactive launches —
# `codex exec`, tmux send-keys panes, orchestrator ssh-exec — inherit it too.
#
# Safe + idempotent: only ever RAISE (never lower an already-healthier limit),
# and clamp to a finite hard limit on hosts that impose one (macOS reports
# "unlimited"; raising soft up to hard needs no privilege). Honors the same
# CODEX_FD_SOFT_LIMIT knob as the wrapper so there is one dial, not two.
_df_fd_target="${CODEX_FD_SOFT_LIMIT:-10240}"
if [[ "$_df_fd_target" == <1-> ]]; then          # zsh glob: a positive integer
    _df_fd_soft="$(ulimit -Sn)"
    _df_fd_hard="$(ulimit -Hn)"
    if [[ "$_df_fd_hard" != unlimited && "$_df_fd_target" -gt "$_df_fd_hard" ]]; then
        _df_fd_target="$_df_fd_hard"
    fi
    if [[ "$_df_fd_soft" != unlimited && "$_df_fd_soft" -lt "$_df_fd_target" ]]; then
        ulimit -Sn "$_df_fd_target" 2>/dev/null
    fi
fi
unset _df_fd_target _df_fd_soft _df_fd_hard

# Review gate for the autoreview skill (openclaw/agent-skills): its helper's own
# default (P0) reports only blockers and passes real regressions, so gate at P2.
# Engines, models and auth routes (a Bedrock profile, a subscription login) are
# per machine or per identity: see identities/example/common.sh.
export AUTOREVIEW_MAX_PRIORITY="${AUTOREVIEW_MAX_PRIORITY:-P2}"

# UTF-8 locale guarantee. Runs for ALL shells (login/interactive/script), so
# every connection path is UTF-8 regardless of transport. Some ssh paths (an
# SSM + ProxyJump double hop, for one) STRIP ssh's SendEnv of LANG/LC_*;
# without this the remote shell falls back to the C locale
# (charmap ANSI_X3.4-1968 = ASCII) and Unicode box-drawing/glyphs in tmux +
# Claude Code render as garbage. Force a UTF-8 locale when LANG isn't already
# one. C.UTF-8 is available on most Linux systems (and macOS); fall back to
# en_US.UTF-8 only if C.UTF-8 somehow isn't.
case "${LANG:-}" in
  *.UTF-8|*.utf8|*.UTF8) : ;;   # already UTF-8 — leave it
  *)
    if command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
      export LANG=C.UTF-8
    else
      export LANG=en_US.UTF-8
    fi
    ;;
esac
# Don't pin LC_ALL globally (it would override per-category locales the user
# may set); only ensure LC_CTYPE — the category that governs glyph rendering —
# is UTF-8 if it's unset/non-UTF-8.
case "${LC_CTYPE:-${LC_ALL:-$LANG}}" in
  *.UTF-8|*.utf8|*.UTF8) : ;;
  *) export LC_CTYPE="$LANG" ;;
esac

# Rust
[[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"

# Homebrew ahead of the system dirs, in every zsh (login or not: SSH commands,
# agents' Bash tools, scripts). A launcher can hand a shell a PATH that macOS
# path_helper has put in system order, and then `bash` is /bin/bash 3.2: a
# daemon's `bash -lc` once did that to every agent it started, and the scripts
# that need bash 4+ refused to run. The prefix differs per machine (see
# zprofile.local): every one that exists goes first, /opt/homebrew
# ahead of ~/homebrew as zprofile.local picks them. -U keeps each dir once, so
# these prepends move a dir to the front instead of adding a second copy.
typeset -U path PATH
for _brew_prefix in /home/linuxbrew/.linuxbrew "$HOME/homebrew" /opt/homebrew; do
    # /home is an autofs mount on macOS: every lookup under it takes ~10 ms, even
    # for a path that is not there, and no Mac has Linuxbrew.
    [[ "$OSTYPE" == darwin* && "$_brew_prefix" == /home/* ]] && continue
    if [[ -d "$_brew_prefix/bin" ]]; then
        export PATH="$_brew_prefix/bin:$_brew_prefix/sbin:$PATH"
    fi
done
unset _brew_prefix

# User-local binaries (the tools install.sh links into ~/.local/bin, and yours).
# Also needed here (not just .zprofile) because .zprofile only fires on login
# shells; non-interactive SSH (agents, scripts, remote commands) sources
# .zshenv but not .zprofile, so local-bin tools wouldn't resolve.
if [[ -d "$HOME/.local/bin" ]]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Managed Node tools must win over stale standalone/global launchers that may
# still exist in ~/.local/bin. Keep this after the local-bin addition because
# each PATH assignment prepends its directory.
if [[ -d "$HOME/.npm-global/bin" ]]; then
    export PATH="$HOME/.npm-global/bin:$PATH"
fi

# Disable fnm's engines.node resolution. Without this, fnm reads the
# `engines.node` field from any package.json in the cwd (or its parents)
# on every `cd` and prints "Using Node vX.Y.Z", which is noisy in scripts
# that cd around. Node is not pinned per repo here: the default Node satisfies
# the projects' engines ranges.
export FNM_RESOLVE_ENGINES=false

# Rokit's installer appends an unguarded source line; guard it so machines
# without rokit don't print "no such file or directory" on every shell.
if [[ -f "$HOME/.rokit/env" ]]; then . "$HOME/.rokit/env"; fi

# Machine-local overrides (gitignored) — CA bundles, GNU coreutils PATH on
# Mac, etc. Sourced last so it can override anything above. An `if`, not
# `[[ ]] &&`: as the last line, a false test would start every `zsh -c` at $? = 1.
if [[ -f ~/.zshenv.local ]]; then source ~/.zshenv.local; fi
