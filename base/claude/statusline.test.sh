#!/usr/bin/env bash
# statusline.test.sh — regression + unit tests for statusline.sh
#
# Two suites:
#   1. parse_model unit table — every real model id we've observed, plus edge
#      cases (empty, unknown, [1m] harness suffix, us-gov. prefix, legacy
#      version-first ids). Sourced directly, so it tests the function not the
#      rendering.
#   2. End-to-end render — feeds realistic stdin payloads through the script
#      and asserts on the ANSI-stripped output. Guards the assembly order and
#      the hidden-when-empty segments.
#
# Run: bash base/claude/statusline.test.sh
# Exits non-zero on any failure so it can gate a commit.
#
# Deliberately NOT run under `set -e` — we want every failure reported, not
# just the first.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="$SCRIPT_DIR/statusline.sh"

# Run from inside Claude Code in tmux, these would make every render register a
# test transcript on the CALLER's real pane (tmux activity registration). The
# suite that tests registration supplies its own, against a private server.
unset TMUX TMUX_PANE CLAUDE_PID
# The caller's own identity, host labels and dotfiles checkout must not leak into
# the renders either (the reflections segment reads <DOTFILES_DIR>/scripts).
unset DF_IDENTITY DF_HOSTS_FILE DF_HOST_LABEL DF_WORK DF_WORK_IDENTITIES STATUSLINE_GITLAB_HOSTS
export DOTFILES_DIR=/nonexistent-dotfiles-for-test

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31mFAIL\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

# Strip ANSI SGR sequences so assertions compare plain text.
strip_ansi() { sed 's/\x1b\[[0-9;:]*m//g'; }

# ── Suite 1: parse_model unit table ──────────────────────────────────
# STATUSLINE_LIB_ONLY makes statusline.sh define its functions and return
# without reading stdin or rendering, so we can unit-test parse_model.
# shellcheck source=/dev/null
STATUSLINE_LIB_ONLY=1 . "$STATUSLINE"

check_model() {
    local id="$1" dn="$2" want="$3" got
    got=$(parse_model "$id" "$dn")
    if [[ "$got" == "$want" ]]; then
        ok "parse_model('$id','$dn') = $want"
    else
        bad "parse_model('$id','$dn')" "$want" "$got"
    fi
}

printf '\n\033[1mparse_model — real model ids\033[0m\n'
check_model 'claude-opus-5'                        'Opus'    'opus5'
check_model 'claude-opus-4-8'                      'Opus'    'opus4.8'
check_model 'claude-opus-4-7'                      'Opus'    'opus4.7'
check_model 'claude-sonnet-5'                      'Sonnet'  'sonnet5'
check_model 'claude-sonnet-4-6'                    'Sonnet'  'sonnet4.6'
check_model 'claude-fable-5'                       'Fable'   'fable5'
check_model 'claude-fable-5-1'                     'Fable'   'fable5.1'
check_model 'claude-haiku-4-5-20251001'            'Haiku'   'haiku4.5'

printf '\n\033[1mparse_model — inference-profile prefixes\033[0m\n'
check_model 'global.anthropic.claude-opus-5'       'Opus'    'opus5'
check_model 'us.anthropic.claude-opus-5'           'Opus'    'opus5'
check_model 'us-gov.anthropic.claude-opus-4-8'     'Opus'    'opus4.8'
check_model 'eu.anthropic.claude-sonnet-5'         'Sonnet'  'sonnet5'

printf '\n\033[1mparse_model — harness suffix + non-Anthropic\033[0m\n'
# [1m] is a Claude Code harness token, not part of the Bedrock model id.
check_model 'global.anthropic.claude-opus-5[1m]'   'Opus'    'opus5'
check_model 'claude-opus-5[1m]'                    'Opus'    'opus5'
check_model 'openai.gpt-5.4'                       'GPT'     'gpt5.4'

