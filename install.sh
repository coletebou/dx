#!/usr/bin/env bash
# shellcheck disable=SC2088  # the messages name paths with a literal ~ on purpose
# install.sh — link this repo's dotfiles and agent tooling into $HOME, one
# component at a time.
#
#   ./install.sh --list                       the components, and what each installs
#   ./install.sh --all --dry-run              every change it would make, making none
#   ./install.sh --all                        every component except schedules, music-video, node-tools, github-kit and manager
#   ./install.sh --with shell,git,claude      just these
#   ./install.sh --with schedules             the background jobs (cc-park, dream, tmux autosave,
#                                             and the dotsync timer when sync is installed)
#   ./install.sh --with github-kit --target ~/code/repo   the GitHub repo kit into that repo's .github/
#   ./install.sh --with manager               point Drover's fleet manager at this identity's overlay
#   ./install.sh --installed                  again, the components earlier runs installed here
#
# Options:
#   --identity ID   identities/<ID>/ supplies your git identity, host labels, Claude rules and
#                   shell settings (default: the one ~/.df-profile names, else "example")
#   --role ROLE     local (a workstation) or server (default: ~/.df-profile's, else local)
#   --replace-dotfiles  move an existing ~/.dotfiles that is not this checkout into the backup
#   --target DIR    github-kit: the git repository whose .github/ gets the kit (github-kit/README.md)
#   --installed     add the components earlier runs installed on this machine (each real run
#                   records them in ~/.local/state/dx/components); dotsync reruns this after a pull
#
# The shell, hooks and schedules find everything through ~/.dotfiles, so a checkout anywhere
# else gets ~/.dotfiles linked to it. Re-running is safe: what is already in place is left
# alone. Anything a run replaces is MOVED to ~/.dotfiles-backup/<time>/ first (with a
# changes.jsonl of what happened), never deleted. Needs bash (3.2 is fine), git, and jq for
# the generated Claude Code settings.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ALL_COMPONENTS="shell git tmux claude codex session worktrees memory review sync toolbox ghostty vscode brew music-video node-tools schedules github-kit manager"
DEFAULT_ALL="shell git tmux claude codex session worktrees memory review sync toolbox ghostty vscode brew"
# Which components this machine installed, so `--installed` (what dotsync runs after a pull)
# reinstalls exactly those.
RECORD_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/dx/components"

describe() {
    case "$1" in
        shell)     echo "zsh entry points (zshenv, zshrc, aliases, zprofile, profile), the starship prompt, ~/.df-profile" ;;
        git)       echo "global git config with identity routing, the global ignore file, gitleaks pre-commit and pre-push hooks" ;;
        tmux)      echo "tmux.conf and its status helpers, Claude/Codex resume after tmux-resurrect, tmux-archive and tmux-organize" ;;
        claude)    echo "Claude Code: generated settings.json (hooks, statusline), a CLAUDE.md rules stub, MCP servers, claude-backup and agent-skills-sync" ;;
        codex)     echo "Codex: AGENTS.md rules and hooks.json, a config.toml seeded once, the codex-subagents and codex-transcripts skills" ;;
        session)   echo "cc-park and cc-handoff, with their skills" ;;
        worktrees) echo "wt-helper, pw, stack-branches and stack-claude, with their skills" ;;
        memory)    echo "reflections, dream, session-analyzer, claude-consolidate, memory-canary and codex-memory-bridge, with their skills" ;;
        review)    echo "autoreview-pair and the adversarial-review, mcp-agent-safety and fable-second-opinion skills" ;;
        sync)      echo "dotsync, dotsync-doctor, dotsync-commit-message and codesync: this checkout and every repository under ~/code in sync across your machines" ;;
        toolbox)   echo "the disk-reclaim and shipped-but-open skills" ;;
        ghostty)   echo "the Ghostty config, and the xterm-ghostty terminfo where it is missing" ;;
        vscode)    echo "VS Code user settings (Prettier off), and how to install the recommended extensions" ;;
        brew)      echo "~/.Brewfile, for brew bundle --global (installs nothing itself)" ;;
        music-video) echo "the music-video skill (song and video pipeline; paid API keys; not in --all)" ;;
        node-tools) echo "the pinned global Node CLIs (codex, pnpm, tsx, ...) from node-tools/'s lock, via npm ci (Node 24; not in --all)" ;;
        schedules) echo "launchd (macOS) or systemd user (Linux) jobs: cc-park autopark, nightly dream, tmux autosave, hourly dotsync (not in --all)" ;;
        github-kit) echo "issue forms, a PR template, labels and workflows, copied into the .github/ of the repo --target names (not in --all)" ;;
        manager)   echo "a Drover setting naming identities/<id>/openclaw-manager as its fleet manager's overlay (not in --all)" ;;
    esac
}

