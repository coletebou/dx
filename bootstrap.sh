#!/usr/bin/env bash
# bootstrap.sh: put dx on a fresh machine (macOS, Debian or Ubuntu) in one line.
#
#   curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh | bash
#
# installs git if it is missing (and nothing else), clones dx to ~/.dotfiles, and shows what
# `install.sh --all` would change, changing nothing. Arguments go after `bash -s --`:
#
#   ... | bash -s -- --install               install every component for real
#   ... | bash -s -- --with shell,git,tmux   install just these
#   ... | bash -s -- --provision             a Debian/Ubuntu server: provision it first
#
# Run `... | bash -s -- --help` for every option, and see docs/bootstrap.md.
#
# Safe to pipe into bash: everything below is one { ... } block, which bash reads to the end
# before running any of it, so a download cut short is a syntax error and does nothing.
{
set -euo pipefail

dx_usage() {
    cat <<'EOF'
bootstrap.sh: clone dx and run its installer (a dry run unless you ask for more).

  curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh | bash -s -- [options]

  --install          run install.sh --all for real (default: install.sh --all --dry-run)
  --with LIST        run install.sh --with LIST for real (e.g. shell,git,tmux,claude)
  --identity ID      install.sh's identity (identities/ID; default: example)
  --role ROLE        install.sh's role: local or server (default: local; server with --provision)
  --dir DIR          where the checkout goes (default: ~/.dotfiles)
  --ref REF          a branch or tag to check out in a new clone (default: master)
  --user NAME        when run as root: set up NAME instead (clone into their home, install as them)
  --provision        Debian or Ubuntu: run scripts/bootstrap/provision first; it sets up the
                     box, then runs install.sh itself. Its own options go after a second --:
                     ... | bash -s -- --provision --install -- --hostname box-a --tailscale
  --no-update        use an existing checkout as it is (no fast-forward)
  --plan             say what would happen, and change nothing at all
  -h, --help         this text

It installs git (with apt, or on macOS through the Command Line Tools or Homebrew) only when git
is missing, and uses sudo only for that, saying so first. An existing dx checkout is fast-forwarded
(never merged or reset); an existing directory that is not dx is left alone and the run stops.

Environment: DX_REPO_URL clones from another URL (a fork, or a local path when testing a branch).
EOF
}

dx_say() { printf 'bootstrap: %s\n' "$*"; }
dx_warn() { printf 'bootstrap: warning: %s\n' "$*" >&2; }
dx_die() { printf 'bootstrap: error: %s\n' "$*" >&2; exit "${2:-1}"; }

dx_is_root() { [ "$(id -u)" -eq 0 ]; }

# dx_home_of USER: a user's home directory.
dx_home_of() {
    local h=""
    case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
    if command -v getent >/dev/null 2>&1; then h="$(getent passwd "$1" | cut -d: -f6)"; fi
    if [ -z "$h" ]; then eval "h=~$1"; case "$h" in "~"*) h="" ;; esac; fi
    [ -n "$h" ] && printf '%s\n' "$h"
}

# dx_as_target CMD...: run CMD as the user being set up, with that user's HOME.
dx_as_target() {
    if [ "$DX_USER" = "$(id -un)" ]; then
        HOME="$DX_HOME" "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$DX_USER" -- env HOME="$DX_HOME" USER="$DX_USER" LOGNAME="$DX_USER" "$@"
    else
        sudo -H -u "$DX_USER" env HOME="$DX_HOME" "$@"
    fi
}

dx_git() { GIT_TERMINAL_PROMPT=0 dx_as_target git "$@" </dev/null; }

# Is git really there? On macOS, /usr/bin/git is a stub that asks to install the Command Line
# Tools until they are installed.
dx_have_git() {
    command -v git >/dev/null 2>&1 || return 1
    if [ "$(uname -s)" = Darwin ] && [ "$(command -v git)" = /usr/bin/git ]; then
        xcode-select -p >/dev/null 2>&1 || return 1
    fi
    git --version >/dev/null 2>&1
}

# dx_apt_git [sudo]: apt-get update and install git, quietly; apt's own output only if it fails.
dx_apt_git() {
    local out
    out="$(mktemp)"
    if ! { ${1:+"$1"} env DEBIAN_FRONTEND=noninteractive apt-get update -q \
        && ${1:+"$1"} env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends git ca-certificates; } \
        </dev/null >"$out" 2>&1; then
        tail -n 20 "$out" >&2
        rm -f "$out"
        dx_die "apt could not install git (its last lines are above)"
    fi
    rm -f "$out"
}

