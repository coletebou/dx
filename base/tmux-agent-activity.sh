#!/usr/bin/env bash
# tmux-agent-activity — publish every window's recency color as the window
# option @recency_fg, which tmux.conf paints window names with (status bar and
# the prefix+s / prefix+w chooser). Runs from status-right as #() and prints
# nothing.
#
#   < 1m    colour46   green   producing output right now
#   < 15m   colour178  yellow  recently active
#   < 1h    colour75   blue    quiet a while
#   older   colour245  grey    dormant
#
# WHY A SCRIPT, NOT A FORMAT: tmux 3.7 stops expanding a status line after 100ms
# (FORMAT_TIME_LIMIT in format.c) and draws whatever is left as empty. Computed
# in the format (an age per threshold, each re-expanding the window's
# timestamp), these colors cost ~1ms per window, so a 75-window session ran out
# of time partway through its window list: the current window and all of
# status-right vanished and the list snapped back to window 1, flashing about
# once a second. Looking up a published color is ~12x cheaper (measured).
#
# ACTIVITY: #{window_activity} is the time of a window's last OUTPUT, and a
# Claude Code TUI produces output while doing nothing. focus-events makes it
# redraw when you switch to it, so VIEWING a window turned it green, and a client
# attach or resize redraws every Claude pane at once (seen: five idle Claude
# windows sharing one activity second). A Claude window therefore uses the
# newest write to its session's own files, over every live Claude pane in it:
#   transcript  ~/.claude/projects/<slug>/<sid>.jsonl   user and assistant
#               messages, tool results, background-task notifications
#   subagents   ~/.claude/projects/<slug>/<sid>/subagents/*.jsonl
#   background  /tmp/claude-<uid>/<slug>/<sid>/tasks/*  background shell output
# Every other window (shells, editors, ssh) uses #{window_activity}.
#
# Panes register themselves: statusline.sh sets the pane option @claude_reg to
# "<claude pid> <transcript path>" once per session. A pane counts while that
# pid is alive (kill -0, a builtin). A dead one is unregistered, and a window
# left with no live Claude pane falls back to window_activity.
#
# WRITES ONLY WHEN A COLOR CHANGES. Any set-option, even of a user option, makes
# tmux redraw every client in full, and that redraw re-runs this job as soon as
# a new second starts. The previous version published the raw timestamp
# (@agent_ts), which some session changed nearly every second, so the job kept
# re-running itself about once a second instead of once per status-interval.
#
# Cost per run: one tmux list, one stat for every Claude pane's newest file
# (picked with the builtin -nt, no fork per file), and one batched tmux set only
# when a color changed (more than one only on a first pass over a big server).
# Bash 3.2 safe: window ids (@N) index plain arrays.
set -u
command -v tmux >/dev/null 2>&1 || exit 0
# Fields are split on tab, the one separator every tmux prints raw: 3.4 turns
# other control characters, 0x1f included, into octal escapes. Tab is IFS
# whitespace, so an empty field would merge into the next separator and shift
# every later one; each field that can be empty carries a "=" prefix instead,
# stripped after the read.
rows=$(tmux list-panes -a -F $'#{window_id}\t#{pane_id}\t=#{@claude_reg}\t#{window_activity}\t=#{@recency_fg}\t=#{@agent_ts}' 2>/dev/null) || exit 0

now=$(date +%s)
uid=${UID:-$(id -u)}
act=() cur=() stale=() agent=() files=() fwin=() cmds=()
# tmux runs NONE of a command line over 1000 arguments (3.7+, cmd_unpack_argv
# in cmd.c) or 16KB (any version, client.c): "command too long". A first pass
# over a big server queues one set per window, so the batch goes out in chunks;
# 800 short arguments stay under both limits.
flush() { (( ${#cmds[@]} )) && tmux "${cmds[@]}" >/dev/null 2>&1; cmds=(); }
queue() {
    (( ${#cmds[@]} + $# >= 800 )) && flush
    (( ${#cmds[@]} )) && cmds+=(";")
    cmds+=("$@")
}

while IFS=$'\t' read -r wid pane reg wact wfg wts; do
    reg=${reg#=} wfg=${wfg#=} wts=${wts#=}
    w=${wid#@}
    [[ "$w" =~ ^[0-9]+$ ]] || continue
    act[w]=$wact cur[w]=$wfg
    [[ -n "$wts" ]] && stale[w]=1
    [[ -n "$reg" ]] || continue
    pid=${reg%% *} transcript=${reg#* }
    if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
        queue set-option -pu -t "$pane" @claude_reg
        continue
    fi
    base=${transcript%.jsonl}
    sid=${base##*/} slug=${base%/*}
    slug=${slug##*/}
    newest=$transcript
    for f in "$base"/subagents/*.jsonl "/tmp/claude-$uid/$slug/$sid"/tasks/*; do
        [[ -e "$f" && "$f" -nt "$newest" ]] && newest=$f
    done
    [[ -e "$newest" ]] || continue
    files+=("$newest") fwin+=("$w")
done <<<"$rows"

complete=1
if (( ${#files[@]} )); then
    # /usr/bin/stat on macOS: a Homebrew coreutils `stat` first on PATH is GNU,
    # where -f means "filesystem status", not "format".
    if [[ "$OSTYPE" == darwin* ]]; then
        mt=$(/usr/bin/stat -f %m "${files[@]}" 2>/dev/null)
    else
        mt=$(stat -c %Y -- "${files[@]}" 2>/dev/null)
    fi
    # A file deleted since the -e test drops its line and shifts every later
    # one onto the wrong window, so publish only a complete answer.
    mts=()
    [[ -n "$mt" ]] && IFS=$'\n' read -r -d '' -a mts <<<"$mt"
    if (( ${#mts[@]} == ${#files[@]} )); then
        for i in "${!mts[@]}"; do
            m=${mts[i]} w=${fwin[i]}
            [[ "$m" =~ ^[0-9]+$ ]] || continue
            (( m > ${agent[w]:-0} )) && agent[w]=$m
        done
    else
        complete=0   # leave every color as it is until the next run
    fi
fi

if (( complete )); then
    for w in ${act[@]+"${!act[@]}"}; do
        ts=${agent[w]:-${act[w]}}
        [[ "$ts" =~ ^[0-9]+$ ]] || continue
        age=$(( now - ts ))
        if   (( age < 60 ));   then want=colour46
        elif (( age < 900 ));  then want=colour178
        elif (( age < 3600 )); then want=colour75
        else                        want=colour245
        fi
        [[ "${cur[w]}" == "$want" ]] || queue set-option -w -t "@$w" @recency_fg "$want"
    done
fi
# @agent_ts is what the previous version published; nothing reads it now.
for w in ${stale[@]+"${!stale[@]}"}; do
    queue set-option -wu -t "@$w" @agent_ts
done
flush
exit 0
