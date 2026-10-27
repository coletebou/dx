# shellcheck shell=bash
# shellcheck disable=SC2034  # OS_ID, OS_CODENAME and OS_PRETTY are read by the other modules
# system.sh: the operating system, apt, and the per-box settings: hostname, /etc/hosts, inotify
# limits, the locale, apt's network timeouts, the base packages, and the EC2 swap fix.
# Every step here is idempotent: a second run finds each file already right and changes nothing.

# os_detect: OS_ID (ubuntu or debian), OS_CODENAME, OS_PRETTY, from /etc/os-release. A derivative
# (ID_LIKE) maps to its parent, with UBUNTU_CODENAME when it has one.
os_detect() {
    local f="${BOOTSTRAP_OS_RELEASE:-/etc/os-release}" ID="" ID_LIKE="" VERSION_CODENAME="" UBUNTU_CODENAME="" PRETTY_NAME=""
    [ -r "$f" ] || die "no $f: this provisioner is for Debian and Ubuntu"
    # shellcheck disable=SC1090
    . "$f"
    OS_PRETTY="${PRETTY_NAME:-$ID}"
    case "$ID" in
        ubuntu) OS_ID=ubuntu OS_CODENAME="${VERSION_CODENAME:-$UBUNTU_CODENAME}" ;;
        debian) OS_ID=debian OS_CODENAME="$VERSION_CODENAME" ;;
        *)
            case " $ID_LIKE " in
                *" ubuntu "*) OS_ID=ubuntu OS_CODENAME="${UBUNTU_CODENAME:-$VERSION_CODENAME}" ;;
                *" debian "*) OS_ID=debian OS_CODENAME="$VERSION_CODENAME" ;;
                *) die "this provisioner is for Debian and Ubuntu, not $OS_PRETTY" ;;
            esac ;;
    esac
    [ -n "$OS_CODENAME" ] || die "no release codename in $f"
}

has_systemd() { [ -d /run/systemd/system ]; }
is_wsl() { [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] || [ -n "${WSL_DISTRO_NAME:-}" ]; }

# root_write FILE CONTENT [MODE]: FILE (written as root) holds CONTENT and a final newline, unless
# it already does. Sets WROTE to 1 when it wrote and 0 when it did not, so never call it in a
# pipeline, where WROTE would be set in a subshell. Writes in place: a container's /etc/hosts is a
# bind mount that cannot be replaced.
root_write() {
    local file="$1" mode="${3:-644}" tmp existed=0
    tmp="$(mktemp)"
    printf '%s\n' "$2" > "$tmp"
    WROTE=0
    if [ -f "$file" ] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
    [ ! -e "$file" ] || existed=1
    as_root mkdir -p "${file%/*}"
    as_root tee "$file" < "$tmp" >/dev/null
    [ "$existed" = 1 ] || as_root chmod "$mode" "$file"
    rm -f "$tmp"
    WROTE=1
}

# ── apt ──────────────────────────────────────────────────────────────────
# apt_get ARGS: apt-get, non-interactive, waiting for the dpkg lock (on a first boot,
# unattended-upgrades may hold it for minutes) for up to BOOTSTRAP_APT_LOCK_TIMEOUT seconds.
_APT_UPDATED=0
apt_get() {
    as_root env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get \
        -o "DPkg::Lock::Timeout=${BOOTSTRAP_APT_LOCK_TIMEOUT:-900}" -o Dpkg::Use-Pty=0 \
        -o Dpkg::Options::=--force-confold -q -y "$@" </dev/null
}
apt_update() {  # apt_update [force]: once per run, unless a new repository needs it again
    [ "$_APT_UPDATED" = 0 ] || [ "${1:-}" = force ] || return 0
    sub_begin apt-update
    apt_get update
    sub_end
    _APT_UPDATED=1
}
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
# apt_ensure PKG...: install whichever of PKG are missing.
apt_ensure() {
    local p missing=""
    for p in "$@"; do pkg_installed "$p" || missing="$missing $p"; done
    [ -n "$missing" ] || return 0
    apt_update
    log "  apt install:$missing"
    # shellcheck disable=SC2086
    apt_get install --no-install-recommends $missing
}

