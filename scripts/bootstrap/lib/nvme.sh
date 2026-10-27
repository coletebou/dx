#!/usr/bin/env bash
# nvme.sh: find a machine's local instance-store NVMe disks, and put Docker's data, caches and swap
# on one of them. The provisioner sources it; `provision --nvme` also installs it as
# /usr/local/sbin/dx-nvme-setup with a boot unit, because an instance store comes back blank after
# every stop and start, and must be formatted and mounted again before Docker starts.
#
#   dx-nvme-setup detect     the instance-store disks: DEVICE<TAB>SERIAL<TAB>STATE, by serial
#   dx-nvme-setup report     the same, for people, with what apply would do
#   dx-nvme-setup apply      format (a blank disk only), mount, bind, swap
#
# What counts as an instance store is the controller's model string, exactly (EC2 reports
# "Amazon EC2 NVMe Instance Storage"; its EBS volumes report "Amazon Elastic Block Store"),
# never the device number, which the kernel hands out in probe order. A disk is used only when it
# is blank or already carries this tool's filesystem label; a disk with partitions, any other
# filesystem or signature, or a mount somewhere else is left alone. More than one usable disk:
# the one with the lowest serial is used and the rest are left untouched.
#
# Settings (environment, or /etc/default/dx-nvme for the boot unit):
#   NVME_MODELS    exact model strings that mean instance store, separated by | (default: EC2's)
#   NVME_LABEL     the ext4 label this tool formats with and recognizes (default: dx-nvme)
#   NVME_MOUNT     where the disk is mounted (default: /srv/nvme)
#   NVME_BINDS     directories bound onto the disk (default: /var/lib/docker /var/lib/containerd);
#                  DIR:USER makes DIR and its place on the disk USER's, for a per-user cache
#   NVME_SWAP_GB   a swap file of this size on the disk; 0 for none (default: 8)
# Where a disk is mounted comes from /proc/self/mountinfo, which tells the disk's own mount (root
# "/") from the bind mounts made from it; lsblk's MOUNTPOINT column names only one of them.
# Tests point NVME_SYSFS, NVME_DEV and NVME_MOUNTINFO at a fake /sys, /dev and mountinfo, put fake
# lsblk, nvme, blkid, wipefs, mkfs.ext4, mount, chown and swapon first on PATH, and set NVME_ROOT
# (a prefix for every path apply writes) with NVME_TEST_MODE=1, which accepts a file as a device.

NVME_SYSFS="${NVME_SYSFS:-/sys}"
NVME_DEV="${NVME_DEV:-/dev}"
NVME_MODELS="${NVME_MODELS:-Amazon EC2 NVMe Instance Storage}"
NVME_EBS_MODEL="Amazon Elastic Block Store"
NVME_LABEL="${NVME_LABEL:-dx-nvme}"
NVME_MOUNT="${NVME_MOUNT:-/srv/nvme}"
NVME_BINDS="${NVME_BINDS:-/var/lib/docker /var/lib/containerd}"
NVME_SWAP_GB="${NVME_SWAP_GB:-8}"
NVME_ROOT="${NVME_ROOT:-}"
NVME_TEST_MODE="${NVME_TEST_MODE:-0}"
NVME_CONFIG="${NVME_CONFIG:-/etc/default/dx-nvme}"
NVME_MOUNTINFO="${NVME_MOUNTINFO:-/proc/self/mountinfo}"

# Messages go to stderr (and syslog); stdout carries only what a command reports.
nvme_log() {
    printf '[nvme] %s\n' "$*" >&2
    if [ "$NVME_TEST_MODE" != 1 ] && command -v logger >/dev/null 2>&1; then
        logger -t dx-nvme-setup -- "$*" 2>/dev/null || true
    fi
}
nvme_die() { nvme_log "error: $*"; exit 1; }

nvme_trim() {  # nvme_trim TEXT: without leading and trailing whitespace (sysfs pads the model)
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# nvme_id_field DEVICE FIELD: a field of `nvme id-ctrl` (mn, the model; sn, the serial).
nvme_id_field() {
    local out
    command -v nvme >/dev/null 2>&1 || return 0
    out="$(nvme id-ctrl "$1" -o json 2>/dev/null)" || return 0
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$out" | jq -r --arg f "$2" '.[$f] // empty' 2>/dev/null || true
    fi
}

# nvme_disk_field NAME model|serial: from sysfs, else from the controller itself.
nvme_disk_field() {
    local name="$1" what="$2" v="" f
    f="$NVME_SYSFS/block/$name/device/$what"
    [ -r "$f" ] && v="$(nvme_trim "$(cat "$f" 2>/dev/null)")"
    if [ -z "$v" ]; then
        case "$what" in model) f=mn ;; *) f=sn ;; esac
        v="$(nvme_trim "$(nvme_id_field "$NVME_DEV/$name" "$f")")"
    fi
    printf '%s' "$v"
}

