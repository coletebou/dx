# shellcheck shell=bash
# overlay.sh: run an overlay's hooks. An overlay is a directory you keep somewhere private (your
# identity, a private repo) that adds to the generic provisioner without forking it:
#
#   overlay.env            sourced once, before the flags are read: BOOTSTRAP_* defaults
#   pre-<phase>.d/*        hooks run before a phase, in name order
#   post-<phase>.d/*       hooks run after it
#   terminfo/*.terminfo    extra terminfo sources, compiled by the toolchains phase
#
# Phases: system, nvme, docker, toolchains, modules, install. A hook is a file whose name starts
# with a letter or digit and does not end in "~" or ".disabled":
#   - an executable file is run, with the environment below;
#   - a non-executable *.sh is sourced in a subshell (set -Eeuo pipefail), with this harness's
#     functions (log, warn, die, as_root, as_user, root_write, apt_ensure) on hand;
#   - anything else (a README, a non-executable file of another kind) is ignored.
# Hooks run in name order (LC_ALL=C), as the provisioner's own user (root in cloud-init mode).
# A hook that exits non-zero stops the run, and the failure names it. The environment:
#   BOOTSTRAP_HOOK         this hook point, e.g. post-toolchains
#   BOOTSTRAP_PHASE        the phase, e.g. toolchains
#   BOOTSTRAP_OVERLAY      the overlay directory
#   BOOTSTRAP_DX_DIR       the dx checkout the provisioner runs from
#   BOOTSTRAP_LIB          its lib/ directory (hook-env.sh there gives an executable bash hook
#                          the same helper functions a sourced one has)
#   BOOTSTRAP_TARGET_USER, BOOTSTRAP_TARGET_HOME   the user being set up
#   BOOTSTRAP_STATE_DIR    markers and logs (default /var/lib/dx-bootstrap)
#   BOOTSTRAP_MODE         interactive or cloud-init
#   BOOTSTRAP_FAST         1 on the baked-image fast path, else 0
#   BOOTSTRAP_INSTALL_MODE dry-run or install
#   BOOTSTRAP_ARCH         x86_64 or aarch64
#   BOOTSTRAP_OS_ID, BOOTSTRAP_OS_CODENAME   ubuntu or debian, and the release codename
# The overlay runs as root on a provisioned box: keep it where only you can write. The provisioner
# refuses an overlay directory, hook directory or hook that anyone can write to.

# shellcheck disable=SC2034  # provision runs the phases in this order
OVERLAY_PHASES="system nvme docker toolchains modules install"

_world_writable() {  # _world_writable PATH: its mode lets anyone write it
    local mode
    mode="$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null)" || return 1
    case "$mode" in *[2367]) return 0 ;; *) return 1 ;; esac
}

# overlay_check DIR: refuse an overlay anyone could have written.
overlay_check() {
    local d="$1" sub
    [ -d "$d" ] || die "no overlay directory: $d"
    if _world_writable "$d"; then die "refusing the overlay $d: it is world-writable"; fi
    for sub in "$d"/*.d; do
        [ -d "$sub" ] || continue
        if _world_writable "$sub"; then die "refusing the overlay: $sub is world-writable"; fi
    done
}

# overlay_hooks DIR POINT: the hooks of one point, in order, one path per line.
overlay_hooks() {
    local dir="$1/$2.d" name f
    [ -d "$dir" ] || return 0
    while IFS= read -r name; do
        f="$dir/$name"
        [ -f "$f" ] || continue
        case "$name" in [!A-Za-z0-9]*|*~|*.disabled) continue ;; esac
        if [ -x "$f" ]; then
            printf '%s\n' "$f"
        else
            case "$name" in *.sh) printf '%s\n' "$f" ;; esac
        fi
    done < <(LC_ALL=C ls -1A "$dir")
}

overlay_env() {  # the environment every hook gets (exported for executable hooks)
    export BOOTSTRAP_HOOK="$1" BOOTSTRAP_PHASE="${1#*-}" BOOTSTRAP_OVERLAY \
        BOOTSTRAP_DX_DIR BOOTSTRAP_LIB BOOTSTRAP_STATE_DIR \
        BOOTSTRAP_TARGET_USER="$TARGET_USER" BOOTSTRAP_TARGET_HOME="$TARGET_HOME" \
        BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-interactive}" BOOTSTRAP_FAST="${BOOTSTRAP_FAST:-0}" \
        BOOTSTRAP_INSTALL_MODE="${BOOTSTRAP_INSTALL_MODE:-dry-run}" \
        BOOTSTRAP_ARCH="${BOOTSTRAP_ARCH:-}" BOOTSTRAP_OS_ID="${OS_ID:-}" \
        BOOTSTRAP_OS_CODENAME="${OS_CODENAME:-}"
}

# _hook_exec HOOK POINT: one hook in a subshell. The caller runs it outside any conditional:
# under `( ... ) || rc=$?` bash ignores set -e inside the subshell, so a sourced hook's failing
# command would not stop it.
_hook_exec() {
    if [ -x "$1" ]; then
        ( overlay_env "$2"; exec "$1" )
    else
        # shellcheck disable=SC1090
        ( overlay_env "$2"; set -Eeuo pipefail; . "$1" )
    fi
}

# overlay_run POINT: every hook of POINT (e.g. pre-system), each as its own timed step.
overlay_run() {
    local point="$1" hook rc errexit=0 hooks
    [ -n "${BOOTSTRAP_OVERLAY:-}" ] || return 0
    hooks="$(overlay_hooks "$BOOTSTRAP_OVERLAY" "$point")"
    [ -n "$hooks" ] || return 0
    while IFS= read -r hook; do
        if _world_writable "$hook"; then die "refusing the hook $hook: it is world-writable"; fi
        step_begin "hook $point/${hook##*/}"
        log "── hook $point/${hook##*/}"
        case "$-" in *e*) errexit=1 ;; esac
        set +e
        _hook_exec "$hook" "$point"
        rc=$?
        [ "$errexit" = 0 ] || set -e
        if [ "$rc" -ne 0 ]; then
            _STEP_STATUS="err-$rc"
            step_end
            die "the overlay hook $point/${hook##*/} failed (exit $rc)"
        fi
        step_end
    done <<EOF
$hooks
EOF
}

# overlay_load_env DIR: the overlay's overlay.env, sourced before the flags (which win over it).
overlay_load_env() {
    [ -f "$1/overlay.env" ] || return 0
    if _world_writable "$1/overlay.env"; then die "refusing $1/overlay.env: it is world-writable"; fi
    # shellcheck disable=SC1091
    . "$1/overlay.env"
}
