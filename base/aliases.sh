# base/aliases.sh — universal aliases and helper functions
#
# Sourced by ~/.aliases for every profile. Contains only identity-free,
# role-free ergonomics: modern-CLI wrappers, git shortcuts, Claude Code
# helpers, the tmux picker, basic system helpers.
#
# Identity-specific things (host shortcuts, vault helpers, service
# management) belong in identities/<id>/common.sh and its local.sh /
# server.sh, which ~/.aliases sources after this file.

# ── fd shim (Ubuntu/Debian packages fd as fdfind) ────────────────────
# Provide the expected name when the Debian-style binary is present.
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    alias fd='fdfind'
fi

# ── ls: eza when available, plain ls fallback ────────────────────────
# eza is the modern replacement, but minimal environments (containers, fresh
# boxes before install.sh's full toolchain) may not have it —
# and unconditionally aliasing ls→eza there BREAKS `ls` entirely
# ("command not found: eza"). Guard on eza's presence; otherwise fall back to
# plain ls with equivalent-ish flags so ls/ll/la always work.
if command -v eza &>/dev/null; then
    alias ls='eza --icons --git'
    alias ll='eza -l --icons --git'
    alias la='eza -a --icons --git'
    alias lla='eza -la --icons --git'
    alias lt='eza --tree --icons --git'
else
    # Plain-ls fallback. --color=auto on GNU/Linux; macOS BSD ls uses -G, but
    # this branch is mainly minimal Linux boxes, so keep it simple.
    alias ls='ls --color=auto'
    alias ll='ls -lh --color=auto'
    alias la='ls -A --color=auto'
    alias lla='ls -lAh --color=auto'
    alias lt='ls -R --color=auto'   # no tree without eza; -R is the closest builtin
fi

# ── Disk / memory ────────────────────────────────────────────────────
alias duh='du -h --max-depth=1 | sort -h'
alias meminfo='free -h && echo "" && ps aux --sort=-%mem | head -6'  # Linux; no-op on macOS

