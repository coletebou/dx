# shellcheck shell=bash
# docker.sh: the instance-store NVMe steps, Docker from Docker's apt repository, and QEMU binfmt
# handlers so Docker builds and runs images of the other architecture (amd64 on arm64 and back).
# The NVMe steps run first, so Docker's data lands on the instance store from its first start.

# step_nvme_detect: read-only, always. Says what is there and what --nvme would do with it.
step_nvme_detect() {
    local report
    report="$(nvme_report)"
    printf '%s\n' "$report" | sed 's/^/  /'
    NVME_PRESENT=0
    case "$report" in *"instance store: none"*) ;; *) NVME_PRESENT=1 ;; esac
    if [ "$NVME_PRESENT" = 1 ] && [ "${BOOTSTRAP_NVME:-0}" != 1 ]; then
        log "  (rerun with --nvme, or --ec2, to put Docker's data, caches and swap there)"
    fi
}

_nvme_unit() {
    cat <<'EOF'
# Written by dx provision. An instance store is blank after every stop and start: format it again,
# mount it, and bind Docker's data, caches and swap onto it before anything uses them.
[Unit]
Description=dx: Docker data, caches and swap on the local instance-store NVMe
After=local-fs.target
Before=docker.service containerd.service systemd-user-sessions.service
ConditionPathExists=/etc/default/dx-nvme

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/dx-nvme-setup apply

[Install]
WantedBy=multi-user.target
EOF
}

# step_nvme_apply: with --nvme, format (a blank disk only), mount, bind and swap now, and install
# the boot unit that does it again at every boot. Docker and containerd then require that unit,
# so a box whose instance store cannot be set up does not start Docker on the root disk unnoticed.
# _nvme_cache_env_snippet PATH: tell TARGET_USER about their cache directory without ever
# touching their home as root. Written (and its ~/.config created, if missing) entirely with
# as_user, so it follows only symlinks the user already chose for their own home — the same as
# anything else they could do there themselves.
_nvme_cache_env_snippet() {
    local path="$1" snippet="$TARGET_HOME/.config/dx-nvme-cache.sh"
    if as_user mkdir -p "$TARGET_HOME/.config" \
        && printf '# Written by dx provision: your cache lives on the instance store, not the root disk.\nexport XDG_CACHE_HOME=%q\n' "$path" \
            | as_user tee "$snippet" >/dev/null; then
        log "  wrote $snippet: source it (e.g. . $snippet from ~/.zshenv.local) to use it as \$XDG_CACHE_HOME"
    else
        warn "could not write $snippet as $TARGET_USER; set XDG_CACHE_HOME=$path yourself to use it"
    fi
}

step_nvme_apply() {
    local out bound cache unit cache_user=""
    if [ "${BOOTSTRAP_NVME:-0}" != 1 ]; then step_skip off "no --nvme"; return 0; fi
    if [ "${NVME_PRESENT:-0}" != 1 ]; then step_skip none "no instance-store disk here"; return 0; fi
    # A user to get a cache directory ON THE INSTANCE STORE (never a bind onto anything under
    # their home): nvme.sh creates it entirely under NVME_MOUNT, which only root can write to,
    # so nothing here ever resolves a path the user controls.
    [ "${BOOTSTRAP_NVME_CACHE:-1}" != 1 ] || [ "$TARGET_USER" = root ] || cache_user="$TARGET_USER"
    out="$(as_root env NVME_MODELS="$NVME_MODELS" NVME_LABEL="$NVME_LABEL" NVME_MOUNT="$NVME_MOUNT" \
        NVME_BINDS="$NVME_BINDS" NVME_SWAP_GB="$NVME_SWAP_GB" NVME_CACHE_USER="$cache_user" \
        bash "$BOOTSTRAP_LIB/nvme.sh" apply --provisioning)"
    bound="$(printf '%s\n' "$out" | sed -n 's/^binds://p' | tail -n 1)"
    bound="${bound# }"
    cache="$(printf '%s\n' "$out" | sed -n 's/^cache://p' | tail -n 1)"
    log "  on the instance store: ${bound:-nothing}${cache:+, cache at $cache}"
    [ -z "$cache" ] || _nvme_cache_env_snippet "$cache"
    as_root install -D -m 0755 "$BOOTSTRAP_LIB/nvme.sh" "$(sysf /usr/local/sbin/dx-nvme-setup)"
    root_write "$(sysf /etc/default/dx-nvme)" "$(printf '# Written by dx provision; read by /usr/local/sbin/dx-nvme-setup at boot.\nNVME_MODELS=%q\nNVME_LABEL=%q\nNVME_MOUNT=%q\nNVME_BINDS=%q\nNVME_CACHE_USER=%q\nNVME_SWAP_GB=%q\n' \
        "$NVME_MODELS" "$NVME_LABEL" "$NVME_MOUNT" "$bound" "${cache:+$TARGET_USER}" "$NVME_SWAP_GB")"
    if has_systemd; then
        root_write "$(sysf /etc/systemd/system/dx-nvme-setup.service)" "$(_nvme_unit)"
        for unit in docker containerd; do
            root_write "$(sysf "/etc/systemd/system/$unit.service.d/dx-nvme.conf")" "# Written by dx provision: never start on the root disk when the instance store failed.
[Unit]
Requires=dx-nvme-setup.service
After=dx-nvme-setup.service"
        done
        as_root systemctl daemon-reload
        as_root systemctl enable dx-nvme-setup.service >/dev/null 2>&1
        log "  dx-nvme-setup.service enabled (runs at every boot, before Docker)"
    else
        warn "no systemd: the instance store is set up now, but nothing redoes it at boot"
    fi
}

