#!/bin/bash
# Print the shortened hostname for tmux status-left, colored by identity:
#   work  → orange (color 166)
#   else  → green  (color 34)
# One subshell, one color signal: the color replaces a separate [work] badge.
#
# The label and the work flag come from your identity's hosts file (see
# base/host-label.sh and identities/example/hosts); an unknown machine shows
# its lowercase short hostname, in green.

# shellcheck source=base/host-label.sh
source "${DOTFILES_DIR:-$HOME/.dotfiles}/base/host-label.sh"
IFS=$'\t' read -r short kind <<<"$(df_host_label)"

if [[ "$kind" == work ]]; then
    color=166   # orange — work
else
    color=34    # green — personal
fi

printf '#[fg=colour%s,bold]%s#[default]' "$color" "$short"