# fcount — count regular files and directories in a path, including dotfiles.
# Usage: fcount [-r] [path]    -r = recursive (descends into all subdirs)
# Glob qualifiers: (.) = regular files, (/) = directories, D = include dotfiles.
# Note: -r descends into node_modules / .git / etc — slow on large trees.
fcount() {
    setopt local_options null_glob
    local recursive=0
    while [[ "$1" == -* ]]; do
        case "$1" in
            -r)        recursive=1; shift ;;
            -h|--help) echo "Usage: fcount [-r] [path]"; return 0 ;;
            --)        shift; break ;;
            *)         echo "fcount: unknown flag: $1" >&2; return 1 ;;
        esac
    done
    local dir="${1:-.}"
    local files dirs
    if (( recursive )); then
        files=("$dir"/**/*(.D))
        dirs=("$dir"/**/*(/D))
    else
        files=("$dir"/*(.D))
        dirs=("$dir"/*(/D))
    fi
    printf 'files: %d\ndirs:  %d\n' "${#files[@]}" "${#dirs[@]}"
}

# ── resources: one-shot CPU/memory/disk snapshot + top consumers ─────
# Usage: resources [N]   # N = top consumers per category (default 5)
# Portable: uses /proc on Linux, vm_stat/sysctl on macOS. ps %CPU is
# lifetime-average, not instantaneous — use `top -l 1 -o cpu` for live.
resources() {
    local n="${1:-5}"
    local os
    os="$(uname -s)"
    local hr="────────────────────────────────────────────────────"

    # ── CPU ──
    echo "── CPU $hr"
    case "$os" in
        Darwin)
            printf "%s (%s cores)  load: %s\n" \
                "$(sysctl -n machdep.cpu.brand_string)" \
                "$(sysctl -n hw.ncpu)" \
                "$(sysctl -n vm.loadavg | tr -d '{}' | xargs)"
            echo
            echo "Top $n by %CPU (lifetime avg):"
            ps -Ao pcpu,pid,comm -r 2>/dev/null | head -$((n + 1)) | \
                awk 'NR==1 {printf "%6s %7s  %s\n", "%CPU", "PID", "COMMAND"; next}
                     {p=""; for (i=3;i<=NF;i++) p = p (i>3 ? " " : "") $i; sub(".*/","",p);
                      printf "%6.1f %7d  %s\n", $1, $2, p}'
            ;;
        Linux)
            printf "%s (%s cores)  load: %s\n" \
                "$(awk -F: '/^model name/ {print $2; exit}' /proc/cpuinfo | xargs)" \
                "$(nproc)" \
                "$(awk '{print $1, $2, $3}' /proc/loadavg)"
            echo
            echo "Top $n by %CPU (lifetime avg):"
            ps -Ao pcpu,pid,comm --sort=-pcpu 2>/dev/null | head -$((n + 1))
            ;;
    esac

    # ── Memory ──
    echo
    echo "── Memory $hr"
    case "$os" in
        Darwin)
            local total pgsize
            total=$(sysctl -n hw.memsize)
            pgsize=$(sysctl -n hw.pagesize)
            vm_stat | awk -v ps="$pgsize" -v total="$total" '
                /^Pages free:/                   { gsub("\\.","",$3); free   = $3 * ps }
                /^Pages active:/                 { gsub("\\.","",$3); active = $3 * ps }
                /^Pages wired down:/             { gsub("\\.","",$4); wired  = $4 * ps }
                /^Pages occupied by compressor:/ { gsub("\\.","",$5); comp   = $5 * ps }
                END {
                    g = 1073741824
                    printf "Total:      %.1f GB\n", total / g
                    printf "App+wired:  %.1f GB\n", (active + wired) / g
                    printf "Compressed: %.1f GB  (high = pressure)\n", comp / g
                    printf "Free:       %.1f GB\n", free / g
                }'
            echo
            echo "Top $n by RSS:"
            # NB: macOS ps `-r` sorts by CPU; `-m` sorts by memory. Don't swap.
            ps -Ao rss,pid,comm -m 2>/dev/null | head -$((n + 1)) | \
                awk 'NR==1 {printf "%8s %7s  %s\n", "RSS_MB", "PID", "COMMAND"; next}
                     {p=""; for (i=3;i<=NF;i++) p = p (i>3 ? " " : "") $i; sub(".*/","",p);
                      printf "%8.0f %7d  %s\n", $1/1024, $2, p}'
            ;;
        Linux)
            free -h
            echo
            echo "Top $n by RSS:"
            ps -Ao rss,pid,comm --sort=-rss 2>/dev/null | head -$((n + 1)) | \
                awk 'NR==1 {printf "%8s %7s  %s\n", "RSS_MB", "PID", "COMMAND"; next}
                     {printf "%8.0f %7d  %s\n", $1/1024, $2, $3}'
            ;;
    esac

    # ── Disk ──
    echo
    echo "── Disk $hr"
    df -h / 2>/dev/null
    echo
    echo "Top $n in \$HOME:"
    du -sh "$HOME"/* 2>/dev/null | sort -rh | head -"$n"
}

# ── resources-deep: pressure detection + per-process burst sampling ──
# Usage: resources-deep [N] [process]
#   N        top consumers per category (default 5)
#   process  process to sample for live CPU bursts (default: contactsd
#            on Darwin, kswapd0 on Linux)
# Builds on resources(): adds swap saturation, compressor delta over 2s,
# free-page floor, and 5×1s bursts of a watched process. Use when you
# suspect thrash or a daemon spinning (contactsd, mdworker, kswapd,
# photoanalysisd, etc). Burst sample shows pcpu via ps's decay-averaged
# window — values dance with real activity but lag a few seconds behind
# instantaneous load. For sub-second resolution use `top -l 5 -s 1`.
resources-deep() {
    local n="${1:-5}"
    local watch="${2:-}"
    local os
    os="$(uname -s)"
    local hr="────────────────────────────────────────────────────"

    [[ -z "$watch" ]] && case "$os" in
        Darwin) watch="contactsd" ;;
        Linux)  watch="kswapd0"   ;;
    esac

    # Run the standard report first
    resources "$n"

    # ── Pressure ──
    echo
    echo "── Pressure $hr"
    case "$os" in
        Darwin)
            local pgsize c1 c2 f1 f2 dc_mb free_mb tag
            pgsize=$(sysctl -n hw.pagesize)
            # awk parses "total = 4096.00M  used = 3764.88M  free = 331.12M  (encrypted)"
            sysctl -n vm.swapusage | \
                awk '{printf "Swap:        %s used / %s total  (%s free)\n", $6, $3, $9}'
            c1=$(vm_stat | awk '/Pages occupied by compressor/ {gsub("\\.","",$5); print $5}')
            f1=$(vm_stat | awk '/Pages free/                   {gsub("\\.","",$3); print $3}')
            sleep 2
            c2=$(vm_stat | awk '/Pages occupied by compressor/ {gsub("\\.","",$5); print $5}')
            f2=$(vm_stat | awk '/Pages free/                   {gsub("\\.","",$3); print $3}')
            dc_mb=$(( (c2 - c1) * pgsize / 1024 / 1024 ))
            free_mb=$((  f2       * pgsize / 1024 / 1024 ))
            tag="stable"
            ((dc_mb >  50)) && tag="rising — pressure climbing"
            ((dc_mb < -50)) && tag="easing — pressure dropping"
            printf "Compressor:  %+d MB / 2s  [%s]\n" "$dc_mb" "$tag"
            printf "Free:        %d MB%s\n" "$free_mb" \
                "$( ((free_mb < 200)) && echo '  [very low]' || echo '' )"
            ;;
        Linux)
            free -h | awk '/^Swap:/ {printf "Swap:        %s used / %s total\n", $3, $2}'
            grep -E '^(pgpgin|pgpgout|pswpin|pswpout|pgmajfault) ' /proc/vmstat 2>/dev/null
            ;;
    esac

    # ── Burst sample ──
    echo
    echo "── ${watch} burst (5× @ 1s) $hr"
    # NB: pgrep emits one PID per line. zsh does NOT word-split unquoted
    # vars (unlike bash), so we join with commas and feed ps -p once.
    local pid_csv i
    pid_csv=$(pgrep -x "$watch" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [[ -z "$pid_csv" ]]; then
        echo "(no process named ${watch})"
    else
        printf "%6s %6s  %-9s  %s\n" "PID" "%CPU" "ETIME" "STATE"
        for i in 1 2 3 4 5; do
            ps -o pid=,pcpu=,etime=,state= -p "$pid_csv" 2>/dev/null | \
                awk '{printf "%6s %6.1f  %-9s  %s\n", $1, $2, $3, $4}'
            if (( i < 5 )); then sleep 1; fi
        done
    fi
    return 0
}

# ── PATH (local bin) ─────────────────────────────────────────────────
[[ ":$PATH:" != *":$HOME/.local/bin:"* ]] && export PATH="$HOME/.local/bin:$PATH"

# ── Git shortcuts (backed by gitconfig [alias] block) ────────────────
alias gs='git s'      # status + diff stats
alias gl='git l'      # incoming + local log with stats
alias gsl='git sl'    # combined status + log
alias gp='git push'
# git-unlock — clear stale .git/index.lock files. Default: current repo's
# worktrees. --all: every git repo under ~/code/ + ~/.dotfiles. See
# `git-unlock --help`. Common after a crashed git op leaves index.lock
# behind, blocking every subsequent git command.
alias gunlock='git-unlock'


# wt — git worktree spinner. Helper script does the work + prompts on
# /dev/tty; we capture the final path on stdout and cd into it. The
# function form is required because a child process can't change the
# parent shell's cwd. See ~/.dotfiles/scripts/wt-helper for the menus.
#   wt feat-foo                 # state-aware: prompts if branch is new/in-use
#   wt feat-foo --from fresh    # skip menu, branch off origin/HEAD
#   wt feat-foo --from head     # skip menu, branch off local HEAD
wt() {
  local target
  target=$(command wt-helper "$@") || return $?
  if [[ -n "$target" && -d "$target" ]]; then
    cd "$target" || return 1
  fi
}

# ── ignore: append a path/pattern to gitignore (repo / local / global) ─
# Usage: ignore [TARGET ...] [flags]
#   -r, --repo           Append to <repo-root>/.gitignore (committed)
#   -l, --local          Append to <repo-root>/.git/info/exclude (per-clone, not committed)
#   -g, --global         Append to ~/.config/git/ignore (every repo, this user)
#   -k, --keep-tracked   Don't untrack files that match the new pattern
#   -h, --help           Show this help
#
# With no destination flag: opens a picker (fzf if available) to choose
# repo / local / global per invocation.
#
# Path semantics:
#   - For repo/local: TARGET resolved against PWD, then written as a
#     repo-root-anchored path (e.g. "/packages/client/foo.md"). A trailing
#     "/" is appended for directories. Raw patterns (starting with one of
#     / * ? [ ! #) pass through verbatim.
#   - For global: TARGET passes through verbatim (global excludes apply
#     across all repos, so anchoring is meaningless).
#
# Duplicate detection: fixed-string whole-line match against the target
# file. Already-ignored entries are skipped silently.
#
# Missing file: prompts before creating .gitignore / global ignore /
# .git/info/exclude (the last is auto-created by `git init` so is rare).
#
# Auto-untrack: gitignore only suppresses untracked files — entries
# already in the index keep tracking despite a new rule. For repo/local
# dests, after appending a new pattern this function checks the index
# for matches and runs `git rm --cached` on them (files stay on disk,
# only the index entry is removed). Use -k/--keep-tracked to opt out.
# Skipped for global dest (would surprise users by mutating an arbitrary
# repo from a global config edit). Revert with `git restore --staged`.
ignore() {
    emulate -L zsh
    setopt local_options pipefail

    local dest=""
    local keep_tracked=""
    local -a targets=()

    while (( $# )); do
        case "$1" in
            -r|--repo)         dest="repo"; shift ;;
            -l|--local)        dest="local"; shift ;;
            -g|--global)       dest="global"; shift ;;
            -k|--keep-tracked) keep_tracked=1; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: ignore [TARGET ...] [-r|-l|-g] [-k]

  -r, --repo           <repo>/.gitignore           (committed)
  -l, --local          <repo>/.git/info/exclude    (per-clone, not committed)
  -g, --global         ~/.config/git/ignore        (this user, all repos)
  -k, --keep-tracked   don't untrack files already in the index

With no destination flag, an fzf picker appears (or numbered prompt
without fzf). Repo/local entries are anchored to the repo root; global
entries pass through verbatim. Duplicates are skipped.

For repo/local dests, files already tracked by git that match a new
pattern are removed from the index via `git rm --cached` (files stay
on disk). Pass -k to skip this step. Revert with `git restore --staged`.
EOF
                return 0
                ;;
            --) shift; targets+=("$@"); break ;;
            -*) echo "ignore: unknown flag: $1" >&2; return 2 ;;
            *)  targets+=("$1"); shift ;;
        esac
    done

    if (( ${#targets[@]} == 0 )); then
        echo "ignore: no target given (try: ignore foo.md, or ignore --help)" >&2
        return 2
    fi

    # ── Pick destination if not specified ────────────────────────────
    if [[ -z "$dest" ]]; then
        local choice
        local -a opts=(
            "repo    — <repo>/.gitignore (committed)"
            "local   — <repo>/.git/info/exclude (per-clone)"
            "global  — ~/.config/git/ignore (all repos)"
        )
        if command -v fzf >/dev/null 2>&1; then
            choice=$(printf '%s\n' "${opts[@]}" | fzf --height=40% --prompt='ignore where? ' --no-info) || return 130
        else
            echo "Where to add the ignore rule?"
            local i=1
            for o in "${opts[@]}"; do printf '  %d) %s\n' "$i" "$o"; (( i++ )); done
            printf 'Choice [1-3]: '
            local n; read -r n
            case "$n" in 1) choice="${opts[1]}" ;; 2) choice="${opts[2]}" ;; 3) choice="${opts[3]}" ;; *) echo "ignore: aborted" >&2; return 130 ;; esac
        fi
        case "$choice" in
            repo*)   dest="repo" ;;
            local*)  dest="local" ;;
            global*) dest="global" ;;
            *) echo "ignore: aborted" >&2; return 130 ;;
        esac
    fi

    # ── Resolve destination file ─────────────────────────────────────
    local file repo_root=""
    if [[ "$dest" == "repo" || "$dest" == "local" ]]; then
        repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
            echo "ignore: not inside a git repo (run from a working tree, or use -g for global)" >&2
            return 1
        }
        # Canonicalize: macOS resolves /tmp → /private/tmp, ~/code may
        # be a symlink to /Volumes/..., and git's behaviour around
        # symlinks varies. Apply :A to match how target paths are
        # resolved below, so the outside-repo check is consistent.
        repo_root="${repo_root:A}"
        if [[ "$dest" == "repo" ]]; then
            file="$repo_root/.gitignore"
        else
            # Ask git: in a linked worktree or a submodule .git is a file, and the
            # exclude file lives in the (shared) git dir.
            file=$(git rev-parse --git-path info/exclude 2>/dev/null) || {
                echo "ignore: cannot find this repo's info/exclude" >&2
                return 1
            }
            file="${file:A}"
        fi
    else
        # Global: prefer git's configured excludesFile, else XDG default.
        # --path makes git expand a `~/` or `~user/` the way it does when it
        # reads the file (nothing else is expanded, as in git itself).
        file=$(git config --global --path --get core.excludesFile 2>/dev/null)
        if [[ -z "$file" ]]; then
            # XDG default. macOS doesn't set XDG_CONFIG_HOME; fall back to ~/.config.
            file="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
        fi
    fi

    # ── Confirm file creation if missing ─────────────────────────────
    if [[ ! -e "$file" ]]; then
        printf '%s does not exist. Create it? [y/N] ' "$file"
        local reply; read -r reply
        case "$reply" in
            y|Y|yes|YES) mkdir -p "${file:h}" && : > "$file" || { echo "ignore: failed to create $file" >&2; return 1; } ;;
            *) echo "ignore: aborted (no file created)" >&2; return 1 ;;
        esac
    fi

    # ── Build patterns and append ────────────────────────────────────
    # All locals declared up-front: re-declaring inside a zsh loop with
    # `local` and no `=` prints the existing value (typeset listing quirk).
    local added=0 skipped=0
    local t pattern abs rel
    local -a added_patterns=()
    for t in "${targets[@]}"; do
        if [[ "$dest" == "global" ]]; then
            pattern="$t"
        else
            # Raw pattern characters: pass through verbatim.
            if [[ "$t" == /* || "$t" == \** || "$t" == \?* || "$t" == \[* || "$t" == \!* || "$t" == \#* ]]; then
                pattern="$t"
            elif [[ -e "$t" ]]; then
                # Anchor to repo root.
                abs=${t:A}
                if [[ "$abs" != "$repo_root"* ]]; then
                    echo "ignore: $t is outside repo $repo_root — skipping" >&2
                    (( skipped++ )); continue
                fi
                rel="${abs#$repo_root}"
                [[ "$rel" != /* ]] && rel="/$rel"
                if [[ -d "$abs" ]]; then
                    pattern="${rel%/}/"
                else
                    pattern="$rel"
                fi
            else
                # Doesn't exist on disk — treat as a literal pattern,
                # anchored if it has a slash, otherwise verbatim (matches
                # by basename anywhere in the repo, which is git's default).
                pattern="$t"
            fi
        fi

        if grep -Fxq -- "$pattern" "$file" 2>/dev/null; then
            printf '  = %s  (already in %s)\n' "$pattern" "$file"
            (( skipped++ ))
        else
            printf '%s\n' "$pattern" >> "$file"
            printf '  + %s  → %s\n' "$pattern" "$file"
            (( added++ ))
            added_patterns+=("$pattern")
        fi
    done

    # ── Auto-untrack tracked files matching new patterns ─────────────
    # Scoped to repo/local dests — see header comment for rationale.
    # git matches each new rule against the index with gitignore semantics
    # (a pathspec would not: `/*.json` would also take src/x.json, and a bare
    # `notes.md` would miss sub/notes.md). A file goes only if the repo's whole
    # rule set, now holding the new rules, ignores it too: a nested
    # `!keep.log` keeps sub/keep.log tracked under a new `*.log`. zsh's
    # unique-array type dedupes, so overlapping patterns don't make `git rm`
    # fail on a duplicate path.
    if (( added > 0 )) && [[ "$dest" != "global" ]]; then
        local -aU to_untrack=()
        local -A ignored_now=()
        local pat f
        while IFS= read -r -d '' f; do
            ignored_now[$f]=1
        done < <(git -C "$repo_root" ls-files -z --cached --ignored --exclude-standard 2>/dev/null)
        for pat in "${added_patterns[@]}"; do
            while IFS= read -r -d '' f; do
                (( ${+ignored_now[$f]} )) && to_untrack+=("$f")
            done < <(git -C "$repo_root" ls-files -z --cached --ignored --exclude="$pat" 2>/dev/null)
        done
        if (( ${#to_untrack[@]} > 0 )); then
            if [[ -n "$keep_tracked" ]]; then
                printf '  ! %d tracked file(s) match (keeping tracked per --keep-tracked)\n' ${#to_untrack[@]}
            else
                # --literal-pathspecs: a file named like a glob is that file only.
                (cd "$repo_root" && git --literal-pathspecs rm --cached --quiet -- "${to_untrack[@]}") || {
                    echo "ignore: git rm --cached failed (pattern added, files still tracked)" >&2
                    return 1
                }
                printf '  ~ untracked %d file(s) matching new pattern(s) (git rm --cached)\n' ${#to_untrack[@]}
                printf '    revert with: git restore --staged .\n'
            fi
        fi
    fi

    (( added > 0 || skipped > 0 ))  # success if we processed anything
}

# ── Reload ───────────────────────────────────────────────────────────
alias sz='source ~/.zshrc'
alias sb='source ~/.zshrc'  # compatibility with an old bash-era shortcut

# ── df-switch: swap identity/role in the current shell ───────────────
# Usage: df-switch                  show current profile and the identities
#        df-switch <identity>       swap identity (keep role)
#        df-switch <identity> local swap identity + role
#        df-switch server           swap role only
# An identity is any directory under ~/.dotfiles/identities/. Only affects
# the current shell; new shells use the install default (~/.df-profile).
df-switch() {
    local root="${DOTFILES_DIR:-$HOME/.dotfiles}" d
    local -a ids=()
    for d in "$root"/identities/*(N/); do ids+=("${d:t}"); done
    if [[ -z "$1" ]]; then
        printf 'Machine: %s\n' "${DF_MACHINE:-unknown}"
        printf 'Current: DF_IDENTITY=%s DF_ROLE=%s\n' "${DF_IDENTITY:-example}" "${DF_ROLE:-local}"
        printf 'Identities: %s\n' "${ids[*]:-none}"
        printf '\nUsage: df-switch [identity|role] [role]\n'
        printf '  df-switch <identity>         swap identity\n'
        printf '  df-switch <identity> local   swap identity + role\n'
        printf '  df-switch server             swap role only\n'
        printf '\nOnly affects the current shell. New shells use the install default.\n'
        return 0
    fi

    case "$1" in
        local|server)
            export DF_ROLE="$1"
            ;;
        -h|--help)
            df-switch
            return 0
            ;;
        *)
            if [[ -d "$root/identities/$1" ]]; then
                export DF_IDENTITY="$1"
                [[ -n "$2" ]] && export DF_ROLE="$2"
            else
                echo "Unknown: $1 (identities: ${ids[*]:-none}). Run 'df-switch' for help." >&2
                return 1
            fi
            ;;
    esac

    # Re-source zshrc to reload the profile chain
    unset _DF_SESSION_SHOWN
    source ~/.zshrc
    printf '✓ Active on %s: DF_IDENTITY=%s DF_ROLE=%s\n' "${DF_MACHINE:-unknown}" "$DF_IDENTITY" "$DF_ROLE"
}

# ── Claude Code shortcuts ────────────────────────────────────────────
alias yolo-unsafe="claude --dangerously-skip-permissions"

# Return a --debug-file arg that points at a fresh log under
# ~/.claude/debug-logs/. Keeps only the most recent 20 logs so the dir
# doesn't grow forever. Printed to stdout so callers can `eval` or splice it.
_claude_debug_file_arg() {
    # Why: zsh errors on unmatched globs by default; local_options scopes the
    # opt-in to this function so we don't affect the caller's shell.
    [[ -n "${ZSH_VERSION:-}" ]] && setopt local_options null_glob 2>/dev/null
    local log_dir="$HOME/.claude/debug-logs"
    mkdir -p "$log_dir"
    # Prune to last 20 logs. List the directory (not a glob arg to ls) so that
    # zsh null_glob doesn't cause ls to fall back to listing CWD when empty.
    ls -1t "$log_dir" 2>/dev/null \
      | grep -E '\.log$' \
      | tail -n +21 \
      | sed "s|^|$log_dir/|" \
      | xargs -r rm -f
    local host
    host="$(hostname -s 2>/dev/null || hostname)"
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    # =form keeps it one token so loops that scan leading -- flags don't split.
    printf -- '--debug-file=%s/yu-%s-%s-%s.log' "$log_dir" "$host" "$ts" "$$"
}

# Opus 5.5 sessions start at max effort. Claude Code cannot keep max as a saved
# default: every settings layer (user, project, local, --settings, managed;
# top-level effortLevel and modelSettings alike) keeps only low..xhigh and
# drops max, which leaves Opus 5.5 on its built-in medium (read in the 2.1.304
# bundle, confirmed by live calls 2026-10-20). /effort max is session-only, and
# CLAUDE_CODE_EFFORT_LEVEL would force every model, beat an explicit --effort
# and lock /effort. So each launcher adds it before the arguments it forwards:
#   effort="$(_claude_effort_arg "$LAUNCHER_SETTINGS" "$@")"
#   claude ... ${effort:+"$effort"} "$@"
# It prints --effort=max when the session will start on Opus 5.5, else nothing.
# SETTINGS is the launcher's own --settings layer (file or inline JSON, or "");
# a --settings in ARGS replaces it. ARGS holding --effort get nothing added.
# The model is the --model in ARGS, else what Claude Code picks from its layers,
# lowest first: ~/.claude/settings.json (where /model saves a new default), the
# project's .claude/settings.json, its .claude/settings.local.json (read in the
# cwd, the repo top and a worktree's main checkout), then SETTINGS. The last
# ANTHROPIC_MODEL a layer's env block sets wins over the shell's; when that is
# empty, the last "model" wins. A resumed session also starts on that model
# (checked 2026-10-20: a Sonnet session resumed on Opus 5.5). The opus alias
# counts as Opus 5.5. CLAUDE_MAX_EFFORT_MODELS (a zsh pattern, default
# 'opus|opus\[1m\]|*opus-5-5*') names the models that get max. Without jq,
# only --model counts.
_claude_effort_arg() {
    emulate -L zsh
    local layer="$1" model="" next="" a f top common root
    local -a files=()
    shift
    for a in "$@"; do
        case "$next" in
            model) model="$a"; next=""; continue ;;
            settings) layer="$a"; next=""; continue ;;
        esac
        case "$a" in
            --) break ;;
            --effort|--effort=*) return 0 ;;
            --model) next=model ;;
            --model=*) model="${a#--model=}" ;;
            --settings) next=settings ;;
            --settings=*) layer="${a#--settings=}" ;;
        esac
    done
    if [[ -z "$model" ]] && command -v jq >/dev/null 2>&1; then
        [[ -n "$layer" && -r "$layer" ]] && layer="$(<"$layer")"
        top="$(git rev-parse --show-toplevel 2>/dev/null)"
        common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        root="${common%/*}"
        # A path listed twice re-applies the same layer at the same rank: harmless.
        for f in "$HOME/.claude/settings.json" \
            "$PWD/.claude/settings.json" "$top/.claude/settings.json" "$root/.claude/settings.json" \
            "$PWD/.claude/settings.local.json" "$top/.claude/settings.local.json" \
            "$root/.claude/settings.local.json"; do
            [[ -f "$f" && -r "$f" ]] && files+=("$f")
        done
        model="$(jq -rn --arg shell "${ANTHROPIC_MODEL-}" --arg layer "$layer" '
            def obj: if type == "object" then . else {} end;
            ([inputs | obj] + [$layer | fromjson? // {} | obj])
            | reduce .[] as $l ({e: $shell, m: ""};
                ($l.env | obj) as $env
                | (if $env | has("ANTHROPIC_MODEL") then .e = ($env.ANTHROPIC_MODEL // "" | tostring) else . end)
                | (if ($l.model | type) == "string" and $l.model != "" then .m = $l.model else . end))
            | if .e != "" then .e else .m end
            ' "${files[@]}" </dev/null 2>/dev/null)"  # no files: `inputs` would read the terminal
    fi
    local max_models=${CLAUDE_MAX_EFFORT_MODELS:-'opus|opus\[1m\]|*opus-5-5*'}
    [[ -n "$model" && "$model" == ${~max_models} ]] && print -r -- --effort=max
    return 0
}

# Claude with dangerous permissions (and max effort on Opus 5.5).
yu() {
    local effort
    effort="$(_claude_effort_arg "" "$@")"
    claude --dangerously-skip-permissions ${effort:+"$effort"} "$@"
}
# Claude on Bedrock Mantle (optional; needs AWS_BEARER_TOKEN_BEDROCK, e.g. in
# ~/.env_secrets). Not `yum`: that shadows the package manager. The overlay
# (base/claude/mantle.settings.json) pins every alias to an id Mantle serves.
# The usual one-key override, --settings '{"env":{"CLAUDE_CODE_USE_MANTLE":"1"}}',
# keeps this machine's own alias pins instead, and a pin Mantle does not serve
# fails with model_not_found (Agent(model: sonnet|haiku) and WebFetch's
# summarizer included).
export YUMA_SETTINGS="${YUMA_SETTINGS:-$HOME/.dotfiles/base/claude/mantle.settings.json}"
# `command claude` skips a machine-local claude() wrapper (one that strips the
# Bedrock bearer so plain claude uses a subscription would leave Mantle with no
# credential).
yuma() {
    local effort
    effort="$(_claude_effort_arg "$YUMA_SETTINGS" "$@")"
    command claude --dangerously-skip-permissions --settings "$YUMA_SETTINGS" ${effort:+"$effort"} "$@"
}
# Claude dangerous + continue
yuc() {
    local effort
    effort="$(_claude_effort_arg "" "$@")"
    claude --dangerously-skip-permissions ${effort:+"$effort"} --continue "$@"
}
# Claude dangerous + resume (supports last-5 of session ID)
yur() { _claude_resume --dangerously-skip-permissions "$@"; }

# Resolve partial session ID (last N chars) to full UUID, then resume
# Usage: cr <last-5-of-session-id>   or   cr <search-term>
cr() { _claude_resume "$@"; }

_claude_resume() {
    # This function uses bash-style 0-indexed array access (`${matches[0]}`).
    # zsh arrays are 1-indexed by default, so without this, `${matches[0]}`
    # silently returns empty and `claude --resume` lands on the interactive
    # picker instead of the requested session. `emulate -L bash` scopes the
    # bash semantics to this function only.
    [[ -n "$ZSH_VERSION" ]] && emulate -L bash

    local extra_flags=()
    # Collect leading flags (e.g. --dangerously-skip-permissions)
    while [[ "$1" == --* ]]; do
        extra_flags+=("$1")
        shift
    done
    local effort
    effort="$(_claude_effort_arg "" "${extra_flags[@]}")"
    [[ -n "$effort" ]] && extra_flags+=("$effort")

    local query="$1"

    # No argument: open interactive picker
    if [[ -z "$query" ]]; then
        claude "${extra_flags[@]}" --resume
        return
    fi

    # If it looks like a full UUID, pass directly
    if [[ "$query" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        claude "${extra_flags[@]}" --resume "$query"
        return
    fi

    # Try suffix match against session filenames across all projects
    local matches=()
    local sid
    for dir in ~/.claude/projects/*/; do
        [[ -d "$dir" ]] || continue
        for f in "$dir"*.jsonl; do
            [[ -f "$f" ]] || continue
            sid="${f##*/}"
            sid="${sid%.jsonl}"
            if [[ "$sid" == *"$query" ]]; then
                matches+=("$sid")
            fi
        done
    done
    # Deduplicate (same session can appear in multiple project dirs)
    local unique=()
    local seen=""
    for m in "${matches[@]}"; do
        if [[ "$seen" != *"$m"* ]]; then
            unique+=("$m")
            seen+="$m "
        fi
    done
    matches=("${unique[@]}")

    case ${#matches[@]} in
        0)
            # No suffix match; pass as search term to interactive picker
            claude "${extra_flags[@]}" --resume "$query"
            ;;
        1)
            echo "Matched session: ${matches[0]}"
            claude "${extra_flags[@]}" --resume "${matches[0]}"
            ;;
        *)
            echo "Multiple sessions match '$query':"
            local i=1
            for m in "${matches[@]}"; do
                echo "  $i) $m"
                ((i++))
            done
            echo ""
            # printf + read, not `read -p`: in zsh -p reads from a coprocess.
            local choice
            printf 'Pick [1-%d]: ' "${#matches[@]}"
            read -r choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
                claude "${extra_flags[@]}" --resume "${matches[$((choice-1))]}"
            else
                echo "Invalid choice."
                return 1
            fi
            ;;
    esac
}

