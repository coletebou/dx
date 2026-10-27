#!/usr/bin/env bash
# tmux-ssh-inherit.test.sh: base/tmux-ssh-inherit.sh on a sandboxed tmux server. A pane runs
# a stand-in `ssh` (a compiled program that only waits, so tmux and the process table see a
# real ssh with a real argv); the script must open a window whose process gets exactly the
# connection arguments back: an argument with a space stays one argument, -t is added unless
# the argv already had the flag (a "t" inside -lroot is not it), and an sshpass wrapper gets
# the plain window, never its password replayed as ssh options.
#
#   bash scripts/tests/tmux-ssh-inherit.test.sh     (under a private /tmp: see lib/tmux-sandbox.sh)
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
script="$root/base/tmux-ssh-inherit.sh"
. "$here/lib/tmux-sandbox.sh"
tsb_require_private_tmp || exit 1
if [[ ! -r /proc/self/cmdline ]] || ! command -v cc >/dev/null 2>&1; then
  echo "# SKIP needs /proc and a C compiler for the stand-in ssh"
  exit 0
fi
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'tsb_teardown; rm -rf "$tmp"' EXIT
tsb_init "$tmp" || exit 1
tsb_own s

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }

mkdir -p "$tmp/fake"
printf '#include <unistd.h>\nint main(void) { for (;;) pause(); }\n' > "$tmp/fake/wait.c"
cc -o "$tmp/fake/ssh" "$tmp/fake/wait.c" || { echo "cc failed"; exit 1; }
cp "$tmp/fake/ssh" "$tmp/fake/sshpass"

tsb new-session -d -s s -x 160 -y 40 'sleep 300'
tsb set -g default-shell /bin/sh

argv_of() { [[ -n "$1" ]] && tr '\0' '|' < "/proc/$1/cmdline" 2>/dev/null; }
# source WINDOW COMMAND: an interactive shell in a new window runs COMMAND in the
# foreground, as a person would; prints the pane id once tmux sees the program.
source_pane() {
  local p
  # exec: the interactive shell must be the pane's own process, as a login shell is, or
  # COMMAND would be its grandchild and the script reads direct children only.
  p="$(tsb new-window -d -t s: -n "$1" -P -F '#{pane_id}' 'exec bash --norc --noprofile -i')"
  tsb send-keys -t "$p" -l "$2"
  tsb send-keys -t "$p" Enter
  for _ in $(seq 50); do
    [[ "$(tsb display-message -p -t "$p" '#{pane_current_command}')" == ssh* ]] && break
    sleep 0.1
  done
  printf '%s\n' "$p"
}
# inherit PANE: run the script on PANE; prints the pid of the one window it added.
inherit() {
  local before after w pid
  before="$(tsb list-windows -t s: -F '#{window_id}')"
  # A new window gets the PATH of the client that asked for it: put the stand-in first.
  PATH="$tmp/fake:$PATH" bash "$script" window "$1" >/dev/null 2>&1
  after="$(tsb list-windows -t s: -F '#{window_id}')"
  w="$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | head -n 1)"
  [[ -n "$w" ]] || return 0
  for _ in $(seq 50); do  # until the window's sh has exec'd its command
    pid="$(tsb display-message -p -t "$w" '#{pane_pid}')"
    [[ "$(argv_of "$pid")" != sh* ]] && break
    sleep 0.1
  done
  printf '%s\n' "$pid"
}

echo "an argument with a space"
pane="$(source_pane a "$tmp/fake/ssh -i '/keys/my key' box.example.com")"
pid="$(inherit "$pane")"
equal "stays one argument" 'ssh|-i|/keys/my key|-t|box.example.com|exec "$SHELL" -l|' "$(argv_of "$pid")"

echo "a t inside an option value"
pane="$(source_pane b "$tmp/fake/ssh -Jbastion -lroot box.example.com")"
pid="$(inherit "$pane")"
equal "is not the -t flag, so -t is added" 'ssh|-Jbastion|-lroot|-t|box.example.com|exec "$SHELL" -l|' "$(argv_of "$pid")"

echo "a -t the argv had"
pane="$(source_pane c "$tmp/fake/ssh -At box.example.com")"
pid="$(inherit "$pane")"
equal "is not added twice" 'ssh|-At|box.example.com|exec "$SHELL" -l|' "$(argv_of "$pid")"

echo "an sshpass wrapper"
pane="$(source_pane d "$tmp/fake/sshpass -p hunter2 ssh box.example.com")"
pid="$(inherit "$pane")"
lacks "gets the plain window: its password is never replayed" "hunter2" "$(argv_of "$pid")"
equal "...which runs the default shell" "-sh|" "$(argv_of "$pid")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
