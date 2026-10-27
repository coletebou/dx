# shellcheck shell=bash
# modules.sh: the opt-in modules. Each runs only when asked for (--aws, --terraform, --tailscale).
#
#   aws        AWS CLI v2 through AWS's own installer, from the pinned zip (sha256-checked)
#   terraform  Terraform from HashiCorp's pinned release zip (sha256-checked)
#   tailscale  Tailscale from its apt repository (signing key fingerprint pinned), then a join
#              with an auth key read from a file or an environment variable, never argv

step_aws() {
    local dir=/usr/local/aws-cli p bin
    if [ "${BOOTSTRAP_AWS:-0}" != 1 ]; then step_skip off "no --aws"; return 0; fi
    p="$PIN_AWSCLI_VERSION:$(pin_sha awscli)"
    bin="$dir/v2/$PIN_AWSCLI_VERSION/dist/aws"
    if ready_ok awscli "$p" "$bin"; then step_skip ready "AWS CLI $PIN_AWSCLI_VERSION is installed"; return 0; fi
    command -v unzip >/dev/null 2>&1 || apt_ensure unzip
    new_tmpdir
    fetch_verified "$(pin_url awscli)" "$(pin_sha awscli)" "$TMPD/awscliv2.zip"
    unzip -q "$TMPD/awscliv2.zip" -d "$TMPD"
    if [ -d "$dir/v2/current" ]; then
        as_root "$TMPD/aws/install" --install-dir "$dir" --bin-dir /usr/local/bin --update
    else
        as_root "$TMPD/aws/install" --install-dir "$dir" --bin-dir /usr/local/bin
    fi
    [ -x "$bin" ] || die "the AWS CLI installer did not produce $bin"
    ready_mark awscli "$p" "$bin"
    log "  $(/usr/local/bin/aws --version 2>&1)"
}

step_terraform() {
    if [ "${BOOTSTRAP_TERRAFORM:-0}" != 1 ]; then step_skip off "no --terraform"; return 0; fi
    command -v unzip >/dev/null 2>&1 || apt_ensure unzip
    tool_step terraform terraform /usr/local/bin/terraform
}

# The auth key comes from BOOTSTRAP_TAILSCALE_AUTHKEY_FILE (a path), or BOOTSTRAP_TAILSCALE_AUTHKEY
# (the key itself), and reaches tailscale as --auth-key=file:PATH, so it is never in argv, ps or
# a trace. tailscale_take_key runs first thing, before any hook or per-user step could inherit
# the variable: it moves the key into a 0600 file under /run (removed at exit) and unsets it.
tailscale_take_key() {
    local f
    xtrace_off
    if [ -n "${BOOTSTRAP_TAILSCALE_AUTHKEY:-}" ]; then
        if [ "${BOOTSTRAP_TAILSCALE:-0}" = 1 ] && [ -z "${BOOTSTRAP_TAILSCALE_AUTHKEY_FILE:-}" ]; then
            f="$(as_root mktemp /run/dx-tailscale-key.XXXXXX)"
            cleanup_add_root "$f"
            printf '%s' "$BOOTSTRAP_TAILSCALE_AUTHKEY" | as_root tee "$f" >/dev/null
            BOOTSTRAP_TAILSCALE_KEY_TMP="$f"
        else
            warn "BOOTSTRAP_TAILSCALE_AUTHKEY is set but unused (no --tailscale, or a key file was given)"
        fi
    fi
    unset BOOTSTRAP_TAILSCALE_AUTHKEY
    xtrace_restore
}

_tailscale_key_file() {
    if [ -n "${BOOTSTRAP_TAILSCALE_AUTHKEY_FILE:-}" ]; then
        as_root test -r "$BOOTSTRAP_TAILSCALE_AUTHKEY_FILE" \
            || die "cannot read the auth key file $BOOTSTRAP_TAILSCALE_AUTHKEY_FILE"
        printf '%s\n' "$BOOTSTRAP_TAILSCALE_AUTHKEY_FILE"
    elif [ -n "${BOOTSTRAP_TAILSCALE_KEY_TMP:-}" ]; then
        printf '%s\n' "$BOOTSTRAP_TAILSCALE_KEY_TMP"
    fi
}

# A machine joined while it had machine-id M. A box started from an image of it has another id
# but the same node identity, and must log out and join as itself.
_tailscale_joined_id() { cat "$BOOTSTRAP_STATE_DIR/tailscale-machine-id" 2>/dev/null || true; }