dx_ensure_git() {
    dx_have_git && return 0
    case "$(uname -s)" in
        Darwin)
            if command -v brew >/dev/null 2>&1; then
                dx_say "git is missing: installing it with Homebrew"
                if dx_is_root; then dx_as_target brew install git </dev/null; else brew install git </dev/null; fi
            else
                dx_say "git is missing: macOS will ask to install the Command Line Tools (a dialog opens)"
                xcode-select --install >/dev/null 2>&1 || true
                dx_die "finish the Command Line Tools install, then run this again"
            fi
            ;;
        Linux)
            command -v apt-get >/dev/null 2>&1 \
                || dx_die "git is missing and this is not Debian or Ubuntu: install git with your package manager, then run this again"
            if dx_is_root; then
                dx_say "git is missing: installing git and ca-certificates with apt"
                dx_apt_git
            else
                command -v sudo >/dev/null 2>&1 \
                    || dx_die "git is missing, installing it needs root, and there is no sudo: install git, then run this again"
                dx_say "git is missing: installing git and ca-certificates with apt, which needs root (sudo may ask for your password)"
                dx_apt_git sudo
            fi
            ;;
        *) dx_die "git is missing: install it, then run this again" ;;
    esac
    dx_have_git || dx_die "git is still not usable after installing it"
}

# dx_dir_state DIR: missing, empty, dx (a dx checkout: its own git top level, with install.sh
# and the dx plugin marketplace) or other. A symlink is judged by what it points to.
dx_dir_state() {
    local d="$1" top
    if [ ! -e "$d" ] && [ ! -L "$d" ]; then echo missing; return; fi
    if [ -L "$d" ] && [ ! -e "$d" ]; then echo other; return; fi
    [ -d "$d" ] || { echo other; return; }
    if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then echo empty; return; fi
    if [ -f "$d/install.sh" ] && [ -f "$d/.claude-plugin/marketplace.json" ] \
        && grep -q '"name": *"dx"' "$d/.claude-plugin/marketplace.json" 2>/dev/null; then
        top="$(dx_git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
        if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$d" && pwd -P)" ]; then echo dx; return; fi
    fi
    echo other
}

dx_checkout() {
    local state
    state="$(dx_dir_state "$DX_DIR")"
    case "$state" in
        missing|empty)
            dx_say "cloning $DX_URL into $DX_DIR"
            if [ "$state" = missing ]; then dx_as_target mkdir -p "$(dirname "$DX_DIR")"; fi
            if [ -n "$DX_REF" ]; then
                dx_git clone --quiet --branch "$DX_REF" "$DX_URL" "$DX_DIR"
            else
                dx_git clone --quiet "$DX_URL" "$DX_DIR"
            fi
            ;;
        dx)
            if [ "$DX_UPDATE" = 0 ]; then
                dx_say "using the dx checkout in $DX_DIR as it is (--no-update)"
            elif dx_git -C "$DX_DIR" pull --ff-only --quiet; then
                dx_say "updated the dx checkout in $DX_DIR (fast-forward only)"
            else
                dx_warn "could not fast-forward $DX_DIR (local commits, local changes, or no upstream); using it as it is"
            fi
            ;;
        *)
            dx_die "$DX_DIR exists and is not a dx checkout; nothing was changed.
  Move it away, or choose another place with --dir (install.sh then links ~/.dotfiles to it)." 3
            ;;
    esac
    dx_say "dx at $(dx_git -C "$DX_DIR" rev-parse --short HEAD 2>/dev/null || echo '?') in $DX_DIR"
}

