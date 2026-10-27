# shellcheck shell=bash
# toolchains.sh: the pinned tools (versions.sh), each downloaded from its project's release URL and
# checked against its sha256 before anything is unpacked. System-wide tools go to /usr/local;
# per-user ones (fnm and Node, starship, Claude Code, the tmux plugins) to the target user's home,
# installed as that user. Each records a readiness marker, so a second run (or a box made from a
# baked image) skips what is already in place.

# _unpack FILE DIR: a release archive into DIR.
_unpack() {
    mkdir -p "$2"
    case "$1" in
        *.zip) unzip -q -o "$1" -d "$2" ;;
        *.tar.gz|*.tgz) tar -xzf "$1" -C "$2" ;;
        *) cp "$1" "$2/" ;;
    esac
}

# fetch_release_binary TOOL BINARY DEST: TOOL's pinned asset, verified, with BINARY from it
# installed as DEST (mode 0755). Root writes for a destination this user cannot write.
fetch_release_binary() {
    local tool="$1" bin="$2" dest="$3" url file found
    url="$(pin_url "$tool")"
    new_tmpdir
    file="$TMPD/${url##*/}"
    fetch_verified "$url" "$(pin_sha "$tool")" "$file"
    _unpack "$file" "$TMPD/x"
    found="$(find "$TMPD/x" -type f -name "$bin" | head -n 1)"
    [ -n "$found" ] || die "no $bin inside $url"
    if [ -w "${dest%/*}" ] || { [ ! -e "${dest%/*}" ] && mkdir -p "${dest%/*}" 2>/dev/null; }; then
        install -m 0755 "$found" "$dest"
    else
        as_root install -D -m 0755 "$found" "$dest"
    fi
}

# tool_step TOOL BINARY DEST: one pinned binary, unless its marker says it is in place.
tool_step() {
    local tool="$1" bin="$2" dest="$3" p
    p="$(pin_version "$tool"):$(pin_sha "$tool")"
    if ready_ok "$tool" "$p" "$dest"; then
        _STEP_STATUS=skip-ready
        [ "${BOOTSTRAP_FAST:-0}" != 1 ] || _STEP_STATUS=skip-fast
        return 0
    fi
    fetch_release_binary "$tool" "$bin" "$dest"
    ready_mark "$tool" "$p" "$dest"
    log "  $bin $(pin_version "$tool") -> $dest"
}

step_gitleaks() { tool_step gitleaks gitleaks /usr/local/bin/gitleaks; }
step_lazygit()  { tool_step lazygit lazygit /usr/local/bin/lazygit; }
step_eza()      { tool_step eza eza /usr/local/bin/eza; }
step_delta()    { tool_step delta delta /usr/local/bin/delta; }
step_zoxide()   { tool_step zoxide zoxide /usr/local/bin/zoxide; }

