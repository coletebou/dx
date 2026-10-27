#!/usr/bin/env bash
# Hermetic tests for the status bar in base/tmux.conf: reloads are idempotent,
# window names read the colors tmux-agent-activity.sh publishes, and the window
# list stays inside tmux's format time budget at a size where the old in-format
# colors did not. A private tmux server loads the real tmux.conf with HOME
# pointed at a sandbox, so TPM's plugins (resurrect, continuum) cannot load,
# while the helper scripts under ~/.dotfiles still resolve to this checkout.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONF="$ROOT/base/tmux.conf"
tmp="$(mktemp -d)"
export TMUX_TMPDIR="$tmp/sock"
mkdir -p "$TMUX_TMPDIR" "$tmp/home"
ln -s "$ROOT" "$tmp/home/.dotfiles"
unset TMUX TMUX_PANE
cleanup() { tmux -L outer kill-server 2>/dev/null; tmux kill-server 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

pass=0 fail=0
equal() {
  if [[ "$3" == "$2" ]]; then printf '  ok   %s\n' "$1"; pass=$((pass + 1))
  else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); fi
}
# TPM is absent from the sandbox, so its run-shell fails; nothing else should.
load() { HOME="$tmp/home" tmux source-file "$CONF" >/dev/null 2>&1; }
count() { tmux show-options -s "$1" | wc -l | tr -d ' '; }

HOME="$tmp/home" tmux -f /dev/null new-session -d -s t -x 156 -y 38 'sleep 300'
load
w=$(tmux display-message -p -t t: '#{window_id}')

printf 'reload\n'
overrides=$(count terminal-overrides) features=$(count terminal-features)
load; load
equal "terminal-overrides does not grow" "$overrides" "$(count terminal-overrides)"
equal "terminal-features does not grow" "$features" "$(count terminal-features)"
# 15 is tmux's default, so tmux-sensible would silently rewrite it to 5.
equal "status-interval is set explicitly" 5 "$(tmux show-options -gv status-interval)"

printf 'status-left\n'
label=$(tmux show-options -gv @host-label)
equal "host label is computed at load" "$(HOME="$tmp/home" bash "$ROOT/base/tmux-hostname.sh")" "$label"
equal "status-left runs no #() job" 0 "$(tmux show-options -gv status-left | grep -c '#(')"

printf 'window names\n'
fmt() { tmux display-message -p -t "$w" "#{T:$1}"; }
equal "unpublished: the dormant default" '#[fg=colour245]0:' "$(fmt window-status-format | cut -c1-17)"
tmux set-option -w -t "$w" @recency_fg colour178
equal "published color" '#[fg=colour178]0:' "$(fmt window-status-format | cut -c1-17)"
equal "current window: same color, bold" '#[fg=colour178,bold]0:' "$(fmt window-status-current-format | cut -c1-22)"

printf 'chooser\n'
# Tree mode only draws for an attached client, so a client runs inside a second
# private server and that server's pane is captured. status-right is emptied
# first: its publisher job would recolor the window as soon as a client exists.
# Up moves the selection off the window row, whose selection style would hide
# its color.
tmux set-option -g status-right ''
pane=$(tmux display-message -p -t "$w" '#{pane_id}')
# TERM is pinned: with -f /dev/null the outer server's default-terminal falls back to "screen"
# where tmux-256color is not in the system terminfo (macOS), and the client then draws colour 178
# as an 8-colour approximation. xterm-256color exists everywhere.
tmux -L outer -f /dev/null new-session -d -x 156 -y 38 'env -u TMUX TERM=xterm-256color tmux attach -t t'
for i in $(seq 1 50); do [[ -n "$(tmux list-clients)" ]] && break; sleep 0.1; done
tmux choose-tree -w -t "$pane" -F '#{E:@tree-fmt}' \; send-keys -t "$pane" Up
for i in $(seq 1 50); do  # the client draws the mode on its next redraw
  row=$(tmux -L outer capture-pane -p -e | grep -m1 '0: ')
  grep -q $'\e\[38;5;178msleep' <<<"$row" && break
  sleep 0.1
done
equal "window row uses the published color" 1 "$(grep -c $'\e\[38;5;178msleep' <<<"$row")"
if ! grep -q $'\e\[38;5;178msleep' <<<"$row"; then
  printf '       row:  %q\n       clients: %s\n       outer screen:\n' "$row" "$(tmux list-clients 2>&1 | head -n 3)"
  tmux -L outer capture-pane -p 2>&1 | sed '/^[[:space:]]*$/d' | head -n 15 | sed 's/^/         | /'
fi
tmux send-keys -t "$pane" q
tmux -L outer kill-server

printf 'window list fits the format time budget\n'
# tmux 3.7+ stops expanding a status line after 100ms (FORMAT_TIME_LIMIT) and
# draws whatever is left as empty, so the current window and all of
# status-right vanish. 500 entries took the old in-format colors ~110ms here and
# take lookups ~15ms. Links of one window make the entries without processes.
for chunk in $(seq 0 9); do
  args=(); for i in $(seq 1 50); do args+=(link-window -d -s "$w" -t "t:$((chunk * 50 + i))" ';'); done
  unset 'args[${#args[@]}-1]'; tmux "${args[@]}"
done
tmux select-window -t t:500
out=$(tmux display-message -p -t t: '#{W:#{T:window-status-format},#{T:window-status-current-format}}|END=#{?#{session_name},ok,}')
equal "the expansion reaches the end" ok "${out##*|END=}"
equal "the current window, last of 501, is drawn" 1 "$(grep -c '#\[fg=colour178,bold\]500:' <<<"$out")"
version=$(tmux -V)
if [[ "$version" =~ ([0-9]+)\.([0-9]+) ]] && (( BASH_REMATCH[1] == 3 && BASH_REMATCH[2] < 7 )); then
  printf '  note %s has no format time limit; the budget checks above pass trivially\n' "$version"
fi

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
