#!/usr/bin/env bash
# tmux-windows-active — print "<active>/<total>" windows for the tmux status bar,
# where "active" means the window produced output in the last few seconds.
#
# Output formats (NO emoji, NO letters — position and color carry the meaning):
#   " 0/38 "   — nothing producing output: both numbers blue
#   " 3/38 "   — 3 windows actively changing: the active count is GREEN
#   "12/38 "   — the active count is padded to the total's width, so the
#                segment's width holds still while the count moves. A window list
#                too long for the bar is centered on the current window, and one
#                cell more or less here (9 -> 10) slid the whole list sideways.
#
# Replaces the old per-harness counter (claude agents --json + pgrep for codex).
# That approach needed a separate query per tool, could only report busy/idle for
# claude (a PID count has no such signal), and missed anything else doing work.
# `window_activity` is harness-agnostic: a build, a test run, an ssh session and
# an agent all count the same, and it costs ONE tmux call with no subprocess per
# window.
#
# HOW IT WORKS: #{window_activity} is an epoch timestamp of the last output in
# that window, so (now - activity) is seconds-since-last-output. Verified in a
# throwaway server: idle 3s -> no advance; during a printing loop -> advanced;
# after the loop -> froze. It tracks real OUTPUT, not attachment.
#
# THRESHOLD is 5s, not 0: an idle shell still nudges the timestamp by ~1s on
# prompt repaint, so a stricter window would report idle shells as active. 5s is
# also >= the 3s cache TTL below, so a window that goes quiet cannot stay "active"
# for longer than one extra refresh.
#
# NOT #{pane_activity} — it exists in the docs but returns EMPTY on tmux 3.4
# (verified on 3.4-1ubuntu0.1). NOT #{window_activity_flag} either: that only
# sets for activity in a window you are NOT viewing, and clears on visit.
#
# Cached briefly so a fast status-interval can't spawn this per redraw. The TTL
# is short because this metric is the live one on the bar — a 10s cache would
# show a stale count for most of its life.

set -u

CACHE="$HOME/.cache/tmux-windows-active"
CACHE_TTL=3
ACTIVE_WINDOW_SECS=5

mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true

# Serve cached output if fresh. mtime read is GNU (-c) then BSD (-f) so this
# works on the Macs too; a failed read yields 0 -> a huge age -> treated as stale,
# which is the safe direction (recompute rather than print something wrong).
if [[ -f "$CACHE" ]]; then
    mtime=$(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0)
    [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
    if (( $(date +%s) - mtime < CACHE_TTL )); then
        cat "$CACHE"
        exit 0
    fi
fi

# No tmux server (or not on PATH) -> print nothing, and do NOT cache it, so the
# next refresh reattempts once a server exists.
command -v tmux >/dev/null 2>&1 || exit 0

# One call for every window on the server. -a spans all sessions.
activity=$(tmux list-windows -a -F '#{window_activity}' 2>/dev/null) || exit 0
[[ -n "$activity" ]] || exit 0

# Count in a single awk pass — no per-window subshell.
# Guard against a non-numeric/empty field: only count rows that look like an
# epoch, so a malformed line can't silently inflate either number.
read -r active total <<<"$(
    printf '%s\n' "$activity" | awk -v now="$(date +%s)" -v win="$ACTIVE_WINDOW_SECS" '
        /^[0-9]+$/ { total++; if (now - $1 <= win) active++ }
        END { printf "%d %d", active+0, total+0 }
    '
)"
[[ "$active" =~ ^[0-9]+$ ]] || active=0
[[ "$total"  =~ ^[0-9]+$ ]] || total=0

(( total > 0 )) || exit 0

# NOTE: this script used to also publish `tmux set -g @now "$(date +%s)"` for the
# window-name recency colors, on the belief that a format could not obtain the
# current epoch. It can — a bare strftime %s works inside #{e|...} (verified on
# 3.4 and 3.7b; the dead end was #{T:%s}, which is "expand a VARIABLE as time").
# tmux-agent-activity.sh computes those colors now and publishes them as
# @recency_fg, so nothing reads @now. Do not re-add it.

# Color: the active count is GREEN when > 0 (it is the only live signal here),
# else it shares the blue of the total so an all-quiet server reads as one flat
# field. Blue 75 rather than the clock's 109 — far enough apart that the adjacent
# segments don't blur together on a narrow client.
BLUE="colour75"
padded=$(printf '%*d' "${#total}" "$active")
if (( active > 0 )); then
    out="#[fg=colour46]${padded}#[fg=${BLUE}]/${total}#[default] "
else
    out="#[fg=${BLUE}]${padded}/${total}#[default] "
fi

printf '%s' "$out" | tee "$CACHE"