# An orphan is an interactive Claude session (launched with --dangerously...)
# whose terminal is gone: no TTY and over 5 minutes old. Headless `-p`/`--print`
# runs have no TTY by design (hooks, reflections, diagnostic agents), so they
# are never counted.
# _claude_orphan_pids prints one "PID AGE_SECONDS" line per orphan, in one ps +
# awk pass that works with GNU ps (etimes, "?" for no TTY) and BSD ps on macOS
# (no etimes, so etime is parsed; "??" for no TTY). The [y] keeps awk's own
# argv from matching the pattern.
_claude_orphan_pids() {
    if [[ "$OSTYPE" == darwin* ]]; then
        ps -axo pid=,tty=,etime=,args= 2>/dev/null | awk '
            function secs(e,  d, p, n, i, s) { d = 0
                if (index(e, "-")) { split(e, p, "-"); d = p[1]; e = p[2] }
                n = split(e, p, ":"); s = 0; for (i = 1; i <= n; i++) s = s * 60 + p[i]
                return d * 86400 + s }
            ($2 == "??" || $2 == "?") && /claude.*--dangerousl[y]/ && !/ (-p|--print)( |$)/ && secs($3) > 300 { print $1, secs($3) }'
    else
        ps -eo pid=,tty=,etimes=,args= 2>/dev/null | awk '
            $2 == "?" && $3 > 300 && /claude.*--dangerousl[y]/ && !/ (-p|--print)( |$)/ { print $1, $3 }'
    fi
}

