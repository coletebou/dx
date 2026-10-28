# shellcheck shell=bash
# harness.sh: logging, the step harness with its timing table, readiness markers, privilege
# helpers and verified downloads, shared by every provisioner module.
#
# Strict mode is the caller's (set -Eeuo pipefail). A step is a function run by run_step; a
# command that fails inside it ends the whole run, and the EXIT trap (harness_on_exit) records the
# open step as err-<code>, prints the timing table and writes the failed marker. A step that has
# nothing to do says why with step_skip, and still gets its row.
#
# Variables a caller may set first:
#   BOOTSTRAP_TAG          the log prefix (default: provision)
#   BOOTSTRAP_TIMINGS      a TSV file each row is appended to (default: none)
#   BOOTSTRAP_STATE_DIR    where readiness markers live (default: /var/lib/dx-bootstrap)
#   TARGET_USER, TARGET_HOME   who the per-user steps run as
# Written for bash 3.2 and newer, so the tests run on macOS too.

BOOTSTRAP_TAG="${BOOTSTRAP_TAG:-provision}"
BOOTSTRAP_TIMINGS="${BOOTSTRAP_TIMINGS:-}"
BOOTSTRAP_STATE_DIR="${BOOTSTRAP_STATE_DIR:-/var/lib/dx-bootstrap}"

log()  { printf '[%s] %s\n' "$BOOTSTRAP_TAG" "$*"; }
warn() { printf '[%s] warning: %s\n' "$BOOTSTRAP_TAG" "$*" >&2; }
die()  { printf '[%s] error: %s\n' "$BOOTSTRAP_TAG" "$*" >&2; exit 1; }

# ── the step harness ─────────────────────────────────────────────────────
# Rows, in order: "name<TAB>status<TAB>milliseconds". Statuses: ok, skip-<why> (skip-off: not
# asked for, skip-ready: already in place, skip-fast: the baked-image fast path), err-<code>.
STEP_ROWS=()
_STEP_NAME="" _STEP_STATUS="" _STEP_START_MS=0 _STEP_EPOCH=0
_SUB_NAME="" _SUB_START_MS=0 _RUN_START_MS=0 _STEP_INDEX=""

now_ms() {
    local t="${EPOCHREALTIME:-}"
    if [ -n "$t" ]; then
        t="${t/,/.}"                      # a locale with a decimal comma
        local frac="${t#*.}000"
        printf '%s%s\n' "${t%.*}" "${frac:0:3}"
    else
        printf '%s000\n' "$(date +%s)"
    fi
}

_record_row() {  # _record_row NAME STATUS MS EPOCH [INDEX]: a row (at INDEX, when reserved)
    if [ -n "${5:-}" ]; then STEP_ROWS[$5]="$1	$2	$3"; else STEP_ROWS+=("$1	$2	$3"); fi
    if [ -n "$BOOTSTRAP_TIMINGS" ]; then
        printf '%s\t%s\t%s\t%s\n' "$4" "$3" "$1" "$2" >> "$BOOTSTRAP_TIMINGS" 2>/dev/null || true
    fi
}

step_begin() {  # step_begin NAME: open a step (closing any open one first)
    [ -z "$_STEP_NAME" ] || step_end
    _STEP_NAME="$1" _STEP_STATUS=ok
    _STEP_START_MS="$(now_ms)" _STEP_EPOCH="$(date +%s)"
    [ "$_RUN_START_MS" != 0 ] || _RUN_START_MS="$_STEP_START_MS"
    # The step's row goes before its sub-steps' rows: reserve its place now.
    _STEP_INDEX="${#STEP_ROWS[@]}"
    STEP_ROWS+=("$1	running	0")
}

step_end() {  # step_end: close the open step with its status
    [ -n "$_STEP_NAME" ] || return 0
    sub_end
    local now
    now="$(now_ms)"
    _record_row "$_STEP_NAME" "$_STEP_STATUS" "$((now - _STEP_START_MS))" "$_STEP_EPOCH" "$_STEP_INDEX"
    _STEP_NAME="" _STEP_STATUS=""
}

