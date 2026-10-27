#!/usr/bin/env bash
# shellcheck disable=SC2088  # the messages name paths with a literal ~ on purpose
# install.sh — link this repo's dotfiles and agent tooling into $HOME, one
# component at a time.
#
#   ./install.sh --list                       the components, and what each installs
#   ./install.sh --all --dry-run              every change it would make, making none
#   ./install.sh --all                        every component except schedules
#   ./install.sh --with shell,git,claude      just these
#   ./install.sh --with schedules             the background jobs (cc-park, dream, tmux autosave)
#
# Options:
#   --identity ID   identities/<ID>/ supplies your git identity, host labels, Claude rules and
#                   shell settings (default: the one ~/.df-profile names, else "example")
#   --role ROLE     local (a workstation) or server (default: ~/.df-profile's, else local)
#   --replace-dotfiles  move an existing ~/.dotfiles that is not this checkout into the backup
#
# The shell, hooks and schedules find everything through ~/.dotfiles, so a checkout anywhere
# else gets ~/.dotfiles linked to it. Re-running is safe: what is already in place is left
# alone. Anything a run replaces is MOVED to ~/.dotfiles-backup/<time>/ first (with a
# changes.jsonl of what happened), never deleted. Needs bash (3.2 is fine), git, and jq for
# the generated Claude Code settings.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ALL_COMPONENTS="shell git tmux claude codex session worktrees memory review schedules"
DEFAULT_ALL="shell git tmux claude codex session worktrees memory review"

describe() {
    case "$1" in
        shell)     echo "zsh entry points (zshenv, zshrc, aliases, zprofile, profile), the starship prompt, ~/.df-profile" ;;
        git)       echo "global git config with identity routing, the global ignore file, gitleaks pre-commit and pre-push hooks" ;;
        tmux)      echo "tmux.conf and its status helpers, Claude/Codex resume after tmux-resurrect, tmux-archive and tmux-organize" ;;
        claude)    echo "Claude Code: generated settings.json (hooks, statusline), a CLAUDE.md rules stub, MCP servers" ;;
        codex)     echo "the codex-subagents and codex-transcripts skills" ;;
        session)   echo "cc-park and cc-handoff, with their skills" ;;
        worktrees) echo "wt-helper, pw, stack-branches and stack-claude, with their skills" ;;
        memory)    echo "reflections, dream, session-analyzer and claude-consolidate, with their skills" ;;
        review)    echo "autoreview-pair and the adversarial-review, mcp-agent-safety and fable-second-opinion skills" ;;
        schedules) echo "launchd (macOS) or systemd user (Linux) jobs: cc-park autopark, nightly dream, tmux autosave (not in --all)" ;;
    esac
}

usage() {
    awk 'NR == 1 || /^# shellcheck/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
say()  { printf '%s\n' "$*"; }

# ── arguments ────────────────────────────────────────────────────────────
WITH="" DRY_RUN=0 LIST=0 IDENTITY="" ROLE="" REPLACE_DOTFILES=0
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
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown argument: $1 (see --help)" ;;
    esac
done

if [ "$LIST" -eq 1 ]; then
    for c in $ALL_COMPONENTS; do printf '  %-10s %s\n' "$c" "$(describe "$c")"; done
    exit 0
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
    for c in $ALL_COMPONENTS; do printf '  %-10s %s\n' "$c" "$(describe "$c")"; done
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

# link SRC DEST: DEST becomes a symlink to SRC, unless it already is one.
link() {
    local src="$1" dest="$2"
    [ -e "$src" ] || die "missing in this checkout: $src"
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
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
    local tmp name="" email=""
    # An identity in the ~/.gitconfig this replaces is carried into ~/.gitconfig.local, which
    # git reads last, so commits keep it.
    if [ -f "$HOME/.gitconfig" ] && [ ! -L "$HOME/.gitconfig" ]; then
        name="$(git config --file "$HOME/.gitconfig" --get user.name 2>/dev/null || true)"
        email="$(git config --file "$HOME/.gitconfig" --get user.email 2>/dev/null || true)"
    fi
    link "$DOTFILES_DIR/base/gitconfig.base" "$HOME/.gitconfig"
    if [ -n "$email" ] && [ -z "$(git config --file "$HOME/.gitconfig.local" --get user.email 2>/dev/null || true)" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  [dry-run] would keep your git identity ($email) in ~/.gitconfig.local"
            CHANGES=$((CHANGES + 1))
        else
            [ -n "$name" ] && git config --file "$HOME/.gitconfig.local" user.name "$name"
            git config --file "$HOME/.gitconfig.local" user.email "$email"
            say "  kept your git identity in ~/.gitconfig.local"
            record git-identity "$HOME/.gitconfig.local" "$email"
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
    link_skills codex
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
    for s in reflections dream dream-prep dream-held-nights session-analyzer claude-consolidate; do
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

# The schedule templates name their binaries under __HOME__/.dotfiles (launchd) or
# $HOME/.dotfiles (systemd), which is why ~/.dotfiles must point at this checkout.
c_schedules() {
    local f tmp label dest unit
    case "$(uname -s)" in
        Darwin)
            for f in "$DOTFILES_DIR"/launchagents/*.plist; do
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
                link "$f" "$HOME/.config/systemd/user/$(basename "$f")"
            done
            if [ "$DRY_RUN" -eq 1 ]; then
                say "  [dry-run] would enable the timers: $(cd "$DOTFILES_DIR/systemd/user" && ls ./*.timer | tr '\n' ' ')"
            elif systemctl --user daemon-reload 2>/dev/null; then
                for unit in "$DOTFILES_DIR"/systemd/user/*.timer; do
                    systemctl --user enable --now "$(basename "$unit")" >/dev/null 2>&1 \
                        && say "  enabled $(basename "$unit")" || warn "could not enable $(basename "$unit")"
                done
            else
                warn "no systemd user session here: link the units and enable the timers once one exists"
            fi
            ;;
        *) warn "schedules: no launchd or systemd here, skipped" ;;
    esac
}

# ── run ──────────────────────────────────────────────────────────────────
[ "$DRY_RUN" -eq 1 ] && say "Dry run: nothing will change."
say "Installing from $DOTFILES_DIR (identity $IDENTITY, role $ROLE):$SELECTED"
ensure_dotfiles_link
for c in $SELECTED; do
    say "[$c] $(describe "$c")"
    "c_$c"
done

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