# nvme_kind MODEL: instance-store, ebs or other.
nvme_kind() {
    local model="$1" m
    local IFS='|'
    for m in $NVME_MODELS; do
        if [ -n "$m" ] && [ "$model" = "$m" ]; then echo instance-store; return; fi
    done
    if [ "$model" = "$NVME_EBS_MODEL" ]; then echo ebs; else echo other; fi
}

# nvme_mounts NAME: one line per mount of disk NAME itself, "ROOT MOUNTPOINT", from mountinfo by
# the disk's major:minor. ROOT is "/" for the disk's own mount, and the directory a bind mount
# was made from otherwise. (lsblk's MOUNTPOINT shows only one of the places a disk is mounted,
# often a bind target, and cannot tell a bind mount from the disk's own mount.)
nvme_mounts() {
    local devno
    devno="$(cat "$NVME_SYSFS/block/$1/dev" 2>/dev/null || true)"
    [ -n "$devno" ] || return 0
    awk -v d="$devno" '$3 == d { print $4, $5 }' "$NVME_MOUNTINFO" 2>/dev/null || true
}

# nvme_disk_state DEVICE NAME: blank, ours (this tool's ext4, not mounted), mounted:<where>,
# partitioned, in-use:<what> or unreadable. A disk mounted at NVME_MOUNT is mounted:NVME_MOUNT,
# whatever binds were made from it; one mounted anywhere else is mounted:<those places>. Partitions,
# what is stacked on the disk (LVM, RAID) and filesystems or swap come from lsblk.
nvme_disk_state() {
    local json mounts where
    mounts="$(nvme_mounts "$2")"
    if [ -n "$mounts" ]; then
        if printf '%s\n' "$mounts" | grep -qxF "/ $(_nvme_path "$NVME_MOUNT")"; then
            echo "mounted:$NVME_MOUNT"
        else
            where="$(printf '%s\n' "$mounts" | cut -d' ' -f2- | tr '\n' ',')"
            echo "mounted:${where%,}"
        fi
        return
    fi
    command -v jq >/dev/null 2>&1 || { echo unreadable; return; }
    json="$(lsblk -J -p -o NAME,TYPE,FSTYPE,LABEL,MOUNTPOINT "$1" 2>/dev/null)" || { echo unreadable; return; }
    printf '%s' "$json" | jq -r --arg label "$NVME_LABEL" '
        (.blockdevices // [])[0] as $d
        | if $d == null then "unreadable"
          else ([$d | .. | objects | .mountpoint? // empty | select(. != "")]) as $mps
          | if ($mps | length) > 0 then "mounted:" + ($mps | join(","))
            elif (($d.children // []) | length) > 0 then "partitioned"
            elif ($d.fstype // "") == "" and ($d.label // "") == "" then "blank"
            elif $d.fstype == "ext4" and $d.label == $label then "ours"
            else "in-use:" + (if ($d.fstype // "") != "" then $d.fstype else "label " + $d.label end)
            end
          end' 2>/dev/null || echo unreadable
}

# nvme_detect: one line per instance-store disk, DEVICE<TAB>SERIAL<TAB>STATE, sorted by serial.
# With NVME_VERBOSE=1 it also says, on stderr, which NVMe disks it passed over and why.
nvme_detect() {
    local d name dev model kind serial state rows=""
    for d in "$NVME_SYSFS"/block/nvme*; do
        [ -e "$d" ] || continue
        name="${d##*/}"
        case "$name" in
            nvme*c*) continue ;;          # a hidden multipath path, not a disk
            nvme[0-9]*n[0-9]*) ;;
            *) continue ;;
        esac
        dev="$NVME_DEV/$name"
        if [ ! -b "$dev" ] && { [ "$NVME_TEST_MODE" != 1 ] || [ ! -e "$dev" ]; }; then
            [ "${NVME_VERBOSE:-0}" != 1 ] || echo "nvme: $name: no device node" >&2
            continue
        fi
        model="$(nvme_disk_field "$name" model)"
        kind="$(nvme_kind "$model")"
        if [ "$kind" != instance-store ]; then
            [ "${NVME_VERBOSE:-0}" != 1 ] || echo "nvme: $dev: $kind (${model:-no model}), not an instance store" >&2
            continue
        fi
        serial="$(nvme_disk_field "$name" serial)"
        state="$(nvme_disk_state "$dev" "$name")"
        rows="$rows${serial:-~$name}	$dev	${serial:--}	$state
"
    done
    [ -n "$rows" ] || return 0
    printf '%s' "$rows" | LC_ALL=C sort -t '	' -k1,1 | cut -f2-
}

# nvme_select: read nvme_detect lines on stdin; print "DEVICE ACTION" for the one disk to use:
# use (already mounted at NVME_MOUNT), mount (this tool's filesystem) or format (blank). Prints
# nothing when no disk qualifies.
nvme_select() {
    local dev serial state use="" mount="" format=""
    while IFS='	' read -r dev serial state; do
        [ -n "$dev" ] || continue
        case "$state" in
            "mounted:$NVME_MOUNT"|"mounted:$NVME_MOUNT,"*) [ -n "$use" ] || use="$dev" ;;
            ours) [ -n "$mount" ] || mount="$dev" ;;
            blank) [ -n "$format" ] || format="$dev" ;;
        esac
    done
    if [ -n "$use" ]; then echo "$use use"
    elif [ -n "$mount" ]; then echo "$mount mount"
    elif [ -n "$format" ]; then echo "$format format"
    fi
}

# nvme_report: what detect found and what apply would do, one line each.
nvme_report() {
    local found sel dev serial state note
    found="$(nvme_detect)"
    if [ -z "$found" ]; then
        echo "instance store: none (no NVMe disk reports an instance-store model)"
        return 0
    fi
    sel="$(printf '%s\n' "$found" | nvme_select)"
    printf '%s\n' "$found" | while IFS='	' read -r dev serial state; do
        note="left alone"
        case "$sel" in "$dev "*) note="would ${sel#* }" ;; esac
        printf 'instance store: %s serial=%s state=%s (%s)\n' "$dev" "$serial" "$state" "$note"
    done
    [ -n "$sel" ] || echo "instance store: no usable disk (each is in use or not blank)"
}

# ── apply ────────────────────────────────────────────────────────────────
_nvme_path() { printf '%s%s' "$NVME_ROOT" "$1"; }

_nvme_mounted_at() {  # _nvme_mounted_at DIR: something is mounted on DIR
    awk -v m="$1" '$5 == m { found = 1 } END { exit !found }' "$NVME_MOUNTINFO" 2>/dev/null
}

# The disk must still be blank when probed directly (not through udev's cache) right before mkfs.
_nvme_format() {
    local dev="$1" sigs rc=0
    blkid -p "$dev" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || nvme_die "refusing to format $dev: blkid finds a signature on it (status $rc)"
    sigs="$(wipefs --no-act --noheadings "$dev" 2>/dev/null)" || nvme_die "could not inspect $dev with wipefs"
    [ -z "$sigs" ] || nvme_die "refusing to format $dev: wipefs finds signatures"
    nvme_log "formatting blank instance store $dev as ext4 (label $NVME_LABEL)"
    mkfs.ext4 -q -F -L "$NVME_LABEL" -E nodiscard "$dev" || nvme_die "mkfs.ext4 failed on $dev"
}

_nvme_bind_name() { local p="${1#/}"; printf '%s' "${p//\//_}"; }

# _nvme_bind ENTRY PROVISIONING: bind MOUNT/binds/<name> onto ENTRY's directory. ENTRY is DIR, or
# DIR:USER for a directory of USER's (a cache in their home): a missing DIR is created as USER's
# (mode 700), and its place on the disk is given to USER on every run, because after a stop and
# start that place is new again and would otherwise be root's, and the bind would show it as root's
# in USER's home. A plain DIR's place copies DIR's owner and mode. While provisioning, a DIR with
# content is skipped (binding would hide it); at boot it is bound anyway, which hides what was
# written to the root disk while the instance store was missing, without deleting it.
_nvme_bind() {
    local target="${1%%:*}" user="" provisioning="$2" t src owner mode
    case "$1" in *:*) user="${1#*:}" ;; esac
    t="$(_nvme_path "$target")"
    src="$(_nvme_path "$NVME_MOUNT")/binds/$(_nvme_bind_name "$target")"
    if _nvme_mounted_at "$t"; then
        nvme_log "$target is already a mount point; leaving it"
        return 0
    fi
    if [ -L "$t" ]; then
        nvme_log "warning: $target is a symlink; not binding it"
        return 1
    fi
    if [ -d "$t" ] && [ -n "$(ls -A "$t" 2>/dev/null)" ]; then
        if [ "$provisioning" = 1 ]; then
            nvme_log "warning: $target already has data on the root disk; leaving it there (move it, then rerun)"
            return 1
        fi
        nvme_log "warning: $target has data on the root disk; the bind hides it until unmounted"
    fi
    if [ -n "$user" ] && [ ! -e "$t" ]; then
        mkdir -p "$t"
        chown "$user:" "$t" || nvme_die "could not give $target to $user"
        chmod 700 "$t"
    fi
    mkdir -p "$t" "$src"
    if [ -n "$user" ]; then
        chown "$user:" "$src" || nvme_die "could not give $src to $user"
        chmod 700 "$src"
    else
        owner="$(stat -c '%u:%g' "$t" 2>/dev/null || echo 0:0)"
        mode="$(stat -c '%a' "$t" 2>/dev/null || echo 755)"
        chown "$owner" "$src" 2>/dev/null || true
        chmod "$mode" "$src" 2>/dev/null || true
    fi
    mount --bind "$src" "$t" || nvme_die "could not bind $src onto $target"
    nvme_log "bound $target onto the instance store${user:+ (owned by $user)}"
}

