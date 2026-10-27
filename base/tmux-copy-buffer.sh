#!/usr/bin/env bash
# tmux-copy-buffer.sh — grab entire pane scrollback and push to system clipboard.
#
# Invoked from tmux via `prefix + C`. Detects the clipboard tool at runtime so
# the same binding works on macOS, WSL, Wayland, X11, and (via OSC 52) over
# SSH to modern terminal emulators.

set -eu

copy_cmd=""
if command -v pbcopy >/dev/null 2>&1; then
    copy_cmd="pbcopy"                             # macOS
elif command -v clip.exe >/dev/null 2>&1; then
    copy_cmd="clip.exe"                            # WSL
elif command -v wl-copy >/dev/null 2>&1; then
    copy_cmd="wl-copy"                             # Wayland
elif command -v xclip >/dev/null 2>&1; then
    copy_cmd="xclip -selection clipboard"          # X11
elif command -v xsel >/dev/null 2>&1; then
    copy_cmd="xsel --clipboard --input"            # X11 fallback
elif [[ -n "${SSH_CONNECTION:-}" || -n "${TMUX:-}" ]]; then
    # OSC 52: remote session. Ask outer terminal to copy.
    # Works in iTerm2, Ghostty, WezTerm, Kitty, Alacritty, Windows Terminal.
    # Not by printing the sequence: run-shell captures this script's stdout and
    # shows it in view mode, so it would never reach the terminal. load-buffer -w
    # (tmux 3.2+) hands the text to tmux, which sends OSC 52 to the client itself
    # (`set -s set-clipboard on` in tmux.conf).
    buf="$(tmux capture-pane -p -S - -E -)"
    lines="$(printf '%s\n' "$buf" | wc -l | tr -d ' ')"
    bytes="$(printf '%s' "$buf" | wc -c | tr -d ' ')"
    printf '%s' "$buf" | tmux load-buffer -w -
    tmux display-message "copied ${lines} lines / ${bytes} bytes via OSC 52"
    exit 0
else
    tmux display-message "copy-buffer: no clipboard tool (pbcopy/clip.exe/xclip/xsel/wl-copy/OSC 52)"
    exit 1
fi

buf="$(tmux capture-pane -p -S - -E -)"
lines="$(printf '%s\n' "$buf" | wc -l | tr -d ' ')"
bytes="$(printf '%s' "$buf" | wc -c | tr -d ' ')"

printf '%s' "$buf" | eval "$copy_cmd"

tmux display-message "copied ${lines} lines / ${bytes} bytes to clipboard"