# List orphaned Claude processes
claude-orphans() {
    local YELLOW='\033[1;33m'
    local GREY='\033[1;30m'
    local NC='\033[0m'

    echo -e "${GREY}Checking for orphaned Claude processes...${NC}"

    local found=0 pid age mem
    while read -r pid age; do
        if [[ $found -eq 0 ]]; then
            printf "${YELLOW}%-8s %-10s %s${NC}\n" "PID" "AGE" "MEM"
        fi
        mem=$(ps -o rss= -p "$pid" 2>/dev/null | awk '{printf "%.0fMB", $1/1024}')
        printf "%-8s %-10s %s\n" "$pid" "$((age / 60))m" "$mem"
        ((found++))
    done < <(_claude_orphan_pids)

    if [[ $found -eq 0 ]]; then
        echo "No orphaned Claude processes found."
    else
        echo ""
        echo -e "${YELLOW}Found $found orphan(s). Run 'claude-kill-orphans' to terminate (or 'claude-kill' for nuclear).${NC}"
    fi
}

# Kill only orphaned Claude processes. The force-kill pass covers only the PIDs
# that were sent TERM, never a session that was not an orphan a second ago.
claude-kill-orphans() {
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m'

    echo -e "${YELLOW}Killing orphaned Claude processes only...${NC}"

    local killed=0 pid age
    local -a pids=()
    while read -r pid age; do
        pkill -TERM -P "$pid" 2>/dev/null
        kill -TERM "$pid" 2>/dev/null
        echo -e "  ${RED}Killed${NC} PID $pid"
        pids+=("$pid")
        ((killed++))
    done < <(_claude_orphan_pids)

    if [[ $killed -gt 0 ]]; then
        sleep 1
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
                echo -e "  ${RED}Force killed${NC} PID $pid"
            fi
        done
    fi

    if [[ $killed -eq 0 ]]; then
        echo -e "${GREEN}No orphaned Claude processes found.${NC}"
    else
        echo -e "${GREEN}Done. Killed $killed orphan(s).${NC}"
    fi
}
alias cko='claude-kill-orphans'

