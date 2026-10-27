#!/usr/bin/env bash
# tmux-plugin.test.sh: hermetic tests for plugins/tmux/bin/tmux-archive and tmux-apply-plan on a
# private tmux server from lib/tmux-sandbox.sh. tmux-archive captures every pane with its signals
# and links each pane's Claude Code transcript (dotted cwds included, which needs Claude Code's
# real projects/ encoding); a fake `claude agents --json` matches one pane to an agent. tmux-apply-plan
# renames sessions and windows, moves windows across sessions without losing a pane, previews with
# --dry-run, and refuses to drain a session without --allow-empty-sessions.
#
#   bash scripts/tests/tmux-plugin.test.sh
set -uo pipefail

# shellcheck source=lib/tmux-sandbox.sh
. "$(cd "$(dirname "$0")" && pwd -P)/lib/tmux-sandbox.sh"
tsb_require_private_tmp || exit 1
for t in tmux jq python3; do
  command -v "$t" >/dev/null 2>&1 || { printf 'tmux-plugin.test.sh needs %s\n' "$t" >&2; exit 1; }
done
here="$(cd "$(dirname "$0")" && pwd -P)"
bin="$(cd "$here/../../plugins/tmux/bin" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tmux-plugin-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
tsb_init "$tmp" || { printf 'the tmux sandbox refused to start\n' >&2; rm -rf "$tmp"; exit 1; }
tsb_own alpha beta gamma
cleanup() { tsb_teardown; rm -rf "$tmp"; }
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
until_true() { local d=$((SECONDS + $1)); shift; while (( SECONDS < d )); do "$@" && return 0; sleep 0.2; done; "$@"; }

export HOME="$tmp/home"
work="$HOME/code/shop"
dotted="$HOME/.config/my_app"
mkdir -p "$HOME/.claude/projects" "$work" "$dotted" "$tmp/bin"
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# `claude agents --json` lists one agent: the shell of pane alpha:0, read from a file the test fills.
cat > "$tmp/bin/claude" <<EOF
#!/bin/sh
[ "\$1 \$2" = "agents --json" ] && exec cat "$tmp/agents.json"
exit 1
EOF
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"

tsb new-session -d -s alpha -n build -c "$work" sh
tsb new-window -t alpha -n docs -c "$dotted" sh
tsb new-session -d -s beta -n solo -c "$work" sh
p_build="$(tsb display-message -p -t alpha:build '#{pane_id}')"
p_docs="$(tsb display-message -p -t alpha:docs '#{pane_id}')"
p_solo="$(tsb display-message -p -t beta:solo '#{pane_id}')"
tsb send-keys -t "$p_build" "printf '%s\\n' 'ERROR: boom' '12 passed, 1 failed'" C-m
tsb send-keys -t "$p_docs" "echo docs" C-m
until_true 5 grep -q 'passed' <(tsb capture-pane -p -t "$p_build")
build_pid="$(tsb display-message -p -t "$p_build" '#{pane_pid}')"
printf '[{"pid": %s, "sessionId": "sess-1", "status": "busy", "name": "build agent", "kind": "interactive", "startedAt": 1700000000000}]\n' \
  "$build_pid" > "$tmp/agents.json"
# Transcripts: the agent's own for the build pane, and the newest one for the dotted cwd.
mkdir -p "$HOME/.claude/projects/$(enc "$work")" "$HOME/.claude/projects/$(enc "$dotted")"
: > "$HOME/.claude/projects/$(enc "$work")/sess-1.jsonl"
: > "$HOME/.claude/projects/$(enc "$dotted")/other.jsonl"

echo "tmux-archive"
out="$("$bin/tmux-archive" --out "$tmp/arch" --dry-run 2>&1)"
equal "a dry run succeeds" 0 "$?"
check "...listing what it would write" "DRY: " "$out"
equal "...and writes nothing" "absent" "$([[ -e "$tmp/arch" ]] && echo present || echo absent)"
out="$("$bin/tmux-archive" --out "$tmp/arch" --latest 2>&1)"
equal "an archive run succeeds" 0 "$?"
m="$tmp/arch/latest/manifest.json"
equal "...capturing every pane" "3" "$(jq '.pane_count' "$m" 2>&1)"
# It counts lines with ERROR/FAIL/... in any case: both output lines at least (the echoed
# command line may count too).
n_err="$(jq --arg p "$p_build" '.panes[] | select(.pane_id == $p) | .error_keyword_count' "$m")"
equal "...counting the error-keyword lines" "yes" "$([[ "$n_err" =~ ^[0-9]+$ ]] && (( n_err >= 2 )) && echo yes || echo "no ($n_err)")"
equal "...and the test summary" "12 passed, 1 failed" "$(jq -r --arg p "$p_build" '.panes[] | select(.pane_id == $p) | .test_summary' "$m")"
equal "...matching the build pane to its agent" "busy sess-1" \
  "$(jq -r --arg p "$p_build" '.panes[] | select(.pane_id == $p) | "\(.agent_status) \(.agent_session_id)"' "$m")"