usage() {
    awk 'NR == 1 || /^# shellcheck/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
say()  { printf '%s\n' "$*"; }

# ── arguments ────────────────────────────────────────────────────────────
WITH="" DRY_RUN=0 LIST=0 IDENTITY="" ROLE="" REPLACE_DOTFILES=0 TARGET="" INSTALLED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --with)       [ $# -ge 2 ] || die "--with needs a list"; WITH="$WITH,$2"; shift 2 ;;
        --with=*)     WITH="$WITH,${1#--with=}"; shift ;;
        --all)        WITH="$WITH,$(printf '%s' "$DEFAULT_ALL" | tr ' ' ',')"; shift ;;
        --identity)   [ $# -ge 2 ] || die "--identity needs a name"; IDENTITY="$2"; shift 2 ;;
        --identity=*) IDENTITY="${1#--identity=}"; shift ;;
        --role)       [ $# -ge 2 ] || die "--role needs local or server"; ROLE="$2"; shift 2 ;;
        --role=*)     ROLE="${1#--role=}"; shift ;;
        --dry-run|-n) DRY_RUN=1; shift ;;
        --list)       LIST=1; shift ;;
        --replace-dotfiles) REPLACE_DOTFILES=1; shift ;;
        --target)     [ $# -ge 2 ] || die "--target needs a directory"; TARGET="$2"; shift 2 ;;
        --target=*)   TARGET="${1#--target=}"; shift ;;
        --installed)  INSTALLED=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown argument: $1 (see --help)" ;;
    esac
done

if [ "$LIST" -eq 1 ]; then
    for c in $ALL_COMPONENTS; do printf '  %-11s %s\n' "$c" "$(describe "$c")"; done
    exit 0
fi

if [ "$INSTALLED" -eq 1 ]; then
    recorded="$( [ -r "$RECORD_FILE" ] && tr -cs 'a-z-' ',' < "$RECORD_FILE" || true)"
    [ -n "$(printf '%s' "$recorded" | tr -d ',')" ] \
        || die "--installed: no components recorded on this machine yet; run ./install.sh --with <components> once"
    WITH="$WITH,$recorded"
fi

# The components asked for, deduplicated, in the canonical order.
SELECTED=""
for c in $(printf '%s' "$WITH" | tr ',' ' '); do
    case " $ALL_COMPONENTS " in *" $c "*) ;; *) die "unknown component: $c (see --list)" ;; esac
done
for c in $ALL_COMPONENTS; do
    case ",$WITH," in *",$c,"*) SELECTED="$SELECTED $c" ;; esac
done
if [ -z "$SELECTED" ]; then
    usage
    printf '\nPick components with --with a,b or --all:\n'
    for c in $ALL_COMPONENTS; do printf '  %-11s %s\n' "$c" "$(describe "$c")"; done
    exit 2
fi
selected() { case " $SELECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Identity and role: flags, else what the last install recorded, else the defaults.
profile_value() {
    [ -r "$HOME/.df-profile" ] || return 0
    sed -n "s/^export $1=//p" "$HOME/.df-profile" | head -n 1
}
[ -n "$IDENTITY" ] || IDENTITY="$(profile_value DF_IDENTITY)"
[ -n "$IDENTITY" ] || IDENTITY=example
[ -n "$ROLE" ] || ROLE="$(profile_value DF_ROLE)"
[ -n "$ROLE" ] || ROLE=local
case "$IDENTITY" in *[!A-Za-z0-9._-]*|"") die "bad identity name: $IDENTITY" ;; esac
[ -d "$DOTFILES_DIR/identities/$IDENTITY" ] \
    || die "no identity '$IDENTITY': copy identities/example to identities/$IDENTITY first"
case "$ROLE" in local|server) ;; *) die "role must be local or server, not: $ROLE" ;; esac

# ── recording changes ────────────────────────────────────────────────────
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$HOME/.dotfiles-backup/$STAMP"
CHANGES=0

