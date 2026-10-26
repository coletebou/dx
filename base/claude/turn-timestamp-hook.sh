#!/bin/bash
# Stop hook — print a date/timestamp line at the end of every turn.
#
# The "✻ Brewed for Xm Ys" summary is harness chrome and can't be rewritten
# by any hook (MessageDisplay only sees assistant message deltas). This is
# the supported way to get a per-turn timestamp into the conversation view:
# Stop-hook `systemMessage` renders as a visible line right when the turn
# ends. Display-only — nothing is written to the transcript or sent to the
# model.
#
# Disable by removing this entry from the Stop array in settings.base.json
# (every machine) or in your identity's claude/common.settings.json.

# UTC with a Z suffix — matches the statusline ✎ segment and tmux zulu
# clock so timestamps compare directly across machines (servers usually
# run UTC, laptops local time).
now=$(date -u '+%a %m-%d %H:%M:%SZ')
printf '{"systemMessage": "⏱ %s"}\n' "$now"
exit 0