dx_main() {
    local a provision=0 plan=0 install=dry-run with="" identity="" role="" user="" dir="" ref="" update=1
    local pargs=() iargs=()
    while [ $# -gt 0 ]; do
        a="$1"
        case "$a" in
            --install) install=all ;;
            --with|--identity|--role|--dir|--ref|--user)
                [ $# -ge 2 ] || dx_die "$a needs a value (see --help)" 2
                case "$a" in
                    --with) install=with with="$2" ;;
                    --identity) identity="$2" ;;
                    --role) role="$2" ;;
                    --dir) dir="$2" ;;
                    --ref) ref="$2" ;;
                    --user) user="$2" ;;
                esac
                shift ;;
            --with=*) install=with with="${a#--with=}" ;;
            --provision) provision=1 ;;
            --no-update) update=0 ;;
            --plan) plan=1 ;;
            -h|--help) dx_usage; return 0 ;;
            --) shift; pargs=("$@"); break ;;
            *) dx_die "unknown argument: $a (see --help)" 2 ;;
        esac
        shift
    done
    [ "$install" != with ] || [ -n "$with" ] || dx_die "--with needs a list of components" 2
    if [ ${#pargs[@]} -gt 0 ] && [ "$provision" = 0 ]; then
        dx_die "arguments after -- go to --provision, which was not given" 2
    fi

    # Who is being set up, and where their checkout goes.
    if [ -n "$user" ] && [ "$user" != "$(id -un)" ]; then
        dx_is_root || dx_die "--user $user needs root (or run this as $user)" 2
    fi
    DX_USER="${user:-$(id -un)}"
    DX_HOME="$(dx_home_of "$DX_USER")" || DX_HOME=""
    if [ -z "$user" ] && [ -n "${HOME:-}" ] && [ "${HOME:-}" != / ]; then DX_HOME="$HOME"; fi
    [ -n "$DX_HOME" ] || dx_die "no home directory for $DX_USER" 2
    case "$dir" in
        "") DX_DIR="$DX_HOME/.dotfiles" ;;
        \~) DX_DIR="$DX_HOME" ;;
        \~/*) DX_DIR="$DX_HOME/${dir:2}" ;;
        /*) DX_DIR="$dir" ;;
        *) DX_DIR="$(pwd -P)/$dir" ;;
    esac
    DX_URL="${DX_REPO_URL:-https://github.com/coletebou/dx.git}"
    DX_REF="$ref" DX_UPDATE="$update"
    [ -z "${DX_REPO_URL:-}" ] || dx_say "DX_REPO_URL is set: cloning from $DX_URL, not GitHub"
    [ -n "$role" ] || { [ "$provision" = 1 ] && role=server; } || true

    # install.sh's arguments, and provision's (which runs install.sh itself).
    case "$install" in
        dry-run) iargs=(--all --dry-run) ;;
        all) iargs=(--all) ;;
        with) iargs=(--with "$with") ;;
    esac
    [ -z "$identity" ] || iargs+=(--identity "$identity")
    [ -z "$role" ] || iargs+=(--role "$role")
    local p=(--user "$DX_USER")
    case "$install" in all) p+=(--install) ;; with) p+=(--with "$with") ;; esac
    [ -z "$identity" ] || p+=(--identity "$identity")
    [ -z "$role" ] || p+=(--role "$role")
    p+=(${pargs[@]+"${pargs[@]}"})

    if [ "$plan" = 1 ]; then
        dx_say "plan (nothing changes):"
        if dx_have_git; then dx_say "  git: present"; else dx_say "  git: would be installed"; fi
        case "$(dx_dir_state "$DX_DIR")" in
            missing|empty) dx_say "  would clone $DX_URL${DX_REF:+ ($DX_REF)} into $DX_DIR" ;;
            dx) if [ "$update" = 1 ]; then dx_say "  would fast-forward the dx checkout in $DX_DIR"; else dx_say "  would use $DX_DIR as it is"; fi ;;
            *) dx_say "  would stop: $DX_DIR exists and is not a dx checkout" ;;
        esac
        if [ "$provision" = 1 ]; then
            dx_say "  would run, as $(id -un): $DX_DIR/scripts/bootstrap/provision ${p[*]}"
        else
            dx_say "  would run, as $DX_USER: $DX_DIR/install.sh ${iargs[*]}"
        fi
        return 0
    fi

    dx_ensure_git
    dx_checkout

    if [ "$provision" = 1 ]; then
        dx_say "provisioning: $DX_DIR/scripts/bootstrap/provision ${p[*]}"
        bash "$DX_DIR/scripts/bootstrap/provision" "${p[@]}" </dev/null
        return
    fi

    dx_say "running install.sh ${iargs[*]} as $DX_USER"
    dx_as_target bash "$DX_DIR/install.sh" "${iargs[@]}" </dev/null
    if [ "$install" = dry-run ]; then
        dx_say "that was a dry run: nothing in $DX_HOME changed apart from the checkout itself."
        dx_say "to apply it: bash $DX_DIR/bootstrap.sh --install   (or --with shell,git,...)"
    fi
}

dx_main "$@"
}