json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
record() {  # record ACTION DEST [DETAIL]
    CHANGES=$((CHANGES + 1))
    [ "$DRY_RUN" -eq 1 ] && return 0
    mkdir -p "$BACKUP_DIR"
    printf '{"at":"%s","action":"%s","dest":"%s","detail":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$(json_str "$2")" "$(json_str "${3:-}")" >> "$BACKUP_DIR/changes.jsonl"
}
tilde() { case "$1" in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# Move whatever is at DEST into the backup dir, keeping its path under $HOME.
backup() {
    local dest="$1" rel
    rel="${dest#"$HOME"/}"
    [ "$rel" = "$dest" ] && rel="abs${dest}"
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] would move $(tilde "$dest") to the backup"
        return 0
    fi
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    mv "$dest" "$BACKUP_DIR/$rel"
    record backup "$dest" "$BACKUP_DIR/$rel"
}

# A DEST whose nearest existing parent resolves into this checkout (say ~/.local/bin is a link
# to its scripts/) would make a run write into the repo, or move a source to the backup and
# link it to itself. Such a DEST is left alone.
into_checkout() {  # into_checkout DEST
    local dir
    dir="$(dirname "$1")"
    while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
    dir="$(cd "$dir" && pwd -P)" || return 1
    case "$dir/" in "$DOTFILES_DIR"/*) return 0 ;; esac
    return 1
}

# link SRC DEST: DEST becomes a symlink to SRC, unless it already is one.
link() {
    local src="$1" dest="$2"
    [ -e "$src" ] || die "missing in this checkout: $src"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
        return 0
    fi
    if into_checkout "$dest"; then
        warn "$(tilde "$dest") is inside this checkout (a linked parent directory); leaving it alone"
        return 0
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        backup "$dest"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] would link $(tilde "$dest") -> $(tilde "$src")"
        CHANGES=$((CHANGES + 1))
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    ln -s "$src" "$dest"
    say "  linked $(tilde "$dest")"
    record link "$dest" "$src"
}

# generate DEST TMPFILE: install a generated file, if it differs from what is there.
# Consumes TMPFILE.
generate() {
    local dest="$1" tmp="$2"
    if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 0
    fi
    if into_checkout "$dest"; then
        warn "$(tilde "$dest") is inside this checkout (a linked parent directory); leaving it alone"
        rm -f "$tmp"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -e "$dest" ]; then
            say "  [dry-run] would rewrite $(tilde "$dest") (the current one goes to the backup)"
        else
            say "  [dry-run] would create $(tilde "$dest")"
        fi
        rm -f "$tmp"
        CHANGES=$((CHANGES + 1))
        return 0
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        backup "$dest"
    fi
    mkdir -p "$(dirname "$dest")"
    mv "$tmp" "$dest"
    say "  wrote $(tilde "$dest")"
    record generate "$dest"
}

# seed SRC DEST: copy SRC to DEST once, for a tool that writes to its own config file (a link
# would make it write into this checkout). A DEST that exists, edited or not, is left alone.
seed() {
    local src="$1" dest="$2"
    [ -e "$src" ] || die "missing in this checkout: $src"
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        cmp -s "$src" "$dest" \
            || say "  note: kept your $(tilde "$dest"); $(tilde "$src") holds this repo's defaults, to merge by hand"
        return 0
    fi
    if into_checkout "$dest"; then
        warn "$(tilde "$dest") is inside this checkout (a linked parent directory); leaving it alone"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] would create $(tilde "$dest") (a copy of $(tilde "$src"))"
        CHANGES=$((CHANGES + 1))
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    say "  wrote $(tilde "$dest") (a copy, not a link: the tool writes to it)"
    record seed "$dest" "$src"
}

link_bins() {  # link_bins FILE...: each into ~/.local/bin under its own name
    local f
    for f in "$@"; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        link "$f" "$HOME/.local/bin/$(basename "$f")"
    done
}

# Skills go into ~/.claude/skills/<name>, one link each. A ~/.claude/skills that is itself a
# symlink belongs to some other setup: linking inside it would write into that tree.
link_skills() {  # link_skills PLUGIN...
    local p s
    if [ -L "$HOME/.claude/skills" ]; then
        warn "~/.claude/skills is a symlink (to $(readlink "$HOME/.claude/skills")); not linking skills into it"
        return 0
    fi
    for p in "$@"; do
        for s in "$DOTFILES_DIR/plugins/$p/skills"/*/; do
            [ -f "$s/SKILL.md" ] || continue
            s="${s%/}"
            link "$s" "$HOME/.claude/skills/$(basename "$s")"
        done
    done
}

need() {  # need TOOL WHY: a warning, not a stop, when a tool is missing
    command -v "$1" >/dev/null 2>&1 || warn "$1 not found: $2"
}