docker_ready() {
    command -v docker >/dev/null 2>&1 && pkg_installed docker-ce && pkg_installed docker-compose-plugin
}

step_docker() {
    local keyring arch
    if [ "${BOOTSTRAP_DOCKER:-1}" != 1 ]; then step_skip off "--no-docker"; return 0; fi
    if docker_ready; then
        _STEP_STATUS=skip-ready
        [ "${BOOTSTRAP_FAST:-0}" != 1 ] || _STEP_STATUS=skip-fast
        log "  Docker is installed: $(docker --version 2>/dev/null)"
    else
        keyring="$(apt_repo_key docker "https://download.docker.com/linux/$OS_ID/gpg" "$PIN_DOCKER_APT_FPR")"
        arch="$(dpkg --print-architecture)"
        root_write /etc/apt/sources.list.d/docker.list \
            "deb [arch=$arch signed-by=$keyring] https://download.docker.com/linux/$OS_ID $OS_CODENAME stable"
        apt_update force
        sub_begin apt-install
        apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sub_end
    fi
    if [ "$TARGET_USER" != root ] && ! id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        as_root usermod -aG docker "$TARGET_USER"
        log "  $TARGET_USER is in the docker group (it applies from the next login)"
    fi
    if has_systemd; then
        as_root systemctl enable --now docker.service >/dev/null 2>&1 || die "docker.service did not start"
        as_root docker info >/dev/null 2>&1 || die "Docker is installed but the daemon does not answer"
    else
        warn "no systemd: Docker is installed but its daemon was not started (a container?)"
    fi
}

step_binfmt() {
    local other
    if [ "${BOOTSTRAP_DOCKER:-1}" != 1 ]; then step_skip off "--no-docker"; return 0; fi
    if is_wsl; then step_skip off "WSL: Windows handles binfmt"; return 0; fi
    case "$(bootstrap_arch)" in x86_64) other=aarch64 ;; *) other=x86_64 ;; esac
    if [ -e "/proc/sys/fs/binfmt_misc/qemu-$other" ]; then
        step_skip ready "qemu-$other is registered"
        return 0
    fi
    apt_ensure qemu-user-static
    if has_systemd && systemctl cat systemd-binfmt.service >/dev/null 2>&1; then
        as_root systemctl restart systemd-binfmt.service || true
    elif command -v update-binfmts >/dev/null 2>&1; then
        as_root update-binfmts --enable >/dev/null 2>&1 || true
    fi
    if [ -e "/proc/sys/fs/binfmt_misc/qemu-$other" ]; then
        log "  qemu-$other registered: Docker can run and build $other images"
    else
        warn "qemu-user-static is installed, but no binfmt handler is registered (no binfmt_misc here?)"
    fi
}