printf '\n\033[1mparse_model — graceful degradation\033[0m\n'
# No id: fall back to the display_name family (today's behavior).
check_model ''                                     'Opus'    'opus'
check_model ''                                     'Sonnet'  'sonnet'
check_model ''                                     'Fable'   'fable'
check_model ''                                     'Haiku'   'haiku'
# Some launch paths put the version in display_name as prose; mine it, and do
# NOT harvest the "1" out of the "(1M context)" suffix.
check_model ''                                     'Opus 5 (1M context)' 'opus5'
check_model ''                                     'Opus (1M context)'   'opus'
check_model ''                                     'Sonnet 5'            'sonnet5'
check_model ''                                     'Haiku 4.5'           'haiku4.5'
# Real ids observed from `claude --model <alias>`: [1m] token + Bedrock -v1:0.
check_model 'global.anthropic.claude-opus-5[1m]'          'Opus 5 (1M context)' 'opus5'
check_model 'global.anthropic.claude-fable-5[1m]'         'Fable 5'             'fable5'
check_model 'global.anthropic.claude-fable-5-1[1m]'       'Fable 5.1'           'fable5.1'
check_model 'global.anthropic.claude-fable-5-1[1m]'       'Fable'               'fable5.1'
check_model 'us.anthropic.claude-haiku-4-5-20251001-v1:0' 'Haiku 4.5'           'haiku4.5'
# Nothing at all -> a stable placeholder, never an empty segment.
check_model ''                                     ''        'unknown'
check_model 'unknown'                              'unknown' 'unknown'
printf '\n\033[1mparse_model — legacy version-FIRST ids (still served in some regions)\033[0m\n'
# Some regional Bedrock catalogs lag by a year or more, so dated legacy ids are
# normal there. These must not collapse to a bare family indistinguishable from v5.
check_model 'claude-3-5-sonnet-20241022'                    'Sonnet'     'sonnet3.5'
check_model 'us-gov.anthropic.claude-3-7-sonnet-20250219-v1:0' 'Sonnet 3.7' 'sonnet3.7'
check_model 'us-gov.anthropic.claude-3-haiku-20240307-v1:0'    'Haiku 3'    'haiku3'
check_model 'claude-3-5-haiku'                              ''           'haiku3.5'

printf '\n\033[1mparse_model — no stray .0, no embedded space\033[0m\n'
# "Opus 4" is never written "opus4.0".
check_model 'claude-opus-4-0'   'Opus 4'    'opus4'
check_model 'claude-sonnet-4-0' 'Sonnet 4'  'sonnet4'
# Same cases with NO display_name, so the ID path (not the label path) does the
# trimming — without these the id-path `%.0` trims are untested.
check_model 'claude-opus-4-0'   ''          'opus4'
check_model 'claude-sonnet-4-0' ''          'sonnet4'
check_model 'openai.gpt-5.0'    ''          'gpt5'
# Mythos is a real family; a space inside the token would read as two fields.
check_model 'claude-mythos-5'   'Mythos 5'  'mythos5'
check_model ''                  'Mythos 5'  'mythos5'

# ── Suite 2: end-to-end render ───────────────────────────────────────
# Build a payload with overridable model/effort/cache fields.
payload() {
    # ${x-default} not ${x:-default}: the tests deliberately pass EMPTY values
    # (no model, no effort) and `:-` would substitute the default over them,
    # silently testing the wrong thing.
    local id="${1-claude-opus-5}" dn="${2-Opus}" effort="${3-xhigh}"
    local read_tok="${4-112000}" create_tok="${5-1000}" pct="${6-11}"
    printf '{"model":{"id":"%s","display_name":"%s"},' "$id" "$dn"
    printf '"workspace":{"current_dir":"%s"},' "$SCRIPT_DIR"
    printf '"session_id":"testsess12345","effort":{"level":"%s"},' "$effort"
    printf '"transcript_path":"/nonexistent-transcript",'
    printf '"context_window":{"used_percentage":%s,' "$pct"
    printf '"current_usage":{"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}},' \
        "$read_tok" "$create_tok"
    printf '"cost":{"total_cost_usd":1.23}}'
}

render() { payload "$@" | bash "$STATUSLINE" 2>&1 | strip_ansi; }

contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$desc"
    else
        bad "$desc" "output containing '$needle'" "$haystack"
    fi
}

not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        ok "$desc"
    else
        bad "$desc" "output WITHOUT '$needle'" "$haystack"
    fi
}

printf '\n\033[1mrender — model segment carries the version\033[0m\n'
out=$(render 'claude-opus-5' 'Opus' 'xhigh')
contains "opus5 with xhigh effort" 'opus5·xh' "$out"

out=$(render 'claude-opus-4-8' 'Opus' 'high')
contains "opus4.8 with high effort" 'opus4.8·hi' "$out"

out=$(render 'claude-fable-5' 'Fable' 'medium')
contains "fable5 lowercased with version" 'fable5·md' "$out"