# ── ~/.dotfiles ──────────────────────────────────────────────────────────
ensure_dotfiles_link() {
    if [ "$HOME/.dotfiles" -ef "$DOTFILES_DIR" ]; then
        return 0
    fi
    if [ -e "$HOME/.dotfiles" ] || [ -L "$HOME/.dotfiles" ]; then
        [ "$REPLACE_DOTFILES" -eq 1 ] || die "~/.dotfiles exists and is not this checkout ($DOTFILES_DIR).
  Move it away, clone this repo to ~/.dotfiles, or rerun with --replace-dotfiles to move it into the backup."
    fi
    link "$DOTFILES_DIR" "$HOME/.dotfiles"
}

# ── components ───────────────────────────────────────────────────────────
c_shell() {
    local tmp machine
    # shellcheck source=base/machine-id.sh
    . "$DOTFILES_DIR/base/machine-id.sh"
    machine="$(df_resolve_machine_id "" "$(profile_value DF_MACHINE)")"
    tmp="$(mktemp)"
    printf '%s\n' "# Written by ~/.dotfiles/install.sh: which identity and role this machine runs." \
        "export DF_MACHINE=$machine" "export DF_IDENTITY=$IDENTITY" "export DF_ROLE=$ROLE" > "$tmp"
    generate "$HOME/.df-profile" "$tmp"
    link "$DOTFILES_DIR/zshenv" "$HOME/.zshenv"
    link "$DOTFILES_DIR/zshrc" "$HOME/.zshrc"
    link "$DOTFILES_DIR/aliases" "$HOME/.aliases"
    link "$DOTFILES_DIR/zprofile.$ROLE" "$HOME/.zprofile"
    link "$DOTFILES_DIR/profile.$ROLE" "$HOME/.profile"
    link "$DOTFILES_DIR/base/starship.toml" "$HOME/.config/starship.toml"
    need zsh "the shell config is for zsh"
    need starship "the prompt falls back to zsh's default"
}

