#!/usr/bin/env bash
# tmux-copy-buffer.test.sh: base/tmux-copy-buffer.sh on a host with no clipboard tool, its
# OSC 52 branch. It runs the way the Alt-C binding runs it, through run-shell on a sandboxed
# server, and must hand the scrollback to tmux (load-buffer -w, which sends the OSC 52 to the
# client) instead of printing an escape sequence that run-shell only captures.
#
#   bash scripts/tests/tmux-copy-buffer.test.sh     (under a private /tmp: see lib/tmux-sandbox.sh)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
. "$here/lib/tmux-sandbox.sh"
tsb_require_private_tmp || exit 1
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'tsb_teardown; rm -rf "$tmp"' EXIT
tsb_init "$tmp" || exit 1
tsb_own cb

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$(printf '%q' "$3")"; fi; }

tsb new-session -d -s cb -x 80 -y 10 "printf 'hello from the pane\n'; exec sleep 300"
# run-shell jobs get the server's global environment: a PATH with only what the script and
# the guard need, and no pbcopy, clip.exe, wl-copy, xclip or xsel, so the OSC 52 branch runs.
mkdir -p "$tmp/onlybin"
for c in bash sh env id grep wc tr cat base64; do ln -s "$(command -v "$c")" "$tmp/onlybin/$c"; done
tsb set-environment -g PATH "$TSB_BIN:$tmp/onlybin"
for _ in $(seq 50); do
  [[ "$(tsb capture-pane -p -t cb: 2>/dev/null)" == *"hello from the pane"* ]] && break
  sleep 0.1
done

echo "the OSC 52 branch"
tsb run-shell -t cb: "$root/base/tmux-copy-buffer.sh" >/dev/null 2>&1
check "the scrollback reaches tmux's buffer (load-buffer -w sends it to the client)" \
  "hello from the pane" "$(tsb show-buffer 2>&1)"
# Run directly, its stdout comes back here: exactly what run-shell would capture.
out="$(env TMUX="$TSB_SOCK,0,0" PATH="$TSB_BIN:$tmp/onlybin" "$root/base/tmux-copy-buffer.sh" 2>/dev/null)"
lacks "...and it prints no escape sequence for run-shell to swallow" $'\e]52' "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