step_skip() {  # step_skip WHY [MESSAGE]: mark the open step skipped (it still gets its row)
    _STEP_STATUS="skip-$1"
    [ $# -lt 2 ] || log "  skipped: $2"
}

sub_begin() {  # sub_begin NAME: time a part of the open step as "<step> > <NAME>"
    sub_end
    _SUB_NAME="${_STEP_NAME:-root} > $1" _SUB_START_MS="$(now_ms)"
}

sub_end() {
    [ -n "$_SUB_NAME" ] || return 0
    local now
    now="$(now_ms)"
    _record_row "$_SUB_NAME" ok "$((now - _SUB_START_MS))" "$(date +%s)"
    _SUB_NAME=""
}

# run_step NAME FUNC [ARGS...]: FUNC as one timed step. Deliberately not in a conditional
# context: under `cmd || ...` bash ignores set -e inside cmd, so a failing command in the step
# would not stop the run.
run_step() {
    local name="$1"
    shift
    step_begin "$name"
    log "── $name"
    "$@"
    step_end
}

# skip_steps WHY NAME...: a row per step that a mode leaves out, so the table still shows it.
skip_steps() {
    local why="$1" n
    shift
    for n in "$@"; do step_begin "$n"; step_skip "$why"; step_end; done
}

# timing_table: every row, then the total since the first step.
timing_table() {
    local row name status ms total=0
    [ "${#STEP_ROWS[@]}" -gt 0 ] || return 0
    printf '\n%-34s %-12s %9s\n' step status seconds
    for row in "${STEP_ROWS[@]}"; do
        name="${row%%	*}" row="${row#*	}"
        status="${row%%	*}" ms="${row#*	}"
        case "$name" in *" > "*) name="    ${name#* > }" ;; esac
        printf '%-34s %-12s %9s\n' "$name" "$status" "$(fmt_secs "$ms")"
    done
    [ "$_RUN_START_MS" = 0 ] || total=$(( $(now_ms) - _RUN_START_MS ))
    printf '%-34s %-12s %9s\n' "total" "" "$(fmt_secs "$total")"
}

fmt_secs() {  # fmt_secs MS: seconds with one decimal
    local ms="${1:-0}"
    [ "$ms" -ge 0 ] 2>/dev/null || ms=0
    printf '%d.%d' "$((ms / 1000))" "$(((ms % 1000) / 100))"
}

# Cleanup: paths removed at exit, whatever happened.
CLEANUP_PATHS=()
cleanup_add() { CLEANUP_PATHS+=("$1"); }
cleanup_run() {
    local p
    for p in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do
        [ -n "$p" ] && [ "$p" != / ] && rm -rf -- "$p" 2>/dev/null || true
    done
    for p in ${CLEANUP_ROOT_PATHS[@]+"${CLEANUP_ROOT_PATHS[@]}"}; do
        [ -n "$p" ] && [ "$p" != / ] && as_root rm -f -- "$p" 2>/dev/null || true
    done
    CLEANUP_PATHS=() CLEANUP_ROOT_PATHS=()
}

# cleanup_add_root PATH: a root-owned path, removed as root at exit.
CLEANUP_ROOT_PATHS=()
cleanup_add_root() { CLEANUP_ROOT_PATHS+=("$1"); }

# xtrace_off / xtrace_restore: around a line that handles a secret, so a --trace log never
# holds it.
xtrace_off() {
    case "$-" in *x*) _XTRACE_WAS=1; set +x ;; *) _XTRACE_WAS=0 ;; esac
} 2>/dev/null
xtrace_restore() {
    [ "${_XTRACE_WAS:-0}" != 1 ] || set -x
} 2>/dev/null

# harness_on_exit RC: close the open step as failed (when RC is not 0) and clean up. The caller's
# EXIT trap calls this, then prints the table and writes its markers.
harness_on_exit() {
    local rc="$1"
    if [ -n "$_STEP_NAME" ]; then
        [ "$rc" -eq 0 ] || _STEP_STATUS="err-$rc"
        step_end
    fi
    cleanup_run
}

# ── privilege ────────────────────────────────────────────────────────────
is_root() { [ "$(id -u)" -eq 0 ]; }

# as_root CMD...: run CMD as root, through sudo when this is not root. The first use says why.
as_root() {
    if is_root; then "$@"; return; fi
    command -v sudo >/dev/null 2>&1 || die "this needs root and there is no sudo: $*"
    if [ -z "${_SUDO_SAID:-}" ]; then
        _SUDO_SAID=1
        log "sudo: ${BOOTSTRAP_SUDO_REASON:-a system step needs root}"
    fi
    sudo "$@"
}

# install_file SRC DST MODE: SRC installed as root at DST (mode MODE), making DST's directory
# first. `install -D` does this in one step on GNU coreutils, but BSD/macOS install has no -D;
# this works on both, and is what the provisioner itself only ever needs (SRC and DST, no `-D`
# multi-source form).
install_file() {
    as_root mkdir -p "$(dirname -- "$2")"
    as_root install -m "$3" -- "$1" "$2"
}

# The environment a per-user command gets: a clean one, plus proxies when set.
_user_env() {
    local v
    printf '%s\n' "HOME=$TARGET_HOME" "USER=$TARGET_USER" "LOGNAME=$TARGET_USER" \
        "PATH=$TARGET_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin" \
        "LANG=C.UTF-8" "TERM=${TERM:-dumb}"
    for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do
        [ -z "${!v:-}" ] || printf '%s=%s\n' "$v" "${!v}"
    done
}

