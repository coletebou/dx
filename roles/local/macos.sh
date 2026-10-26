# roles/local/macos.sh — local+macOS specific
#
# Sourced when [[ "$OSTYPE" == darwin* ]] on any local machine.
# Future content: macOS-specific helpers (pbcopy/pbpaste already built
# in, Finder integration, VS Code path if not already in PATH via Shell
# Command, etc.).

# ── caffeinate: keep this Mac awake ──────────────────────────────────
# caf12 keeps the machine fully awake for 12h, detached from the calling
# shell (nohup + disown) so closing the terminal or SSH session does NOT
# kill it. Flags: -d display, -i idle, -m disk, -s system (on AC), -u
# user-active, -t <seconds>. `caf <hours>` for an arbitrary duration;
# `caf-stop` kills any running caffeinate.
caf() {
    local hours="${1:-12}"
    local secs=$(( hours * 3600 ))
    nohup caffeinate -dimsu -t "$secs" >/dev/null 2>&1 &
    disown
    local pid=$!
    # `until` time: GNU date (coreutils gnubin may shadow BSD in PATH) uses
    # -d "+Nh"; BSD date uses -v+NH. Try GNU, fall back to BSD, else blank.
    local until
    until=$(date -d "+${hours} hours" '+%H:%M' 2>/dev/null) \
        || until=$(date -v+"${hours}"H '+%H:%M' 2>/dev/null) \
        || until="+${hours}h"
    echo "caffeinate: Mac awake for ${hours}h (pid ${pid}, until ${until})"
}
alias caf12='caf 12'
alias caf-stop='pkill -x caffeinate && echo "caffeinate stopped" || echo "no caffeinate running"'
