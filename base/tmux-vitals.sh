#!/bin/bash
# Output a compact vitals string for tmux status-right.
# - On Mac: battery % (when <100 or on battery)
# - On Linux: load average (color-graded)
#
# Keep FAST — tmux calls this on interval.status (default 15s). Avoid any
# external network/IO.

if [[ "$(uname)" == "Darwin" ]]; then
    # Battery: percentage + charging state when relevant
    pmset_out=$(pmset -g batt 2>/dev/null | tail -1)
    pct=$(echo "$pmset_out" | grep -oE '[0-9]+%' | head -1)
    [[ -z "$pct" ]] && exit 0
    pct_num="${pct%\%}"
    state=""
    if echo "$pmset_out" | grep -q "discharging"; then
        if (( pct_num < 20 )); then
            state="#[fg=colour160]🔋 ${pct}#[default]"
        elif (( pct_num < 50 )); then
            state="#[fg=colour208]🔋 ${pct}#[default]"
        else
            state="#[fg=colour244]🔋 ${pct}#[default]"
        fi
    elif echo "$pmset_out" | grep -q "charging"; then
        state="#[fg=colour118]⚡ ${pct}#[default]"
    fi
    [[ -n "$state" && "$pct_num" -lt 100 ]] && printf '%s ' "$state"
else
    # Linux: load average, color-graded by cores
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    [[ -z "$load" ]] && exit 0
    cores=$(nproc 2>/dev/null || echo 4)
    # awk comparison since load is float
    color=$(awk -v l="$load" -v c="$cores" 'BEGIN {
        if (l >= c) print "colour160"          # red: load >= cores
        else if (l >= c*0.7) print "colour208" # orange
        else print "colour244"                  # grey
    }')
    # `L:x.x` — 1 decimal, not /proc/loadavg's raw 2. printf rounds (not
    # truncates), so 3.96 shows 4.0 rather than a misleadingly-calm 3.9. The
    # color grade above still uses the FULL-precision value, so a box right at
    # the cores threshold is graded on the real number, not the rounded display.
    printf '#[fg=%s]L:%.1f#[default] ' "$color" "$load"
fi