out=$(render 'claude-sonnet-5' 'Sonnet' 'low')
contains "sonnet5 with low effort" 'sonnet5·lo' "$out"

out=$(render 'claude-haiku-4-5-20251001' 'Haiku' 'max')
contains "haiku4.5 renders max effort" 'haiku4.5' "$out"

printf '\n\033[1mrender — no effort set\033[0m\n'
out=$(render 'claude-opus-5' 'Opus' '')
contains "bare model, no separator" 'opus5' "$out"
not_contains "no dangling effort separator" 'opus5·' "$out"

printf '\n\033[1mrender — empty model never yields an empty segment\033[0m\n'
out=$(render '' '' 'xhigh')
contains "placeholder instead of bare separator" 'unknown·xh' "$out"

printf '\n\033[1mrender — cache segment is percentage-only\033[0m\n'
out=$(render 'claude-opus-5' 'Opus' 'xhigh' 112000 1000)
contains "cache hit percentage shown" '99%' "$out"
not_contains "no r<read> volume" 'r112k' "$out"
not_contains "no w<write> volume" 'w1k' "$out"

printf '\n\033[1mrender — cache hidden when no cache activity\033[0m\n'
out=$(render 'claude-opus-5' 'Opus' 'xhigh' 0 0)
# The needle was once mojibake ('â\232¡' in single quotes: no escapes), so this
# check could never fail. $'…' yields the real UTF-8 bytes of ⚡ (E2 9A A1).
not_contains "no lightning bolt at zero cache" $'\xe2\x9a\xa1' "$out"
out=$(render 'claude-opus-5' 'Opus' 'xhigh' 112000 1000)
contains "lightning bolt present when cache is active (needle is real)" $'\xe2\x9a\xa1' "$out"

printf '\n\033[1mrender — context percentage\033[0m\n'
out=$(render 'claude-opus-5' 'Opus' 'xhigh' 112000 1000 42)
contains "context percentage rendered" '42%' "$out"

printf '\n\033[1mrender — output is a single line, never empty\033[0m\n'
out=$(render)
if [[ -n "$out" ]]; then ok "non-empty output"; else bad "non-empty output" "some text" "(empty)"; fi
lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
if [[ "$lines" == "0" ]]; then ok "single line (no trailing newline)"; else bad "single line" "0 newlines" "$lines"; fi

printf '\n\033[1mrender — survives a malformed payload\033[0m\n'
out=$(printf 'not json at all' | bash "$STATUSLINE" 2>&1 | strip_ansi)
if [[ -n "$out" ]]; then ok "degrades to some output on bad JSON"; else bad "bad-JSON fallback" "some text" "(empty)"; fi

printf '\n\033[1mepoch_to_hhmm — GNU/BSD false friend\033[0m\n'
# GNU `date -r` means --reference=FILE, so a file NAMED like the epoch must not
# hijack the conversion. 1784980800 = 2026-07-23 12:00:00 UTC.
decoy_dir=$(mktemp -d)
( cd "$decoy_dir" && touch -t 202001011200 1784980800 )
got=$(cd "$decoy_dir" && epoch_to_hhmm 1784980800)
if [[ "$got" == "12:00Z" ]]; then
    ok "epoch wins over a same-named decoy file (got $got)"
else
    bad "epoch_to_hhmm with decoy file present" "12:00Z" "$got"
fi
rm -rf "$decoy_dir"

printf '\n\033[1mage_of — portable mtime, no 56-year cache miss\033[0m\n'
tmpf=$(mktemp)
got=$(age_of "$tmpf")
if [[ "$got" =~ ^[0-9]+$ ]] && (( got < 60 )); then
    ok "fresh file reads as young (${got}s)"
else
    bad "age_of on a fresh file" "a small integer" "$got"
fi
rm -f "$tmpf"
# A missing file must read as STALE (huge), never as 0/fresh.
got=$(age_of /nonexistent-file-for-test)
if [[ "$got" =~ ^[0-9]+$ ]] && (( got > 1000000 )); then
    ok "missing file reads as stale"
else
    bad "age_of on a missing file" "a huge integer" "$got"
fi