step_tailscale() {
    local keyring arch state key args=() tags="" mid t joined why
    if [ "${BOOTSTRAP_TAILSCALE:-0}" != 1 ]; then step_skip off "no --tailscale"; return 0; fi
    if ! command -v tailscale >/dev/null 2>&1; then
        keyring="$(apt_repo_key tailscale "https://pkgs.tailscale.com/stable/$OS_ID/$OS_CODENAME.noarmor.gpg" "$PIN_TAILSCALE_APT_FPR")"
        arch="$(dpkg --print-architecture)"
        root_write /etc/apt/sources.list.d/tailscale.list \
            "deb [arch=$arch signed-by=$keyring] https://pkgs.tailscale.com/stable/$OS_ID $OS_CODENAME main"
        apt_update force
        sub_begin apt-install
        apt_get install tailscale
        sub_end
    fi
    if has_systemd; then
        as_root systemctl enable --now tailscaled.service >/dev/null 2>&1 || die "tailscaled did not start"
    else
        warn "no systemd: tailscaled is installed but not running, so no join (a container?)"
        return 0
    fi
    state="$(as_root tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null || true)"
    mid="$(cat /etc/machine-id 2>/dev/null || true)"
    key="$(_tailscale_key_file)"
    if [ "$state" = Running ]; then
        joined="$(_tailscale_joined_id)"
        if [ "${BOOTSTRAP_TAILSCALE_REJOIN:-0}" != 1 ] && { [ -z "$joined" ] || [ "$joined" = "$mid" ]; }; then
            [ -n "$joined" ] || root_write "$BOOTSTRAP_STATE_DIR/tailscale-machine-id" "$mid"
            step_skip ready "already on the tailnet as $(as_root tailscale status --json | jq -r '.Self.HostName')"
            return 0
        fi
        why="--tailscale-rejoin"
        [ "${BOOTSTRAP_TAILSCALE_REJOIN:-0}" = 1 ] || why="its node identity came with the image it was made from"
        # Never log out without a key to join again: that would leave the box off the tailnet.
        [ -n "$key" ] || die "this node must join the tailnet again ($why), but there is no auth key (--tailscale-authkey-file)"
        log "  logging out first: $why"
        as_root tailscale logout || true
    fi
    if [ -z "$key" ]; then
        log "  installed; no auth key, so not joined. Join with:"
        log "    sudo tailscale up --auth-key=file:<key file> --advertise-tags=${BOOTSTRAP_TAILSCALE_TAGS:-tag:server}"
        return 0
    fi
    args=(up "--auth-key=file:$key")
    [ -z "${BOOTSTRAP_TAILSCALE_TAGS:-}" ] || args+=("--advertise-tags=$BOOTSTRAP_TAILSCALE_TAGS")
    [ -z "${BOOTSTRAP_TAILSCALE_HOSTNAME:-${BOOTSTRAP_HOSTNAME:-}}" ] \
        || args+=("--hostname=${BOOTSTRAP_TAILSCALE_HOSTNAME:-${BOOTSTRAP_HOSTNAME%%.*}}")
    if [ "${BOOTSTRAP_TAILSCALE_SSH:-0}" = 1 ]; then args+=(--ssh); fi
    as_root tailscale "${args[@]}"
    [ -z "${BOOTSTRAP_TAILSCALE_KEY_TMP:-}" ] || as_root rm -f "$BOOTSTRAP_TAILSCALE_KEY_TMP"
    # An interrupted `up` can leave a node authorized but untagged, which a tag-based policy then
    # cuts off with nothing but "access revoked" on the client: check the tags right away.
    if [ -n "${BOOTSTRAP_TAILSCALE_TAGS:-}" ]; then
        tags="$(as_root tailscale status --json | jq -r '(.Self.Tags // []) | join(",")')"
        for t in $(printf '%s' "$BOOTSTRAP_TAILSCALE_TAGS" | tr ',' ' '); do
            case ",$tags," in *",$t,"*) ;; *) die "joined, but the node does not carry $t (it has: ${tags:-no tags}); fix the tags in the admin console" ;; esac
        done
    fi
    root_write "$BOOTSTRAP_STATE_DIR/tailscale-machine-id" "$mid"
    log "  joined the tailnet as $(as_root tailscale status --json | jq -r '.Self.HostName')${tags:+ with $tags}"
}
