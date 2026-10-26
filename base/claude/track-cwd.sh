#!/bin/bash
# PostToolUse hook: records the user's *intended* working directory to a
# per-session file so the statusline can show the actually-active directory
# instead of Claude Code's session-origin cwd (which is fixed and can be
# wrong when the session starts in one checkout but work happens in a
# worktree).
#
# Strategy: inspect the Bash command. If it starts with `cd <path>` or
# `cd <path> &&`, record that path. This catches the common pattern of
# Claude Code's Bash tool calls that `cd` into a worktree to do work.
# Ignore commands that don't explicitly cd — those don't change intent.
#
# Writes to /tmp/claude-cwd-${session_id} — tiny file, atomic write.

set -u

input=$(cat)

tool_name=$(jq -r '.tool_name // ""' <<<"$input" 2>/dev/null)
[[ "$tool_name" != "Bash" ]] && exit 0

session_id=$(jq -r '.session_id // ""' <<<"$input" 2>/dev/null)
[[ -z "$session_id" ]] && exit 0

# Only update on successful commands (not interrupted, no stderr spam)
interrupted=$(jq -r '.tool_response.interrupted // false' <<<"$input" 2>/dev/null)
[[ "$interrupted" == "true" ]] && exit 0

# Extract the command text
cmd=$(jq -r '.tool_input.command // ""' <<<"$input" 2>/dev/null)
[[ -z "$cmd" ]] && exit 0

# Look for a leading `cd <path>` or `cd <path> && ...`. This covers the
# common harness pattern. Expand ~ to $HOME.
if [[ "$cmd" =~ ^[[:space:]]*cd[[:space:]]+([^[:space:]&|;]+) ]]; then
    target="${BASH_REMATCH[1]}"
    # Strip surrounding quotes
    target="${target#\"}"
    target="${target%\"}"
    target="${target#\'}"
    target="${target%\'}"
    # Expand ~
    target="${target/#\~/$HOME}"
    # Only record absolute paths that exist AND are inside a git repo
    # (otherwise statusline falls back to session_cwd, which is usually
    # a repo already). Non-repo targets like /tmp or $HOME shouldn't
    # update the tracker — the user probably still wants to see their
    # repo in the statusline.
    if [[ "$target" = /* && -d "$target" ]]; then
        if git -C "$target" rev-parse --git-dir &>/dev/null; then
            printf '%s' "$target" > "/tmp/claude-cwd-${session_id}" 2>/dev/null || true
        fi
    fi
fi

exit 0
