#!/usr/bin/env bash
# Canonical machine IDs shared by installers and shell entry points.
#
# DF_MACHINE is this machine's stable id: the short hostname, lowercased and
# reduced to [a-z0-9._:-]. install.sh writes it to ~/.df-profile; pin another
# one with `install.sh --machine <id>` (e.g. a laptop whose hostname changes
# with the network). The display label shown in the tmux bar and the Claude
# Code statusline is separate: see base/host-label.sh.

df_normalize_machine_id_part() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    value="$(printf '%s' "$value" | LC_ALL=C tr -cs 'a-z0-9._:-' '-')"
    [[ -n "$value" ]] || value="unknown"
    case "$value" in
        [a-z0-9]*) ;;
        *) value="id-$value" ;;
    esac
    printf '%s\n' "$value"
}

df_machine_id() {
    local raw_host="${1:-}"
    if [[ -z "$raw_host" ]]; then
        raw_host="$(hostname -s 2>/dev/null || hostname 2>/dev/null)" || return 1
    fi

    # Keep one stable, lowercase label even when macOS reports a .local suffix
    # or a host command returns an FQDN.
    raw_host="${raw_host%%.*}"
    df_normalize_machine_id_part "$raw_host"
}

df_machine_id_is_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._:-]*$ ]]
}

# The id install.sh persists: an explicit --machine value when it is valid,
# else the hostname-derived one. A DF_MACHINE already in ~/.df-profile is not
# reused: a home directory copied from another machine must not keep its id.
df_resolve_machine_id() {
    local raw_host="${1:-}" pinned="${2:-}"
    if [[ -n "$pinned" ]] && df_machine_id_is_valid "$pinned"; then
        printf '%s\n' "$pinned"
    else
        df_machine_id "$raw_host"
    fi
}
