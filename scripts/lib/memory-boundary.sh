#!/usr/bin/env bash
# memory-boundary.sh — the memory tools' data boundary (MEMORY_BOUNDARY_CMD).
#
# Some sessions must never reach a model or the memory tree: a restricted model
# route, a client's data, anything your contract says stays put. Set
# MEMORY_BOUNDARY_CMD to a shell command that answers "is this restricted?":
#
#   exit 0      yes: keep it out
#   exit 1      no: go ahead
#   any other   yes (not found, a crash, a timeout): a broken check fails closed
#
# It runs through `sh -c` with the caller's environment plus
#   MEMORY_BOUNDARY_TOOL     reflector | consolidate | session-analyzer | context-advisor
#   MEMORY_BOUNDARY_PATH     the file in question: a transcript, or a prompt or
#                            input on its way to a model
#   MEMORY_BOUNDARY_SESSION  and MEMORY_BOUNDARY_TRIGGER, when the caller knows them
# and is cut off after MEMORY_BOUNDARY_TIMEOUT seconds (default 20).
# Unset, nothing is restricted.
#
# Examples:
#   MEMORY_BOUNDARY_CMD='[ "$CLIENT_MODE" = 1 ] || exit 1'                 # by environment
#   MEMORY_BOUNDARY_CMD='grep -q "acme-confidential" "$MEMORY_BOUNDARY_PATH"'  # by content
#
# Callers: claude-consolidate, session-analyzer, and base/claude/session_reflector.py
# (the same contract, in Python; base/claude/context_advisor.py reuses it).

# memory_boundary_blocks TOOL PATH → status 0 when the data must be kept out.
memory_boundary_blocks() {
  [[ -n "${MEMORY_BOUNDARY_CMD:-}" ]] || return 1
  local rc=0 secs="${MEMORY_BOUNDARY_TIMEOUT:-20}" timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then timeout_bin=gtimeout
  fi
  MEMORY_BOUNDARY_TOOL="$1" MEMORY_BOUNDARY_PATH="${2:-}" \
    ${timeout_bin:+"$timeout_bin" "$secs"} sh -c "$MEMORY_BOUNDARY_CMD" </dev/null >/dev/null 2>&1 || rc=$?
  [[ $rc -ne 1 ]]
}
