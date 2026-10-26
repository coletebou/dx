#!/usr/bin/env bash
# tmux-rename-hook — Stop + UserPromptSubmit hook
#
# Reads `transcript_path` from hook stdin, scans the JSONL for the most
# recent `{"type":"custom-title", ...}` entry, and renames the tmux window
# containing this Claude session's pane to match. Idempotent — silent when
# the desired name equals the current name. Also clears a stale handoff flag
# on the window (see below).
#
# Wired from ~/.claude/settings.json:
#   "hooks": {
#     "Stop": [{ "hooks": [{ "type": "command", "command": "bash ~/.dotfiles/base/claude/tmux-rename-hook.sh" }] }],
#     "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "bash ~/.dotfiles/base/claude/tmux-rename-hook.sh" }] }]
#   }
#
# Why two events: Stop fires at end-of-turn (slight lag after `/rename`).
# UserPromptSubmit catches the *next* user prompt — together they cover
# both "rename takes effect at end of current turn" and "rename takes
# effect at start of next turn", whichever the user notices first.

set -u

# We need TMUX in the env to do anything. Claude Code launched outside tmux
# (e.g. from VSCode terminal panel) just exits silently.
[[ -n "${TMUX:-}" ]] || exit 0

# $TMUX_PANE is set by tmux for any process running inside a pane. If it's
# missing, we can't target the right window — exit silently.
[[ -n "${TMUX_PANE:-}" ]] || exit 0

input=$(cat)

# `transcript_path` and `session_id` exist on every hook input shape we use
# here. US (0x1f) delimits them: unlike a tab it is not IFS whitespace, so an
# empty first field cannot shift the second into it.
IFS=$'\x1f' read -r session_id transcript <<<"$(jq -j '[.session_id // "", .transcript_path // ""] | join("\u001f")' <<<"$input" 2>/dev/null)"

# cc-handoff launch (the fresh-session-handoff skill) flags the window of the session that handed
# off (@handoff_to: red badge in the status bar and tab title) and records
# "<pane> <session id>" in @handoff_src. A different session in that same pane
# (a new `claude`, or /clear) means the window is in use again, so drop the
# flag. Other panes in the window, and the handed-off session itself, leave it.
if [[ -n "${session_id:-}" ]]; then
  handoff_src=$(tmux show-options -wqv -t "$TMUX_PANE" @handoff_src 2>/dev/null || true)
  if [[ -n "$handoff_src" && "${handoff_src%% *}" == "$TMUX_PANE" && "${handoff_src#* }" != "$session_id" ]]; then
    tmux set-option -wu -t "$TMUX_PANE" @handoff_to \; set-option -wu -t "$TMUX_PANE" @handoff_src 2>/dev/null || true
  fi
fi

[[ -n "${transcript:-}" && -r "$transcript" ]] || exit 0

# Find the latest custom-title entry. Read forward + take `last` instead
# of reversing the file — `tac` is GNU-only (missing on macOS) and
# `tail -r` is BSD-only (missing on Linux). jq handles a 35MB transcript
# comfortably under a second, so forward-scan is fine for a hook.
title=$(jq -rs '
          [ .[] | select(.type == "custom-title") | .customTitle | select(. != null and . != "") ]
          | last // ""
        ' "$transcript" 2>/dev/null)

# No /rename in this session → leave automatic-rename to do its thing.
[[ -n "$title" ]] || exit 0

# Compare against current window name; only act on diff.
current=$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null || true)
[[ "$current" == "$title" ]] && exit 0

# Rename, and pin it (otherwise tmux's automatic-rename will overwrite at
# next pane_current_command change). `setw automatic-rename off` is scoped
# to the window containing $TMUX_PANE.
tmux rename-window -t "$TMUX_PANE" "$title" 2>/dev/null || true
tmux set-window-option -t "$TMUX_PANE" automatic-rename off 2>/dev/null || true

exit 0