printf '\n\033[1mrender — corrupt session-start cache self-heals\033[0m\n'
# `>` truncates before `date` writes, so a cancelled render can leave this
# empty or non-numeric. Neither may produce a bogus duration or a bash error.
for bogus in '' 'not-a-number' '111
222'; do
    printf '%s' "$bogus" > /tmp/claude-session-start-testsess12345
    out=$(render 2>&1)
    label=$(printf '%s' "$bogus" | tr '\n' '/')
    if [[ "$out" != *"arithmetic"* && "$out" != *"495840h"* && "$out" != *"error"* ]]; then
        ok "no bogus duration or error for start_ts='${label:-<empty>}'"
    else
        bad "corrupt start_ts '${label:-<empty>}'" "clean output" "$out"
    fi
done
rm -f /tmp/claude-session-start-testsess12345

# ── Suite 3: hook-facing sensor + hook-state segments ────────────────
# Every state dir is redirected into a temp dir, never the real ~/.claude/state.
state_root=$(mktemp -d)
export CONTEXT_SENSOR_DIR="$state_root/context" API_RECOVERY_STATE_DIR="$state_root/api" \
       CONTEXT_ADVISOR_STATE_DIR="$state_root/advisor"
mkdir -p "$API_RECOVERY_STATE_DIR" "$CONTEXT_ADVISOR_STATE_DIR"

# Payload with the fields the new segments read: window size, input tokens,
# subscription rate limits.
payload_ext() {
    local rl5="$1" rl7="$2"
    printf '{"model":{"id":"claude-opus-5-5","display_name":"Opus"},"workspace":{"current_dir":"%s"},' "$SCRIPT_DIR"
    printf '"session_id":"testsess12345","effort":{"level":"high"},"transcript_path":"/nonexistent-transcript",'
    printf '"context_window":{"used_percentage":29,"context_window_size":1000000,'
    printf '"current_usage":{"input_tokens":500,"cache_read_input_tokens":280000,"cache_creation_input_tokens":9500}},'
    printf '"rate_limits":{"five_hour":{"used_percentage":%s},"seven_day":{"used_percentage":%s}},' "$rl5" "$rl7"
    printf '"cost":{"total_cost_usd":1.23}}'
}
render_ext() { payload_ext "$@" | bash "$STATUSLINE" 2>&1 | strip_ansi; }

printf '\n\033[1mcontext sensor — exact tokens published for hooks\033[0m\n'
out=$(render_ext 10 10)
sensor="$CONTEXT_SENSOR_DIR/testsess12345.json"
if [[ -r "$sensor" ]] && [[ "$(jq -r '"\(.tokens) \(.size)"' "$sensor")" == "290000 1000000" ]]; then
    ok "sensor holds input+cache tokens and the window size"
else
    bad "sensor file" "290000 1000000" "$(cat "$sensor" 2>/dev/null || echo missing)"
fi
before=$(mtime_of "$sensor"); sleep 1; render_ext 10 10 >/dev/null
if [[ "$(mtime_of "$sensor")" == "$before" ]]; then ok "unchanged count is not rewritten"; else bad "sensor rewrite" "same mtime" "rewritten"; fi

printf '\n\033[1mrate limits — shown only when worth a glance\033[0m\n'
out=$(render_ext 10 10)
not_contains "5h hidden under 50%" '5h ' "$out"
out=$(render_ext 62 60)
contains "5h shown at 62%" '5h 62%' "$out"
not_contains "7d hidden under 75%" '7d ' "$out"
out=$(render_ext 91 80)
contains "7d shown at 80%" '7d 80%' "$out"

printf '\n\033[1mAPI-error streak and advisor hint\033[0m\n'
printf '{"attempts":3,"last_class":"transient","last_error":"server_error"}' > "$API_RECOVERY_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
contains "transient streak shows its retry count" '⚠ retry 3' "$out"
printf '{"attempts":0,"last_class":"config","last_error":"model_not_found"}' > "$API_RECOVERY_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
contains "non-retryable streak shows the error" '⚠ model_not_found' "$out"
rm -f "$API_RECOVERY_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
not_contains "no streak, no warning" '⚠' "$out"
printf '{"band": 1, "hint": "handoff", "tokens": 290000}\n' > "$CONTEXT_ADVISOR_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
contains "advisor handoff hint" '↻handoff?' "$out"
printf '{"band": 1, "hint": "lean", "tokens": 290000}\n' > "$CONTEXT_ADVISOR_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
not_contains "lean hint stays quiet" '↻' "$out"

