#!/bin/bash
# Global SessionStart hook: surface session handoff + list supplementary memory
# files from whatever auto-memory directory Claude Code is using for this cwd.
#
# MEMORY.md is auto-loaded by Claude Code natively; this hook surfaces the rest
# (the session handoff, and a one-line index of the other topic files so the
# model knows what's available to Read on demand).
#
# Global (dotfiles-managed), on by default:
#   - Self-scoping: resolves the memory dir per-cwd and no-ops instantly when
#     there's no memory dir, so it's harmless in non-memory projects.
#   - Registered once in settings.base.json, so every machine running these
#     dotfiles gets it with no per-repo / team buy-in.
set -euo pipefail

# Resolve the same auto-memory dir Claude Code reads/writes.
# Precedence mirrors the CLI: an `autoMemoryDirectory` override in
# local/user settings wins (used LITERALLY — no per-cwd slug appended);
# otherwise fall back to the default ~/.claude/projects/<encoded-cwd>/memory
# (worktrees map to the main worktree's dir). Claude Code encodes the path by
# turning every character that is not a letter or digit into "-", so
# /home/me/.dotfiles is -home-me--dotfiles.
encode() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# Read autoMemoryDirectory from local then project then user settings (jq if available).
AUTO_MEM_DIR=""
if command -v jq >/dev/null 2>&1; then
  for _sf in "$PWD/.claude/settings.local.json" \
             "$PWD/.claude/settings.json" \
             "$HOME/.claude/settings.json"; do
    [ -f "$_sf" ] || continue
    _v=$(jq -r '.autoMemoryDirectory // empty' "$_sf" 2>/dev/null)
    if [ -n "$_v" ]; then
      # Expand a leading ~/ to $HOME (the CLI does the same).
      # shellcheck disable=SC2088  # intentional literal-tilde glob pattern, not expansion
      case "$_v" in '~/'*) _v="$HOME/${_v#'~/'}";; esac
      AUTO_MEM_DIR="$_v"
      break
    fi
  done
fi

if [ -n "$AUTO_MEM_DIR" ]; then
  MEMORY_DIR="$AUTO_MEM_DIR"
else
  # `|| true`: outside a repo git exits 128, and under `set -e` that silently
  # killed the hook — sessions in non-git dirs with a memory dir (e.g. ~/code)
  # lost their handoff and memory index, and showed "SessionStart hook error".
  GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null || true)
  if [ -n "$GIT_COMMON" ] && [ "$GIT_COMMON" != ".git" ]; then
    # Worktree: resolve main repo root from the shared .git dir
    MAIN_ROOT=$(cd "$(dirname "$GIT_COMMON")" 2>/dev/null && pwd)
    MEMORY_DIR="$HOME/.claude/projects/$(encode "$MAIN_ROOT")/memory"
  else
    MEMORY_DIR="$HOME/.claude/projects/$(encode "$PWD")/memory"
  fi
fi

if [ -d "$MEMORY_DIR" ]; then
  # Output session handoff if it exists (accept both dash and underscore forms;
  # different memory dirs have used either spelling).
  for _hf in session-handoff.md session_handoff.md; do
    if [ -f "$MEMORY_DIR/$_hf" ]; then
      echo "## Session Handoff"
      cat "$MEMORY_DIR/$_hf"
      echo ""
      break
    fi
  done

  # List other memory files (MEMORY.md is auto-loaded; the handoff is already
  # shown above) so the model knows what topic files exist to Read on demand.
  EXTRA=$(find "$MEMORY_DIR" -maxdepth 1 -name "*.md" \
            ! -name "MEMORY.md" ! -name "session-handoff.md" ! -name "session_handoff.md" \
            -exec basename {} \; 2>/dev/null | sort)
  if [ -n "$EXTRA" ]; then
    echo "## Supplementary Memory Files"
    echo "Read these from $MEMORY_DIR/ if relevant:"
    for f in $EXTRA; do
      echo "  - $f"
    done
  fi
fi

# Open items and recent learnings for this repo from the reflections store —
# what a PreCompact/SessionEnd reflection or a /reflect run left for the next
# session. Independent of the memory dir: unregistered repos have reflections too.
# Also runs after /compact (source=compact), so open items survive compaction.
REFL="${DOTFILES_DIR:-$HOME/.dotfiles}/scripts/reflections"
if [ -x "$REFL" ]; then
  REFL_CTX=$("$REFL" context 2>/dev/null || true)
  if [ -n "$REFL_CTX" ]; then
    echo ""
    echo "$REFL_CTX"
  fi
fi