# Nuclear kill all Claude-related processes
claude-kill() {
    local RED='\033[0;31m'
    local GREEN='\033[0;32m'
    local YELLOW='\033[1;33m'
    local NC='\033[0m'

    echo -e "${YELLOW}Nuclear cleanup: killing all Claude-related processes...${NC}"
    echo ""

    local total_killed=0

    # Kill patterns (order matters — children before parents)
    local patterns=(
        "vtsls"                    # TypeScript language server
        "typescript-language"      # TypeScript language server (alt)
        "eslint.*--stdio"         # ESLint language server
        "biome.*lsp"              # Biome LSP
        "node.*mcp"               # MCP servers (node-based)
        "npx.*mcp"                # MCP servers (npx)
        "chrome-devtools-mcp"     # Chrome DevTools MCP
        "obsidian-mcp"            # Obsidian MCP
        "playwright"              # Playwright browser automation
        "chromium.*remote-debug"  # Chromium spawned by Playwright
        "claude"                  # All Claude processes
    )

    for pattern in "${patterns[@]}"; do
        local count=0
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid=$(echo "$line" | awk '{print $1}')
            local cmd=$(echo "$line" | cut -d' ' -f3-)

            pkill -TERM -P "$pid" 2>/dev/null
            kill -TERM "$pid" 2>/dev/null
            ((count++))
            echo -e "  ${RED}Killed${NC} [$pattern] PID $pid"
        done < <(ps -eo pid,tty,args 2>/dev/null | grep -iE "$pattern" | grep -v "grep" | grep -v "claude-kill")

        total_killed=$((total_killed + count))
    done

    # Kill the tmux sessions named in CLAUDE_KILL_TMUX_SESSIONS (default: claude)
    echo ""
    if command -v tmux &>/dev/null; then
        for session in ${=CLAUDE_KILL_TMUX_SESSIONS:-claude}; do
            if tmux has-session -t "$session" 2>/dev/null; then
                tmux kill-session -t "$session" 2>/dev/null
                echo -e "  ${RED}Killed${NC} tmux session: $session"
                ((total_killed++))
            fi
        done
    fi

    # Force kill any stragglers
    sleep 1
    for pattern in "${patterns[@]}"; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid=$(echo "$line" | awk '{print $1}')
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
                echo -e "  ${RED}Force killed${NC} PID $pid"
            fi
        done < <(ps -eo pid,args 2>/dev/null | grep -iE "$pattern" | grep -v "grep" | grep -v "claude-kill")
    done

    echo ""
    if [[ $total_killed -eq 0 ]]; then
        echo -e "${GREEN}No Claude-related processes found.${NC}"
    else
        echo -e "${GREEN}Done. Killed $total_killed process(es)/session(s).${NC}"
    fi
}
alias ck='claude-kill'