printf '\n\033[1mhandoff marker (cc-handoff launch)\033[0m\n'
export HANDOFF_STATE_DIR="$state_root/handoff"
mkdir -p "$HANDOFF_STATE_DIR"
out=$(render_ext 10 10)
not_contains "no marker, no badge" '⤳' "$out"
printf '{"band": 2, "hint": "handoff", "tokens": 290000}\n' > "$CONTEXT_ADVISOR_STATE_DIR/testsess12345.json"
printf '{"target":"handoffs:work-2","pane":"%%9","brief":"/b/README.md","state":"ok","ts":1}\n' \
    > "$HANDOFF_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
if [[ "$out" == " ⤳ HANDED OFF → handoffs:work-2 "* ]]; then ok "handed-off badge leads the line"
else bad "handed-off badge" "leading ' ⤳ HANDED OFF → handoffs:work-2 '" "$out"; fi
not_contains "badge replaces the advisor hint" '↻handoff?' "$out"
raw=$(payload_ext 10 10 | bash "$STATUSLINE" 2>&1)
contains "badge is on a red background" $'\033[1;38;5;231;48;5;196m' "$raw"
printf '{"target":"handoffs:work-2","pane":"%%9","brief":"/b/README.md","state":"starting","ts":1}\n' \
    > "$HANDOFF_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
contains "a launch that has not confirmed reads HANDOFF?" '⤳ HANDOFF? → handoffs:work-2' "$out"
printf '{"target":"x\033[31my","state":"ok"}\n' > "$HANDOFF_STATE_DIR/testsess12345.json"
out=$(payload_ext 10 10 | bash "$STATUSLINE" 2>&1)
contains "control characters in the target are neutralized" '→ x??31my ' "$out"
printf '{"target":"ops:5","pane":"%%9","brief":"/b/gen-02/brief.md","state":"responded","ts":1}\n' \
    > "$HANDOFF_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
contains "a successor that replied reads HANDED OFF" '⤳ HANDED OFF → ops:5 ' "$out"
printf '{"target":"ops:5","pane":"%%9","brief":"/b/gen-02/brief.md","state":"held","ts":1}\n' \
    > "$HANDOFF_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
contains "background jobs holding the window read HELD" '⤳ HELD (jobs) → ops:5 ' "$out"
printf '{"target":"otherbox:handoffs:ocean-3","pane":"%%9","brief":"/b/README.md","state":"ok","ts":1}\n' \
    > "$HANDOFF_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
contains "a cross-host target keeps its host prefix" '→ otherbox:handoffs:ocean-3 ' "$out"
rm -f "$HANDOFF_STATE_DIR/testsess12345.json"

printf '\n\033[1mhandoff generation badge (cc-handoff chain marker)\033[0m\n'
export HANDOFF_CHAIN_STATE_DIR="$state_root/handoff-chain"
mkdir -p "$HANDOFF_CHAIN_STATE_DIR"
out=$(render_ext 10 10)
not_contains "no chain marker, no badge" '⤷' "$out"
printf '{"gen":3,"chain":"dotfiles-handoff-20261023","dir":"/b/dotfiles-handoff-20261023"}\n' \
    > "$HANDOFF_CHAIN_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
contains "generation 3 shows ⤷3 right after machine:session" ':12345 ⤷3 ' "$out"
raw=$(payload_ext 10 10 | bash "$STATUSLINE" 2>&1)
contains "the badge is bold cyan" $'\033[1;38;5;81m⤷3' "$raw"
printf '{"gen":1,"chain":"c","dir":"/b/c"}\n' > "$HANDOFF_CHAIN_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
not_contains "generation 1 (the chain's first session) shows no badge" '⤷' "$out"
printf '{"gen":"3\033[31m","chain":"c"}\n' > "$HANDOFF_CHAIN_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
not_contains "a malformed marker shows no badge" '⤷' "$out"
printf '{"gen":12,"chain":"c","dir":"/b/c"}\n' > "$HANDOFF_CHAIN_STATE_DIR/testsess12345.json"
printf '{"target":"ops:7","pane":"%%9","brief":"/b/gen-12/brief.md","state":"ok","ts":1}\n' \
    > "$HANDOFF_STATE_DIR/testsess12345.json"
