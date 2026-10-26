# ~/.zshrc — universal entry point (profile-aware)
#
# Active profile determined by DF_IDENTITY × DF_ROLE. Those env vars are
# written to ~/.df-profile by install.sh and exported from ~/.zshenv so
# every shell (interactive, login, non-interactive) sees them.
#
# Use `df-switch` to swap identity/role in the current shell.

# Load secrets (runs for all shells, before interactive check)
# ~/.env_secrets is sourced by zshenv (every zsh, interactive or not).

# Non-interactive shells: bail
[[ $- != *i* ]] && return

# Start of interactive startup, for the slow-prompt log in base/zshrc.
zmodload zsh/datetime
_df_shell_started=$EPOCHREALTIME

# Ghostty shell integration (macOS). Ghostty normally auto-injects this, but
# when zsh is launched in a way that bypasses the auto-inject (custom rc order,
# etc.) GHOSTTY_SHELL_FEATURES stays unset and the integration's `ssh` wrapper —
# which forwards TERM=xterm-ghostty and installs the remote terminfo — never
# loads, so remote tmux renders with the wrong terminal (garbled glyphs and a
# misplaced cursor). Source it explicitly so ssh-env/ssh-terminfo work.
# Harmless if already injected.
if [[ "$TERM" == xterm-ghostty && -z "${GHOSTTY_SHELL_FEATURES:-}" ]]; then
  for _gi in \
    "/Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration/zsh/ghostty-integration" \
    "${GHOSTTY_RESOURCES_DIR:-}/shell-integration/zsh/ghostty-integration"; do
    [[ -r "$_gi" ]] && { source "$_gi"; break; }
  done
  unset _gi
fi

# Defaults (install.sh should have written real values to ~/.df-profile)
: "${DF_IDENTITY:=example}" "${DF_ROLE:=local}"

# ── Base (universal zsh bones) ───────────────────────────────────────
source ~/.dotfiles/base/zshrc

# ── Aliases (profile-aware chain via ~/.dotfiles/aliases) ────────────
[[ -f ~/.aliases ]] && source ~/.aliases

# ── Once per session: warn about orphaned Claude Code processes ─────
# (A login dashboard such as porchlight installs its own hook.)
if [[ -z "$_DF_SESSION_SHOWN" ]]; then
    export _DF_SESSION_SHOWN=1
    (( $+functions[_claude_orphan_warning] )) && _claude_orphan_warning
fi

# ── Machine-specific escape hatch ────────────────────────────────────
[[ -f ~/.zshrc_machine ]] && source ~/.zshrc_machine

# ── Auto-cd (first shell only) ───────────────────────────────────────
# DF_LOGIN_DIR (set it in ~/.zshenv.local) wins; a local machine otherwise
# starts in ~/code when it exists.
if [[ "$PWD" == "$HOME" ]]; then
    # -q: skip the chpwd hooks. zoxide would fork to log a visit nobody
    # made (~7 ms), and ~/code pins no Node version for fnm to switch to.
    if [[ -n "${DF_LOGIN_DIR:-}" && -d "$DF_LOGIN_DIR" ]]; then
        cd -q "$DF_LOGIN_DIR"
    elif [[ "$DF_ROLE" == "local" && -d ~/code/ ]]; then
        cd -q ~/code/
    fi
fi

# ── OpenClaw completion (if present) ─────────────────────────────────
[[ -f "$HOME/.openclaw/completions/openclaw.zsh" ]] && source "$HOME/.openclaw/completions/openclaw.zsh"

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"
# The following lines have been added by Docker Desktop to enable Docker CLI completions.
# Its ~/.docker/completions is on fpath in base/zshrc, ahead of the one compinit;
# move any fpath or compinit lines an installer adds here to that spot.
# End of Docker CLI completions


# pnpm
export PNPM_HOME="$HOME/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME/bin:"*) ;;
  *) export PATH="$PNPM_HOME/bin:$PATH" ;;
esac
# pnpm end

# >>> Codex installer >>>
# $HOME-relative: installers write their own absolute home here, and this file
# is shared by every machine, so a literal home path would be a dead PATH entry
# on every other one.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< Codex installer <<<

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
# Its completions dir is on fpath in base/zshrc, ahead of the one compinit.
# <<< grok installer <<<

export PATH="$HOME/.local/bin:$PATH"

# codex-update owns this launcher. Select it for interactive Codex without
# changing which installation wins for Claude or other commands on PATH.
if [[ -x "$HOME/.npm-global/bin/codex" ]]; then
    function codex() { "$HOME/.npm-global/bin/codex" "$@"; }
fi
