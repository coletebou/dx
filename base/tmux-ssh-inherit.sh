#!/usr/bin/env bash
# tmux-ssh-inherit.sh — open a new tmux window already SSH'd to the same host
# as the current pane (and, when known, the same remote directory).
#
# Invoked from tmux via `prefix + c` (see base/tmux.conf). When the current pane
# is NOT running ssh this is a pure passthrough to the stock behavior, so the
# binding is safe to use as the unconditional new-window key.
#
# Usage: tmux-ssh-inherit.sh <mode> [source-pane]
#   mode = window | hsplit | vsplit
#
# source-pane is only used to READ the pane being inherited from (it defaults to
# the pane the binding fired in, which is what the key bindings rely on). It is
# deliberately NOT forwarded to new-window: there, -t means "target window
# INDEX", not "source pane", so passing a pane id makes tmux fail with "can't
# specify pane here". The new window's placement comes from -a (after current)
# instead. split-window -t DOES take a pane, so splits forward it.
#
# ── How the ssh command is recovered ────────────────────────────────────────
# tmux knows a pane is running ssh (#{pane_current_command}) but NOT with which
# arguments, so the argv is read back from the process table. Two subtleties,
# both verified empirically on tmux 3.7b / macOS 25.6 and Linux:
#
#  1. ONLY DIRECT CHILDREN of the pane's shell are considered. With ProxyJump,
#     `ssh -J jump.example.com box` spawns a SECOND ssh as a GRANDCHILD:
#         pane_pid ── ssh -J jump.example.com box     <- the real command
#                      └── ssh -W [192.0.2.10]:22 jump.example.com
#     A recursive walk (or `pgrep -f ssh`) can return the -W transport, and
#     replaying that opens a bare stdio tunnel with no shell — a hung window.
#     Depth-1 selection structurally cannot pick it, since the transport is
#     never a direct child of the pane shell.
#
#  2. The remote command is DROPPED, only connection args are replayed. A
#     host-picker alias may end its ssh with `... exec $SHELL -l`, and other
#     call sites end with `claude` or a one-shot. Replaying the tail verbatim would relaunch an
#     agent or rerun a command instead of giving you a shell. See split_argv().
#
# ── How the remote directory is recovered ───────────────────────────────────
# #{pane_current_path} is the LOCAL cwd of the pane's shell — during ssh it is
# wherever you were before connecting, which is useless (and misleading) for a
# remote window. The remote cwd is only knowable if the remote shell reports it
# via OSC 7, which tmux parses into #{pane_path} (verified: an OSC 7 emitted on
# a box named `box` arrives as `file://box/etc`). base/zshrc emits OSC 7 from a
# chpwd hook, so machines running these dotfiles report their cwd; anything else
# degrades to the remote default (usually $HOME), which is correct-but-generic
# rather than wrong.
#
# The host in the OSC 7 URI is authoritative for whether the path applies: it is
# the box that emitted it. If it does not correspond to the ssh destination we
# are about to replay, the path belongs to some other host and is discarded.

set -uo pipefail

mode="${1:-window}"
pane="${2:-}"

# Reject an unknown mode instead of silently treating it as `window`. A typo in
# a binding should surface, not quietly open the wrong kind of thing.
case "$mode" in
    window|hsplit|vsplit) ;;
    *) tmux display-message "ssh-inherit: unknown mode '$mode'" 2>/dev/null; exit 2 ;;
esac

# ── tmux plumbing ───────────────────────────────────────────────────────────

tmux_q() { tmux display-message ${pane:+-t "$pane"} -p "$1" 2>/dev/null; }

# new-window needs a WINDOW target (see the -t note in the header), so resolve
# the source pane's window once and use that for window placement.
win_target="$(tmux_q '#{session_name}:#{window_index}')"

# Refuse to act unless the source pane resolves to a REAL window. Two traps here,
# both verified — an empty-string test catches neither:
#
#   * A bogus/stale pane id does NOT make display-message fail. It prints the
#     format with every field empty (":" for this one) and still exits 0.
#   * With no pane argument at all, tmux resolves "current" from its own state,
#     which is an arbitrary session — not the caller's.
#
# Either way the fallback would then run new-window with a meaningless target and
# drop a stray window into an unrelated session. Require both halves to be
# present, and require the pane id itself to exist when one was passed.
if [[ ! "$win_target" =~ ^.+:[0-9]+$ ]]; then
    tmux display-message "ssh-inherit: cannot resolve pane ${pane:-<current>}" 2>/dev/null
    exit 3
fi
if [[ -n "$pane" ]] && ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qxF "$pane"; then
    tmux display-message "ssh-inherit: no such pane $pane" 2>/dev/null
    exit 3
fi