out=$(render_ext 10 10)
if [[ "$out" == " ⤳ HANDED OFF → ops:7 "*":12345 ⤷12 "* ]]; then ok "a passer shows both its badge and its generation"
else bad "passer badge + generation" "' ⤳ HANDED OFF → ops:7 ' … ':12345 ⤷12 '" "$out"; fi
rm -f "$HANDOFF_STATE_DIR/testsess12345.json" "$HANDOFF_CHAIN_STATE_DIR/testsess12345.json"

printf '\n\033[1mtmux activity registration (tmux-agent-activity.sh)\033[0m\n'
if command -v tmux >/dev/null 2>&1; then
    reg_sock=$(mktemp -d)
    rm -f /tmp/claude-tmux-reg-testsess12345
    TMUX_TMPDIR="$reg_sock" tmux -f /dev/null new-session -d -s reg 'sleep 60'
    reg_pane=$(TMUX_TMPDIR="$reg_sock" tmux list-panes -t '=reg:' -F '#{pane_id}')
    render_reg() { payload_ext 10 10 | TMUX_TMPDIR="$reg_sock" TMUX_PANE="$reg_pane" CLAUDE_PID=4242 bash "$STATUSLINE" >/dev/null 2>&1; }
    render_reg
    got=$(TMUX_TMPDIR="$reg_sock" tmux show-options -pqv -t "$reg_pane" @claude_reg)
    if [[ "$got" == "4242 /nonexistent-transcript" ]]; then ok "registers '<pid> <transcript>' on its pane"
    else bad "pane registration" "4242 /nonexistent-transcript" "$got"; fi
    TMUX_TMPDIR="$reg_sock" tmux set-option -pu -t "$reg_pane" @claude_reg
    render_reg
    got=$(TMUX_TMPDIR="$reg_sock" tmux show-options -pqv -t "$reg_pane" @claude_reg)
    if [[ -z "$got" ]]; then ok "an unchanged registration is not re-sent"
    else bad "re-registration" "<nothing: cached>" "$got"; fi
    TMUX_TMPDIR="$reg_sock" tmux kill-server 2>/dev/null
    rm -rf "$reg_sock" /tmp/claude-tmux-reg-testsess12345
else
    printf '  skip tmux not installed\n'
fi
rm -rf "$state_root"
rm -f /tmp/claude-session-start-testsess12345 /tmp/claude-cost-offset-testsess12345

# ── Suite 4: issue link (branch / prompt hook → OSC 8) ───────────────
printf '\nissue link\n'
fixture_origin="https://github.com/example/app.git"
issues="https://github.com/example/app/issues"
check_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
check_eq "branch 8544_mobile-header"     "8544" "$(branch_issue_number 8544_mobile-header)"
check_eq "branch 1847-image-gen"         "1847" "$(branch_issue_number 1847-image-gen)"
check_eq "branch feat/123-fix-login"     "123"  "$(branch_issue_number feat/123-fix-login)"
check_eq "branch master: none"           ""     "$(branch_issue_number master)"
check_eq "branch 2026-10-06-sync: none"  ""     "$(branch_issue_number 2026-10-06-sync)"
check_eq "GitHub https origin"           "$issues/8544" "$(issue_url 8544 "$fixture_origin")"
check_eq "GitHub ssh origin"             "https://github.com/example/dotfiles/issues/12" \
    "$(issue_url 12 git@github.com:example/dotfiles.git)"
check_eq "gitlab.com ssh origin"         "https://gitlab.com/group/app/-/issues/8544" \
    "$(issue_url 8544 git@gitlab.com:group/app.git)"
check_eq "gitlab.com ssh:// with a port" "https://gitlab.com/group/sub/app/-/issues/7" \
    "$(issue_url 7 ssh://git@gitlab.com:2222/group/sub/app.git)"
check_eq "self-hosted GitLab, listed"    "https://gitlab.example.com/group/app/-/issues/12" \
    "$(STATUSLINE_GITLAB_HOSTS='git.example.org gitlab.example.com' issue_url 12 https://gitlab.example.com/group/app.git)"
check_eq "self-hosted GitLab, unlisted: none" "" "$(issue_url 12 https://gitlab.example.com/group/app.git)"
check_eq "unknown forge: none"           "" "$(issue_url 12 https://git.example.org/group/app.git)"
check_eq "recorded URL kept"             "https://github.com/o/r/issues/7" "$(issue_url https://github.com/o/r/issues/7 '')"
check_eq "malformed URL dropped"         "" "$(issue_url $'https://evil.example/x/1\e]8;;' '')"