# tmux from its release tarball, built as this user in a temporary tree; only the installed
# binary and man page go through root.
step_tmux() {
    local p dest=/usr/local/bin/tmux src
    p="$PIN_TMUX_VERSION:$PIN_TMUX_SHA256"
    if ready_ok tmux "$p" "$dest"; then
        _STEP_STATUS=skip-ready
        [ "${BOOTSTRAP_FAST:-0}" != 1 ] || _STEP_STATUS=skip-fast
        return 0
    fi
    sub_begin build-deps
    apt_ensure build-essential pkg-config bison libevent-dev libncurses-dev
    sub_begin build
    new_tmpdir
    fetch_verified "$(pin_url tmux)" "$PIN_TMUX_SHA256" "$TMPD/tmux.tar.gz"
    tar -xzf "$TMPD/tmux.tar.gz" -C "$TMPD"
    src="$TMPD/tmux-$PIN_TMUX_VERSION"
    ( cd "$src" && ./configure --prefix=/usr/local >"$TMPD/configure.log" 2>&1 \
        && make -j"$(nproc 2>/dev/null || echo 2)" >"$TMPD/make.log" 2>&1 \
        && make DESTDIR="$TMPD/stage" install >"$TMPD/install.log" 2>&1 ) \
        || { tail -n 20 "$TMPD"/*.log >&2; die "the tmux $PIN_TMUX_VERSION build failed"; }
    as_root install -m 0755 "$TMPD/stage/usr/local/bin/tmux" "$dest"
    as_root install -D -m 0644 "$TMPD/stage/usr/local/share/man/man1/tmux.1" /usr/local/share/man/man1/tmux.1
    sub_end
    ready_mark tmux "$p" "$dest"
    log "  $("$dest" -V) -> $dest"
}

# Ghostty's terminfo, so a session from Ghostty renders and edits properly. From ncurses' pinned
# database (entry "ghostty", plus "xterm-ghostty", the TERM Ghostty sets, as its alias); an
# overlay's terminfo/*.terminfo (say, `infocmp -x xterm-ghostty` exported from Ghostty itself)
# is compiled after, and wins.
step_terminfo() {
    local f overlay_files=""
    if [ -n "${BOOTSTRAP_OVERLAY:-}" ] && [ -d "$BOOTSTRAP_OVERLAY/terminfo" ]; then
        for f in "$BOOTSTRAP_OVERLAY"/terminfo/*.terminfo; do [ -f "$f" ] && overlay_files="$overlay_files $f"; done
    fi
    command -v tic >/dev/null 2>&1 || apt_ensure ncurses-bin
    if [ -z "$overlay_files" ] && infocmp -x xterm-ghostty >/dev/null 2>&1; then
        _STEP_STATUS=skip-ready
        [ "${BOOTSTRAP_FAST:-0}" != 1 ] || _STEP_STATUS=skip-fast
        return 0
    fi
    if ! infocmp -x xterm-ghostty >/dev/null 2>&1; then
        new_tmpdir
        fetch_verified "$(pin_url terminfo)" "$PIN_TERMINFO_SRC_SHA256" "$TMPD/terminfo.src"
        printf '\nxterm-ghostty|Ghostty (the TERM it sets; the ncurses ghostty entry),\n\tuse=ghostty,\n' >> "$TMPD/terminfo.src"
        as_root mkdir -p /etc/terminfo
        as_root tic -x -o /etc/terminfo -e ghostty,xterm-ghostty "$TMPD/terminfo.src" 2>&1 \
            | grep -v 'older tic versions' >&2 || true
    fi
    for f in $overlay_files; do
        as_root tic -x -o /etc/terminfo "$f" 2>&1 | grep -v 'older tic versions' >&2 || true
        log "  compiled $f"
    done
    infocmp -x xterm-ghostty >/dev/null 2>&1 || die "xterm-ghostty still has no terminfo entry"
    log "  xterm-ghostty terminfo in /etc/terminfo"
}

# ── per-user tools (run as TARGET_USER through as_user_fn) ──────────────
fnm_dir() { printf '%s/.local/share/fnm\n' "$1"; }   # fnm_dir HOME

user_install_fnm() {
    fetch_release_binary fnm fnm "$(fnm_dir "$HOME")/fnm"
}

# Node unpacked into the directory fnm itself installs to, so `fnm default` and `fnm use` see it,
# from a tarball checked against its pinned sum (fnm's own download is not checked). Linked into
# ~/.local/bin as well: non-interactive shells (ssh host cmd, cron) do not run `fnm env`.
user_install_node() {
    local fnm b dir
    fnm="$(fnm_dir "$HOME")"
    dir="$fnm/node-versions/v$PIN_NODE_VERSION"
    new_tmpdir
    fetch_verified "$(pin_url node)" "$(pin_sha node)" "$TMPD/node.tar.gz"
    rm -rf "$dir.partial"
    mkdir -p "$dir.partial/installation"
    tar -xzf "$TMPD/node.tar.gz" -C "$dir.partial/installation" --strip-components=1
    rm -rf "$dir"
    mv "$dir.partial" "$dir"
    FNM_DIR="$fnm" "$fnm/fnm" default "$PIN_NODE_VERSION" >/dev/null
    mkdir -p "$HOME/.local/bin"
    for b in node npm npx corepack; do
        [ ! -e "$dir/installation/bin/$b" ] || ln -sfn "$dir/installation/bin/$b" "$HOME/.local/bin/$b"
    done
}

user_install_starship() {
    fetch_release_binary starship starship "$HOME/.local/bin/starship"
}

# Claude Code the way its native installer lays it out: versions/<v>, linked as ~/.local/bin/claude.
user_install_claude() {
    local dest="$HOME/.local/share/claude/versions/$PIN_CLAUDE_VERSION"
    new_tmpdir
    fetch_verified "$(pin_url claude)" "$(pin_sha claude)" "$TMPD/claude"
    mkdir -p "${dest%/*}" "$HOME/.local/bin"
    install -m 0755 "$TMPD/claude" "$dest"
    ln -sfn "$dest" "$HOME/.local/bin/claude"
}

# _plugin_at NAME URL COMMIT: ~/.tmux/plugins/NAME checked out at COMMIT (detached). A checkout
# with local changes is refused rather than overwritten.
_plugin_at() {
    local dir="$HOME/.tmux/plugins/$1" url="$2" commit="$3"
    if [ ! -d "$dir/.git" ]; then
        mkdir -p "$HOME/.tmux/plugins"
        git clone --quiet --filter=blob:none --no-checkout "$url" "$dir" </dev/null
    elif ! git -C "$dir" diff --quiet || ! git -C "$dir" diff --cached --quiet; then
        die "$dir has local changes; not moving it to the pinned commit"
    fi
    git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null \
        || git -C "$dir" fetch --quiet origin "$commit" </dev/null
    git -C "$dir" -c advice.detachedHead=false checkout --quiet --detach "$commit"
    [ "$(git -C "$dir" rev-parse HEAD)" = "$commit" ] || die "$dir is not at $commit"
}

user_install_tpm() {
    _plugin_at tpm https://github.com/tmux-plugins/tpm "$PIN_TPM_COMMIT"
    _plugin_at tmux-sensible https://github.com/tmux-plugins/tmux-sensible "$PIN_TMUX_SENSIBLE_COMMIT"
    _plugin_at tmux-resurrect https://github.com/tmux-plugins/tmux-resurrect "$PIN_TMUX_RESURRECT_COMMIT"
    _plugin_at tmux-continuum https://github.com/tmux-plugins/tmux-continuum "$PIN_TMUX_CONTINUUM_COMMIT"
}

tpm_ready() {
    local spec name commit
    for spec in "tpm:$PIN_TPM_COMMIT" "tmux-sensible:$PIN_TMUX_SENSIBLE_COMMIT" \
        "tmux-resurrect:$PIN_TMUX_RESURRECT_COMMIT" "tmux-continuum:$PIN_TMUX_CONTINUUM_COMMIT"; do
        name="${spec%%:*}" commit="${spec#*:}"
        [ "$(as_user git -C "$TARGET_HOME/.tmux/plugins/$name" rev-parse HEAD 2>/dev/null)" = "$commit" ] || return 1
    done
}

# The file each per-user tool's marker hashes.
user_tool_file() {
    case "$1" in
        fnm) echo "$(fnm_dir "$TARGET_HOME")/fnm" ;;
        node) echo "$(fnm_dir "$TARGET_HOME")/node-versions/v$PIN_NODE_VERSION/installation/bin/node" ;;
        starship) echo "$TARGET_HOME/.local/bin/starship" ;;
        claude) echo "$TARGET_HOME/.local/share/claude/versions/$PIN_CLAUDE_VERSION" ;;
    esac
}

# user_tool_step TOOL: install TOOL as the target user unless its marker says it is in place.
# Markers are per user: user-<name>-<tool>.
user_tool_step() {
    local tool="$1" file p
    file="$(user_tool_file "$tool")"
    p="$(pin_version "$tool"):$(pin_sha "$tool")"
    if ready_ok "user-$TARGET_USER-$tool" "$p" "$file"; then
        _STEP_STATUS=skip-ready
        [ "${BOOTSTRAP_FAST:-0}" != 1 ] || _STEP_STATUS=skip-fast
        return 0
    fi
    as_user_fn "user_install_$tool"
    ready_mark "user-$TARGET_USER-$tool" "$p" "$file"
    log "  $tool $(pin_version "$tool") for $TARGET_USER"
}

step_fnm()      { user_tool_step fnm; }
step_node()     { user_tool_step node; }
step_starship() { user_tool_step starship; }
step_claude()   { user_tool_step claude; }
step_tpm() {
    if tpm_ready; then
        _STEP_STATUS=skip-ready
        [ "${BOOTSTRAP_FAST:-0}" != 1 ] || _STEP_STATUS=skip-fast
        return 0
    fi
    as_user_fn user_install_tpm
    log "  tpm and its plugins at their pinned commits"
}

# Every pinned tool's readiness, for the fast path: all in place means a baked image.
toolchains_ready() {
    local t p
    for t in gitleaks lazygit eza delta zoxide; do
        p="$(pin_version "$t"):$(pin_sha "$t")"
        ready_ok "$t" "$p" "/usr/local/bin/$t" || return 1
    done
    ready_ok tmux "$PIN_TMUX_VERSION:$PIN_TMUX_SHA256" /usr/local/bin/tmux || return 1
    infocmp -x xterm-ghostty >/dev/null 2>&1 || return 1
    for t in fnm node starship claude; do
        p="$(pin_version "$t"):$(pin_sha "$t")"
        ready_ok "user-$TARGET_USER-$t" "$p" "$(user_tool_file "$t")" || return 1
    done
    tpm_ready
}

# verify_pins: download every pinned asset, for both architectures, and compare with versions.sh.
verify_pins() {
    local a t url want got bad=0
    for a in x86_64 aarch64; do
        for t in $PINNED_TOOLS; do
            case "$a:$t" in aarch64:tmux|aarch64:terminfo) continue ;; esac   # one asset for both
            url="$(BOOTSTRAP_ARCH="$a" pin_url "$t")"
            want="$(BOOTSTRAP_ARCH="$a" pin_sha "$t")"
            new_tmpdir
            if ! curl -fsSL --retry 3 -o "$TMPD/a" "$url" </dev/null; then
                printf 'FAIL  %-8s %-9s download failed: %s\n' "$a" "$t" "$url"; bad=1; continue
            fi
            got="$(sha256_of "$TMPD/a")"
            rm -rf "$TMPD"
            if [ "$got" = "$want" ]; then
                printf 'ok    %-8s %-9s %s\n' "$a" "$t" "$url"
            else
                printf 'FAIL  %-8s %-9s want %s got %s\n' "$a" "$t" "$want" "$got"; bad=1
            fi
        done
    done
    return "$bad"
}