# Warn on login if orphaned Claude processes exist (called from zshrc).
# One ps + awk pass (the old per-PID ps/awk forks cost ~250 ms per login).
_claude_orphan_warning() {
    local found
    found=$(_claude_orphan_pids | awk '{ c++; ids = ids " " $1 } END { if (c) print c ids }')
    [[ -z "$found" ]] && return 0
    printf '\033[1;33m⚠ %s orphaned Claude process(es) detected (PIDs: %s)\033[0m\n' "${found%% *}" "${found#* }"
    printf '\033[1;33m  Run %s to inspect or %s to terminate\033[0m\n' "'claude-orphans'" "'claude-kill-orphans' (cko)"
}

# ── tmux session picker (interactive fzf, or list) ───────────────────
tm() {
    local sessions
    sessions=$(tmux ls 2>/dev/null)

    if [[ ! -t 0 || ! -t 1 ]]; then
        [[ -n "$sessions" ]] && echo "$sessions" || echo "No tmux sessions"
        return 0
    fi

    # MRU ordering: most-recently-attached session first.
    # Score per session = max of two signals, so neither can be stale:
    #   1. tmux's native #{session_last_attached} epoch — authoritative,
    #      updated on EVERY attach (incl. `tl`, raw `tmux attach`, IDEs).
    #   2. the picks log at $cache_dir/picks (one "epoch<TAB>session" per
    #      attach via this picker) — also captures the "[+ new session]"
    #      name you typed before tmux has recorded an attach for it.
    # Session name is the key (the part before the first ":" in a `tmux ls`
    # line). Never-attached sessions get score 0 and fall below attached
    # ones, then sort by name. "[+ new session]" is always pinned to top.
    local cache_dir="$HOME/.cache/tm"
    local picks="$cache_dir/picks"
    mkdir -p "$cache_dir" 2>/dev/null
    touch "$picks" 2>/dev/null

    local new_item="[+ new session]"
    local ordered=""
    if [[ -n "$sessions" ]]; then
        ordered=$(echo "$sessions" | awk -v picksfile="$picks" '
            BEGIN {
                FS="\n"
                # tmux native: most-recent attach epoch per session name.
                cmd = "tmux list-sessions -F \"#{session_last_attached}\t#{session_name}\" 2>/dev/null"
                while ((cmd | getline line) > 0) {
                    n = split(line, p, "\t")
                    if (n >= 2 && p[2] != "") mru[p[2]] = p[1]+0
                }
                close(cmd)
                # picks log: take whichever epoch is larger (last wins per line).
                while ((getline line < picksfile) > 0) {
                    n = split(line, p, "\t")
                    if (n >= 2 && p[2] != "" && p[1]+0 > mru[p[2]]) mru[p[2]] = p[1]+0
                }
                close(picksfile)
            }
            {
                # Session name = everything before the first ":" on the line.
                name = $0
                sub(/:.*/, "", name)
                score = (name in mru) ? mru[name] : 0
                # 20-digit zero-padded score so lexical desc sort == numeric;
                # carry the original `tmux ls` line intact as the payload.
                printf "%020d\t%s\t%s\n", score, name, $0
            }' | sort -t"$(printf '\t')" -k1,1nr -k2,2 | cut -f3-)
    fi

    local selected
    selected=$(printf '%s\n%s\n' "$new_item" "$ordered" \
        | fzf --height=40% --reverse --prompt="tmux> ")

    [[ -z "$selected" ]] && return 0

    # Record an attach for MRU (append epoch<TAB>session), trimmed to 200 lines.
    _tm_record() {
        { printf '%s\t%s\n' "$(date +%s)" "$1" >>"$picks"; } 2>/dev/null
        if [[ $(wc -l <"$picks" 2>/dev/null || echo 0) -gt 200 ]]; then
            tail -200 "$picks" >"$picks.tmp" 2>/dev/null && mv "$picks.tmp" "$picks" 2>/dev/null
        fi
    }

    if [[ "$selected" == "$new_item" ]]; then
        local name
        printf 'New session name: '
        read -r name
        [[ -z "$name" ]] && { echo "Cancelled"; return 1; }
        _tm_record "$name"
        if tmux has-session -t "$name" 2>/dev/null; then
            tmux attach -t "$name"
        else
            tmux new-session -s "$name"
        fi
    else
        local target="${selected%%:*}"
        _tm_record "$target"
        tmux attach -t "$target"
    fi
}

# ── tmux: attach to the most-recently-attached session ──────────────
# `tm` without the picker — jumps straight to whichever session tmux saw
# attached last (its own #{session_last_attached} epoch, authoritative
# regardless of how you attached). Never-attached sessions sort to the
# bottom. If already inside tmux, switches client instead of nesting.
tl() {
    local target
    target=$(tmux list-sessions -F '#{session_last_attached} #{session_name}' 2>/dev/null \
        | sort -k1,1nr | head -1 | cut -d' ' -f2-)

    if [[ -z "$target" ]]; then
        echo "No tmux sessions"
        return 1
    fi

    if [[ -n "$TMUX" ]]; then
        tmux switch-client -t "$target"
    else
        tmux attach -t "$target"
    fi
}

# ── PDF → Markdown via marker-pdf (WSL-aware; no-op on non-WSL) ──────
pdf2md() {
    if ! command -v marker_single &>/dev/null; then
        echo "marker not installed. Run: pipx install marker-pdf"
        return 1
    fi

    local input="$1"
    local output_dir="${2:-.}"

    if [[ -z "$input" ]]; then
        echo "Usage: pdf2md <input.pdf> [output_dir]"
        return 1
    fi

    # Convert Windows path to WSL path if needed (harmless elsewhere)
    if [[ "$input" == *":"* ]]; then
        input=$(wslpath -u "$input" 2>/dev/null || echo "$input")
    fi

    local basename="${input##*/}"
    local outname="${basename%.*}.md"

    echo "Converting: $input -> $output_dir/$outname"
    marker_single "$input" --output_dir "$output_dir"
}

# ── acpx (source-linked install) ─────────────────────────────────────
# acpx runs from a git clone (pnpm link --global), not the npm registry.
# Pull latest, refresh deps, rebuild — the global `acpx` picks up the new
# dist/ immediately since the wrapper points straight at the checkout.
acpx-update() {
    local repo="${ACPX_REPO:-$HOME/code/acpx}"
    if [[ ! -d "$repo/.git" ]]; then
        echo "acpx-update: $repo is not a git clone (set ACPX_REPO)" >&2
        return 1
    fi
    ( set -e
      cd "$repo"
      echo "── git pull ──────────────────────────────"
      git pull --ff-only
      echo "── pnpm install ──────────────────────────"
      pnpm install
      echo "── pnpm run build ────────────────────────"
      pnpm run build
    ) && echo "── done: $(acpx --version) ───────────────"
}

# ── clawpatch (source-linked install) ────────────────────────────────
# Same shape as acpx-update: clawpatch runs from a git clone via an
# absolute-path wrapper in $PNPM_HOME/bin, not the npm registry. Pull
# latest main, refresh deps, rebuild — the global `clawpatch` picks up
# the new dist/ immediately.
clawpatch-update() {
    local repo="${CLAWPATCH_REPO:-$HOME/code/clawpatch}"
    if [[ ! -d "$repo/.git" ]]; then
        echo "clawpatch-update: $repo is not a git clone (set CLAWPATCH_REPO)" >&2
        return 1
    fi
    ( set -e
      cd "$repo"
      echo "── git pull ──────────────────────────────"
      git pull --ff-only
      echo "── pnpm install ──────────────────────────"
      pnpm install
      echo "── pnpm run build ────────────────────────"
      pnpm run build
    ) && echo "── done: $(clawpatch --version) ──────────"
}

# ── Mid-command abbreviations (expand-on-space) ──────────────────────
# A plain `alias` only expands in COMMAND position (the first word), so
# `alias dsp=--dangerously-skip-permissions` does nothing in `claude dsp`.
# zsh's `alias -g` does expand mid-command, but it fires EVERYWHERE — inside
# `echo dsp`, in `grep dsp file`, in a heredoc — which is unacceptable for a
# flag that disables permission prompts.
#
# Instead: a ZLE widget that rewrites the word to the left of the cursor when
# you press space. The full text lands in the buffer BEFORE you hit Enter, so
# you always see what will run and history records the real command (a global
# alias records the cryptic token and hides the flag from `history`/audit).
#
# Add entries to the ABBRS map below. Keys must be [-_a-zA-Z0-9] only.
#
# Escape hatches (all verified): Ctrl-Space inserts a literal space with no
# expansion, and quoting the token suppresses it ("dsp" or a bare open quote —
# the guard requires whitespace before the word, and a quote char isn't
# whitespace). Known tradeoff: an unquoted `grep dsp file` DOES expand, since
# the widget can't know the word is data rather than a flag. Quote it or use
# Ctrl-Space; either way you see the result before pressing Enter.
if [[ -n "${ZSH_VERSION:-}" ]] && [[ -o interactive ]]; then
    typeset -gA ABBRS
    ABBRS=(
        dsp  '--dangerously-skip-permissions'
    )

    # Expand the trailing word of LBUFFER if it's a known abbreviation.
    # Guard: only when the token starts the line or follows whitespace, so
    # `cd /some/path/dsp`, `mydsp`, and `FOO=dsp` are all left alone.
    _abbr_expand() {
        emulate -L zsh
        setopt extended_glob
        local MATCH word head
        head=${LBUFFER%%(#m)[-_a-zA-Z0-9]#}
        word=$MATCH
        if [[ -n "$word" && ( -z "$head" || "$head" == *[[:space:]] ) \
              && -n "${ABBRS[$word]}" ]]; then
            LBUFFER="$head${ABBRS[$word]}"
        fi
    }

    _abbr_expand_and_space() { _abbr_expand; zle self-insert; }
    _abbr_expand_and_accept() { _abbr_expand; zle accept-line; }

    zle -N _abbr_expand_and_space
    zle -N _abbr_expand_and_accept
    bindkey ' '    _abbr_expand_and_space    # space expands then inserts a space
    bindkey '^M'   _abbr_expand_and_accept   # Enter expands then runs
    # Ctrl-Space: literal space, no expansion. Terminals disagree on the byte
    # sent (^@ NUL vs a literal ^-space), so bind both.
    bindkey '^ '   magic-space
    bindkey '^@'   magic-space
fi