c_git() {
    local tmp name="" email="" local_cfg="$HOME/.gitconfig.local"
    # An identity in the ~/.gitconfig this replaces is carried into ~/.gitconfig.local, which
    # git reads last, so commits keep it. A field ~/.gitconfig.local already sets is never
    # overwritten, so that file only ever gains keys.
    if [ -f "$HOME/.gitconfig" ] && [ ! -L "$HOME/.gitconfig" ]; then
        name="$(git config --file "$HOME/.gitconfig" --get user.name 2>/dev/null || true)"
        email="$(git config --file "$HOME/.gitconfig" --get user.email 2>/dev/null || true)"
    fi
    [ -n "$(git config --file "$local_cfg" --get user.name 2>/dev/null || true)" ] && name=""
    [ -n "$(git config --file "$local_cfg" --get user.email 2>/dev/null || true)" ] && email=""
    link "$DOTFILES_DIR/base/gitconfig.base" "$HOME/.gitconfig"
    if [ -n "$name$email" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  [dry-run] would keep your git identity (${email:-$name}) in ~/.gitconfig.local"
            CHANGES=$((CHANGES + 1))
        else
            [ -n "$name" ] && git config --file "$local_cfg" user.name "$name"
            [ -n "$email" ] && git config --file "$local_cfg" user.email "$email"
            say "  kept your git identity in ~/.gitconfig.local"
            record git-identity "$local_cfg" "${email:-$name}"
        fi
    fi
    tmp="$(mktemp)"
    printf '%s\n' "# Written by ~/.dotfiles/install.sh: the commit identity of identity '$IDENTITY'." \
        "[include]" "	path = ~/.dotfiles/identities/$IDENTITY/gitconfig" > "$tmp"
    generate "$HOME/.gitconfig.identity" "$tmp"
    link "$DOTFILES_DIR/base/git/ignore" "$HOME/.config/git/ignore"
    need gitleaks "the pre-commit and pre-push hooks refuse to run without it"
}

c_tmux() {
    link "$DOTFILES_DIR/base/tmux.conf" "$HOME/.tmux.conf"
    link_bins "$DOTFILES_DIR"/plugins/tmux/bin/* "$DOTFILES_DIR/scripts/tmux-resurrect-claude-save" \
        "$DOTFILES_DIR/scripts/tmux-resurrect-claude-restore" "$DOTFILES_DIR/scripts/tmux-resurrect-autosave"
    link_skills tmux
    need tmux "the tmux config needs tmux 3.4 or newer"
    need jq "tmux-archive and tmux-apply-plan use it"
    [ -d "$HOME/.tmux/plugins/tpm" ] \
        || say "  note: tmux plugins need TPM: git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm, then prefix + I"
}

merge_layers() {  # merge_layers OUT FILTER LAYER...: jq-merge the layers that exist
    local out="$1" filter="$2" layers="" l
    shift 2
    for l in "$@"; do [ -f "$l" ] && layers="$layers
$l"; done
    # jq -s with no files would read stdin and hang.
    [ -n "$layers" ] || return 1
    # The layer paths come from this checkout and $HOME: one per line, no newlines in them.
    local IFS='
'
    # shellcheck disable=SC2086
    jq -s "$filter" $layers > "$out"
}

c_claude() {
    local tmp
    # Linked only: neither runs unless you run it.
    link_bins "$DOTFILES_DIR/scripts/claude-backup" "$DOTFILES_DIR/scripts/agent-skills-sync"
    if ! command -v jq >/dev/null 2>&1; then
        warn "jq not found: skipping the generated Claude Code settings (install jq and rerun)"
        return 0
    fi
    tmp="$(mktemp)"
    merge_layers "$tmp" "$(cat "$DOTFILES_DIR/scripts/lib/agent-settings.jq")" \
        "$DOTFILES_DIR/base/claude/settings.base.json" \
        "$DOTFILES_DIR/roles/$ROLE/claude/settings.json" \
        "$DOTFILES_DIR/identities/$IDENTITY/claude/common.settings.json" \
        "$DOTFILES_DIR/claude/settings.local.json" \
        || die "could not merge the Claude Code settings layers"
    generate "$HOME/.claude/settings.json" "$tmp"

    tmp="$(mktemp)"
    {
        printf '%s\n' "# Generated by ~/.dotfiles/install.sh: edit the files it imports, then rerun it." "" \
            "@~/.dotfiles/base/claude/CLAUDE.base.md"
        if [ -f "$DOTFILES_DIR/identities/$IDENTITY/claude/common.CLAUDE.md" ]; then
            printf '%s\n' "@~/.dotfiles/identities/$IDENTITY/claude/common.CLAUDE.md"
        fi
    } > "$tmp"
    generate "$HOME/.claude/CLAUDE.md" "$tmp"

    tmp="$(mktemp)"
    merge_layers "$tmp" 'reduce .[] as $l ({}; . * $l)' \
        "$DOTFILES_DIR/base/claude/mcp.base.json" \
        "$DOTFILES_DIR/roles/$ROLE/claude/mcp.extra.json" \
        "$DOTFILES_DIR/identities/$IDENTITY/claude/mcp.extra.json" \
        "$DOTFILES_DIR/claude/mcp.local.json" \
        || die "could not merge the MCP layers"
    generate "$HOME/.claude/mcp.json" "$tmp"
    register_mcp
    need python3 "the Claude Code hooks are Python"
}

# Each MCP server becomes a user-scope server through Claude Code's own CLI (never by editing
# ~/.claude.json), once, and only when its command exists here.
register_mcp() {
    local name spec cmd
    [ -f "$HOME/.claude/mcp.json" ] || return 0
    if ! command -v claude >/dev/null 2>&1; then
        say "  note: claude not found; register the servers in ~/.claude/mcp.json later with: claude mcp add-json --scope user <name> '<json>'"
        return 0
    fi
    for name in $(jq -r '.mcpServers // {} | keys[]' "$HOME/.claude/mcp.json"); do
        spec="$(jq -c --arg n "$name" '.mcpServers[$n]' "$HOME/.claude/mcp.json")"
        cmd="$(jq -r '.command // empty' <<<"$spec")"
        if [ -n "$cmd" ] && ! command -v "$cmd" >/dev/null 2>&1; then
            say "  note: MCP server $name skipped: $cmd is not installed"
            continue
        fi
        claude mcp get "$name" >/dev/null 2>&1 && continue
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  [dry-run] would register the MCP server $name"
            CHANGES=$((CHANGES + 1))
            continue
        fi
        if claude mcp add-json --scope user "$name" "$spec" >/dev/null; then
            say "  registered the MCP server $name"
            record mcp "$name"
        else
            warn "could not register the MCP server $name"
        fi
    done
}

c_codex() {
    local home="${CODEX_HOME:-$HOME/.codex}"
    link_skills codex
    # Codex keeps its sign-in in this directory: one created here is private to you.
    if [ ! -e "$home" ] && [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$home" && chmod 700 "$home"
    fi
    link "$DOTFILES_DIR/codex/AGENTS.md" "$home/AGENTS.md"
    link "$DOTFILES_DIR/codex/hooks.json" "$home/hooks.json"
    seed "$DOTFILES_DIR/codex/config.toml" "$home/config.toml"
}

c_session() {
    link_bins "$DOTFILES_DIR"/plugins/session/bin/* "$DOTFILES_DIR/scripts/cc-handoff"
    link_skills session
    need tmux "cc-park and cc-handoff drive sessions in tmux"
}

c_worktrees() {
    link_bins "$DOTFILES_DIR"/plugins/worktrees/bin/* "$DOTFILES_DIR/scripts/wt-helper" \
        "$DOTFILES_DIR/scripts/claude-worktree-hook"
    link_skills worktrees
}

c_memory() {
    local s
    for s in reflections dream dream-prep dream-held-nights session-analyzer claude-consolidate \
        memory-canary codex-memory-bridge; do
        link_bins "$DOTFILES_DIR/scripts/$s"
    done
    link_skills memory
    for s in memory-homes memory-canonicals dreaming; do
        [ -f "$DOTFILES_DIR/claude/$s.conf" ] \
            || say "  note: copy claude/$s.conf.example to claude/$s.conf to configure the memory tools (docs/memory/README.md)"
    done
}

c_review() {
    link_bins "$DOTFILES_DIR/scripts/autoreview-pair"
    link_skills review
}

c_toolbox() {
    link_skills toolbox
    need python3 "disk-reclaim's survey is Python"
    need glab "shipped-but-open reads GitLab through glab"
}

c_music_video() {
    link_skills music-video
    need ffmpeg "music-video mixes, masters and encodes with ffmpeg"
    need node "music-video renders frames in headless Chrome through Node"
}

c_ghostty() {
    link "$DOTFILES_DIR/ghostty/config" "$HOME/.config/ghostty/config"
    # SSH sessions from Ghostty arrive with TERM=xterm-ghostty, and where no terminfo entry has
    # that name ncurses apps garble keys. Compile it for this user (no sudo), once.
    if ! command -v tic >/dev/null 2>&1 || ! command -v infocmp >/dev/null 2>&1; then
        say "  note: tic or infocmp not found: install ncurses to add the xterm-ghostty terminfo"
    elif ! infocmp -x xterm-ghostty >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  [dry-run] would compile the xterm-ghostty terminfo into ~/.terminfo"
            CHANGES=$((CHANGES + 1))
        elif tic -x -o "$HOME/.terminfo" "$DOTFILES_DIR/ghostty/ghostty.terminfo" 2>/dev/null; then
            say "  compiled the xterm-ghostty terminfo into ~/.terminfo"
            record terminfo "$HOME/.terminfo" xterm-ghostty
        else
            warn "could not compile the xterm-ghostty terminfo (tic -x ghostty/ghostty.terminfo)"
        fi
    fi
}

c_vscode() {
    local dir
    case "$(uname -s)" in
        Darwin) dir="$HOME/Library/Application Support/Code/User" ;;
        *)      dir="${XDG_CONFIG_HOME:-$HOME/.config}/Code/User" ;;
    esac
    # VS Code writes through the link, so a setting changed in its UI lands in this checkout.
    link "$DOTFILES_DIR/vscode/settings.jsonc" "$dir/settings.json"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        say "  note: on WSL, VS Code reads its user settings on the Windows side: copy vscode/settings.jsonc there"
    fi
    if command -v code >/dev/null 2>&1; then
        say "  note: install the recommended extensions with: jq -r '.recommendations[]' ~/.dotfiles/vscode/extensions.json | xargs -n 1 code --install-extension"
    else
        say "  note: VS Code's code command is not on PATH; the settings are in place for when it is"
    fi
}

c_brew() {
    link "$DOTFILES_DIR/Brewfile" "$HOME/.Brewfile"
    if command -v brew >/dev/null 2>&1; then
        say "  note: brew bundle --global installs what it lists; brew bundle check --global shows what is missing"
    else
        say "  note: Homebrew is not installed (https://brew.sh); afterwards brew bundle --global installs ~/.Brewfile"
    fi
}

# npm ci from the committed lock into ~/.npm-global (NODE_TOOLS_PREFIX), which zshenv puts on
# PATH. Without the Node major it needs, it says so and installs nothing.
c_node_tools() {
    local script="$DOTFILES_DIR/scripts/install-node-tools.sh" want="${NODE_TOOLS_NODE_MAJOR:-24}"
    local prefix="${NODE_TOOLS_PREFIX:-$HOME/.npm-global}" have
    have="$(node -p 'process.versions.node' 2>/dev/null || true)"
    if [ "${have%%.*}" != "$want" ] || ! command -v npm >/dev/null 2>&1; then
        say "  note: the pinned Node tools need Node $want and npm (found ${have:-no node}): fnm install $want, then rerun"
        return 0
    fi
    bash "$script" --check >/dev/null 2>&1 && return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] would install the pinned Node tools into $(tilde "$prefix") (npm ci from node-tools/package-lock.json)"
        CHANGES=$((CHANGES + 1))
    elif bash "$script"; then
        record node-tools "$prefix/node-tools-current"
    else
        warn "the pinned Node tools did not install (scripts/install-node-tools.sh says why above)"
    fi
}

# codesync is linked, never scheduled: it commits and pushes every repository under ~/code, so it
# runs only when you run it. It reads dotsync's peers file unless it has one of its own.
c_sync() {
    link_bins "$DOTFILES_DIR/scripts/dotsync" "$DOTFILES_DIR/scripts/dotsync-doctor" \
        "$DOTFILES_DIR/scripts/dotsync-commit-message" "$DOTFILES_DIR/scripts/codesync"
    need python3 "dotsync needs it for its lock and its checks"
    need gitleaks "dotsync refuses to commit or push without it"
    need ssh "dotsync and codesync update your other machines over ssh"
    [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/dotsync/peers" ] || [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/codesync/peers" ] \
        || say "  note: list your other machines (one ssh alias per line) in ~/.config/dotsync/peers; codesync reads it too, unless ~/.config/codesync/peers exists (docs/dotsync.md, docs/codesync.md)"
}

# The dotsync timer belongs to the sync component: --with schedules alone never starts
# automatic commits on a machine that did not install dotsync.
schedule_wanted() {  # schedule_wanted FILE
    case "$(basename "$1")" in
        dotsync.*|com.dotsync.plist)
            selected sync || [ "$HOME/.local/bin/dotsync" -ef "$DOTFILES_DIR/scripts/dotsync" ] ;;
        *) return 0 ;;
    esac
}

# The schedule templates name their binaries under __HOME__/.dotfiles (launchd) or
# $HOME/.dotfiles (systemd), which is why ~/.dotfiles must point at this checkout.
c_schedules() {
    local f tmp label dest unit timers=""
    case "$(uname -s)" in
        Darwin)
            for f in "$DOTFILES_DIR"/launchagents/*.plist; do
                schedule_wanted "$f" || continue
                label="$(basename "$f" .plist)"
                dest="$HOME/Library/LaunchAgents/$label.plist"
                tmp="$(mktemp)"
                sed "s|__HOME__|$HOME|g" "$f" > "$tmp"
                if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; continue; fi
                generate "$dest" "$tmp"
                if [ "$DRY_RUN" -eq 1 ]; then
                    say "  [dry-run] would load $label"
                else
                    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
                    if launchctl bootstrap "gui/$(id -u)" "$dest"; then
                        say "  loaded $label"
                    else
                        warn "could not load $label"
                    fi
                fi
            done
            ;;
        Linux)
            for f in "$DOTFILES_DIR"/systemd/user/*; do
                schedule_wanted "$f" || continue
                link "$f" "$HOME/.config/systemd/user/$(basename "$f")"
                case "$f" in *.timer) timers="$timers $(basename "$f")" ;; esac
            done
            if [ "$DRY_RUN" -eq 1 ]; then
                say "  [dry-run] would enable the timers:$timers"
            elif systemctl --user daemon-reload 2>/dev/null; then
                for unit in $timers; do
                    systemctl --user enable --now "$unit" >/dev/null 2>&1 \
                        && say "  enabled $unit" || warn "could not enable $unit"
                done
            else
                warn "no systemd user session here: link the units and enable the timers once one exists"
            fi
            ;;
        *) warn "schedules: no launchd or systemd here, skipped" ;;
    esac
}

# OWNER/NAME of a git repository's github.com origin, or nothing.
github_slug() {  # github_slug REPO_DIR
    local url
    url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 0
    case "$url" in
        https://github.com/*)   url="${url#https://github.com/}" ;;
        git@github.com:*)       url="${url#git@github.com:}" ;;
        ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
        *) return 0 ;;
    esac
    url="${url%/}"
    url="${url%.git}"
    case "$url" in
        */*/*|/*|*/|*[!A-Za-z0-9_./-]*) return 0 ;;
        */*) printf '%s' "$url" ;;
    esac
}

# The kit is copied, not linked: a repository commits its .github/ files. Each is installed like a
# generated file (replaced ones go to the backup), with OWNER/REPO in links filled from the origin.
c_github_kit() {
    local kit="$DOTFILES_DIR/github-kit" top slug f tmp
    [ -n "$TARGET" ] || die "github-kit needs --target DIR: the git repository whose .github/ gets the kit"
    top="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)" \
        || die "--target $TARGET is not inside a git repository"
    top="$(cd "$top" && pwd -P)"
    case "$top/" in
        "$DOTFILES_DIR"/*) warn "$(tilde "$top") is this checkout (or inside it); leaving it alone"; return 0 ;;
    esac
    slug="$(github_slug "$top")"
    while IFS= read -r f; do
        tmp="$(mktemp)"
        if [ -n "$slug" ]; then
            sed "s|github\.com/OWNER/REPO/|github.com/$slug/|g" "$kit/$f" > "$tmp"
        else
            cp "$kit/$f" "$tmp"
        fi
        chmod 644 "$tmp"
        generate "$top/.github/$f" "$tmp"
    done < <(cd "$kit" && find . -type f ! -name README.md ! -name sync-labels.sh | sed 's|^\./||' | LC_ALL=C sort)
    [ -n "$slug" ] || say "  note: $(tilde "$top") has no github.com origin: replace OWNER/REPO in .github/ISSUE_TEMPLATE/config.yml"
    say "  next: commit the files, then sync the labels: $(tilde "$kit")/sync-labels.sh --repo ${slug:-OWNER/NAME} --dry-run"
}

# Drover reads its settings from ~/.config/drover/*.env (DROVER_CONFIG_DIR moves it), in name order, with the
# first file to set a name winning, so a 00-*.env of your own overrides this one. The overlay is named through
# ~/.dotfiles, which is why ~/.dotfiles must point at this checkout.
c_manager() {
    local rel="identities/$IDENTITY/openclaw-manager" tmp
    if [ ! -d "$DOTFILES_DIR/$rel" ]; then
        say "  note: $rel does not exist; copy identities/example/openclaw-manager there to give this identity an overlay"
        return 0
    fi
    tmp="$(mktemp)"
    printf '%s\n' "# Written by ~/.dotfiles/install.sh: the OpenClaw manager overlay of identity '$IDENTITY'." \
        "DROVER_OPENCLAW_OVERLAY=~/.dotfiles/$rel" > "$tmp"
    generate "${DROVER_CONFIG_DIR:-$HOME/.config/drover}/dx-openclaw-manager.env" "$tmp"
    need drover "drover manager setup reads the overlay (https://github.com/coletebou/drover)"
}

# ── run ──────────────────────────────────────────────────────────────────
[ "$DRY_RUN" -eq 1 ] && say "Dry run: nothing will change."
say "Installing from $DOTFILES_DIR (identity $IDENTITY, role $ROLE):$SELECTED"
[ -z "$TARGET" ] || selected github-kit || warn "--target is for github-kit, which is not selected; ignoring it"
# Everything but github-kit (which writes only into its target) finds this checkout through ~/.dotfiles.
for c in $SELECTED; do
    [ "$c" = github-kit ] || { ensure_dotfiles_link; break; }
done
for c in $SELECTED; do
    say "[$c] $(describe "$c")"
    "c_$(printf '%s' "$c" | tr - _)"
done

# Remember what this machine installed (the union of every real run), in the canonical order.
if [ "$DRY_RUN" -eq 0 ]; then
    recorded=" $( [ -r "$RECORD_FILE" ] && tr -cs 'a-z-' ' ' < "$RECORD_FILE" || true) $SELECTED "
    union=""
    for c in $ALL_COMPONENTS; do
        case "$recorded" in *" $c "*) union="$union $c" ;; esac
    done
    if [ "$(cat "$RECORD_FILE" 2>/dev/null || true)" != "${union# }" ]; then
        mkdir -p "$(dirname "$RECORD_FILE")"
        printf '%s\n' "${union# }" > "$RECORD_FILE.tmp" && mv "$RECORD_FILE.tmp" "$RECORD_FILE"
    fi
fi

if [ "$CHANGES" -eq 0 ]; then
    say "Everything was already in place."
elif [ "$DRY_RUN" -eq 1 ]; then
    say "Dry run: $CHANGES change(s) would be made."
else
    say "Done: $CHANGES change(s)."
    [ -d "$BACKUP_DIR" ] && say "Replaced files and the change log are in $(tilde "$BACKUP_DIR")."
    if selected shell; then say "Open a new shell to pick up the configuration."; fi
fi
exit 0
