#!/usr/bin/env bash
# fable-second-opinion.test.sh: the fable-second-opinion helpers on a private tmux server from
# lib/tmux-sandbox.sh. ask-fable starts the advisor with FABLE_LAUNCH_CMD in a new window, submits
# the prompt only once the composer is empty, and tells the advisor the relay that sits next to it;
# ask/status/stop use the recorded state. send-to-primary relays into a Claude pane and refuses a
# shell. A fake TUI (a prompt loop that logs each submitted line, run as `claude`) stands in for
# Claude Code, so no real agent starts.
#
#   bash scripts/tests/fable-second-opinion.test.sh
set -uo pipefail

# shellcheck source=lib/tmux-sandbox.sh
. "$(cd "$(dirname "$0")" && pwd -P)/lib/tmux-sandbox.sh"
tsb_require_private_tmp || exit 1
for t in tmux python3; do
  command -v "$t" >/dev/null 2>&1 || { printf 'fable-second-opinion.test.sh needs %s\n' "$t" >&2; exit 1; }
done
here="$(cd "$(dirname "$0")" && pwd -P)"
skill="$(cd "$here/../../plugins/review/skills/fable-second-opinion/scripts" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/fable-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
tsb_init "$tmp" || { printf 'the tmux sandbox refused to start\n' >&2; rm -rf "$tmp"; exit 1; }
tsb_own work
cleanup() { tsb_teardown; rm -rf "$tmp"; }
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
until_true() { local d=$((SECONDS + $1)); shift; while (( SECONDS < d )); do "$@" && return 0; sleep 0.2; done; "$@"; }

export HOME="$tmp/home" XDG_CACHE_HOME="$tmp/cache"
mkdir -p "$HOME"
# The fake TUI: a banner, then a "❯ " composer; each submitted line is logged and a fresh,
# empty composer drawn, which is what the helpers wait for.
cat > "$tmp/fake_tui.py" <<'EOF'
import sys
log = sys.argv[1]
print("Claude Code v0.0.0 (fake)", flush=True)
while True:
    sys.stdout.write("❯ ")
    sys.stdout.flush()
    try:
        line = input()
    except EOFError:
        break
    with open(log, "a") as f:
        f.write(line + "\n")
EOF
tui() { printf "bash -c 'exec -a claude python3 %s %s'" "$tmp/fake_tui.py" "$1"; }

tsb new-session -d -s work -n primary -c "$tmp" "$(tui "$tmp/primary.log")"
# New windows (the advisor's) start /bin/sh: no user rc file slows or changes them.
tsb set -g default-shell /bin/sh
tsb new-window -t work -n plain -c "$tmp" sh
primary="$(tsb display-message -p -t work:primary '#{pane_id}')"
plain="$(tsb display-message -p -t work:plain '#{pane_id}')"
until_true 10 grep -q 'Claude Code v' <(tsb capture-pane -p -t "$primary")
equal "the primary pane reads as claude" "claude" "$(tsb display-message -p -t "$primary" '#{pane_current_command}')"

echo "ask-fable start --long-running"
out="$(printf '%s\n' 'Is the plan sound?' | FABLE_LAUNCH_CMD="$(tui "$tmp/advisor.log")" \
  "$skill/ask-fable" start --long-running --session work --source-pane "$primary" --source-client claude \
  --cwd "$tmp" --window fable-advisor 2>&1)"
equal "start succeeds" 0 "$?"
check "...once the prompt left the composer" "submitted=yes" "$out"
check "...in long-running mode" "mode=long-running" "$out"
advisor="$(sed -n 's/^advisor_pane=//p' <<<"$out")"
equal "FABLE_LAUNCH_CMD started the advisor" "claude" "$(tsb display-message -p -t "$advisor" '#{pane_current_command}' 2>&1)"
until_true 5 grep -q 'Is the plan sound' "$tmp/advisor.log"
prompt="$(cat "$tmp/advisor.log" 2>&1)"
check "the advisor is told the relay next to the helper" "| $skill/send-to-primary --pane '$primary' --client 'claude'" "$prompt"
check "...and the initial question" "Initial question: Is the plan sound?" "$prompt"
check "the state records the advisor and the source pane" "source_pane=$primary" "$(cat "$XDG_CACHE_HOME/fable-second-opinion/current" 2>&1)"
check "status says it is alive" "alive=true" "$("$skill/ask-fable" status 2>&1)"

echo "ask-fable ask"
out="$(printf '%s\n' 'Why did step 2 fail?' | "$skill/ask-fable" ask 2>&1)"
equal "ask succeeds" 0 "$?"
check "...once submitted" "submitted=yes" "$out"
until_true 5 grep -q 'Why did step 2 fail' "$tmp/advisor.log"
check "the follow-up reminds the advisor of the relay and the question" \
  "$skill/send-to-primary --pane '$primary' --client 'claude'. Use only that guarded relay" "$(tail -n 1 "$tmp/advisor.log")"

echo "send-to-primary"
out="$(printf '%s\n' 'run the tests first' | "$skill/send-to-primary" --pane "$primary" --client claude 2>&1)"
equal "relaying to a Claude pane succeeds" 0 "$?"
check "...and is confirmed" "submitted=yes" "$out"
until_true 5 grep -q 'run the tests first' "$tmp/primary.log"
equal "...arriving prefixed" "[Fable advisor] run the tests first" "$(tail -n 1 "$tmp/primary.log" 2>&1)"
out="$(printf '%s\n' 'rm -rf /' | "$skill/send-to-primary" --pane "$plain" 2>&1)"
equal "a shell pane is refused" 1 "$?"
check "...saying why" "Refusing relay: pane $plain is at a sh shell" "$out"
equal "...and nothing was typed there" "" "$(tsb capture-pane -p -t "$plain" | grep -F 'Fable advisor')"

echo "ask-fable stop"
out="$("$skill/ask-fable" stop 2>&1)"
equal "stop succeeds" 0 "$?"
# list-panes, not display-message: tmux 3.4 prints nothing and exits 0 for a missing pane.
equal "...closing the advisor's window" "gone" "$(tsb list-panes -t "$advisor" >/dev/null 2>&1 && echo present || echo gone)"
equal "...and clearing the state" "gone" "$([[ -e "$XDG_CACHE_HOME/fable-second-opinion/current" ]] && echo present || echo gone)"
equal "the primary pane is untouched" "claude" "$(tsb display-message -p -t "$primary" '#{pane_current_command}')"

echo "an advisor that died behind the helper's back"
out="$(printf '%s\n' 'second advisor' | FABLE_LAUNCH_CMD="$(tui "$tmp/advisor2.log")" \
  "$skill/ask-fable" start --long-running --session work --source-pane "$primary" --source-client claude \
  --cwd "$tmp" --window fable-two 2>&1)"
equal "a second advisor starts" 0 "$?"
tsb kill-window -t work:fable-two
check "status says it is dead" "alive=false" "$("$skill/ask-fable" status 2>&1)"
out="$(printf '%s\n' 'anyone there?' | "$skill/ask-fable" ask 2>&1)"
equal "ask refuses" 1 "$?"
check "...saying the pane is gone" "Recorded Fable pane is no longer available" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