_nvme_swap() {
    local file size want
    [ "${NVME_SWAP_GB:-0}" -gt 0 ] 2>/dev/null || return 0
    file="$(_nvme_path "$NVME_MOUNT")/swapfile"
    want=$((NVME_SWAP_GB * 1024 * 1024 * 1024))
    if grep -q "^$file " /proc/swaps 2>/dev/null; then return 0; fi
    size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    if [ "$size" != "$want" ]; then
        rm -f "$file"
        fallocate -l "${NVME_SWAP_GB}G" "$file" || nvme_die "could not allocate $file"
        chmod 600 "$file"
        mkswap "$file" >/dev/null || nvme_die "mkswap failed on $file"
    fi
    swapon "$file" || nvme_die "swapon failed on $file"
    nvme_log "swap: ${NVME_SWAP_GB}G on the instance store"
}

# nvme_apply [--provisioning]: format (blank only), mount, bind and swap. Prints one line on
# stdout, "binds: TARGET...", naming what is now on the disk. With no instance store at all it
# does nothing and succeeds (the machine runs from its root disk); with instance stores that are
# all unusable it fails, so the boot unit keeps Docker from starting on the root disk unnoticed.
nvme_apply() {
    local provisioning=0 found sel dev action mnt target bound=""
    [ "${1:-}" != --provisioning ] || provisioning=1
    found="$(nvme_detect)"
    if [ -z "$found" ]; then
        nvme_log "no instance-store disk; nothing to do"
        echo "binds:"
        return 0
    fi
    sel="$(printf '%s\n' "$found" | nvme_select)"
    [ -n "$sel" ] || nvme_die "instance-store disks found, but none is blank or ours: $(printf '%s' "$found" | tr '\t\n' ' ;')"
    dev="${sel% *}" action="${sel#* }"
    if [ "$NVME_TEST_MODE" != 1 ] && [ ! -b "$dev" ]; then nvme_die "$dev is not a block device"; fi
    mnt="$(_nvme_path "$NVME_MOUNT")"
    case "$action" in
        format) _nvme_format "$dev" ;;
    esac
    if [ "$action" != use ]; then
        mkdir -p "$mnt"
        mount -o defaults,noatime "$dev" "$mnt" || nvme_die "could not mount $dev on $NVME_MOUNT"
        nvme_log "mounted $dev on $NVME_MOUNT"
    fi
    for target in $NVME_BINDS; do
        if _nvme_bind "$target" "$provisioning"; then bound="$bound $target"; fi
    done
    _nvme_swap
    echo "binds:$bound"
}

nvme_main() {
    set -euo pipefail
    # The boot unit's settings; the provisioner passes its own (and writes them here after).
    if [ -r "$NVME_CONFIG" ] && [ "$NVME_TEST_MODE" != 1 ] && [ "${2:-}" != --provisioning ]; then
        # shellcheck disable=SC1090
        . "$NVME_CONFIG"
    fi
    case "${1:-report}" in
        detect) nvme_detect ;;
        report) nvme_report ;;
        apply) [ "$(id -u)" -eq 0 ] || [ "$NVME_TEST_MODE" = 1 ] || nvme_die "apply needs root"
               nvme_apply "${2:-}" ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) nvme_die "unknown command: $1 (detect, report or apply)" ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    nvme_main "$@"
fi
