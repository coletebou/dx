#!/bin/bash
# Claude Code statusline script
# Requires: jq (install via: sudo apt install jq)

# Every git call below only reads. `git status` also refreshes the index and
# writes it back under index.lock when it can, and this script runs on every
# message update in whatever repo or worktree the session last cd'd into, so the
# session's own `git add`/`git commit` a moment later failed with "index.lock:
# File exists". GIT_OPTIONAL_LOCKS=0 skips that optional write for every git
# process started from here; the displayed counts are unchanged.
export GIT_OPTIONAL_LOCKS=0

# Check for jq dependency
if ! command -v jq &>/dev/null; then
    printf '\033[38;5;196mjq not installed\033[0m - run: sudo apt install jq'
    exit 0
fi

# ── Portable helpers ─────────────────────────────────────────────────
# mtime of $1, or 0. `stat -c` is GNU/Linux, `stat -f` is macOS/BSD. Every
# mtime read MUST go through this: a bare `stat -c` on a Mac without Homebrew
# coreutils on PATH fails, and the surrounding `|| echo 0` then yields an age
# of ~56 years — so every cache looks stale forever and the "cached" glab call
# ran on EVERY render. Centralized so a new call site can't reintroduce it.
mtime_of() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Seconds since $1 was modified; a missing/unreadable file yields a huge age
# (treated as stale by callers), never a negative or empty value.
age_of() {
    local m
    m=$(mtime_of "$1")
    [[ "$m" =~ ^[0-9]+$ ]] || m=0
    printf '%d' "$(( $(date +%s) - m ))"
}

# Format an epoch as UTC HH:MMZ. The two spellings are a FALSE FRIEND, not a
# simple GNU/BSD split: BSD `date -r <epoch>` means "seconds since epoch", but
# GNU defines `-r, --reference=FILE`. So on GNU (Linux, and any Mac with
# Homebrew coreutils first on PATH) `date -r 1784980800` looks for a
# FILE named 1784980800 — relative to the cwd we just cd'd into. Normally that
# errors and a `||` fallback rescues it, but if such a file happens to exist the
# wrong time is printed with no error at all. Probe the implementation instead
# of ordering fallbacks and hoping.
epoch_to_hhmm() {
    if date --version >/dev/null 2>&1; then
        date -u -d "@$1" +%H:%MZ 2>/dev/null      # GNU
    else
        date -u -r "$1" +%H:%MZ 2>/dev/null       # BSD
    fi
}

# Family+version for the model segment, e.g. opus5 / opus4.8 / haiku4.5.
#
# BOTH fields must be handled: their shapes differ by how the session was
# launched, verified by capturing the real live stdin payload.
#   - resumed session (`claude -r <id>`):  id="claude-opus-5", display_name="Opus"
#       -> version only in the id; display_name is a BARE family.
#   - `claude --model opus`:               id="global.anthropic.claude-opus-5[1m]",
#                                          display_name="Opus 5 (1M context)"
#       -> version in both.
# So we parse the id first, then mine a version out of display_name, and only
# then fall back to the bare family. Never assume one field carries it.
# bash 3.2 compatible (macOS /bin/bash) — no ${v,,}, no associative arrays.
# NO SUBPROCESSES: this runs on every render, and a single $( )+tr fork costs
# ~10ms on macOS — more than the entire consolidated-jq pass. Case-folding uses
# a literal `case` map rather than `tr`, and dash-to-dot uses ${v//-/.} (which
# works on bash 3.2).
parse_model() {
    local id="$1" dn="$2" s fam ver

    # ── 1. display_name, but ONLY when it actually carries a version.
    # A bare family ("Opus") is what a resumed session sends, and the id is the
    # only version source in that case — so a bare label must NOT short-circuit
    # the id parse below. When display_name IS versioned ("Opus 5", "Haiku 4.5",
    # "Sonnet 3.7") it is the most reliable source, and the only one for legacy
    # version-first ids like claude-3-7-sonnet.
    case "$dn" in
        *Opus*|*opus*)     fam="opus" ;;
        *Sonnet*|*sonnet*) fam="sonnet" ;;
        *Haiku*|*haiku*)   fam="haiku" ;;
        *Fable*|*fable*)   fam="fable" ;;
        *Mythos*|*mythos*) fam="mythos" ;;
        *)                 fam="" ;;
    esac
    if [[ -n "$fam" ]]; then
        # Version = first number in the label, but NOT the "1" of "(1M context)".
        case "$dn" in
            *"(1M context)"*|*"(1m context)"*) s="${dn%%(*}" ;;
            *) s="$dn" ;;
        esac
        if [[ "$s" =~ ([0-9]+(\.[0-9]+)?) ]]; then
            ver="${BASH_REMATCH[1]}"
            ver="${ver%.0}"      # "Opus 4" is never called "opus4.0"
            printf '%s%s' "$fam" "$ver"
            return
        fi
    fi

    # ── 2. display_name had no version — parse the id. `fam` is kept as the
    # fallback family for an id that turns out to be unparseable too.
    s="$id"
    s="${s%%\[*}"      # drop a "[1m]" harness token — not part of the model id
    s="${s%% *}"       # drop any trailing prose
    s="${s%%:*}"       # drop a Bedrock ":0" revision (…-v1:0)
    s="${s%-v[0-9]}"   # drop the Bedrock "-v1" version segment
    s="${s##*/}"
    # Strip region/partition/vendor prefixes: global. us. us-gov. eu. apac.
    # anthropic. openai. bedrock. — applied repeatedly since they stack
    # (e.g. us-gov.anthropic.claude-opus-4-8).
    while :; do
        case "$s" in
            global.*|us.*|us-gov.*|eu.*|apac.*|anthropic.*|openai.*|bedrock.*)
                s="${s#*.}" ;;
            *) break ;;
        esac
    done
    s="${s#claude-}"
    # Drop a trailing -YYYYMMDD datestamp (claude-haiku-4-5-20251001).
    if [[ "$s" =~ ^(.+)-[0-9]{8}$ ]]; then s="${BASH_REMATCH[1]}"; fi
    # Version-FIRST legacy ids: 3-7-sonnet -> sonnet3.7, 3-opus -> opus3.
    if [[ "$s" =~ ^([0-9]+)-([0-9]+)-([a-z]+)$ ]]; then
        printf '%s%s.%s' "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        return
    fi
    if [[ "$s" =~ ^([0-9]+)-([a-z]+)$ ]]; then
        printf '%s%s' "${BASH_REMATCH[2]}" "${BASH_REMATCH[1]}"
        return
    fi
    # family-N or family-N-M -> familyN / familyN.M
    if [[ "$s" =~ ^([a-z]+)-([0-9]+(-[0-9]+)*)$ ]]; then
        ver="${BASH_REMATCH[2]//-/.}"
        printf '%s%s' "${BASH_REMATCH[1]}" "${ver%.0}"
        return
    fi
    # Already-dotted, e.g. gpt-5.4
    if [[ "$s" =~ ^([a-z]+)-?([0-9]+(\.[0-9]+)*)$ ]]; then
        ver="${BASH_REMATCH[2]}"
        printf '%s%s' "${BASH_REMATCH[1]}" "${ver%.0}"
        return
    fi
    # Id carried no version either. Prefer the family we recognized from
    # display_name; else the cleaned id; else a stable placeholder — never an
    # empty segment. Spaces would read as two fields in the bar, so collapse.
    s="${fam:-${s:-unknown}}"
    printf '%s' "${s// /}"
}