hook="$SCRIPT_DIR/issue-focus-hook.sh"
hook_ref() {
    rm -f /tmp/claude-issue-testsess12345
    jq -n --arg p "$1" '{session_id:"testsess12345",prompt:$p}' | bash "$hook"
    cat /tmp/claude-issue-testsess12345 2>/dev/null
}
check_eq "hook: last #N wins"            "8600" "$(hook_ref 'compare #8544 with #8600')"
check_eq "hook: MR !4291 ignored"        "8544" "$(hook_ref 'work on #8544 then !4291')"
check_eq "hook: GitHub issue URL recorded" "$issues/8601" "$(hook_ref "see $issues/8601 please")"
check_eq "hook: GitLab issue URL recorded" "https://gitlab.com/group/app/-/issues/77" \
    "$(hook_ref 'see https://gitlab.com/group/app/-/issues/77 please')"
check_eq "hook: no ref leaves no file"   "" "$(hook_ref 'nothing here, #1 priority')"
check_eq "hook prints nothing"           "" "$(jq -n '{session_id:"testsess12345",prompt:"#8544"}' | bash "$hook")"

# A fixture repo with a GitHub origin, so the result does not depend on where
# this checkout's own origin points (a fresh clone or a fork has another one).
link_repo=$(mktemp -d)
git init -q "$link_repo" && git -C "$link_repo" remote add origin "$fixture_origin"
printf '8544\n' > /tmp/claude-issue-testsess12345
raw=$(payload | sed "s|\"current_dir\":\"[^\"]*\"|\"current_dir\":\"$link_repo\"|" | bash "$STATUSLINE" 2>&1)
case "$raw" in
    *$'\e]8;;'"$issues/8544"*'#8544'*) ok "render: recorded #8544 is an OSC 8 link" ;;
    *) bad "render: recorded #8544 is an OSC 8 link" "OSC 8 to $issues/8544" "$(printf '%s' "$raw" | strip_ansi)" ;;
esac
rm -f /tmp/claude-issue-testsess12345; rm -rf "$link_repo"

# ── Suite 5: issue link when the worktree guess lands on a detached HEAD ──
# Seen live: sessions on 8536_pwa-web-push with no saved cwd rendered no link
# because the newest sibling worktree was a detached review checkout.
printf '\nissue link: worktree guess fallback\n'
fx=$(mktemp -d); main="$fx/mainwt"; sib="$fx/review-4299"
git init -q "$main" && git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$main" checkout -q -b 8544_fixture && git -C "$main" remote add origin "$fixture_origin"
git -C "$main" worktree add -q --detach "$sib" HEAD 2>/dev/null
age_head() {  # push the main checkout's HEAD mtime 20 min back so the sibling is "newer"
    local t; t=$(date -v-20M +%Y%m%d%H%M 2>/dev/null || date -d '20 minutes ago' +%Y%m%d%H%M)
    touch -t "$t" "$main/.git/HEAD"
}
age_head
payload_at() {  # $1 current_dir, $2 session id
    printf '{"model":{"id":"claude-opus-5","display_name":"Opus"},"workspace":{"current_dir":"%s"},' "$1"
    printf '"session_id":"%s","transcript_path":"/nonexistent-transcript","context_window":{"used_percentage":1}}' "$2"
}
link_of() {  # first OSC 8 URL in the rendered bytes, or nothing (bash-native: BSD sed has no \x1b)
    local t="$1"; [[ "$t" == *$'\e]8;;http'* ]] || return 0
    t="${t#*$'\e]8;;http'}"; printf 'http%s' "${t%%$'\e'*}"
}
rm -f /tmp/claude-cwd-fxsess* /tmp/claude-issue-fxsess*

raw=$(payload_at "$main" fxsessB | bash "$STATUSLINE" 2>/dev/null)
check_eq "guess->detached: link from launch-dir branch" "$issues/8544" "$(link_of "$raw")"
case "$(printf '%s' "$raw" | strip_ansi)" in
    *detached*) ok "guess->detached: display still shows the detached sibling" ;;
    *) bad "guess->detached: display still shows the detached sibling" "…:detached…" "$(printf '%s' "$raw" | strip_ansi)" ;;
esac