# as_user CMD...: run CMD as TARGET_USER with that user's HOME.
as_user() {
    if [ "$(id -un)" = "$TARGET_USER" ]; then "$@"; return; fi
    local envs=() line
    while IFS= read -r line; do envs+=("$line"); done < <(_user_env)
    if is_root; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$TARGET_USER" -- env -i "${envs[@]}" "$@"
        else
            su -s /bin/sh "$TARGET_USER" -c "$(printf '%q ' env -i "${envs[@]}" "$@")"
        fi
    else
        as_root -u "$TARGET_USER" env -i "${envs[@]}" "$@"
    fi
}

# as_user_fn FUNC [ARGS...]: run one of this script's functions as TARGET_USER. The functions
# and settings travel inline, so the user needs no read access to this checkout.
as_user_fn() {
    local fn="$1" vars
    shift
    if [ "$(id -un)" = "$TARGET_USER" ]; then "$fn" "$@"; return; fi
    vars="$(compgen -v | grep -E '^(BOOTSTRAP_|PIN_|TARGET_|DX_)' | grep -vE '_AUTHKEY' || true)"
    # shellcheck disable=SC2086  # the names are identifiers, one per word
    as_user bash -c "$( [ -z "$vars" ] || declare -p $vars 2>/dev/null ); $(declare -f); set -Eeuo pipefail; trap cleanup_run EXIT; \"\$@\"" \
        bash "$fn" "$@"
}

# ── files and downloads ──────────────────────────────────────────────────
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

new_tmpdir() {  # new_tmpdir: a fresh directory, removed at exit; its path in TMPD
    TMPD="$(mktemp -d "${TMPDIR:-/tmp}/dx-bootstrap.XXXXXX")"
    cleanup_add "$TMPD"
}

# fetch_verified URL SHA256 FILE: download URL to FILE and stop unless its sha256 is SHA256.
fetch_verified() {
    local url="$1" want="$2" file="$3" got
    [ -n "$want" ] || die "no pinned sha256 for $url"
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$file" "$url" </dev/null \
        || die "download failed: $url"
    got="$(sha256_of "$file")"
    [ "$got" = "$want" ] || die "checksum mismatch for $url (want $want, got $got)"
}

# Architecture as the release assets name it: x86_64 or aarch64.
bootstrap_arch() {
    case "$(uname -m)" in
        x86_64|amd64) echo x86_64 ;;
        aarch64|arm64) echo aarch64 ;;
        *) die "unsupported architecture: $(uname -m) (x86_64 and aarch64 only)" ;;
    esac
}

# pin VAR_PREFIX: the value of <PREFIX>_<arch>, or <PREFIX> when there is no per-arch value.
pin() {
    local name="$1_${BOOTSTRAP_ARCH:-$(bootstrap_arch)}"
    if [ -n "${!name:-}" ]; then printf '%s\n' "${!name}"; else printf '%s\n' "${!1:-}"; fi
}

# ── readiness markers ────────────────────────────────────────────────────
# A marker says "PIN is installed as FILE, whose sha256 was S". It counts only while the pin is
# the same and FILE still hashes to S, so a version bump, a missing file or a changed one all
# mean "install again". A baked image carries its markers, which is what makes the fast path.
ready_file() { printf '%s/ready/%s\n' "$BOOTSTRAP_STATE_DIR" "$1"; }

ready_ok() {  # ready_ok NAME PIN FILE
    local m want_pin="$2" file="$3" pin_line sha_line
    [ "${BOOTSTRAP_FULL:-0}" != 1 ] || return 1       # --full: every marker is ignored
    m="$(ready_file "$1")"
    [ -r "$m" ] && [ -f "$file" ] || return 1
    pin_line="$(sed -n 's/^pin=//p' "$m" | head -n 1)"
    sha_line="$(sed -n 's/^sha256=//p' "$m" | head -n 1)"
    [ "$pin_line" = "$want_pin" ] && [ -n "$sha_line" ] && [ "$(sha256_of "$file")" = "$sha_line" ]
}

ready_mark() {  # ready_mark NAME PIN FILE
    local m sha
    m="$(ready_file "$1")"
    [ -f "$3" ] || die "cannot mark $1 ready: $3 is missing"
    sha="$(sha256_of "$3")"
    if [ -w "$BOOTSTRAP_STATE_DIR" ] || { [ ! -e "$BOOTSTRAP_STATE_DIR" ] && mkdir -p "$BOOTSTRAP_STATE_DIR/ready" 2>/dev/null; }; then
        mkdir -p "${m%/*}"
        printf 'pin=%s\nfile=%s\nsha256=%s\nat=%s\n' "$2" "$3" "$sha" "$(date -u +%FT%TZ)" > "$m"
    else
        as_root mkdir -p "${m%/*}"
        printf 'pin=%s\nfile=%s\nsha256=%s\nat=%s\n' "$2" "$3" "$sha" "$(date -u +%FT%TZ)" \
            | as_root tee "$m" >/dev/null
    fi
}