# apt_repo_key NAME URL FPR: fetch a repository's signing key and keep it only if its primary
# key has fingerprint FPR. Installs /etc/apt/keyrings/NAME.gpg (binary) and prints that path.
apt_repo_key() {
    local name="$1" url="$2" want="$3" dir fprs dest="/etc/apt/keyrings/$1.gpg"
    command -v gpg >/dev/null 2>&1 || apt_ensure gnupg
    dir="$(mktemp -d)"
    cleanup_add "$dir"
    curl -fsSL --retry 3 --connect-timeout 20 -o "$dir/key" "$url" </dev/null || die "could not fetch the $name signing key: $url"
    fprs="$(GNUPGHOME="$dir" gpg --batch --quiet --with-colons --show-keys "$dir/key" 2>/dev/null \
        | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }')"
    printf '%s\n' "$fprs" | grep -qx "$want" \
        || die "the $name signing key at $url has fingerprint ${fprs:-none}, not the pinned $want"
    if head -c 40 "$dir/key" | grep -q 'BEGIN PGP'; then
        GNUPGHOME="$dir" gpg --batch --quiet --dearmor -o "$dir/key.gpg" "$dir/key"
    else
        cp "$dir/key" "$dir/key.gpg"
    fi
    as_root install -d -m 0755 /etc/apt/keyrings
    as_root install -m 0644 "$dir/key.gpg" "$dest"
    printf '%s\n' "$dest"
}

# ── steps ────────────────────────────────────────────────────────────────
valid_hostname() {
    local h="$1" label rest
    [ -n "$h" ] && [ "${#h}" -le 253 ] || return 1
    rest="$h"
    while :; do
        label="${rest%%.*}"
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
        [ "$rest" != "$label" ] || return 0
        rest="${rest#*.}"
    done
}

# The system files these steps write, under BOOTSTRAP_SYSROOT (tests point it at a scratch tree).
sysf() { printf '%s%s\n' "${BOOTSTRAP_SYSROOT:-}" "$1"; }

step_hostname() {
    local want="${BOOTSTRAP_HOSTNAME:-}" short hosts hf line changed=0
    if [ -z "$want" ]; then step_skip off "no --hostname"; return 0; fi
    valid_hostname "$want" || die "not a valid hostname: $want"
    short="${want%%.*}" hf="$(sysf /etc/hosts)"
    if [ "$(hostname 2>/dev/null)" != "$want" ]; then
        changed=1
        if [ -z "${BOOTSTRAP_SYSROOT:-}" ] && has_systemd && command -v hostnamectl >/dev/null 2>&1; then
            as_root hostnamectl set-hostname "$want"
        else
            root_write "$(sysf /etc/hostname)" "$want"
            as_root hostname "$want" 2>/dev/null || warn "could not set the running hostname (a container?); /etc/hostname says $want"
        fi
        log "  hostname: $want"
    fi
    # Debian's convention: the machine's own name on 127.0.1.1. That line is replaced where it is
    # (or added after 127.0.0.1), so the file's order, and the hosts step's block, stay put.
    line="127.0.1.1 $want"
    [ "$short" = "$want" ] || line="$line $short"
    [ -f "$hf" ] || root_write "$hf" "127.0.0.1 localhost"
    if grep -q '^127\.0\.1\.1[[:space:]]' "$hf"; then
        hosts="$(awk -v l="$line" '/^127\.0\.1\.1[[:space:]]/ { if (!d) print l; d = 1; next } { print }' "$hf")"
    else
        hosts="$(awk -v l="$line" '{ print } /^127\.0\.0\.1[[:space:]]/ && !d { print l; d = 1 } END { if (!d) print l }' "$hf")"
    fi
    root_write "$hf" "$hosts"
    [ "$WROTE" = 0 ] || changed=1
    # cloud-init sets the hostname from instance metadata at every boot unless told not to.
    if [ -d "$(sysf /etc/cloud/cloud.cfg.d)" ]; then
        root_write "$(sysf /etc/cloud/cloud.cfg.d/99-dx-hostname.cfg)" \
            "# Written by dx provision: keep the hostname it set.
preserve_hostname: true"
        [ "$WROTE" = 0 ] || changed=1
    fi
    [ "$changed" = 1 ] || step_skip ready "the hostname is $want"
}