printf '%s\n' "$main" > /tmp/claude-cwd-fxsessA
raw=$(payload_at "$main" fxsessA | bash "$STATUSLINE" 2>/dev/null)
check_eq "saved cwd: link from its own branch" "$issues/8544" "$(link_of "$raw")"
case "$(printf '%s' "$raw" | strip_ansi)" in
    *mainwt*) ok "saved cwd: display is the saved checkout" ;;
    *) bad "saved cwd: display is the saved checkout" "mainwt" "$(printf '%s' "$raw" | strip_ansi)" ;;
esac

printf '8600\n' > /tmp/claude-issue-fxsessC
raw=$(payload_at "$main" fxsessC | bash "$STATUSLINE" 2>/dev/null)
check_eq "explicit focus beats the fallback" "$issues/8600" "$(link_of "$raw")"

printf '%s\n' "$sib" > /tmp/claude-cwd-fxsessE
raw=$(payload_at "$main" fxsessE | bash "$STATUSLINE" 2>/dev/null)
check_eq "saved cwd IS the detached sibling: no guess, no link" "" "$(link_of "$raw")"

# A fresh, deliberately unnumbered branch: `git init` may default to main or
# master depending on init.defaultBranch, so never assume either exists.
git -C "$main" checkout -q -b unnumbered-branch && age_head \
    || bad "fixture: switch to an unnumbered branch" "checkout ok" "checkout failed"
raw=$(payload_at "$main" fxsessD | bash "$STATUSLINE" 2>/dev/null)
check_eq "unnumbered launch branch: no link" "" "$(link_of "$raw")"

rm -f /tmp/claude-cwd-fxsess* /tmp/claude-issue-fxsess*; rm -rf "$fx"

# ── Suite 6: machine label and work styling from configuration ───────
# Host names are configuration (identities/<id>/hosts), never code.
printf '\nmachine label and work styling\n'
hosts_dir=$(mktemp -d)
machine_of() {  # the machine:session field, i.e. the first word of the bar
    local out; out=$(payload | env "$@" bash "$STATUSLINE" 2>&1 | strip_ansi)
    printf '%s' "${out%% *}"
}
bar_of() { payload | env "$@" bash "$STATUSLINE" 2>&1 | strip_ansi; }
hn=$(hostname -s 2>/dev/null || hostname); hn=$(printf '%s' "${hn%%.*}" | tr '[:upper:]' '[:lower:]')
check_eq "no hosts file: the bare hostname"  "$hn:12345" "$(machine_of)"
printf '# comment\n\nno-such-host-*  nope\n*  devbox\n' > "$hosts_dir/hosts"
check_eq "first matching glob wins"          "devbox:12345" "$(machine_of DF_HOSTS_FILE="$hosts_dir/hosts")"
check_eq "DF_HOST_LABEL beats the file"      "pinned:12345" "$(machine_of DF_HOSTS_FILE="$hosts_dir/hosts" DF_HOST_LABEL=pinned)"
mkdir -p "$hosts_dir/dot/identities/example"
printf '*  fromidentity\n' > "$hosts_dir/dot/identities/example/hosts"
check_eq "identity hosts file via DF_IDENTITY" "fromidentity:12345" \
    "$(machine_of DOTFILES_DIR="$hosts_dir/dot" DF_IDENTITY=example)"
out=$(bar_of DF_HOSTS_FILE="$hosts_dir/hosts")
contains "personal machine shows the cost" '$0.0000' "$out"
printf '*  corp  work\n' > "$hosts_dir/work-hosts"
out=$(bar_of DF_HOSTS_FILE="$hosts_dir/work-hosts")
not_contains "work host (hosts file) hides the cost" '$0.' "$out"
contains "work host keeps its label" 'corp:12345' "$out"
raw=$(payload | DF_HOSTS_FILE="$hosts_dir/work-hosts" bash "$STATUSLINE" 2>&1)
contains "work host label is on orange" $'\033[48;5;130m' "$raw"
out=$(bar_of DF_WORK=1)
not_contains "DF_WORK=1 hides the cost" '$0.' "$out"
out=$(bar_of DF_IDENTITY=work)
not_contains "the work identity hides the cost" '$0.' "$out"
out=$(bar_of DF_IDENTITY=client DF_WORK_IDENTITIES='work client')
not_contains "DF_WORK_IDENTITIES widens the work set" '$0.' "$out"
out=$(bar_of DF_IDENTITY=example)
contains "any other identity is personal" '$0.0000' "$out"
rm -rf "$hosts_dir" /tmp/claude-cost-offset-testsess12345

printf '\n────────────────────────────────────────\n'
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