check "...and linking that agent's own transcript" "/$(enc "$work")/sess-1.jsonl" \
  "$(jq -r --arg p "$p_build" '.panes[] | select(.pane_id == $p) | .claude_transcript' "$m")"
check "a dotted cwd's transcript is found (Claude Code's encoding)" "/$(enc "$dotted")/other.jsonl" \
  "$(jq -r --arg p "$p_docs" '.panes[] | select(.pane_id == $p) | .claude_transcript' "$m")"
check "the README lists the sessions" "## Session \`alpha\`" "$(cat "$tmp/arch/latest/README.md")"
out="$("$bin/tmux-archive" --out "$tmp/arch" --session nope 2>&1)"
equal "an unknown --session fails" 1 "$?"
check "...by name" "Session not found: nope" "$out"

echo "tmux-apply-plan"
before="$(tsb list-panes -a -F '#{pane_id} #{pane_pid}' | sort)"
cat > "$tmp/plan.json" <<EOF
{"sessions": [{"current_name": "beta", "new_name": "gamma"}],
 "windows": [{"target": "$p_build", "new_name": "ci-build"},
             {"target": "$p_docs", "new_name": "docs-site", "new_session": "gamma", "new_index": 5}]}
EOF
out="$("$bin/tmux-apply-plan" --dry-run "$tmp/plan.json" 2>&1)"
equal "a dry run succeeds" 0 "$?"
check "...and says nothing changed" "DRY RUN" "$out"
equal "...leaving the names alone" "build" "$(tsb display-message -p -t "$p_build" '#{window_name}')"
out="$("$bin/tmux-apply-plan" "$tmp/plan.json" 2>&1)"
equal "applying the plan succeeds" 0 "$?"
equal "the session is renamed" "gamma" "$(tsb display-message -p -t "$p_solo" '#{session_name}')"
equal "a window is renamed" "ci-build" "$(tsb display-message -p -t "$p_build" '#{window_name}')"
equal "a window moves to the renamed session, at its index" "gamma:5 docs-site" \
  "$(tsb display-message -p -t "$p_docs" '#{session_name}:#{window_index} #{window_name}')"
equal "no pane or process was lost" "$before" "$(tsb list-panes -a -F '#{pane_id} #{pane_pid}' | sort)"

cat > "$tmp/drain.json" <<EOF
{"windows": [{"target": "$p_build", "new_session": "gamma"}]}
EOF
out="$("$bin/tmux-apply-plan" "$tmp/drain.json" 2>&1)"
equal "draining a session needs --allow-empty-sessions" 1 "$?"
check "...which it asks for" "Pass --allow-empty-sessions" "$out"
equal "...leaving the window where it was" "alpha" "$(tsb display-message -p -t "$p_build" '#{session_name}')"
out="$("$bin/tmux-apply-plan" --allow-empty-sessions "$tmp/drain.json" 2>&1)"
equal "with it the move succeeds" 0 "$?"
equal "...the window is in its new session" "gamma" "$(tsb display-message -p -t "$p_build" '#{session_name}')"
equal "...the drained session is gone" "gone" "$(tsb has-session -t '=alpha' 2>/dev/null && echo present || echo gone)"
equal "...and still no pane was lost" "$before" "$(tsb list-panes -a -F '#{pane_id} #{pane_pid}' | sort)"
printf '{"windows": [{"target": "%%999", "new_name": "x"}]}\n' > "$tmp/missing.json"
out="$("$bin/tmux-apply-plan" "$tmp/missing.json" 2>&1)"
equal "a plan naming a missing pane fails" 1 "$?"
check "...before changing anything" "Plan references missing panes: %999" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