# Extra /etc/hosts lines live in one marked block, rewritten from the configured entries each
# run, so an entry dropped from the configuration leaves the file too.
step_hosts() {
    local begin='# >>> dx-bootstrap hosts >>>' end='# <<< dx-bootstrap hosts <<<' e block="" rest hf n
    hf="$(sysf /etc/hosts)"
    if [ -z "${BOOTSTRAP_HOSTS_ENTRIES:-}" ] && ! grep -qF "$begin" "$hf" 2>/dev/null; then
        step_skip off "no --hosts-entry"
        return 0
    fi
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        [[ "$e" =~ ^[0-9A-Fa-f:.]+[[:space:]]+[A-Za-z0-9.-]+([[:space:]]+[A-Za-z0-9.-]+)*$ ]] \
            || die "not an /etc/hosts entry (ADDRESS NAME...): $e"
        block="$block$e
"
    done <<EOF
${BOOTSTRAP_HOSTS_ENTRIES:-}
EOF
    rest="$(awk -v b="$begin" -v e="$end" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip' "$hf")"
    if [ -n "$block" ]; then
        root_write "$hf" "$rest
$begin
$block$end"
    else
        root_write "$hf" "$rest"
    fi
    n="$(printf '%s' "$block" | grep -c . || true)"
    if [ "$WROTE" = 1 ]; then log "  /etc/hosts: $n managed entries"; else step_skip ready "/etc/hosts has the $n entries"; fi
}

step_inotify() {
    local f
    f="$(sysf /etc/sysctl.d/60-dx-inotify.conf)"
    root_write "$f" "# Written by dx provision. Editors, file watchers and test runners in many containers
# exhaust the defaults (128 instances), which surfaces as ENOSPC far from the cause.
fs.inotify.max_user_watches = ${BOOTSTRAP_INOTIFY_WATCHES:-1048576}
fs.inotify.max_user_instances = ${BOOTSTRAP_INOTIFY_INSTANCES:-8192}
fs.inotify.max_queued_events = ${BOOTSTRAP_INOTIFY_EVENTS:-32768}"
    if [ "$WROTE" = 0 ]; then
        step_skip ready "$f is in place"
    elif [ -z "${BOOTSTRAP_SYSROOT:-}" ]; then
        as_root sysctl -q -p "$f" >/dev/null 2>&1 || warn "could not apply $f now (no sysctl, or a read-only /proc/sys); it applies at boot"
    fi
}

# A UTF-8 system locale, so every session (ssh, cron, a transport that drops LANG) renders the
# box-drawing and glyphs that tmux and Claude Code print. An existing UTF-8 LANG is kept.
step_locale() {
    local f
    f="$(sysf /etc/default/locale)"
    if grep -qiE '^LANG=.*UTF-?8' "$f" 2>/dev/null; then
        step_skip ready "/etc/default/locale is UTF-8"
        return 0
    fi
    if [ -z "${BOOTSTRAP_SYSROOT:-}" ] && ! locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then
        command -v locale-gen >/dev/null 2>&1 && as_root locale-gen C.UTF-8 >/dev/null 2>&1 || true
    fi
    root_write "$f" "LANG=C.UTF-8"
}

