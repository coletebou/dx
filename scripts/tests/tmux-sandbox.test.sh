#!/usr/bin/env bash
# tmux-sandbox.test.sh: proves scripts/tests/lib/tmux-sandbox.sh cannot reach a tmux server
# it did not create. A DECOY server (its socket in this test's own temp dir) stands in for
# the real one, and this shell pretends to run inside one of its panes ($TMUX points at it):
# the situation in which `TMUX_TMPDIR=<dir> tmux kill-server` typed from an agent's pane
# once killed a real server and every session on it. The real server is never
# contacted: each check that names /tmp/tmux-$UID refuses before any tmux call runs.
#
#   bash scripts/tests/tmux-sandbox.test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=lib/tmux-sandbox.sh
. "$here/lib/tmux-sandbox.sh"
# First: the real server's socket must not be visible at all (a private /tmp).
tsb_require_private_tmp || exit 1
printf '  ok   no real tmux socket is visible from this test\n'
command -v tmux >/dev/null 2>&1 || { printf 'tmux-sandbox.test.sh needs tmux\n' >&2; exit 1; }
real_tmux="$(type -P tmux)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-sandbox-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
uid="$(id -u)"
case "$tmp" in "/tmp/tmux-$uid"/*|"/private/tmp/tmux-$uid"/*) printf 'temp dir %s is a tmux socket dir; refusing\n' "$tmp" >&2; exit 1 ;; esac
decoy="$tmp/decoy/real.sock"
mkdir -p "$tmp/decoy"
cleanup() {
  # Only sockets inside $tmp, each named explicitly with -S.
  [[ -n "${TSB_ROOT:-}" ]] && tsb_teardown 2>/dev/null
  "$real_tmux" -S "$decoy" kill-server 2>/dev/null
  "$real_tmux" -S "$tmp/busy/tsb/main.sock" kill-server 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
decoy_alive() { "$real_tmux" -S "$decoy" list-sessions -F '#{session_name}' 2>/dev/null | sort; }

# The decoy, and a shell that believes it runs in one of its panes.
"$real_tmux" -S "$decoy" -f /dev/null new-session -d -s ops 'sleep 600'
"$real_tmux" -S "$decoy" new-session -d -s work-chat 'sleep 600'
decoy_pid="$("$real_tmux" -S "$decoy" display-message -p '#{pid}')"
export TMUX="$decoy,$decoy_pid,0" TMUX_PANE=%0

printf 'tsb_init forgets the server this shell runs in\n'
tsb_init "$tmp"; code=$?
# Nothing below may run unless the sandbox is fully in place.
if (( code != 0 )) || [[ -n "${TMUX:-}" || "$(type -P tmux)" != "$TSB_BIN/tmux" || "$TMUX_TMPDIR" != "$tmp"/* ]]; then
  printf 'tmux-sandbox.test.sh: the sandbox did not come up; refusing to continue\n' >&2; exit 1
fi
equal "init: exit 0" 0 "$code"
equal "TMUX is unset" "" "${TMUX:-}"
equal "TMUX_PANE is unset" "" "${TMUX_PANE:-}"
equal "it remembers that server, to refuse it" "$decoy" "$TSB_ORIG_SOCK"
equal "the guard comes first on PATH" "$TSB_BIN/tmux" "$(type -P tmux)"
case "$TSB_SOCK" in "$tmp"/*) ok "the sandbox socket is inside the test's temp dir" ;; *) bad "socket inside tmp" "$tmp/..." "$TSB_SOCK" ;; esac

printf 'that command, replayed against the decoy\n'
out="$(TMUX="$decoy,$decoy_pid,0" TMUX_TMPDIR="$tmp/x" "$TSB_BIN/tmux" kill-server 2>&1)"; code=$?
equal "TMUX_TMPDIR=<dir> tmux kill-server from a pane: refused (97)" 97 "$code"
equal "the decoy server lives" "ops work-chat" "$(decoy_alive | xargs)"

printf 'every call lands in the sandbox, whatever $TMUX says\n'
tsb new-session -d -s origin 'sleep 600'; code=$?
equal "tsb new-session: exit 0" 0 "$code"
tsb_own origin
equal "tmux through PATH with TMUX set to the decoy lists only the sandbox" "origin" \
  "$(TMUX="$decoy,$decoy_pid,0" tmux list-sessions -F '#{session_name}' | xargs)"
equal "tsb lists only the sandbox" "origin" "$(tsb list-sessions -F '#{session_name}' | xargs)"
out="$(tmux capture-pane -p -S - -t '=origin:' 2>&1)"; code=$?
equal "a command's own -S (capture-pane -S -) still works" 0 "$code"

printf 'every way to aim at another server is refused\n'
for attempt in "-S $decoy kill-server" "-S $decoy list-sessions" "-L default kill-server" "-L default list-sessions" \
    "-uS $decoy list-sessions" "set -g @x 1 ; kill-server" "kill-serv" "kill-server"; do
  # shellcheck disable=SC2086 # each attempt is a word list on purpose
  out="$("$TSB_BIN/tmux" $attempt 2>&1)"; code=$?
  equal "tmux $attempt: refused (97)" 97 "$code"
done
out="$(TSB_SOCK="$decoy" "$TSB_BIN/tmux" list-sessions 2>&1)"; code=$?
equal "TSB_SOCK pointed at the decoy: refused" 97 "$code"
out="$(env -u TSB_SOCK "$TSB_BIN/tmux" list-sessions 2>&1)"; code=$?
equal "TSB_SOCK unset: refused" 97 "$code"
out="$(TSB_SOCK="$tmp/other.sock" "$TSB_BIN/tmux" list-sessions 2>&1)"; code=$?
equal "a socket the sandbox did not create: refused" 97 "$code"
out="$(tsb kill-server 2>&1)"; code=$?
equal "tsb kill-server: refused" 97 "$code"
out="$(tsb -S "$decoy" list-sessions 2>&1)"; code=$?
equal "tsb -S <another socket> (tmux honours the last -S): refused" 97 "$code"
out="$(tsb -L default list-sessions 2>&1)"; code=$?
equal "tsb -L default: refused" 97 "$code"
out="$(tsb -f /dev/null -uS "$decoy" list-sessions 2>&1)"; code=$?
equal "tsb -f <file> -uS <socket>: refused" 97 "$code"
out="$(tsb set -g @x 1 \; kill-server 2>&1)"; code=$?
equal "tsb ... \\; kill-server: refused" 97 "$code"
equal "the decoy server lives" "ops work-chat" "$(decoy_alive | xargs)"
equal "the sandbox server lives" "origin" "$(tsb list-sessions -F '#{session_name}' | xargs)"

printf 'real socket paths are refused before any tmux call\n'
stub_log="$tmp/stub.log"
saved_real="$TSB_REAL"
printf '#!/bin/sh\necho "$@" >> %q\n' "$stub_log" > "$tmp/stub-tmux"; chmod +x "$tmp/stub-tmux"
TSB_REAL="$tmp/stub-tmux"
for s in "/tmp/tmux-$uid/default" "/private/tmp/tmux-$uid/default" "/tmp/tmux-$uid/other" "$decoy" "/var/tmp/elsewhere.sock" "relative.sock"; do
  out="$(tsb_at "$s" list-sessions 2>&1)"; code=$?
  equal "tsb_at $s: refused" 97 "$code"
done
out="$(TSB_ORIG_TMUX_TMPDIR="$tmp/xdg" tsb_socket_ok "$tmp/xdg/tmux-$uid/default" 2>&1)"; code=$?
equal "a socket under the caller's own TMUX_TMPDIR default: refused" 97 "$code"
TSB_REAL="$saved_real"
if [[ ! -e "$stub_log" ]]; then ok "none of them ran tmux"; else bad "no tmux call" "no stub calls" "$(cat "$stub_log")"; fi

printf 'teardown kills only a server whose sessions are all the test'"'"'s own\n'
"$real_tmux" -S "$TSB_SOCK" new-session -d -s intruder 'sleep 600'
out="$(tsb_teardown 2>&1)"; code=$?
equal "a foreign session on the socket: teardown refuses (1)" 1 "$code"
equal "and leaves that server running" "intruder origin" "$(tsb list-sessions -F '#{session_name}' | sort | xargs)"
"$real_tmux" -S "$TSB_SOCK" kill-session -t '=intruder'
tsb_teardown; code=$?
equal "only the test's sessions: teardown exits 0" 0 "$code"
if "$real_tmux" -S "$TSB_SOCK" list-sessions >/dev/null 2>&1; then bad "sandbox server gone" "no server" "still answers"
else ok "the sandbox server is gone"; fi
equal "the decoy server still lives" "ops work-chat" "$(decoy_alive | xargs)"

printf 'init refuses a socket that already has a server\n'
mkdir -p "$tmp/busy/tsb"
"$real_tmux" -S "$tmp/busy/tsb/main.sock" -f /dev/null new-session -d -s someone 'sleep 600'
out="$(tsb_init "$tmp/busy" 2>&1)"; code=$?
equal "tsb_init over a live socket: refused" 97 "$code"
equal "that server is untouched" "someone" "$("$real_tmux" -S "$tmp/busy/tsb/main.sock" list-sessions -F '#{session_name}')"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