# Issue number a branch is named after, behind an optional type/ prefix:
# 8544_mobile-header, 1847-image-gen-admin, feat/123-fix-login. Prints nothing
# for other branches, including date-led ones (2026-10-06-sync is not #2026).
branch_issue_number() {
    local name="${1#*/}"
    [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] && return 0
    [[ "$name" =~ ^([0-9]{1,6})[-_] ]] && printf '%s' "${BASH_REMATCH[1]}"
    return 0
}

# Web page for issue ref $1 (a bare number, or a URL the prompt hook recorded)
# in the repo whose origin URL is $2: a GitHub issue for github.com, a GitLab
# issue for gitlab.com or any host listed in STATUSLINE_GITLAB_HOSTS
# (space-separated, for self-hosted GitLab). Prints nothing when neither
# applies. Recorded URLs are re-checked against a strict shape because they end
# up inside an OSC 8 escape.
issue_url() {
    local ref="$1" origin="$2" host path h
    if [[ "$ref" =~ ^https?:// ]]; then
        [[ "$ref" =~ ^https?://[A-Za-z0-9.:-]+/[A-Za-z0-9/_.-]+/[0-9]+$ ]] && printf '%s' "$ref"
        return 0
    fi
    [[ "$ref" =~ ^[0-9]+$ ]] || return 0
    if [[ "$origin" =~ github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
        printf 'https://github.com/%s/issues/%s' "${BASH_REMATCH[1]%.git}" "$ref"
        return 0
    fi
    # GitLab: https://host/group/sub/project(.git) or git@host:group/project.git.
    # Credentials in an https origin (user:token@) are dropped with the prefix.
    if [[ "$origin" =~ ^(https?://|ssh://)?([^@/]+@)?([A-Za-z0-9.-]+)(:[0-9]+)?[:/]([A-Za-z0-9_./-]+)$ ]]; then
        host="${BASH_REMATCH[3]}" path="${BASH_REMATCH[5]%.git}"
        path="${path%/}"
        for h in gitlab.com ${STATUSLINE_GITLAB_HOSTS:-}; do
            if [[ "$host" == "$h" && "$path" == */* ]]; then
                printf 'https://%s/%s/-/issues/%s' "$host" "$path" "$ref"
                return 0
            fi
        done
    fi
    return 0
}

# Sourced by statusline.test.sh to unit-test the helpers above without
# reading stdin or rendering.
if [[ -n "${STATUSLINE_LIB_ONLY:-}" ]]; then
    # `return` when sourced; the `exit` is the fallback if someone executes it
    # with the flag set. shellcheck can't see the sourced path, hence SC2317.
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

input=$(cat)

# ── Single consolidated jq pass ──────────────────────────────────────
# Every field the script needs, extracted in ONE jq process. This was 9
# separate `echo "$input" | jq` spawns, which measured 66ms/render vs 6.7ms
# for the consolidated form — a 10x cut on a script that re-runs on every
# assistant message.
#
# Delimiter is US (0x1f), NOT a tab. Tab is IFS *whitespace*, so bash collapses
# runs of it even with IFS=$'\t' — one empty field (e.g. no /effort set) would
# shift every later field left, and `transcript_path` would land in `effort`.
# A non-whitespace delimiter makes each empty field its own empty column. US
# also cannot appear in any of these values, so nothing needs escaping.
IFS=$'\x1f' read -r model_id model_full session_cwd session_id effort \
    transcript_path pct cache_read cache_create raw_cost \
    ctx_size ctx_tokens rl5 rl7 <<EOF
$(printf '%s' "$input" | jq -j '
    [ .model.id // ""
    , .model.display_name // ""
    , .workspace.current_dir // "."
    , .session_id // ""
    , .effort.level // ""
    , .transcript_path // ""
    , (.context_window.used_percentage // 0 | floor | tostring)
    , ((.context_window.current_usage // .current_usage // .cost.current_usage // {}) | .cache_read_input_tokens // 0 | tostring)
    , ((.context_window.current_usage // .current_usage // .cost.current_usage // {}) | .cache_creation_input_tokens // 0 | tostring)
    , (.cost.total_cost_usd // 0 | tostring)
    , (.context_window.context_window_size // 0 | tostring)
    , ((.context_window.current_usage // .current_usage // .cost.current_usage // {})
       | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) | tostring)
    , (.rate_limits.five_hour.used_percentage // null | if . == null then "" else (floor | tostring) end)
    , (.rate_limits.seven_day.used_percentage // null | if . == null then "" else (floor | tostring) end)
    ] | join("")' 2>/dev/null)
EOF

# Defaults for a malformed/empty payload — jq failing must not blank the line.
session_cwd="${session_cwd:-.}"
[[ "$pct" =~ ^[0-9]+$ ]] || pct=0
[[ "$cache_read" =~ ^[0-9]+$ ]] || cache_read=0
[[ "$cache_create" =~ ^[0-9]+$ ]] || cache_create=0
[[ -n "$raw_cost" ]] || raw_cost=0
[[ "$ctx_size" =~ ^[0-9]+$ ]] || ctx_size=0
[[ "$ctx_tokens" =~ ^[0-9]+$ ]] || ctx_tokens=0
sid_file="${session_id//[^A-Za-z0-9._-]/_}"

# ── Context sensor for hooks ──────────────────────────────────────────
# Hooks receive no token count; the statusline receives the exact live
# context_window. Publishing it gives context_advisor.py (PostToolBatch) an
# exact figure, and lets its bash fast path skip Python below 100k tokens.
# Written only when the count changes; the comparison uses the `read` builtin
# (no fork), so an unchanged render costs nothing.
if [[ -n "$session_id" ]] && (( ctx_tokens > 0 )); then
    sensor_dir="${CONTEXT_SENSOR_DIR:-$HOME/.claude/state/context}"
    sensor="$sensor_dir/${sid_file}.json"
    sensor_prev=""
    [[ -r "$sensor" ]] && IFS= read -r sensor_prev < "$sensor"
    if [[ "$sensor_prev" != "{\"tokens\":${ctx_tokens},"* ]]; then
        [[ -d "$sensor_dir" ]] || mkdir -p "$sensor_dir" 2>/dev/null
        printf '{"tokens":%d,"size":%d,"pct":%d,"ts":%d}\n' "$ctx_tokens" "$ctx_size" "$pct" "$(date +%s)" \
            > "$sensor.$$" 2>/dev/null && mv -f "$sensor.$$" "$sensor" 2>/dev/null
    fi
fi

# ── tmux activity registration (base/tmux-agent-activity.sh) ─────────
# Tells the tmux status job which transcript this pane's Claude writes, so the
# window's recency color follows real session activity instead of TUI redraws.
# Set once per session, pane and pid: the compare is a builtin read, so a steady
# render forks nothing. CLAUDE_PID is the claude process; the job unregisters
# the pane once it dies.
if [[ -n "${TMUX_PANE:-}" && -n "$session_id" && -n "$transcript_path" && -n "${CLAUDE_PID:-}" ]]; then
    tmux_reg="$TMUX_PANE $CLAUDE_PID $transcript_path"
    tmux_reg_cache="/tmp/claude-tmux-reg-${sid_file}"
    tmux_reg_prev=""
    [[ -r "$tmux_reg_cache" ]] && IFS= read -r tmux_reg_prev < "$tmux_reg_cache"
    if [[ "$tmux_reg_prev" != "$tmux_reg" ]]; then
        tmux set-option -p -t "$TMUX_PANE" @claude_reg "$CLAUDE_PID $transcript_path" 2>/dev/null \
            && printf '%s\n' "$tmux_reg" > "$tmux_reg_cache" 2>/dev/null
    fi
fi

model=$(parse_model "$model_id" "$model_full")

# Resolve the *actually-active* cwd. Claude Code's workspace.current_dir is
# fixed at session start, so it's wrong when the session launches in one
# checkout but work happens in a worktree. Prefer (in order):
#   1. Per-session cwd tracked by the PostToolUse/track-cwd.sh hook
#   2. Most-recently-modified git repo under ~/code/ if that repo has been
#      touched more recently than the session_cwd
#   3. session_cwd (the original default)
cwd="$session_cwd"
tracked_file="/tmp/claude-cwd-${session_id}"
have_tracked=false
if [[ -n "$session_id" && -r "$tracked_file" ]]; then
    tracked_cwd=$(cat "$tracked_file" 2>/dev/null)
    if [[ -n "$tracked_cwd" && -d "$tracked_cwd" ]]; then
        cwd="$tracked_cwd"
        have_tracked=true
    fi
fi

# Recency fallback — ONLY when the track-cwd hook hasn't answered yet (first
# render of a session, before any Bash tool has run).
#
# The guard used to be `[[ "$cwd" == "$session_cwd" ]]`, which is true whenever
# the hook resolved to the SAME directory the session started in — the common
# case. So this 20-worktree scan ran on every render and its answer was
# discarded: ~57 extra forks and several hundred ms per render in a repo
# with 20 worktrees.
# `$have_tracked` asks the actual question ("do we already know?").
# Launch-dir root remembered when the recency guess below flips cwd to a
# sibling worktree. The issue link may fall back to it (see the issue block);
# the displayed worktree/branch never does.
issue_fallback_root=""
if ! $have_tracked; then
    # Try git worktree list from the session cwd first — handles the common
    # case where the session was launched in the main checkout but work is
    # happening in a sibling worktree.
    #
    # Only override if a sibling worktree's HEAD is *meaningfully* newer than
    # the session's own HEAD (>5 min). HEAD mtime updates on git fetch/status
    # too, so a 10-second lead is just noise — and would silently flip the
    # statusline to whichever worktree another agent happened to touch last.
    if worktree_list=$(cd "$session_cwd" 2>/dev/null && git worktree list --porcelain 2>/dev/null); then
        # Read the worktree pointer with bash builtins — `cat | sed` was two
        # extra forks per worktree (60 for 20 worktrees) for a job `read` and
        # ${v#prefix} do natively.
        head_mtime() {
            local wt="$1" head_file gitdir line
            if [[ -f "$wt/.git" ]]; then
                read -r line < "$wt/.git" 2>/dev/null || line=""
                gitdir="${line#gitdir: }"
                head_file="$gitdir/HEAD"
            else
                head_file="$wt/.git/HEAD"
            fi
            mtime_of "$head_file"
        }
        # Resolve the session's worktree ROOT. `head_mtime "$session_cwd"`
        # returned 0 for any session started in a SUBDIRECTORY (no .git there),
        # which made session_mtime=0 and collapsed the +300s guard below — so
        # any sibling worktree won and the statusline reported a DIFFERENT
        # worktree's branch, dirty count and ahead count than the session's.
        session_root=$(cd "$session_cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
        [[ -n "$session_root" ]] || session_root="$session_cwd"
        session_mtime=$(head_mtime "$session_root")
        newest_cwd=""
        newest_mtime=0
        while IFS= read -r line; do
            case "$line" in
                worktree\ *)
                    current_wt="${line#worktree }"
                    [[ "$current_wt" == "$session_root" ]] && continue
                    wt_mtime=$(head_mtime "$current_wt")
                    if (( wt_mtime > newest_mtime )); then
                        newest_mtime=$wt_mtime
                        newest_cwd="$current_wt"
                    fi
                    ;;
            esac
        done <<<"$worktree_list"
        # 300s = 5 min — only flip if the sibling is meaningfully newer.
        # session_mtime must be a real mtime: if resolving it failed (0), the
        # comparison would be "anything > 300", i.e. no guard at all, and we'd
        # mislabel the session. Failing closed keeps the session's own cwd.
        if [[ -n "$newest_cwd" ]] && (( session_mtime > 0 )) \
           && (( newest_mtime > session_mtime + 300 )); then
            cwd="$newest_cwd"
            issue_fallback_root="$session_root"
        fi
    fi
fi
session_suffix="${session_id: -5}"

# Effort level — 2.1.119+ stdin JSON exposes the live session value at
# .effort.level (reflects /effort overrides, not just persisted settings).
# Extracted in the consolidated jq pass above.
case "$effort" in
    low)     effort_abbr="lo" ;;
    medium)  effort_abbr="md" ;;
    high)    effort_abbr="hi" ;;
    xhigh)   effort_abbr="xh" ;;
    max)     effort_abbr="mx" ;;
    null|"") effort_abbr="" ;;
    *)       effort_abbr="$effort" ;;
esac

# Identity (install.sh writes DF_IDENTITY to ~/.df-profile; zshenv exports it).
# Read with builtins when it is not in the environment: no fork per render.
df_id="${DF_IDENTITY:-}"
if [[ -z "$df_id" && -r "$HOME/.df-profile" ]]; then
    while IFS= read -r df_line; do
        [[ "$df_line" == "export DF_IDENTITY="* ]] && { df_id="${df_line#export DF_IDENTITY=}"; break; }
    done < "$HOME/.df-profile"
fi
df_id="${df_id//[^A-Za-z0-9._-]/}"

# Get machine name (shortened for display). Labels are configuration, not code:
# DF_HOST_LABEL wins, then the first line of the hosts file whose glob matches
# the short hostname, then the hostname itself. The hosts file belongs to your
# identity (identities/<id>/hosts, see identities/example/hosts) and is shared
# with the tmux status bar (base/tmux-hostname.sh, base/tmux-tabhost.sh). One
# rule per line, first match wins:
#     <hostname glob>  <label>  [work]
#     my-desktop       desk
#     corp-laptop-*    corp     work
# "work" marks a machine whose sessions should look different: an orange label
# and no cost segment (see is_work below).
host_name=$(hostname -s 2>/dev/null || hostname)
host_name=$(printf '%s' "${host_name%%.*}" | tr '[:upper:]' '[:lower:]')
machine="${DF_HOST_LABEL:-}"
host_is_work=false
df_hosts_file="${DF_HOSTS_FILE:-${DOTFILES_DIR:-$HOME/.dotfiles}/identities/${df_id:-none}/hosts}"
if [[ -r "$df_hosts_file" ]]; then
    while read -r h_glob h_label h_flag _; do
        [[ -z "$h_glob" || "$h_glob" == \#* || -z "$h_label" ]] && continue
        # shellcheck disable=SC2053  # the glob is a pattern on purpose
        if [[ "$host_name" == $h_glob ]]; then
            [[ -n "$machine" ]] || machine="$h_label"
            [[ "$h_flag" == "work" ]] && host_is_work=true
            break
        fi
    done < "$df_hosts_file"
fi
[[ -n "$machine" ]] || machine="$host_name"

# Truncate a string to at most $2 chars; if longer, cut to ($2 - 1) + ellipsis
# (U+2026, single visible col).
truncate_to() {
    local name="$1" max="$2"
    if (( ${#name} > max )); then
        printf '%s…' "${name:0:$((max - 1))}"
    else
        printf '%s' "$name"
    fi
}

# If a name starts with a 4-digit issue number followed by a dash (the
# issue-numbered branch convention, e.g. 1847-image-gen-admin), return just the digits.
# Otherwise echo the input unchanged.
extract_issue_prefix() {
    local name="$1"
    if [[ "$name" =~ ^([0-9]{4})- ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$name"
    fi
}

# Strip a leading 4-digit issue prefix + first dash from a branch name and
# truncate the remainder to 10 chars. Branches without the prefix are
# truncated as-is.
shorten_branch() {
    local name="$1"
    if [[ "$name" =~ ^[0-9]{4}-(.+)$ ]]; then
        truncate_to "${BASH_REMATCH[1]}" 10
    else
        truncate_to "$name" 14
    fi
}

# Get git info
# If both the tracked cwd and $HOME are unreachable, stay put rather than
# running the git block against whatever directory we happen to be in — a
# deleted worktree would otherwise report the PARENT repo's branch.
cd "$cwd" 2>/dev/null || cd ~ 2>/dev/null || true
if git rev-parse --git-dir > /dev/null 2>&1; then
    worktree_raw=$(basename "$cwd")
    worktree=$(truncate_to "$(extract_issue_prefix "$worktree_raw")" 14)
    # `git branch --show-current` exits 0 with EMPTY stdout on a detached HEAD,
    # so `|| echo detached` never fired and the branch field rendered blank.
    # Key the fallback off empty output, not off exit status.
    branch_raw=$(git branch --show-current 2>/dev/null)
    [[ -n "$branch_raw" ]] || branch_raw="detached"
    # Strip prefix up to and including the first slash (e.g. feat/foo → foo),
    # then strip a 4-digit issue prefix and truncate.
    branch=$(shorten_branch "${branch_raw#*/}")

    # Dirty + unpushed counts
    dirty=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
    git_suffix=""
    (( dirty > 0 )) && git_suffix+=$(printf '\033[38;5;166m*%d\033[0m' "$dirty")
    (( ahead > 0 )) && git_suffix+=$(printf '\033[38;5;178m↑%d\033[0m' "$ahead")

    git_display=$(printf '\033[38;5;33m%s\033[0m:\033[38;5;34m%s\033[0m%s' "$worktree" "$branch" "$git_suffix")
else
    worktree_raw=$(basename "$cwd")
    worktree=$(truncate_to "$(extract_issue_prefix "$worktree_raw")" 14)
    git_display=$(printf '\033[38;5;33m%s\033[0m' "$worktree")
fi

# ── Issue link — the activity/issue this session works on (OSC 8) ────
# The branch's number wins; otherwise the last #N or issue URL you typed in this
# session (issue-focus-hook.sh writes it). Claude Code passes OSC 8 through as a
# clickable link; inside tmux it needs the `hyperlinks` terminal feature.
issue_ref=""
[[ -n "${branch_raw:-}" ]] && issue_ref=$(branch_issue_number "$branch_raw")
issue_file="/tmp/claude-issue-${sid_file}"
if [[ -z "$issue_ref" && -n "$session_id" && -r "$issue_file" ]]; then
    IFS= read -r issue_ref < "$issue_file" || true
fi
# Guessed sibling worktree on a detached HEAD, nothing typed yet: the number the
# session is really working on is in the LAUNCH directory's branch name
# (sessions on 8536_pwa-web-push rendered no link while a detached review
# worktree was the newest sibling). Link from that branch; the
# worktree and branch shown stay the guessed one, which is where the work is.
issue_origin=""
if [[ -z "$issue_ref" && "${branch_raw:-}" == "detached" && -n "$issue_fallback_root" ]]; then
    fallback_branch=$(git -C "$issue_fallback_root" branch --show-current 2>/dev/null)
    issue_ref=$(branch_issue_number "${fallback_branch:-}")
    [[ -n "$issue_ref" ]] && issue_origin=$(git -C "$issue_fallback_root" config --get remote.origin.url 2>/dev/null)
fi
if [[ -n "$issue_ref" ]]; then
    [[ -n "$issue_origin" ]] || issue_origin=$(git config --get remote.origin.url 2>/dev/null)
    issue_href=$(issue_url "$issue_ref" "$issue_origin")
    if [[ -n "$issue_href" ]]; then
        git_display+=$(printf ' \033]8;;%s\033\\\033[4;38;5;75m#%s\033[0m\033]8;;\033\\' \
            "$issue_href" "${issue_href##*/}")
    fi
fi

# ── Work identity — apply orange bg to machine name if work host ─────
# A machine is "work" when its hosts-file line says so, DF_WORK=1 is set, or
# its identity is one of DF_WORK_IDENTITIES (space-separated, default "work").
is_work=$host_is_work
[[ "${DF_WORK:-}" == "1" ]] && is_work=true
for w_id in ${DF_WORK_IDENTITIES:-work}; do
    [[ -n "$df_id" && "$df_id" == "$w_id" ]] && is_work=true
done

# ── MR status — open MR for current branch via glab (cached 5 min) ───
mr_display=""
if [[ -n "${branch_raw:-}" && "$branch_raw" != "detached" ]] && command -v glab &>/dev/null; then
    # Cache key from cwd+branch. md5sum is GNU-only (absent on stock macOS,
    # where it's `md5`); an empty hash would collapse every branch onto ONE
    # cache file and report the wrong MR. Prefer either binary, and fall back
    # to a sanitized literal key so the filename is never hash-less.
    # Key on the repo ROOT, not the raw cwd: the cached value depends only on
    # (repo, branch), so keying on cwd made every subdirectory pay its own
    # rate-limited round trip for an identical answer.
    mr_root=$(git rev-parse --show-toplevel 2>/dev/null) || mr_root="$cwd"
    [[ -n "$mr_root" ]] || mr_root="$cwd"
    mr_key=$(printf '%s' "$mr_root:$branch_raw" | { md5sum 2>/dev/null || md5 2>/dev/null; } | tr -cd '0-9a-f')
    if [[ -z "$mr_key" ]]; then
        mr_key=$(printf '%s' "$mr_root:$branch_raw" | tr -c '0-9A-Za-z' '_')
    fi
    mr_cache="/tmp/claude-mr-cache-$mr_key"
    mr_iid=""
    mr_cached=""
    if [[ -f "$mr_cache" ]] && (( $(age_of "$mr_cache") < 300 )); then
        mr_cached=$(cat "$mr_cache" 2>/dev/null)
    fi
    # "no open MR" is cached as the sentinel "-", NOT as an empty string.
    # Empty was indistinguishable from a cache MISS, so every branch without
    # an MR re-ran `glab api` on EVERY render — a network round-trip per
    # statusline update (measured ~0.5s), which is most branches most of the
    # time. The sentinel makes a negative result cacheable.
    if [[ -z "$mr_cached" ]]; then
        mr_iid=$(timeout 3 glab api "projects/:id/merge_requests?source_branch=$branch_raw&state=opened" 2>/dev/null | jq -r '.[0].iid // empty')
        printf '%s' "${mr_iid:--}" > "$mr_cache" 2>/dev/null
    elif [[ "$mr_cached" != "-" ]]; then
        mr_iid="$mr_cached"
    fi
    if [[ -n "$mr_iid" && "$mr_iid" != "-" ]]; then
        mr_display=$(printf ' | \033[38;5;208mMR !%s\033[0m' "$mr_iid")
    fi
fi

# ── Session duration — cached per session_id in /tmp ─────────────────
duration_display=""
if [[ -n "$session_id" ]]; then
    sess_start_file="/tmp/claude-session-start-${session_id}"
    if [[ ! -f "$sess_start_file" ]]; then
        date +%s > "$sess_start_file"
    fi
    start_ts=$(cat "$sess_start_file" 2>/dev/null)
    # Validate before arithmetic. `>` truncates before `date` writes, so a
    # render cancelled mid-flight (the harness cancels in-flight scripts) can
    # leave this file empty or partial — and macOS purges /tmp. A non-numeric
    # value made bash treat it as 0 and render a duration of ~495840h; a
    # multi-line one printed an arithmetic syntax error on every render. The
    # `-f` test above sees the file exists, so it was never repaired.
    if [[ ! "$start_ts" =~ ^[0-9]+$ ]]; then
        start_ts=$(date +%s)
        printf '%s' "$start_ts" > "$sess_start_file" 2>/dev/null
    fi
    if [[ -n "$start_ts" ]]; then
        now_ts=$(date +%s)
        dur=$((now_ts - start_ts))
        if (( dur >= 3600 )); then
            duration_display=$(printf ' | \033[38;5;244m%dh\033[0m' $((dur / 3600)))
        elif (( dur >= 60 )); then
            duration_display=$(printf ' | \033[38;5;244m%dm\033[0m' $((dur / 60)))
        fi
    fi
fi

# ── Transcript freshness — wall-clock time the transcript last changed ──
# transcript_path is in the statusline stdin JSON; its mtime is the last
# moment anything (user turn, assistant text, tool result) was appended.
# Shown as ✎HH:MM. Color shifts as it goes stale so an idle/wedged session
# is visible at a glance. stat: -c is GNU/Linux, -f is macOS/BSD.
transcript_display=""
if [[ -n "$transcript_path" && -f "$transcript_path" ]]; then
    t_mtime=$(mtime_of "$transcript_path")
    if [[ "$t_mtime" =~ ^[0-9]+$ ]] && (( t_mtime > 0 )); then
        # UTC with a Z suffix so the time reads the same on every machine
        # regardless of its timezone (a Mac on local time, a server on UTC).
        t_hhmm=$(epoch_to_hhmm "$t_mtime")
        t_age=$(( $(date +%s) - t_mtime ))
        if (( t_age < 300 )); then
            t_color="34"     # green — active in the last 5 min
        elif (( t_age < 1800 )); then
            t_color="178"    # yellow — quiet for 5-30 min
        else
            t_color="245"    # grey — idle 30+ min
        fi
        transcript_display=$(printf ' | \033[38;5;%sm✎%s\033[0m' "$t_color" "$t_hhmm")
    fi
fi

# ── Peer agents — busy count from `claude agents --json`, excluding self ──
# Cached for 10s to keep this off the critical path. Hidden when zero.
peers_display=""
# Requires a session_id: without one every such session would share the single
# cache file "/tmp/claude-peers-" and read each other's counts.
if [[ -n "$session_id" ]] && command -v claude &>/dev/null; then
    peers_cache="/tmp/claude-peers-${session_id}"
    peers_count=""
    if [[ -f "$peers_cache" ]] && (( $(age_of "$peers_cache") < 10 )); then
        peers_count=$(cat "$peers_cache" 2>/dev/null)
    fi
    if [[ -z "$peers_count" ]]; then
        # 1s timeout — never wedge the statusline if claude is hung.
        # (timeout is GNU coreutils; absent on stock macOS, where the
        # || fallback turns the failure into an empty agent list.)
        agents_json=$(timeout 1 claude agents --json 2>/dev/null || echo '[]')
        peers_count=$(jq --arg me "$session_id" '
            [.[] | select(.status == "busy" and .sessionId != $me)] | length
        ' <<<"$agents_json" 2>/dev/null || echo 0)
        printf '%s' "$peers_count" > "$peers_cache" 2>/dev/null
    fi
    # Guard the arithmetic — a failed jq/cat can yield empty or multi-line
    # output, which (( )) chokes on.
    [[ "$peers_count" =~ ^[0-9]+$ ]] || peers_count=0
    if (( peers_count > 0 )); then
        peers_display=$(printf ' | \033[38;5;46m🟢 %d\033[0m' "$peers_count")
    fi
fi

# ── API-error streak (api_error_recovery.py) — hidden when none ──────
# The state file exists only while a failure streak is open, so a plain `-f`
# test keeps this free on every normal render.
retry_display=""
retry_state="${API_RECOVERY_STATE_DIR:-$HOME/.claude/state/api-recovery}/${sid_file}.json"
if [[ -n "$session_id" && -f "$retry_state" ]]; then
    IFS=$'\x1f' read -r r_attempts r_class r_error <<EOF
$(jq -j '[(.attempts // 0 | tostring), (.last_class // ""), (.last_error // "")] | join("\u001f")' "$retry_state" 2>/dev/null)
EOF
    if [[ "$r_class" == "transient" || "$r_class" == "output" ]]; then
        retry_display=$(printf ' | \033[38;5;196m⚠ retry %s\033[0m' "${r_attempts:-?}")
    elif [[ -n "$r_error" ]]; then
        retry_display=$(printf ' | \033[38;5;196m⚠ %s\033[0m' "$r_error")
    fi
fi

# ── Context advisor hint (context_advisor.py) — shown only for "handoff" ──
# Jev judged this a good point for a fresh session; the advisor wrote a
# one-line JSON state, so a builtin read + regex extracts it without a fork.
advisor_display=""
advisor_state="${CONTEXT_ADVISOR_STATE_DIR:-$HOME/.claude/state/context-advisor}/${sid_file}.json"
if [[ -n "$session_id" && -r "$advisor_state" ]]; then
    advisor_line=""
    IFS= read -r advisor_line < "$advisor_state"
    if [[ "$advisor_line" =~ \"hint\":\ \"handoff\" ]]; then
        advisor_display=$(printf ' \033[38;5;178m↻handoff?\033[0m')
    fi
fi

# ── Handed off (cc-handoff launch) — first, on red ───────────────────
# The launcher writes a one-line marker for the session that ran it, with
# "target" first so a builtin regex reads it without a fork. "starting" (mid-
# launch, or a launch that failed after the window opened) shows as HANDOFF?;
# "ok"/"responded" (the successor started, then replied) as HANDED OFF; "held"
# means this session's background jobs keep its window open until they finish
# or the successor adopts them. Replaces the advisor hint.
handoff_display=""
handoff_state="${HANDOFF_STATE_DIR:-$HOME/.claude/state/handoff}/${sid_file}.json"
if [[ -n "$session_id" && -r "$handoff_state" ]]; then
    handoff_line=""
    IFS= read -r handoff_line < "$handoff_state"
    if [[ "$handoff_line" =~ ^\{\"target\":\"([^\"]+)\" ]]; then
        handoff_target="${BASH_REMATCH[1]//[^A-Za-z0-9_.:@-]/?}"
        case "$handoff_line" in
            *'"state":"ok"'*|*'"state":"responded"'*) handoff_label="HANDED OFF" ;;
            *'"state":"held"'*) handoff_label="HELD (jobs)" ;;
            *) handoff_label="HANDOFF?" ;;
        esac
        handoff_display=$(printf '\033[1;38;5;231;48;5;196m ⤳ %s → %s \033[0m ' "$handoff_label" "$handoff_target")
        advisor_display=""
    fi
fi

# ── Handoff generation (cc-handoff) — ⤷N after the session id ────────
# cc-handoff launch writes a one-line marker for the successor's session id
# before it starts, "gen" first, so a builtin regex reads it without a fork:
# ⤷3 is the third session of its chain. /clear (a new id) drops it.
gen_display=""
gen_state="${HANDOFF_CHAIN_STATE_DIR:-$HOME/.claude/state/handoff-chain}/${sid_file}.json"
if [[ -n "$session_id" && -r "$gen_state" ]]; then
    gen_line=""
    IFS= read -r gen_line < "$gen_state"
    if [[ "$gen_line" =~ ^\{\"gen\":([0-9]{1,4})[,}] ]] && (( BASH_REMATCH[1] > 1 )); then
        gen_display=$(printf ' \033[1;38;5;81m⤷%d\033[0m' "${BASH_REMATCH[1]}")
    fi
fi

# ── Open reflection items for this repo (`reflections`) ──────────────
# Counting needs the CLI (~70ms), so it runs in the background at most every
# 2 minutes per repo and the render shows the last cached count. Hidden at 0.
refl_display=""
refl_bin="${DOTFILES_DIR:-$HOME/.dotfiles}/scripts/reflections"
if [[ -x "$refl_bin" ]]; then
    # Keyed on the resolved cwd (the CLI maps it to the repo itself), which
    # avoids another git fork per render.
    refl_cache="/tmp/claude-refl-open-${cwd//[^A-Za-z0-9]/_}"
    if [[ ! -f "$refl_cache" ]] || (( $(age_of "$refl_cache") > 120 )); then
        touch "$refl_cache" 2>/dev/null  # claim the refresh so parallel renders don't pile up
        ( cd "$cwd" 2>/dev/null && n=$("$refl_bin" list --json --status open --limit 200 2>/dev/null | jq length 2>/dev/null) \
            && [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n" > "$refl_cache" ) </dev/null >/dev/null 2>&1 &
    fi
    refl_open=""
    [[ -r "$refl_cache" ]] && IFS= read -r refl_open < "$refl_cache"
    if [[ "$refl_open" =~ ^[0-9]+$ ]] && (( refl_open > 0 )); then
        refl_display=$(printf ' | \033[38;5;180m📝%d\033[0m' "$refl_open")
    fi
fi

# ── Subscription rate limits — only once they are worth a glance ─────
# rate_limits is present for claude.ai Pro/Max sessions only. 5h shows from
# 50%, the weekly window from 75%; colour escalates toward the limit.
limits_display=""
rl_color() { if (( $1 >= 90 )); then echo 196; elif (( $1 >= 75 )); then echo 208; else echo 178; fi; }
if [[ "$rl5" =~ ^[0-9]+$ ]] && (( rl5 >= 50 )); then
    limits_display+=$(printf ' | \033[38;5;%sm5h %d%%\033[0m' "$(rl_color "$rl5")" "$rl5")
fi
if [[ "$rl7" =~ ^[0-9]+$ ]] && (( rl7 >= 75 )); then
    limits_display+=$(printf ' | \033[38;5;%sm7d %d%%\033[0m' "$(rl_color "$rl7")" "$rl7")
fi

# Context usage — v2.1.6+ provides used_percentage directly (consolidated jq).
if (( pct >= 80 )); then
    ctx_color="196"
elif (( pct >= 60 )); then
    ctx_color="208"
elif (( pct >= 40 )); then
    ctx_color="178"
else
    ctx_color="34"
fi
context_display=$(printf '\033[38;5;%sm%d%%\033[0m' "$ctx_color" "$pct")

# ── Cache diagnostics — hit ratio only ───────────────────────────────
# Hit ratio = cache_read / (cache_read + cache_creation): high = stable prefix
# paying off; persistently low = something keeps invalidating the prefix. The
# colour already carries the signal, so the r<read>/w<write> token volumes were
# dropped as too wide for the bar (they read as "r112k/w1k"). Token counts come
# from the consolidated jq pass above.
cache_display=""
cache_total=$((cache_read + cache_create))
if (( cache_total > 0 )); then
    ratio=$(( cache_read * 100 / cache_total ))
    if (( ratio >= 70 )); then
        cache_color="34"    # green — caching is working well (mostly reads)
    elif (( ratio >= 40 )); then
        cache_color="178"   # yellow — mixed
    else
        cache_color="166"   # orange — prefix churn / expiry: big re-write this turn
    fi
    cache_display=$(printf ' | \033[38;5;%sm⚡%d%%\033[0m' "$cache_color" "$ratio")
fi

# Per-conversation cost (personal machines only)
cost_display=""
# Requires session_id for the same reason the peers block does: without one,
# every concurrent session shares "/tmp/claude-cost-offset-" and inherits the
# first session's cumulative cost as its baseline (rendering $0.0000 forever,
# since the awk clamp hides the resulting negative).
if ! $is_work && [[ -n "$session_id" ]]; then
    cost_offset_file="/tmp/claude-cost-offset-${session_id}"

    cost_offset=0
    if [[ -f "$cost_offset_file" ]]; then
        cost_offset=$(cat "$cost_offset_file" 2>/dev/null)
        # An empty/truncated offset file would make awk treat it as 0 and show
        # the full session cost instead of the per-conversation delta.
        [[ -n "$cost_offset" ]] || cost_offset="$raw_cost"
    else
        cost_offset="$raw_cost"
        printf '%s' "$cost_offset" > "$cost_offset_file"
    fi

    cost=$(echo "$raw_cost $cost_offset" | awk '{
        v = $1 - $2; if (v < 0) v = 0
        if (v < 0.01) printf "$%.4f", v
        else if (v < 1.00) printf "$%.3f", v
        else printf "$%.2f", v
    }')

    cost_display=$(printf ' | \033[38;5;148m%s\033[0m' "$cost")
fi

# Machine + session suffix (e.g. "dell:a7b2c"), orange bg if work host
if $is_work; then
    if [[ -n "$session_suffix" ]]; then
        machine_display=$(printf '\033[48;5;130m\033[38;5;255m%s:%s\033[0m' "$machine" "$session_suffix")
    else
        machine_display=$(printf '\033[48;5;130m\033[38;5;255m%s\033[0m' "$machine")
    fi
else
    if [[ -n "$session_suffix" ]]; then
        machine_display=$(printf '\033[38;5;245m%s\033[38;5;240m:\033[38;5;242m%s\033[0m' "$machine" "$session_suffix")
    else
        machine_display=$(printf '\033[38;5;245m%s\033[0m' "$machine")
    fi
fi

case "$effort_abbr" in
    mx) model_display=$(printf '\033[38;5;214m%s\033[38;5;240m·\033[1;3m\033[4:3m\033[58;5;87m\033[38;5;226mm\033[38;5;214ma\033[38;5;196mx\033[0m' "$model") ;;
    xh) model_display=$(printf '\033[38;5;214m%s\033[38;5;240m·\033[38;5;196m%s\033[0m' "$model" "$effort_abbr") ;;
    hi) model_display=$(printf '\033[38;5;214m%s\033[38;5;240m·\033[38;5;208m%s\033[0m' "$model" "$effort_abbr") ;;
    md) model_display=$(printf '\033[38;5;214m%s\033[38;5;240m·\033[38;5;178m%s\033[0m' "$model" "$effort_abbr") ;;
    lo) model_display=$(printf '\033[38;5;214m%s\033[38;5;240m·\033[38;5;245m%s\033[0m' "$model" "$effort_abbr") ;;
    "") model_display=$(printf '\033[38;5;214m%s\033[0m' "$model") ;;
    *)  model_display=$(printf '\033[38;5;214m%s\033[38;5;240m·\033[38;5;215m%s\033[0m' "$model" "$effort_abbr") ;;
esac

# Final assembly:
#   [⤳ HANDED OFF → s:w ]<machine:sess>[ ⤷gen] <worktree:branch[*dirty↑ahead]> | <modelVer·effort> [| MR !N]
#   | <%%>[ ↻handoff?] [| ⚠ retry N] [| ⚡hit%] [| ✎HH:MM] [| 🟢 peers] [| 📝open]
#   [| 5h N%] [| 7d N%] [| duration] [| cost]
printf '%s%s %s | %s%s | %s%s%s%s%s%s%s%s%s%s' \
    "$handoff_display" "$machine_display$gen_display" "$git_display" \
    "$model_display" "$mr_display" \
    "$context_display" "$advisor_display" "$retry_display" \
    "$cache_display" "$transcript_display" "$peers_display" "$refl_display" \
    "$limits_display" "$duration_display" "$cost_display"