# apt has no network timeout of its own: a mirror that stalls mid-fetch can hold the apt lock
# (and every later apt run) indefinitely. Fail fast and retry instead.
step_apt_config() {
    root_write "$(sysf /etc/apt/apt.conf.d/80-dx-timeouts)" '// Written by dx provision: a stalled mirror fails and retries instead of hanging.
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::ftp::Timeout "30";
Acquire::Retries "3";'
    [ "$WROTE" = 1 ] || step_skip ready "apt timeouts are in place"
}

# What the shell, the git hooks and the installer use, plus BOOTSTRAP_APT_EXTRA.
BOOTSTRAP_APT_PACKAGES="${BOOTSTRAP_APT_PACKAGES:-ca-certificates curl git gnupg unzip zsh jq python3 tmux fzf ripgrep fd-find bat tree htop zsh-autosuggestions zsh-syntax-highlighting}"

apt_packages_ready() {
    local p
    for p in $BOOTSTRAP_APT_PACKAGES ${BOOTSTRAP_APT_EXTRA:-}; do pkg_installed "$p" || return 1; done
}

step_packages() {
    if [ "${BOOTSTRAP_FAST:-0}" = 1 ]; then step_skip fast; return 0; fi
    if apt_packages_ready && [ "${BOOTSTRAP_UPGRADE:-0}" != 1 ]; then
        step_skip ready "every base package is installed"
        return 0
    fi
    apt_update
    if [ "${BOOTSTRAP_UPGRADE:-0}" = 1 ]; then
        sub_begin apt-upgrade
        apt_get upgrade
        sub_end
    fi
    sub_begin apt-install
    # shellcheck disable=SC2086
    apt_ensure $BOOTSTRAP_APT_PACKAGES ${BOOTSTRAP_APT_EXTRA:-}
    sub_end
    # Debian and Ubuntu ship fd as fdfind and bat as batcat.
    if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
        as_root ln -sfn "$(command -v fdfind)" /usr/local/bin/fd
    fi
    if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
        as_root ln -sfn "$(command -v batcat)" /usr/local/bin/bat
    fi
}

# ── EC2 extras (--ec2) ───────────────────────────────────────────────────
# Decided from local evidence only (the DMI vendor), never a network probe.
is_ec2() {
    grep -qs 'Amazon EC2' "${BOOTSTRAP_DMI_DIR:-/sys/class/dmi/id}/sys_vendor" \
        || grep -qs 'Amazon EC2' "${BOOTSTRAP_DMI_DIR:-/sys/class/dmi/id}/board_vendor"
}

# EC2's hibernation agent creates a swap file the size of RAM on the root disk at every boot,
# which on a large instance fills the root volume. Nothing here hibernates: stop the agent and
# shrink an oversized root swap file to BOOTSTRAP_SWAP_GB (default 8).
step_ec2_swap() {
    local size max want="${BOOTSTRAP_SWAP_GB:-8}"
    if [ "${BOOTSTRAP_EC2:-0}" != 1 ]; then step_skip off "no --ec2"; return 0; fi
    if ! is_ec2; then step_skip off "not an EC2 machine (DMI says so)"; return 0; fi
    if has_systemd && systemctl list-unit-files hibinit-agent.service 2>/dev/null | grep -q '^hibinit-agent'; then
        as_root systemctl disable --now hibinit-agent.service >/dev/null 2>&1 || warn "could not stop hibinit-agent"
        log "  hibinit-agent disabled"
    fi
    max=$(( ${BOOTSTRAP_SWAP_MAX_GB:-16} * 1024 * 1024 * 1024 ))
    if [ -f /swapfile ] && [ ! -L /swapfile ]; then
        size="$(stat -c %s /swapfile)"
        if [ "$size" -gt "$max" ]; then
            log "  shrinking /swapfile from $((size / 1073741824))G to ${want}G"
            as_root swapoff /swapfile 2>/dev/null || true
            as_root rm -f /swapfile
            as_root fallocate -l "${want}G" /swapfile
            as_root chmod 600 /swapfile
            as_root mkswap /swapfile >/dev/null
            as_root swapon /swapfile
        fi
    fi
}
