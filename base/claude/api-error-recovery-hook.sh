#!/usr/bin/env bash
# api-error-recovery-hook — wrapper for api_error_recovery.py (design, env knobs
# and the verified asyncRewake mechanism are documented in that file).
#
#   StopFailure: bash ~/.dotfiles/base/claude/api-error-recovery-hook.sh
#                (registered with "asyncRewake": true and a timeout above the
#                 backoff cap, so the retry sleep is never killed mid-wait)
#   Stop:        bash ~/.dotfiles/base/claude/api-error-recovery-hook.sh --stop
#                (runs at the end of every successful turn, so it exits before
#                 starting Python unless some failure streak is on record)
#   UserPromptSubmit: … api-error-recovery-hook.sh --prompt
#                (a new prompt cancels any pending retry wake; same fast exit)
#
# Fails open: disabled, no python3, or any error → exit 0, no output.
set -u
[[ "${API_RECOVERY_DISABLE:-0}" == "1" ]] && exit 0
if [[ "${1:-}" == "--stop" || "${1:-}" == "--prompt" ]]; then
  compgen -G "${API_RECOVERY_STATE_DIR:-$HOME/.claude/state/api-recovery}/*.json" >/dev/null || exit 0
fi
command -v python3 >/dev/null 2>&1 || exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
exec python3 "$here/api_error_recovery.py"
