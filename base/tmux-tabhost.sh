#!/bin/bash
# Short hostname for terminal tab titles (Ghostty/iTerm2/etc.).
# Plain text, no colors — OSC titles don't render ANSI.
#
# Tab real estate is the scarcest, so this is the label from your identity's
# hosts file (see base/host-label.sh and identities/example/hosts), the same one
# the tmux status bar shows; an unknown machine shows its lowercase short
# hostname.

# shellcheck source=base/host-label.sh
source "${DOTFILES_DIR:-$HOME/.dotfiles}/base/host-label.sh"
IFS=$'\t' read -r label _ <<<"$(df_host_label)"
printf '%s\n' "$label"