# Stock behavior, used both for non-ssh panes and for any failure below.
# -c keeps the local cwd; -a inserts after the current window (renumber-windows
# on => the new window lands at current_index + 1).
plain() {
    case "$mode" in
        hsplit) exec tmux split-window ${pane:+-t "$pane"} -h -c "$1" ;;
        vsplit) exec tmux split-window ${pane:+-t "$pane"} -v -c "$1" ;;
        *)      exec tmux new-window -a ${win_target:+-t "$win_target"} -c "$1" ;;
    esac
}

pane_pid="$(tmux_q '#{pane_pid}')"
pane_cmd="$(tmux_q '#{pane_current_command}')"
local_path="$(tmux_q '#{pane_current_path}')"
osc7_path="$(tmux_q '#{pane_path}')"
: "${local_path:=$HOME}"

# #{pane_current_command} is the FOREGROUND process, so this test is inherently
# self-correcting: quit ssh and the pane reports its shell again on the next
# keypress. There is no cached state that can go stale, and therefore nothing to
# invalidate — which is why this whole feature needs no bookkeeping.
case "$pane_cmd" in
    ssh|sshpass|autossh|mosh|mosh-client) ;;
    *) plain "$local_path" ;;
esac
[[ -n "$pane_pid" ]] || plain "$local_path"

# ── Recover the ssh argv from the pane's DIRECT children (see note 1) ───────

# NUL-delimited so an argument containing whitespace (e.g. -o "SetEnv=X=a b")
# survives into the array intact.
read_children() {
    if command -v pgrep >/dev/null 2>&1; then
        # -P is POSIX-ish and present on macOS + Linux; it is depth-1 by
        # definition, which is exactly the property we need.
        local kid
        for kid in $(pgrep -P "$pane_pid" 2>/dev/null); do
            printf '%s\n' "$kid"
        done
    else
        # BusyBox / minimal container fallback.
        ps -eo pid=,ppid= 2>/dev/null | awk -v p="$pane_pid" '$2==p {print $1}'
    fi
}

ssh_argv=()
for kid in $(read_children); do
    kid_args="$(ps -o args= -p "$kid" 2>/dev/null)"
    [[ -n "$kid_args" ]] || continue
    # First word must be an ssh-family binary. Matching the whole string would
    # hit `vim ssh_config` or `git commit -m "fix ssh"`.
    kid_bin="${kid_args%% *}"; kid_bin="${kid_bin##*/}"
    case "$kid_bin" in
        ssh|sshpass|autossh|mosh|mosh-client) ;;
        *) continue ;;
    esac
    # shellcheck disable=SC2206  # deliberate word-split of a flat ps string
    ssh_argv=($kid_args)
    break
done

[[ ${#ssh_argv[@]} -gt 0 ]] || plain "$local_path"

# ── Split argv into connection args / destination / remote command ──────────
#
# Walks the option grammar rather than assuming a position, because the
# destination can sit anywhere among the flags. Option letters are taken from
# ssh(1): the arg-taking set must be exact, since treating a bare flag as
# arg-taking would swallow the destination as its value (and vice versa).
split_argv() {
    conn_args=(); dest=""; i=1
    local n=${#ssh_argv[@]}
    while (( i < n )); do
        local a="${ssh_argv[i]}"
        case "$a" in
            --) ((i++)); continue ;;
            -[46AaCfGgKkMNnqsTtVvXxYy]*)
                # Bundled boolean flags. Session-shaping ones are dropped:
                #   -f/-N/-n  background / no-command / stdin-from-devnull
                #   -M        become a ControlMaster (only one may exist)
                #   -T        disable pty  -s subsystem  -G config-dump-and-exit
                # Keeping any of them yields a window with no usable shell.
                local keep="${a//[fNnMTsGV]/}"
                [[ "$keep" != "-" && -n "$keep" ]] && conn_args+=("$keep")
                ((i++)) ;;
            -[bcDEeFIiJLlmOopQRSWw])
                # Separated value: -o Foo=bar
                conn_args+=("$a")
                (( i+1 < n )) && { conn_args+=("${ssh_argv[i+1]}"); ((i++)); }
                ((i++)) ;;
            -[bcDEeFIiJLlmOopQRSWw]*)
                # Attached value: -oFoo=bar
                conn_args+=("$a"); ((i++)) ;;
            -*)
                conn_args+=("$a"); ((i++)) ;;
            *)
                # First non-option is the destination; everything after it is
                # the remote command, which we deliberately DISCARD (note 2).
                dest="$a"; break ;;
        esac
    done
}
split_argv
[[ -n "$dest" ]] || plain "$local_path"

# Drop a control-socket override. Replaying `-S <path>` would attach the new
# window to the existing master's socket; if that connection dies (or was
# opened -O exit) the window dies with it. Multiplexing still applies via
# ssh_config, which is where multiplexing belongs.
filtered=(); skip_next=0
for a in "${conn_args[@]}"; do
    if (( skip_next )); then skip_next=0; continue; fi
    case "$a" in
        -S) skip_next=1; continue ;;
        -S*) continue ;;
    esac
    filtered+=("$a")
