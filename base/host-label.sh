#!/usr/bin/env bash
# host-label.sh — the short label and work flag for this machine, shared by the
# tmux status bar (tmux-hostname.sh) and the terminal tab title (tmux-tabhost.sh).
# The Claude Code statusline (base/claude/statusline.sh) reads the same file inline,
# since it runs on every render.
#
# Labels are configuration, not code. Lookup, first hit wins:
#   1. DF_HOST_LABEL (and DF_WORK=1) in the environment;
#   2. the first line of the hosts file whose glob matches the short hostname.
#      The hosts file is DF_HOSTS_FILE, else your identity's
#      $DOTFILES_DIR/identities/<DF_IDENTITY>/hosts (see identities/example/hosts):
#          <hostname glob>  <label>  [work]
#          my-desktop       desk
#          corp-laptop-*    corp     work
#   3. the lowercase short hostname.
# A machine is "work" when its hosts line says so, DF_WORK=1 is set, or its
# identity is one of DF_WORK_IDENTITIES (space-separated, default "work").
#
# Usage: source it, then `df_host_label` prints "<label><TAB><work|personal>".

df_host_identity() {
    local id="${DF_IDENTITY:-}" line
    if [[ -z "$id" && -r "$HOME/.df-profile" ]]; then
        while IFS= read -r line; do
            [[ "$line" == "export DF_IDENTITY="* ]] && { id="${line#export DF_IDENTITY=}"; break; }
        done < "$HOME/.df-profile"
    fi
    printf '%s' "${id//[^A-Za-z0-9._-]/}"
}

df_host_label() {
    local host id file glob label flag rest w_id kind=personal out="${DF_HOST_LABEL:-}"
    host="$(hostname -s 2>/dev/null || hostname 2>/dev/null)"
    host="$(printf '%s' "${host%%.*}" | tr '[:upper:]' '[:lower:]')"
    id="$(df_host_identity)"
    file="${DF_HOSTS_FILE:-${DOTFILES_DIR:-$HOME/.dotfiles}/identities/${id:-none}/hosts}"
    if [[ -r "$file" ]]; then
        while read -r glob label flag rest; do
            [[ -z "$glob" || "$glob" == \#* || -z "$label" ]] && continue
            # shellcheck disable=SC2053  # the glob is a pattern on purpose
            if [[ "$host" == $glob ]]; then
                [[ -n "$out" ]] || out="$label"
                [[ "$flag" == work ]] && kind=work
                break
            fi
        done < "$file"
    fi
    [[ "${DF_WORK:-}" == 1 ]] && kind=work
    for w_id in ${DF_WORK_IDENTITIES:-work}; do
        [[ -n "$id" && "$id" == "$w_id" ]] && kind=work
    done
    printf '%s\t%s\n' "${out:-${host:-unknown}}" "$kind"
}
