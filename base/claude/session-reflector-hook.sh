#!/usr/bin/env bash
# session-reflector-hook — PreCompact / SessionEnd → background reflection of the
# transcript into the `reflections` store (design in session_reflector.py).
#
#   PreCompact: bash ~/.dotfiles/base/claude/session-reflector-hook.sh precompact
#   SessionEnd: bash ~/.dotfiles/base/claude/session-reflector-hook.sh sessionend
#
# Returns in ~50 ms: Python validates the payload, then double-forks the reflection
# into its own session, so compaction never waits and SessionEnd's 1.5 s budget holds.
# Fails open: disabled, a reflection's own child, no python3 → exit 0.
set -u
[[ "${REFLECTOR_DISABLE:-0}" == "1" || "${AGENT_HOOK_CHILD:-0}" == "1" ]] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
exec python3 "$here/session_reflector.py" hook "${1:-sessionend}"