done
conn_args=("${filtered[@]}")

# ── Decide the remote directory (see note 2 on OSC 7) ──────────────────────

remote_dir=""
if [[ "$osc7_path" == file://* ]]; then
    rest="${osc7_path#file://}"
    osc_host="${rest%%/*}"
    osc_dir="/${rest#*/}"

    # Compare the OSC 7 authority against the ssh destination. `dest` may be
    # user@host, an ssh_config alias, or an IP; the OSC 7 host is whatever the
    # remote box calls itself. Accept when either is a prefix of the other on a
    # dot boundary (box vs box.example.com) — a conservative test
    # that errs toward dropping a path rather than applying a foreign one.
    dest_host="${dest##*@}"; dest_host="${dest_host%%:*}"
    dl="$(printf '%s' "$dest_host" | tr '[:upper:]' '[:lower:]')"
    ol="$(printf '%s' "$osc_host"  | tr '[:upper:]' '[:lower:]')"
    if [[ -n "$ol" && ( "$ol" == "$dl" || "$ol" == "$dl".* || "$dl" == "$ol".* ) ]]; then
        # %XX-decode: OSC 7 is a URI, so a path with spaces arrives as %20.
        #
        # Only decode when EVERY '%' starts a well-formed %XX pair. A stray '%'
        # (a literal one from a shell that does not escape, or truncated output)
        # makes the \x rewrite produce "\xs"-style garbage plus printf warnings
        # on stderr; better to keep the path undecoded-but-intact and let the
        # host check below decide. The data is passed as an ARGUMENT to %b, never
        # as the format string, so a path containing %s / %n cannot be
        # interpreted as a printf directive.
        if [[ "$osc_dir" != *%* ]]; then
            remote_dir="$osc_dir"
        elif [[ "$(printf '%s' "$osc_dir" | tr -dc '%' | wc -c)" -eq \
                "$(printf '%s' "$osc_dir" | grep -oE '%[0-9A-Fa-f]{2}' | wc -l)" ]]; then
            remote_dir="$(printf '%b' "${osc_dir//%/\\x}" 2>/dev/null)"
        fi
    fi
fi

# ── Build the remote command ────────────────────────────────────────────────
#
# -t forces a pty (the recovered argv may have carried -T, and without a pty
# there is no usable interactive shell).
have_t=0
for a in "${conn_args[@]}"; do [[ "$a" == "-t" || "$a" == -*t* ]] && have_t=1; done
(( have_t )) || conn_args+=("-t")

if [[ -n "$remote_dir" ]]; then
    # Single-quote for the REMOTE shell; embedded quotes are escaped the POSIX
    # way ('\'') since remote_dir ultimately comes from remote output.
    esc_dir="${remote_dir//\'/\'\\\'\'}"
    # `cd || true` then exec: if the directory is gone (deleted since, or a
    # different fs layout) you still get a shell in $HOME rather than a window
    # that flashes an error and exits.
    remote_cmd="cd '$esc_dir' 2>/dev/null || true; exec \"\$SHELL\" -l"
else
    remote_cmd="exec \"\$SHELL\" -l"
fi

# ── Launch ─────────────────────────────────────────────────────────────────
#
# The command is handed to tmux as a single string, so each element is quoted
# for the `sh -c` that tmux will run it under.
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

cmdline="exec command ssh"
for a in "${conn_args[@]}"; do cmdline+=" $(shq "$a")"; done
cmdline+=" $(shq "$dest") $(shq "$remote_cmd")"

# Name the window for the host, and pin it: automatic-rename would immediately
# relabel it "ssh", which is useless when several windows are ssh'd to
# different boxes. Strip the domain for brevity; keep any user@ prefix off.
win_name="${dest##*@}"; win_name="${win_name%%.*}"

case "$mode" in
    hsplit) exec tmux split-window ${pane:+-t "$pane"} -h -c "$local_path" "$cmdline" ;;
    vsplit) exec tmux split-window ${pane:+-t "$pane"} -v -c "$local_path" "$cmdline" ;;
    *)
        # `setw -t` must name the NEW window, not the source one, so let
        # new-window print the id it created (-P) and pin that. Chaining a bare
        # `\; setw automatic-rename off` would instead disable renaming on
        # whichever window happened to be current.
        new_win="$(tmux new-window -a ${win_target:+-t "$win_target"} \
            -c "$local_path" -n "$win_name" -P -F '#{session_name}:#{window_index}' \
            "$cmdline")" || exit 1
        tmux setw -t "$new_win" automatic-rename off
        exit 0
        ;;
esac
