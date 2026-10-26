#!/usr/bin/env bash
# Hermetic tests for base/tmux-agent-activity.sh (window recency colors from
# Claude session files and window_activity) and the handoff-flag clearing in
# base/claude/tmux-rename-hook.sh. A private tmux server (own TMUX_TMPDIR, no
# config) stands in for the user's.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUBLISH="$ROOT/base/tmux-agent-activity.sh"
RENAME="$ROOT/base/claude/tmux-rename-hook.sh"
tmp="$(mktemp -d)"
export TMUX_TMPDIR="$tmp/sock"
mkdir -p "$TMUX_TMPDIR"
unset TMUX TMUX_PANE
uid=${UID:-$(id -u)}
slug="-fsh-activity-test-$$"
bgdir="/tmp/claude-$uid/$slug"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$tmp" "$bgdir"; }
trap cleanup EXIT

pass=0 fail=0
equal() {
  if [[ "$3" == "$2" ]]; then printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
# touch -t takes [[CC]YY]MMDDhhmm[.SS] in local time on both GNU and BSD.
stamp() { touch -t "$(date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S)" "$2"; }
wopt() { tmux show-options -wqv -t "$1" "$2"; }
# The color a window renders with: its own @recency_fg, else an inherited one.
color() { tmux display-message -p -t "$1" '#{@recency_fg}'; }

now=$(date +%s)
proj="$tmp/projects/$slug"
mkdir -p "$proj/sidA/subagents" "$bgdir/sidA/tasks" "$proj"
transcript="$proj/sidA.jsonl"
other="$proj/sidB.jsonl"
: > "$transcript"; : > "$other"
# Every age below sits well inside its color band, so a second of drift between
# this script and the one under test cannot move a window across a boundary.
stamp $((now - 7200)) "$transcript"
stamp $((now - 4000)) "$other"

tmux -f /dev/null new-session -d -s t -n claude 'sleep 300'
tmux new-window -d -t t: -n shell 'sleep 300'
tmux new-window -d -t t: -n dead 'sleep 300'
pane_claude=$(tmux list-panes -t '=t:=claude' -F '#{pane_id}')
pane_dead=$(tmux list-panes -t '=t:=dead' -F '#{pane_id}')
sleep 300 & live_pid=$!
dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid - 1)); done
tmux set-option -p -t "$pane_claude" @claude_reg "$live_pid $transcript"
tmux set-option -p -t "$pane_dead" @claude_reg "$dead_pid $other"
tmux set-option -w -t '=t:=dead' @agent_ts 12345   # the previous version's option

printf 'publish: colors by age\n'
bash "$PUBLISH"
equal "2h-old transcript: grey" colour245 "$(color '=t:=claude')"
equal "shell window: its fresh window_activity is green" colour46 "$(color '=t:=shell')"
equal "dead pid: pane unregistered" "" "$(tmux show-options -pqv -t "$pane_dead" @claude_reg)"
equal "dead pid: window falls back to window_activity" colour46 "$(color '=t:=dead')"
equal "stale @agent_ts removed" "" "$(wopt '=t:=dead' @agent_ts)"

printf 'publish: subagent and background-shell writes count too\n'
: > "$proj/sidA/subagents/agent-1.jsonl"; stamp $((now - 1800)) "$proj/sidA/subagents/agent-1.jsonl"
bash "$PUBLISH"
equal "newer subagent transcript wins: 30m is blue" colour75 "$(color '=t:=claude')"
: > "$bgdir/sidA/tasks/b1.output"; stamp $((now - 300)) "$bgdir/sidA/tasks/b1.output"
bash "$PUBLISH"
equal "newer background output wins: 5m is yellow" colour178 "$(color '=t:=claude')"

printf 'publish: viewing a window does not change it\n'
before=$(color '=t:=claude')
tmux select-window -t '=t:=claude'; tmux send-keys -t "$pane_claude" ''  # focus + redraw
bash "$PUBLISH"
equal "unchanged without a file write" "$before" "$(color '=t:=claude')"

printf 'publish: a window with two Claude panes takes the newer\n'
pane_split=$(tmux split-window -d -P -F '#{pane_id}' -t '=t:=claude' 'sleep 300')
fresh="$proj/sidC.jsonl"; : > "$fresh"; stamp $((now - 5)) "$fresh"
tmux set-option -p -t "$pane_split" @claude_reg "$live_pid $fresh"
bash "$PUBLISH"
equal "max over the window's panes: green" colour46 "$(color '=t:=claude')"

printf 'publish: a run with nothing to change writes nothing\n'
# Every set-option redraws every client in full, and the redraw re-runs this
# job, so a write on a quiet run keeps the job re-running itself. A shim logs
# each tmux call. The shell window's pane has an empty @claude_reg, which
# shifts every later tab-separated field without the script's "=" prefixes
# (window_activity read as a dead pid, unregistered on every run).
mkdir -p "$tmp/shim"
cat > "$tmp/shim/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/tmux.log"
exec "$(command -v tmux)" "\$@"
EOF
chmod +x "$tmp/shim/tmux"
: > "$tmp/tmux.log"
PATH="$tmp/shim:$PATH" bash "$PUBLISH"
equal "one tmux call" 1 "$(wc -l < "$tmp/tmux.log" | tr -d ' ')"
equal "and it is the list" 0 "$(grep -c 'set-option' "$tmp/tmux.log")"

printf 'publish: a first pass over a big server goes out in chunks\n'
# tmux 3.7+ refuses a command line over 1000 arguments ("command too long") and
# runs none of it, and one set is 7 of them; older tmux only caps it at 16KB, so
# there this passes unchunked too. remain-on-exit keeps each window after its
# command exits, so 150 windows need no processes.
tmux set-option -g remain-on-exit on
tmux new-session -d -s big 'true'
for _ in 1 2 3; do
  args=(); for _ in $(seq 1 50); do args+=(new-window -d -t big: 'true' ';'); done
  unset 'args[${#args[@]}-1]'; tmux "${args[@]}"
done
bash "$PUBLISH"
equal "every window published" 151 "$(tmux list-windows -t big -F '#{@recency_fg}' | grep -c colour)"
tmux kill-session -t big
tmux set-option -gu remain-on-exit

printf 'rename hook: handoff flag\n'
tmux set-option -w -t "$pane_claude" @handoff_to handoffs:work
tmux set-option -w -t "$pane_claude" @handoff_src "$pane_claude sess-OLD"
# The hook needs $TMUX set, and tmux reads its socket path from it, so it must
# name the private server's socket, not just be non-empty.
hook() {  # hook <pane> <session id>
  printf '{"session_id":"%s","transcript_path":"%s"}' "$2" "$tmp/no-transcript" \
    | TMUX="$TMUX_TMPDIR/tmux-$uid/default,0,0" TMUX_PANE="$1" bash "$RENAME"
}
hook "$pane_claude" sess-OLD
equal "the handed-off session keeps its flag" "handoffs:work" "$(wopt "$pane_claude" @handoff_to)"
hook "$pane_split" sess-OTHER
equal "another pane in the window leaves it" "handoffs:work" "$(wopt "$pane_claude" @handoff_to)"
hook "$pane_claude" sess-NEW
equal "a new session in that pane clears it" "" "$(wopt "$pane_claude" @handoff_to)"
equal "and its source" "" "$(wopt "$pane_claude" @handoff_src)"

kill "$live_pid" 2>/dev/null; wait "$live_pid" 2>/dev/null
printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
