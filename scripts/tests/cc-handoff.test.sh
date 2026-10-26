#!/usr/bin/env bash
# cc-handoff.test.sh: hermetic end-to-end tests for scripts/cc-handoff and
# scripts/lib/cc_handoff.py. Private tmux servers from scripts/tests/lib/tmux-sandbox.sh
# (every call -S <socket in this test's temp dir>; a guard on PATH refuses any other server
# and any kill-server), no config, /bin/sh panes, a throwaway HOME, fake launchers (claude, yu and yuma on PATH: a fake Claude
# Code that logs its argv, writes a real-shaped transcript for its --session-id and replies
# once) and a fake ssh (a second "host": its own HOME, tmux server and machine id) stand in
# for the real thing, so nothing touches the user's tmux, ~/.claude or another machine.
#
#   bash scripts/tests/cc-handoff.test.sh
set -uo pipefail

# First: the real server's socket must not be visible at all (a private /tmp; see
# scripts/tests/lib/tmux-sandbox.sh for the systemd-run line, or TSB_ALLOW_SHARED_TMP=1 on a Mac).
# shellcheck source=lib/tmux-sandbox.sh
. "$(cd "$(dirname "$0")" && pwd -P)/lib/tmux-sandbox.sh"
tsb_require_private_tmp || exit 1
printf '  ok   no real tmux socket is visible from this test\n'
for t in tmux jq python3 zsh; do
  command -v "$t" >/dev/null 2>&1 || { printf 'cc-handoff.test.sh needs %s\n' "$t" >&2; exit 1; }
done
here="$(cd "$(dirname "$0")" && pwd -P)"
scripts="$(cd "$here/.." && pwd -P)"
CCH="$scripts/cc-handoff"
LIB="$scripts/lib/cc_handoff.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/cc-handoff-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
# Never the real tmux server: inside a pane $TMUX beats TMUX_TMPDIR, so the sandbox unsets
# it, names its sockets explicitly, and guards every tmux on PATH.
tsb_init "$tmp" || { printf 'cc-handoff.test.sh: the tmux sandbox refused to start\n' >&2; rm -rf "$tmp"; exit 1; }
tsb_own origin handoffs
REMOTE_SOCK="$(tsb_new_socket remote)" || { rm -rf "$tmp"; exit 1; }
cleanup() {
  if [[ -n "${KEEP:-}" ]]; then
    printf 'KEEP: fixtures left in %s. Inspect with an explicit socket only: tmux -S %s ls\n' "$tmp" "$TSB_SOCK" >&2
    printf 'Clean up with: (. %q; TSB_ROOT=%q tsb_teardown); rm -rf %q\n' "$here/lib/tmux-sandbox.sh" "$tmp" "$tmp" >&2
    return
  fi
  tsb_teardown
  pkill -f "$tmp/" 2>/dev/null   # $tmp is this run's own mktemp path: nothing else names it
  rm -rf "$tmp"
}
trap cleanup EXIT
cd "$tmp" || exit 1   # anything a failed step writes by relative path lands in the temp dir

# The provider route, Claude session and tunables of whoever runs these tests must not
# leak in: each case sets what it tests.
unset CLAUDECODE CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_FOUNDRY CLAUDE_CODE_USE_ANTHROPIC_AWS \
  CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD CLAUDE_CODE_USE_MANTLE CLAUDE_CODE_USE_VERTEX \
  ANTHROPIC_BASE_URL ANTHROPIC_DEFAULT_OPUS_MODEL AWS_REGION AWS_BEARER_TOKEN_BEDROCK \
  FSH_LAUNCHERS FSH_DEFAULT_LAUNCHER FSH_BYPASS FSH_LAUNCH_CMD FSH_MODEL \
  FSH_EFFORT FSH_AUTHORIZED FSH_PLACEMENT FSH_SESSION FSH_BRIEFS_DIR FSH_KILL CLAUDE_CONFIG_DIR \
  HANDOFF_STATE_DIR HANDOFF_CHAIN_STATE_DIR CLAUDE_CODE_SESSION_ID CLAUDE_PID CLAUDE_EFFORT \
  DF_MACHINE CLAUDE_MACHINE CC_HANDOFF_SECRETS_FILE ZDOTDIR
export HOME="$tmp/home" DF_MACHINE=test-box DF_IDENTITY=personal
export FSH_POLL=0.2 FSH_WATCH_POLL=0.3 FSH_QUIET_SECS=1 FSH_QUIET_MAX=20 FSH_ENGAGE_TIMEOUT=20
mkdir -p "$HOME/.claude" "$HOME/repo" "$HOME/code/.briefs"
: > "$HOME/.zshrc"   # every real host has one; without it zsh -i stops in its first-run wizard
printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"","CLAUDE_CODE_USE_MANTLE":"","AWS_REGION":"us-east-1"}}\n' \
  > "$HOME/.claude/settings.json"
# A known secret: the renderer must redact its literal value wherever it shows up.
printf 'export FAKE_SERVICE_TOKEN="tok-%s"\nexport PLAIN=short\nexport FAKE_PASSPHRASE="%s"\n' "q7Zr2LmX9vKc4WbN" "correct horse battery staple" > "$HOME/.env_secrets"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$(printf '%s' "$3" | tail -c 600)"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$(printf '%s' "$3" | grep -F -- "$2" | head -3)"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
until_true() {  # until_true <seconds> <command...>: poll until the command succeeds
  local deadline=$((SECONDS + $1)); shift
  while (( SECONDS < deadline )); do "$@" && return 0; sleep 0.2; done
  "$@"
}

# ── fakes ────────────────────────────────────────────────────────────────────────
mkdir -p "$tmp/bin"
cat > "$tmp/bin/fake-claude" <<'EOF'
#!/usr/bin/env bash
# A fake Claude Code TUI. Logs its exact argv (NUL-separated, one file per session id),
# writes the transcript Claude Code would (agent-name, the prompt as a user record, one
# assistant reply unless FAKE_NO_REPLY), then waits on its tty. Typing "BG" starts a
# shell shaped like a Claude Code background Bash task; "STOPBG" ends it.
sid="" name="" prompt="" n=0
argv=("${0##*/}" "$@")
while (( $# )); do
  case "$1" in
    --session-id) sid="$2"; shift ;;
    -n|--name) name="$2"; shift ;;
    --model|--effort|--settings|--add-dir|--plugin-dir) shift ;;
    --mcp-config) shift; while [[ $# -gt 1 && "$1" != -* && "$1" == *.json ]]; do shift; done; continue ;;
    -*) ;;
    *) prompt="$1" ;;
  esac
  shift
done
[[ -n "$sid" ]] || sid="nosid-$$"
printf '%s\0' "${argv[@]}" > "$FSH_TEST_LOG/$sid.argv"
printf '%s\n' "$PWD" > "$FSH_TEST_LOG/$sid.cwd"
printf '%s\n' "${IS_SANDBOX-unset}" > "$FSH_TEST_LOG/$sid.is_sandbox"
# Like the real TUI's first frames in a small window: erase the visible rows bottom-up
# (no clear-screen, so tmux's scroll-on-clear does not save them).
rows="$(stty size 2>/dev/null | cut -d' ' -f1)"; [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
for ((i = 0; i < rows; i++)); do printf '\033[2K\033[1A'; done; printf '\033[2K\r'
printf 'Claude Code v9.9.9 (fake) %s\n' "$name"
dir="$HOME/.claude/projects/-fake-$(basename "$PWD")"
mkdir -p "$dir"
t="$dir/$sid.jsonl"
rec() { python3 -c 'import json, sys, time
r = json.loads(sys.argv[1]); r.setdefault("sessionId", sys.argv[2]); r.setdefault("cwd", sys.argv[3])
r.setdefault("timestamp", time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()))
print(json.dumps(r))' "$1" "$sid" "$PWD" >> "$t"; }
[[ -z "$name" ]] || rec "$(jq -nc --arg n "$name" '{type: "agent-name", agentName: $n}')"
: >> "$t"
# Its pid, once the transcript exists: tests find this process by pid, never by a pattern.
printf '%s\n' "$$" > "$FSH_TEST_LOG/$sid.pid"
if [[ -n "$prompt" ]]; then
  rec "$(jq -nc --arg p "$prompt" '{type: "user", message: {role: "user", content: $p}}')"
  if [[ -z "${FAKE_NO_REPLY:-}" ]]; then
    sleep 0.3
    rec '{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Reading the brief now."}]}}'
    printf '⏺ Reading the brief now.\n'
  fi
fi
bg=""
while IFS= read -r line; do
  case "$line" in
    BG) bash -c "source $HOME/.claude/shell-snapshots/snapshot-bash-1.sh 2>/dev/null || true && eval 'sleep 300' < /dev/null && pwd -P >| /tmp/claude-x-cwd" &
        bg=$!; printf '%s\n' "$bg" > "$FSH_TEST_LOG/$sid.bgpid" ;;
    STOPBG) [[ -n "$bg" ]] && { pkill -P "$bg" 2>/dev/null; kill "$bg" 2>/dev/null; }; bg="" ;;
  esac
done
EOF
chmod +x "$tmp/bin/fake-claude"
for l in yu yuma claude; do ln -s fake-claude "$tmp/bin/$l"; done
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# A fake ssh to "remote-box": the command runs with that host's own HOME, tmux server
# and machine id. Any other alias does not resolve.
while [[ "${1:-}" == -* ]]; do case "$1" in -o) shift ;; esac; shift; done
alias="$1"; shift
printf '%s %s\n' "$alias" "$*" >> "$FSH_TEST_LOG/ssh.log"
if [[ "$alias" == self-box ]]; then   # an alias that is really this machine
  exec env -u TMUX -u TMUX_PANE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${REMOTE_UID:+FSH_PREFLIGHT_UID=$REMOTE_UID} bash -c "$*"
fi
[[ "$alias" == remote-box ]] || { echo "ssh: Could not resolve hostname $alias" >&2; exit 255; }
exec env -u FSH_BRIEFS_DIR -u TMUX -u TMUX_PANE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
  HOME="$REMOTE_HOME" TSB_SOCK="$REMOTE_SOCK" DF_MACHINE=remote-box DF_IDENTITY="${REMOTE_IDENTITY:-personal}" \
  ${REMOTE_UID:+FSH_PREFLIGHT_UID=$REMOTE_UID} \
  bash -c "$*"
EOF
chmod +x "$tmp/bin/ssh"
cat > "$tmp/bin/fleet-place" <<'EOF'
#!/usr/bin/env bash
printf 'fleet-place %s\n' "$*" >> "$FSH_TEST_LOG/fleet-place.log"
[[ -n "${FAKE_PLACE:-}" ]] || exit 3
printf '%s\n' "$FAKE_PLACE"
EOF
chmod +x "$tmp/bin/fleet-place"
cat > "$tmp/bin/drover" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FSH_TEST_LOG/drover.log"
EOF
chmod +x "$tmp/bin/drover"
# ps and pgrep pass through unless told to fail (a macOS sandbox refuses the setuid ps).
real_ps="$(type -P ps)" real_pgrep="$(type -P pgrep)"
# A flag file, not an environment variable, so a watcher that is already running sees it change.
printf '#!/bin/sh\n[ -e "$FSH_TEST_LOG/ps-fail" ] && { echo "ps: Operation not permitted" >&2; exit 1; }\nexec %s "$@"\n' "$real_ps" > "$tmp/bin/ps"
printf '#!/bin/sh\n[ -e "$FSH_TEST_LOG/pgrep-fail" ] && { echo "pgrep: Operation not permitted" >&2; exit 3; }\nexec %s "$@"\n' "$real_pgrep" > "$tmp/bin/pgrep"
chmod +x "$tmp/bin/ps" "$tmp/bin/pgrep"
cat > "$tmp/bin/pbcopy" <<'EOF'
#!/usr/bin/env bash
cat > "$FSH_TEST_LOG/clipboard"
EOF
chmod +x "$tmp/bin/pbcopy"
cat > "$tmp/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -s && -n "${FAKE_UNAME:-}" ]]; then echo "$FAKE_UNAME"; else exec /usr/bin/env -i PATH=/usr/bin:/bin uname "$@"; fi
EOF
chmod +x "$tmp/bin/uname"
export FSH_TEST_LOG="$tmp/log" REMOTE_HOME="$tmp/remote-home" REMOTE_SOCK
mkdir -p "$FSH_TEST_LOG" "$REMOTE_HOME/.claude" "$REMOTE_HOME/repo" "$REMOTE_HOME/.dotfiles"
: > "$REMOTE_HOME/.zshrc"
ln -s "$scripts" "$REMOTE_HOME/.dotfiles/scripts"
mkdir -p "$HOME/.dotfiles" && ln -s "$scripts" "$HOME/.dotfiles/scripts"   # for the self-box alias
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$HOME/repo" > "$HOME/.claude.json"   # a passer runs somewhere trusted
printf '{"projects":{"%s":{"hasTrustDialogAccepted":true}}}\n' "$REMOTE_HOME/repo" > "$REMOTE_HOME/.claude.json"
cp "$HOME/.claude/settings.json" "$REMOTE_HOME/.claude/settings.json"
export PATH="$tmp/bin:$PATH"

argv_of() { tr '\0' '\n' < "$FSH_TEST_LOG/$1.argv"; }   # one argument per line
prompt_of() { "$scripts/../scripts/lib/cc_handoff.py" --help >/dev/null 2>&1; tr '\0' '\n' < "$FSH_TEST_LOG/$1.argv" | sed -n '/^\[cc-handoff\]/,$p; /^\/goal /,$p' | head -40; }

printf 'guards: the harness and the launcher cannot reach a server they did not create\n'
# These checks stay harmless even if the sandbox were broken: they name no real socket,
# and the guard is called by its absolute path.
[[ "$(type -P tmux)" == "$TSB_BIN/tmux" ]] || { printf 'cc-handoff.test.sh: the tmux guard is not first on PATH; refusing to run\n' >&2; exit 1; }
ok "the guard is the tmux on PATH"
out="$("$TSB_BIN/tmux" kill-server 2>&1)"; code=$?
equal "kill-server through the guard is refused (97)" 97 "$code"
out="$("$TSB_BIN/tmux" -L default list-sessions 2>&1)"; code=$?
equal "a caller's own -L is refused (97)" 97 "$code"
out="$(python3 - "$LIB" <<'PY'
import subprocess, sys
sys.path.insert(0, sys.argv[1].rsplit("/", 1)[0])
import cc_handoff as c
ran = []
subprocess.run = lambda *a, **k: ran.append(a[0]) or subprocess.CompletedProcess(a[0], 0, "", "")
for args in (["kill-server"], ["kill-ses", "-t", "x"], ["set", "-g", "@x", "1", ";", "kill-server"],
             ["kill-window", "-t", "ops:1"], ["kill-pane"], ["kill-window", "-t", "%3", "-a"]):
    print(" ".join(args), c.tmux(*args)[0])
print("ran", len(ran))
c.tmux("kill-window", "-t", "%3"); c.tmux("kill-pane", "-t", "%4")
print("ran", len(ran))
PY
)"
check "launcher: kill-server refused" "kill-server 97" "$out"
check "launcher: kill-session refused" "kill-ses -t x 97" "$out"
check "launcher: a kill chained after ; refused" "set -g @x 1 ; kill-server 97" "$out"
check "launcher: kill-window needs a %pane target" "kill-window -t ops:1 97" "$out"
check "launcher: kill-window with extra flags refused" "kill-window -t %3 -a 97" "$out"
check "launcher: refused calls never ran tmux" "ran 0" "$out"
check "launcher: kill-window/kill-pane by %pane run" "ran 2" "$out"
kills="$(grep -nE '(^|[^-])kill-(server|session)' "$CCH" "$LIB" | grep -vE '_KILL_SERVER|kill-ser\|kill-serv|never kills|kill-server took|kill-server refused' || true)"
equal "the shipped launcher has no kill-server or kill-session call" "" "$kills"

# Start the server with no config (PATH above is in its environment); panes are plain sh.
tsb -f /dev/null new-session -d -s origin -n work -x 220 -y 50 'sh'
tsb set -g default-shell /bin/sh
tsb set -g history-limit 5000

# start_passer <session id> <window> <dir>: a window running a fake Claude Code session
# (generation 1 of a chain), with a transcript that already holds a short conversation.
start_passer() {
  local sid="$1" win="$2" dir="$3" pane
  pane="$(tsb new-window -d -P -F '#{pane_id}' -t '=origin:' -n "$win" -c "$dir" \
    "cd $dir && exec $tmp/bin/fake-claude --session-id $sid -n $win")"
  until_true 5 test -s "$FSH_TEST_LOG/$sid.pid" || true
  local t; t="$(ls "$HOME"/.claude/projects/*/"$sid".jsonl)"
  python3 - "$t" "$sid" "$dir" <<'PY'
import json, sys
t, sid, cwd = sys.argv[1:4]
def r(o, ts):
    o.setdefault("sessionId", sid); o.setdefault("cwd", cwd); o["timestamp"] = ts
    return json.dumps(o)
rows = [
  r({"type": "user", "message": {"role": "user", "content": "Build the widget and keep the tests green."}}, "2026-10-23T10:00:00.000Z"),
  r({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "thinking", "thinking": "SECRET-THOUGHTS"}]}}, "2026-10-23T10:00:01.000Z"),
  r({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Starting on the widget."}]}}, "2026-10-23T10:00:02.000Z"),
  r({"type": "assistant", "message": {"role": "assistant", "content": [{"type": "tool_use", "id": "tu1", "name": "Bash", "input": {"command": "make test", "description": "Run the tests"}}]}}, "2026-10-23T10:00:03.000Z"),
  r({"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "tu1", "content": "42 passed\nall green"}]}}, "2026-10-23T10:00:04.000Z"),
  r({"type": "assistant", "message": {"role": "assistant", "stop_reason": "end_turn", "content": [{"type": "text", "text": "Tests pass (42). Handing off next."}]}}, "2026-10-23T10:00:05.000Z"),
]
with open(t, "a") as f:
    f.write("\n".join(rows) + "\n")
PY
  printf '%s' "$pane"
}
claude_pid_of() { tsb display-message -p -t "$1" '#{pane_pid}'; }
# as_session <sid> <pane> <cmd...>: run cc-handoff the way the agent in that pane would
as_session() {
  local sid="$1" pane="$2"; shift 2
  env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID="$sid" CLAUDE_PID="$(claude_pid_of "$pane")" TMUX_PANE="$pane" \
    CLAUDE_EFFORT="${RUN_EFFORT:-high}" "$@"
}
fill_brief() {  # fill_brief <brief> <tag>: what an agent writes into the skeleton
  python3 - "$1" "$2" <<'PY'
import re, sys
p, tag = sys.argv[1:3]
s = open(p).read()
s = s.replace("Continuing: <<FILL: one line: the task the next session continues, in plain words>>", f"Continuing: the widget build ({tag})")
s = s.replace("Done: <<FILL: one line: the most important things finished and verified>>", f"Done: tests green at 42 ({tag})")
s = s.replace("Left: <<FILL: one line: what is still open, highest priority first>>", f"Left: ship the widget ({tag})")
s = re.sub(r"<<FILL[^>]*>>", f"filled by the {tag} test", s, flags=re.S)
open(p, "w").write(s)
PY
}
window_gone() { ! tsb list-panes -a -F '#{pane_id}' 2>/dev/null | grep -Fxq "$1"; }
mode_of() { python3 -c 'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "o"))' "$1" 2>&1; }
# Processes are found by the pids the fake recorded, never by a command pattern: PrivateTmp
# does not isolate pids, so `pkill -f 'eval ...'` could hit any agent's shell on the host.
bg_pid() { cat "$FSH_TEST_LOG/$1.bgpid" 2>/dev/null; }
bg_running() { local p; p="$(bg_pid "$1")" && [[ -n "$p" ]] && kill -0 "$p" 2>/dev/null; }
kill_bg() { local p; p="$(bg_pid "$1")"; [[ -n "$p" ]] || return 0; pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; }
kill_state() { python3 "$LIB" get "$1" "$2" handoff.kill.state; }

printf 'render: text in full, one line per tool call, no thinking, secrets redacted\n'
fx="$tmp/fixture.jsonl"
python3 - "$fx" <<'PY'
import json, sys
rows = [
 {"type": "agent-name", "agentName": "widget"},
 {"type": "user", "message": {"content": "<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>Ship the widget with tests</command-args>"}},
 {"type": "attachment", "attachment": {"type": "goal_status", "met": False, "condition": "Ship the widget with tests"}},
 {"type": "user", "isMeta": True, "message": {"content": "META-INJECTED-TEXT"}},
 {"type": "user", "message": {"content": "Please use key " + "sk-" + "ant-api03-" + "A" * 30 + " and password=hunter2hunter2"}},
 {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t9", "name": "Bash", "input": {"command": "show-config"}}]}},
 {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t9", "content": ("x" * 145) + "tok-" + "q7Zr2LmX9vKc4WbN tail\npass is correct horse battery staple"}]}},
 # The email and phone values are built from pieces, so no PII-shaped literal sits in this file.
 {"type": "user", "message": {"content": "The tenant in pool.json is jane.customer" + "@" + "gmail.com at +1" + "555" + "8675309, office (555) " + "867-5310, fax 555." + "867.5311; push to git@github.com:example/dotfiles.git, cc noreply@anthropic.com, epoch 1792799084"}},
 {"type": "assistant", "message": {"content": [{"type": "thinking", "thinking": "PRIVATE-THINKING"}]}},
 {"type": "assistant", "message": {"content": [{"type": "text", "text": "I will not echo " + "AKIA" + "ABCDEFGHIJKLMNOP" + " or tok-" + "q7Zr2LmX9vKc4WbN."}]}},
 {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "git push https://bob:" + "s3cr3tpass@example.com/x.git", "description": "Push"}},
                                               {"type": "tool_use", "id": "t2", "name": "Read", "input": {"file_path": "/etc/hosts", "offset": 3, "limit": 10}}]}},
 {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "content": "fatal: auth failed\nline2", "is_error": True},
                                          {"type": "tool_result", "tool_use_id": "t2", "content": "127.0.0.1 localhost"}]}},
 {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t3", "name": "Bash", "input": {"command": "sleep 900", "description": "Long wait", "run_in_background": True}}]}},
 {"type": "user", "toolUseResult": {"backgroundTaskId": "bgaaa111"}, "message": {"content": [{"type": "tool_result", "tool_use_id": "t3", "content": "Command running in background with ID: bgaaa111. Output is being written to: /tmp/x"}]}},
 {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t4", "name": "Bash", "input": {"command": "sleep 1", "run_in_background": True}}]}},
 {"type": "user", "toolUseResult": {"backgroundTaskId": "bgbbb222"}, "message": {"content": [{"type": "tool_result", "tool_use_id": "t4", "content": "Command running in background with ID: bgbbb222."}]}},
 {"type": "queue-operation", "operation": "enqueue", "content": "<task-notification>\n<task-id>bgbbb222</task-id>\n<status>completed</status>\n<summary>Background command \"sleep 1\" completed (exit code 0)</summary>\n</task-notification>"},
 {"type": "attachment", "attachment": {"type": "queued_command", "prompt": "<task-notification>\n<task-id>bgbbb222</task-id>\n<status>completed</status>\n<summary>Background command \"sleep 1\" completed</summary>\n</task-notification>"}},
 {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t5", "name": "Agent", "input": {"description": "Scout the repo", "subagent_type": "Explore", "prompt": "look", "run_in_background": True}}]}},
 {"type": "user", "toolUseResult": {"isAsync": True, "status": "async_launched", "agentId": "agentccc333"}, "message": {"content": [{"type": "tool_result", "tool_use_id": "t5", "content": "Async agent launched"}]}},
 {"type": "attachment", "attachment": {"type": "queued_command", "prompt": "<cross-session-message from-name=\"lead\" from-mode=\"bypass\">\n[lead] status please\n</cross-session-message>"}},
 {"type": "system", "subtype": "compact_boundary", "content": "Conversation compacted"},
 {"type": "assistant", "isApiErrorMessage": True, "message": {"content": [{"type": "text", "text": "API Error: 529 overloaded"}]}},
 {"type": "assistant", "isSidechain": True, "message": {"content": [{"type": "text", "text": "SIDECHAIN-TEXT"}]}},
 {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t6", "name": "TodoWrite", "input": {"todos": [{"content": "write tests", "status": "completed"}, {"content": "ship", "status": "pending"}]}}]}},
 {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t7", "name": "mcp__drover__drover_send", "input": {"id": "lead", "text": "hi"}}]}},
 {"type": "assistant", "message": {"stop_reason": "end_turn", "content": [{"type": "text", "text": "Done for now."}]}},
]
with open(sys.argv[1], "w") as f:
    for i, r in enumerate(rows):
        r.setdefault("sessionId", "fixture-sid"); r.setdefault("timestamp", f"2026-10-23T11:{i:02d}:00.000Z")
        f.write(json.dumps(r) + "\n")
    f.write("{torn line\n")
PY
out="$("$CCH" render "$fx")"
check "names the session and its goal" '"widget"' "$out"
check "shows the active /goal" '# Active /goal: Ship the widget with tests' "$out"
check "user text in full" 'Please use key' "$out"
check "assistant text in full" 'I will not echo' "$out"
check "one line per tool call, with its result" '▸ Read: /etc/hosts:3-12  ⇒ 127.0.0.1 localhost' "$out"
check "an error result is marked" '⇒ ✗ fatal: auth failed (+1 lines)' "$out"
check "a background call is labeled" 'sleep 900 # Long wait [background]' "$out"
check "task notifications are one line" '⚑ task bgbbb222 completed' "$out"
check "messages from other sessions are labeled" 'MESSAGE from lead (another session)' "$out"
check "compaction is marked" 'context compacted here' "$out"
check "API errors are one line" '⚠ API error: API Error: 529 overloaded' "$out"
lacks "thinking is left out" 'PRIVATE-THINKING' "$out"
lacks "system-injected text is left out" 'META-INJECTED-TEXT' "$out"
lacks "subagent sidechains are left out" 'SIDECHAIN-TEXT' "$out"
lacks "an Anthropic key is redacted" 'sk-ant-api03-AAAA' "$out"
lacks "an AWS key id is redacted" "AKIA""ABCDEFGHIJKLMNOP" "$out"   # built from pieces: no key-shaped literal in the source
lacks "a password assignment is redacted" 'hunter2hunter2' "$out"
lacks "URL credentials are redacted" 's3cr3tpass' "$out"
lacks "a value from ~/.env_secrets is redacted" 'q7Zr2LmX9vKc4WbN' "$out"
check "redactions say what they hid" '[REDACTED:FAKE_SERVICE_TOKEN]' "$out"
lacks "a customer email is redacted" 'jane.customer''@gmail.com' "$out"
lacks "an E.164 phone number is redacted" '+1555''8675309' "$out"
lacks "a (NNN) NNN-NNNN number is redacted" '867-5310' "$out"
lacks "a NNN.NNN.NNNN number is redacted" '867.5311' "$out"
check "PII redactions are labeled" 'is [REDACTED:email] at [REDACTED:phone], office [REDACTED:phone], fax [REDACTED:phone];' "$out"
check "an SSH remote is not an email" 'git@github.com:example/dotfiles.git' "$out"
check "a noreply address stays" 'noreply@anthropic.com' "$out"
check "an epoch is not a phone number" 'epoch 1792799084' "$out"
lacks "a secret at the 160-character cut is redacted before the cut" 'tok-q7Zr' "$out"
lacks "a passphrase with spaces is redacted" 'correct horse battery' "$out"

printf 'info: goal, open background tasks, todos, sessions messaged\n'
info="$(python3 "$LIB" info "$fx")"
equal "the active goal" "Ship the widget with tests" "$(jq -r .goal <<<"$info")"
equal "open tasks: the running shell and the agent, not the finished one" "bgaaa111 agentccc333" \
  "$(jq -r '[.open_tasks[].id] | join(" ")' <<<"$info")"
equal "the last todo list" "write tests:completed ship:pending" "$(jq -r '[.todos[] | "\(.content):\(.status)"] | join(" ")' <<<"$info")"
equal "drover targets" "lead" "$(jq -r '.messaged | join(",")' <<<"$info")"
equal "it has responded" "true" "$(jq -r .first_response <<<"$info")"
equal "its turn ended" "true" "$(jq -r .turn_ended <<<"$info")"
python3 - "$fx" "$tmp/fixture-cleared.jsonl" <<'PY'
import json, sys
rows = open(sys.argv[1]).read().splitlines()[:-1]
rows.append(json.dumps({"type": "user", "message": {"content": "<command-name>/goal</command-name>\n<command-args>clear</command-args>"}}))
open(sys.argv[2], "w").write("\n".join(rows) + "\n")
PY
equal "/goal clear ends the goal" "null" "$(python3 "$LIB" info "$tmp/fixture-cleared.jsonl" | jq -r .goal)"

sleep 30 & lonely=$!
jobs_out="$(python3 "$LIB" jobs --pid "$lonely" --transcript "$fx")"
check "an open Bash task with no tool shell still blocks (it may have exec'd)" "bgaaa111" "$jobs_out"
check "and says why" "it may have exec'd into another program" "$jobs_out"
check "an open background agent blocks" "agentccc333" "$jobs_out"
kill "$lonely" 2>/dev/null
python3 - "$fx" "$tmp/fixture-typed.jsonl" <<'PY'
import json, sys
rows = open(sys.argv[1]).read().splitlines()[:-1]
add = [
 {"type": "attachment", "timestamp": "2026-10-23T12:00:00.000Z", "attachment": {"type": "queued_command", "prompt": "<cross-session-message from-name=\"lead\">hi</cross-session-message>", "origin": {"kind": "peer"}}},
 {"type": "attachment", "timestamp": "2026-10-23T12:01:00.000Z", "attachment": {"type": "queued_command", "prompt": "stop and wait", "origin": {"kind": "human"}}},
 {"type": "attachment", "timestamp": "2026-10-23T12:02:00.000Z", "attachment": {"type": "queued_command", "prompt": "<task-notification><task-id>z</task-id></task-notification>", "origin": {"kind": "task-notification"}}},
]
open(sys.argv[2], "w").write("\n".join(rows + [json.dumps(r) for r in add]) + "\n")
rows.append(json.dumps({"type": "user", "timestamp": "2026-10-23T12:05:00.000Z", "message": {"content": "<command-name>/goal</command-name>\n<command-args>new work</command-args>"}}))
open(sys.argv[2] + ".cmd", "w").write("\n".join(rows) + "\n")
PY
equal "text queued by a person while busy counts as someone using the session" "2026-10-23T12:01:00.000Z" \
  "$(python3 "$LIB" info "$tmp/fixture-typed.jsonl" | jq -r .last_user_ts)"
equal "a typed slash command counts too" "2026-10-23T12:05:00.000Z" \
  "$(python3 "$LIB" info "$tmp/fixture-typed.jsonl.cmd" | jq -r .last_user_ts)"

printf 'init: a chain, generation 1 and its brief skeleton\n'
pA="$(start_passer sess-A widget "$HOME/repo")"
out="$(cd "$HOME/repo" && as_session sess-A "$pA" "$CCH" init 2>&1)"; code=$?
equal "exit 0" 0 "$code"
brief1="$(printf '%s\n' "$out" | head -n 1)"
check "the brief is gen-01/brief.md of a new chain" "/code/.briefs/repo-handoff-$(date -u +%Y%m%d)/gen-01/brief.md" "$brief1"
chainA="$(dirname "$(dirname "$brief1")")"
b="$(cat "$brief1" 2>/dev/null)"
for s in "Summary" "What happened" "Done" "Left" "Proposed improvements" "Driver and manager" "Background jobs" "IDs and paths" "Rules"; do
  check "section: $s" "## $s" "$b"
done
check "ids: the session" "- Session: sess-A \"widget\"" "$b"
check "ids: the resume command" "claude --resume sess-A" "$b"
check "ids: the tmux pane" "pane $pA" "$b"
check "facts: the first prompt" "First prompt: Build the widget" "$b"
check "jobs: none running" "None running when this was checked." "$b"
equal "the chain root is the session's name" "widget" "$(jq -r .root "$chainA/chain.json")"
out="$("$CCH" launch "$brief1" 2>&1)"; code=$?
equal "launch refuses outside a session" 2 "$code"
out="$(as_session sess-A "$pA" "$CCH" launch "$brief1" 2>&1)"; code=$?
equal "launch refuses an unfilled brief: exit 2" 2 "$code"
check "and says why" "<<FILL ...>> marker(s) left" "$out"
equal "nothing opened" "2" "$(tsb list-windows -t '=origin:' | wc -l | xargs)"
out="$(cd "$HOME/repo" && as_session sess-A "$pA" "$CCH" init 2>&1)"
check "a second init keeps the brief" "already exists (kept as is" "$out"

printf 'launch: generation 2, local, adjacent window, inline prompt, linear history\n'
fill_brief "$brief1" gen1
pidx="$(tsb display-message -p -t "$pA" '#{window_index}')"
out="$(as_session sess-A "$pA" "$CCH" launch "$brief1" 2>&1)"; code=$?
equal "exit 0" 0 "$code"
check "reports the launcher" "launcher: claude, because" "$out"
check "reports the window" "launched: generation 2 (widget-2, session" "$out"
check "says the window closes on its own" "this window closes by itself shortly after" "$out"
check "tells the passer to stop" "This session has handed off." "$out"
sid2="$(python3 "$LIB" get "$chainA" 2 session_id)"
# Indexes, not names: the watcher may already have closed the passer (indexes do not shift).
equal "the successor sits right after the passer" "$((pidx + 1)) widget-2" \
  "$(tsb display-message -p -t "$(python3 "$LIB" get "$chainA" 2 tmux.pane)" '#{window_index} #{window_name}')"
equal "the successor has a fresh session id" 36 "${#sid2}"
args="$(argv_of "$sid2")"
check "started through the launcher" "claude" "$(head -n 1 <<<"$args")"
lacks "the successor gets no permission bypass its passer did not have" "--dangerously-skip-permissions" "$args"
check "passes the session id" $'--session-id\n'"$sid2" "$args"
check "names it <root>-2" $'-n\nwidget-2' "$args"
check "pins the model" $'--model\nopus' "$args"
check "keeps the passer's effort" $'--effort\nhigh' "$args"
p="$(cat "$chainA/gen-02/prompt.txt")"
check "prompt: generation and chain" "[cc-handoff] You are generation 2 (session name widget-2) of handoff chain repo-handoff-" "$p"
check "prompt: not typed by a person" "not typed by a person" "$p"
check "prompt: only a summary, brief path" "It is only a summary. The brief is the source of truth: $brief1" "$p"
check "prompt: continuing" "Continuing: the widget build (gen1)" "$p"
check "prompt: done" "Done: tests green at 42 (gen1)" "$p"
check "prompt: left" "Left: ship the widget (gen1)" "$p"
check "prompt: compare against the transcript" "check it against the end of the previous session's own transcript ($chainA/gen-01/transcript.md" "$p"
check "prompt: trust the transcript" "where they disagree, trust the transcript" "$p"
check "prompt: todo list" "Build or refresh your todo list" "$p"
check "prompt: asks before starting" "ask which to start" "$p"
check "prompt: no jobs" "Background jobs: none were running" "$p"
equal "prompt: 8 lines" 8 "$(wc -l < "$chainA/gen-02/prompt.txt" | xargs)"
equal "the prompt reached claude as one argument" "$p" "$(tr '\0' '\n' < "$FSH_TEST_LOG/$sid2.argv" | sed -n '/^\[cc-handoff\]/,$p')"
check "the rendered transcript sits next to the brief" "Tests pass (42). Handing off next." "$(cat "$chainA/gen-01/transcript.md")"
pane2="$(python3 "$LIB" get "$chainA" 2 tmux.pane)"
screen="$(tsb capture-pane -p -J -S - -t "$pane2")"
check "echo: the history banner" "generation 2 starts below" "$screen"
check "echo: generation 1's transcript" "──── generation 1 transcript · session sess-A" "$screen"
check "echo: user text" "Build the widget and keep the tests green." "$screen"
check "echo: the tool line" "▸ Bash: make test # Run the tests  ⇒ 42 passed (+1 lines)" "$screen"
lacks "echo: no thinking" "SECRET-THOUGHTS" "$screen"
check "echo: the footer survives the TUI's start-up erase" "──── end of history ────" "$screen"
check "echo: the raw JSONL path" "Raw JSONL: $HOME/.claude/projects/" "$screen"
check "echo: how to resume generation 1" "claude --resume sess-A" "$screen"
check "echo: the tmux buffer" "tmux buffer cc-handoff-repo-handoff-" "$screen"
check "echo: then Claude Code starts" "Claude Code v9.9.9 (fake) widget-2" "$screen"
buf="$(tsb list-buffers -F '#{buffer_name}' | grep '^cc-handoff-' | head -n 1)"
check "the buffer holds the rendered transcript" "Tests pass (42)" "$(tsb show-buffer -b "$buf")"
equal "statusline marker: generation 2" '{"gen":2,' "$(head -c 9 "$HOME/.claude/state/handoff-chain/$sid2.json")"
until_true 15 window_gone "$pA"
if window_gone "$pA"; then ok "the passer's window closed after the first reply"; else bad "passer closed" "gone" "still there"; fi
equal "the decision is recorded" "killed" "$(kill_state "$chainA" 1)"
if [[ ! -e "$chainA/gen-01/passer-screen.txt" ]]; then ok "no close-time screen capture (the watcher would redact less than launch did)"
else bad "no close-time capture" "absent" "present"; fi
equal "passer marker: responded" '"state":"responded"' "$(grep -o '"state":"[a-z]*"' "$HOME/.claude/state/handoff/sess-A.json")"
check "status lists both generations" "  2  " "$("$CCH" status "$chainA")"

printf 'generation 2 hands off to 3: briefs 1..n-1, then the full transcript of n\n'
python3 - "$(ls "$HOME"/.claude/projects/*/"$sid2".jsonl)" "$sid2" <<'PY'
import json, sys
t, sid = sys.argv[1:3]
rows = [{"type": "assistant", "message": {"content": [{"type": "text", "text": "Generation two did the packaging."}], "stop_reason": "end_turn"}}]
with open(t, "a") as f:
    for r in rows:
        r.update(sessionId=sid, timestamp="2026-10-23T12:00:00.000Z"); f.write(json.dumps(r) + "\n")
PY
out="$(cd "$HOME/repo" && as_session "$sid2" "$pane2" "$CCH" init 2>&1)"
brief2="$(head -n 1 <<<"$out")"
equal "generation 2 writes gen-02/brief.md in the same chain" "$chainA/gen-02/brief.md" "$brief2"
check "it lists the earlier generation" "| 1 | sess-A widget |" "$(cat "$brief2")"
fill_brief "$brief2" gen2
printf '\nNote: the staging service uses %s=%s\n' token "abcdefghijkl""12345" >> "$brief2"   # a fake value, built from pieces
out="$(as_session "$sid2" "$pane2" "$CCH" launch 2>&1)"; code=$?
equal "launch with no brief argument uses this generation's" 0 "$code"
sid3="$(python3 "$LIB" get "$chainA" 3 session_id)"
pane3="$(python3 "$LIB" get "$chainA" 3 tmux.pane)"
check "named <root>-3" $'-n\nwidget-3' "$(argv_of "$sid3")"
screen="$(tsb capture-pane -p -J -S - -t "$pane3")"
check "echo order: brief 1, then generation 2's transcript" "History, oldest first: brief 1, generation 2's transcript." "$screen"
check "echo: brief 1 in full" "Continuing: the widget build (gen1)" "$screen"
check "echo: generation 2's transcript" "Generation two did the packaging." "$screen"
lacks "echo: brief 2 is not echoed (the new session reads it)" "Continuing: the widget build (gen2)" "$screen"
first="$(grep -n 'Continuing: the widget build (gen1)' <<<"$screen" | head -n 1 | cut -d: -f1)"
second="$(grep -n 'Generation two did the packaging' <<<"$screen" | head -n 1 | cut -d: -f1)"
if [[ -n "$first" && -n "$second" ]] && (( first < second )); then ok "history is linear (brief 1 above transcript 2)"
else bad "linear history" "brief 1 line < transcript 2 line" "$first vs $second"; fi
check "prompt points at brief 2" "The brief is the source of truth: $chainA/gen-02/brief.md" "$(cat "$chainA/gen-03/prompt.txt")"
equal "statusline marker: generation 3" '{"gen":3,' "$(head -c 9 "$HOME/.claude/state/handoff-chain/$sid3.json")"
until_true 15 window_gone "$pane2"
if window_gone "$pane2"; then ok "generation 2's window closed"; else bad "gen 2 closed" "gone" "still there"; fi
out="$(python3 "$LIB" history "$chainA" 4 2>&1 || true)"
lacks "a brief's secret is redacted in the echo" "abcdefghijkl""12345" "$(python3 "$LIB" history "$chainA" 3)"

printf 'background jobs hold the passer until they finish or the successor adopts them\n'
pB="$(start_passer sess-B jobs "$HOME/repo")"
tsb send-keys -t "$pB" BG Enter
until_true 5 bg_running sess-B
out="$(cd "$HOME/repo" && as_session sess-B "$pB" "$CCH" init --name jobs-chain 2>&1)"
briefB="$(head -n 1 <<<"$out")"; chainB="$(dirname "$(dirname "$briefB")")"
check "init lists the live background shell" "| pid:" "$(cat "$briefB")"
check "with its command" "sleep 300" "$(cat "$briefB")"
fill_brief "$briefB" jobs
out="$(as_session sess-B "$pB" "$CCH" launch "$briefB" 2>&1)"; code=$?
equal "exit 0" 0 "$code"
check "launch says the window stays open" "1 background job(s) still run here" "$out"
check "the prompt asks to adopt" "Background jobs: 1 still running in the previous session" "$(cat "$chainB/gen-02/prompt.txt")"
until_true 15 test "$(kill_state "$chainB" 1)" = held
equal "the watcher holds the passer" "held" "$(kill_state "$chainB" 1)"
equal "the window shows the hold" "1 job(s)" "$(tsb show-options -wqv -t "$pB" @handoff_hold)"
sleep 1
if window_gone "$pB"; then bad "held window stays" "present" "gone"; else ok "the held window stays open"; fi
sidB2="$(python3 "$LIB" get "$chainB" 2 session_id)"
paneB2="$(python3 "$LIB" get "$chainB" 2 tmux.pane)"
out="$(as_session "$sidB2" "$paneB2" "$CCH" adopt 2>&1)"; code=$?
equal "adopt needs job ids or --all" 2 "$code"
out="$(as_session "$sidB2" "$paneB2" "$CCH" adopt --all 2>&1)"; code=$?
equal "adopt --all from the successor" 0 "$code"
until_true 20 window_gone "$pB"
if window_gone "$pB"; then ok "after adoption the passer closes"; else bad "closed after adopt" "gone" "$(kill_state "$chainB" 1)"; fi
kill_bg sess-B

printf 'ps unavailable: pgrep finds the job; neither: an unknown job holds the window\n'
pJ="$(start_passer sess-J nops "$HOME/repo")"
tsb send-keys -t "$pJ" BG Enter
until_true 5 bg_running sess-J
cpJ="$(claude_pid_of "$pJ")"
touch "$FSH_TEST_LOG/ps-fail"
check "ps refused: the shell is found through pgrep" "sleep 300" "$(python3 "$LIB" jobs --pid "$cpJ")"
touch "$FSH_TEST_LOG/pgrep-fail"
check "ps and pgrep refused: an unknown job (fail closed)" "could not list this session's processes" \
  "$(python3 "$LIB" jobs --pid "$cpJ")"
tsb send-keys -t "$pJ" STOPBG Enter
out="$(cd "$HOME/repo" && as_session sess-J "$pJ" "$CCH" init --name nops-chain 2>&1)"
briefJ="$(head -n 1 <<<"$out")"; chainJ="$(dirname "$(dirname "$briefJ")")"
fill_brief "$briefJ" nops
as_session sess-J "$pJ" "$CCH" launch "$briefJ" >/dev/null 2>&1
until_true 15 test "$(kill_state "$chainJ" 1)" = held
equal "with no process listing the watcher holds the passer" "held" "$(kill_state "$chainJ" 1)"
rm -f "$FSH_TEST_LOG/pgrep-fail"
until_true 30 window_gone "$pJ"
if window_gone "$pJ"; then ok "with pgrep back (ps still refused) it closes: no job, pane checked by pgrep"
else bad "closed with pgrep only" "gone" "$(kill_state "$chainJ" 1)"; fi
rm -f "$FSH_TEST_LOG/ps-fail"

printf 'a job that finishes by itself releases the hold\n'
pC="$(start_passer sess-C finish "$HOME/repo")"
tsb send-keys -t "$pC" BG Enter
until_true 5 bg_running sess-C
out="$(cd "$HOME/repo" && as_session sess-C "$pC" "$CCH" init --name finish-chain 2>&1)"
briefC="$(head -n 1 <<<"$out")"; chainC="$(dirname "$(dirname "$briefC")")"
fill_brief "$briefC" finish
as_session sess-C "$pC" "$CCH" launch "$briefC" >/dev/null 2>&1
until_true 15 test "$(kill_state "$chainC" 1)" = held
equal "held while the job runs" "held" "$(kill_state "$chainC" 1)"
tsb send-keys -t "$pC" STOPBG Enter
until_true 30 window_gone "$pC"
if window_gone "$pC"; then ok "closed once the job finished"; else bad "closed after finish" "gone" "$(kill_state "$chainC" 1)"; fi

printf 'no first reply: the passer stays, launch exits 7\n'
pD="$(start_passer sess-D silent "$HOME/repo")"
out="$(cd "$HOME/repo" && as_session sess-D "$pD" "$CCH" init --name silent-chain 2>&1)"
briefD="$(head -n 1 <<<"$out")"; chainD="$(dirname "$(dirname "$briefD")")"
fill_brief "$briefD" silent
tsb set-environment -g FAKE_NO_REPLY 1
out="$(FSH_ENGAGE_TIMEOUT=3 FSH_FIRST_RESPONSE_TIMEOUT=4 as_session sess-D "$pD" "$CCH" launch "$briefD" 2>&1)"; code=$?
tsb set-environment -gu FAKE_NO_REPLY
equal "exit 7" 7 "$code"
check "says the new window is left running" "LEFT RUNNING" "$out"
until_true 15 test "$(kill_state "$chainD" 1)" = skipped
equal "the watcher gives up and keeps the passer" "skipped" "$(kill_state "$chainD" 1)"
if window_gone "$pD"; then bad "passer kept" "present" "gone"; else ok "the passer's window is still open"; fi
out="$(as_session sess-D "$pD" "$CCH" launch "$briefD" 2>&1)"; code=$?
equal "relaunching a running brief: exit 4" 4 "$code"

printf 'someone typing in the passer keeps it open\n'
pE="$(start_passer sess-E typed "$HOME/repo")"
out="$(cd "$HOME/repo" && as_session sess-E "$pE" "$CCH" init --name typed-chain 2>&1)"
briefE="$(head -n 1 <<<"$out")"; chainE="$(dirname "$(dirname "$briefE")")"
fill_brief "$briefE" typed
tsb set-environment -g FAKE_NO_REPLY 1
FSH_ENGAGE_TIMEOUT=2 as_session sess-E "$pE" "$CCH" launch "$briefE" >/dev/null 2>&1
tsb set-environment -gu FAKE_NO_REPLY
sleep 1
tE="$(ls "$HOME"/.claude/projects/*/sess-E.jsonl)"
printf '{"type":"user","sessionId":"sess-E","timestamp":"%s","message":{"content":"wait, one more thing"}}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.999Z)" >> "$tE"
sidE2="$(python3 "$LIB" get "$chainE" 2 session_id)"
tE2="$(ls "$HOME"/.claude/projects/*/"$sidE2".jsonl)"
printf '{"type":"assistant","sessionId":"%s","timestamp":"%s","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"late reply"}]}}\n' "$sidE2" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$tE2"
until_true 15 test "$(kill_state "$chainE" 1)" = kept
equal "kept: a person typed after the handoff" "kept" "$(kill_state "$chainE" 1)"
check "and why" "someone typed in the passer" "$(python3 "$LIB" get "$chainE" 1 handoff.kill.reason)"

printf 'a passer whose Claude already exited is left as it is (its pane may be in use)\n'
pK="$(tsb new-window -d -P -F '#{pane_id}' -t '=origin:' -n exited -c "$HOME/repo" \
  "cd $HOME/repo && $tmp/bin/fake-claude --session-id sess-K -n exited; exec sh")"
until_true 5 test -s "$FSH_TEST_LOG/sess-K.argv"
cpK="$(cat "$FSH_TEST_LOG/sess-K.pid")"
asK() { env CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=sess-K CLAUDE_PID="$cpK" TMUX_PANE="$pK" CLAUDE_EFFORT=high "$@"; }
out="$(cd "$HOME/repo" && asK "$CCH" init --name exited-chain 2>&1)"
briefK="$(head -n 1 <<<"$out")"; chainK="$(dirname "$(dirname "$briefK")")"
fill_brief "$briefK" exited
tsb set-environment -g FAKE_NO_REPLY 1
FSH_ENGAGE_TIMEOUT=2 asK "$CCH" launch "$briefK" >/dev/null 2>&1
tsb set-environment -gu FAKE_NO_REPLY
kill "$cpK" 2>/dev/null                       # the passer's Claude exits; its pane keeps a shell
sidK2="$(python3 "$LIB" get "$chainK" 2 session_id)"
tK2="$(ls "$HOME"/.claude/projects/*/"$sidK2".jsonl)"
printf '{"type":"assistant","sessionId":"%s","timestamp":"%s","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"late reply"}]}}\n' "$sidK2" "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" >> "$tK2"
until_true 15 test "$(kill_state "$chainK" 1)" = kept
equal "kept: the passer's Claude is gone" "kept" "$(kill_state "$chainK" 1)"
if window_gone "$pK"; then bad "pane kept" "present" "gone"; else ok "its pane (now a shell) is still open"; fi

printf 'goal carry-over, --go and --no-goal\n'
pF="$(start_passer sess-F goal "$HOME/repo")"
tF="$(ls "$HOME"/.claude/projects/*/sess-F.jsonl)"
printf '{"type":"attachment","sessionId":"sess-F","timestamp":"2026-10-23T10:00:00.500Z","attachment":{"type":"goal_status","met":false,"condition":"Finish the widget; done when CI is green"}}\n' >> "$tF"
out="$(cd "$HOME/repo" && as_session sess-F "$pF" "$CCH" init --name goal-chain 2>&1)"
briefF="$(head -n 1 <<<"$out")"; chainF="$(dirname "$(dirname "$briefF")")"
check "the brief records the goal" "Active /goal: Finish the widget; done when CI is green" "$(cat "$briefF")"
fill_brief "$briefF" goal
out="$(IS_SANDBOX=1 FSH_KILL=0 FSH_DEFAULT_LAUNCHER=yu as_session sess-F "$pF" "$CCH" launch --go --notify lead-session "$briefF" 2>&1)"; code=$?
equal "exit 0" 0 "$code"
p="$(cat "$chainF/gen-02/prompt.txt")"
check "the prompt starts with the passer's /goal" "/goal Finish the widget; done when CI is green" "$(head -n 1 <<<"$p")"
check "--go authorizes the whole brief" "do all of it without asking which item to start" "$p"
check "FSH_KILL=0 keeps the passer" "this window stays open" "$out"
sidF2="$(python3 "$LIB" get "$chainF" 2 session_id)"
check "the goal reached claude" "/goal Finish the widget" "$(argv_of "$sidF2")"
equal "a zsh launcher runs through the login shell (yu here)" "yu" "$(argv_of "$sidF2" | head -n 1)"
equal "a successor on this machine keeps this session's IS_SANDBOX" 1 "$(cat "$FSH_TEST_LOG/$sidF2.is_sandbox" 2>/dev/null)"
tF2="$(ls "$HOME"/.claude/projects/*/"$sidF2".jsonl)"
printf '{"type":"attachment","sessionId":"%s","timestamp":"2026-10-23T13:00:00.000Z","attachment":{"type":"goal_status","met":false,"condition":"Finish the widget; done when CI is green\\n\\n[cc-handoff] You are generation 2 (session name goal-2) of handoff chain goal-chain."}}\n' "$sidF2" >> "$tF2"
equal "a carried goal drops the inline prompt that rode along (no snowball)" "Finish the widget; done when CI is green" \
  "$(python3 "$LIB" info "$tF2" | jq -r .goal)"
python3 "$LIB" prepare --chain-dir "$chainF" --gen 1 --successor-sid x --successor-name y --successor-host h \
  --successor-cwd "$HOME/repo" --launcher yu --no-goal >/dev/null
equal "--no-goal drops it" "" "$(grep '^/goal ' "$chainF/gen-02/prompt.txt")"
python3 "$LIB" prepare --chain-dir "$chainF" --gen 1 --successor-sid x2 --successor-name y --successor-host h \
  --successor-cwd "$HOME/repo" --launcher yu --successor-env '{"STALE_FLAG": "1"}' >/dev/null
python3 "$LIB" prepare --chain-dir "$chainF" --gen 1 --successor-sid x3 --successor-name y --successor-host h \
  --successor-cwd "$HOME/repo" --launcher yu >/dev/null
equal "a retried launch keeps no environment from the earlier attempt" "{}" "$(python3 "$LIB" get "$chainF" 2 env)"
equal "nor its window" "{}" "$(python3 "$LIB" get "$chainF" 2 tmux)"

printf 'the launcher follows the provider route; an unmatched route opens nothing\n'
pG="$(start_passer sess-G route "$HOME/repo")"
out="$(cd "$HOME/repo" && as_session sess-G "$pG" "$CCH" init --name route-chain 2>&1)"
briefG="$(head -n 1 <<<"$out")"
fill_brief "$briefG" route
# The choice only, via --print.
pick() { RUN_EFFORT="${RUN_EFFORT:-xhigh}" as_session sess-G "$pG" "$CCH" launch --print "$briefG" 2>&1; }
mkdir -p "$tmp/home-bedrock/.claude" "$tmp/home-none"
printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1","AWS_REGION":"us-east-1"}}\n' > "$tmp/home-bedrock/.claude/settings.json"
out="$(pick)"
check "Anthropic API: claude, the route claude starts here" \
  'launcher: claude, because this session is on the Anthropic API (Claude subscription or API key), the route claude starts on this machine' "$out"
out="$(FSH_DEFAULT_LAUNCHER=yu pick)"
check "FSH_DEFAULT_LAUNCHER names the launcher for that case" 'launcher: yu, because this session is on the Anthropic API' "$out"
out="$(CLAUDE_CODE_USE_MANTLE=1 AWS_REGION=us-east-1 ANTHROPIC_DEFAULT_OPUS_MODEL=anthropic.claude-opus-5-5 pick)"; code=$?
equal "Mantle: exit 0" 0 "$code"
check "Mantle: yuma (the default map) with this session's Mantle id" 'yuma --model "anthropic.claude-opus-5-5" --effort xhigh' "$out"
check "Mantle: says which launcher and why" \
  'launcher: yuma, because this session is on Bedrock Mantle [CLAUDE_CODE_USE_MANTLE=1 AWS_REGION=us-east-1], which FSH_LAUNCHERS maps to yuma' "$out"
out="$(CLAUDE_CODE_USE_MANTLE=' TRUE ' CLAUDE_CODE_USE_BEDROCK=0 AWS_REGION=us-east-1 pick)"
check "flags read as Claude Code reads them (' TRUE ' on, 0 off)" 'launcher: yuma, because this session is on Bedrock Mantle' "$out"
out="$(FSH_LAUNCHERS='' CLAUDE_CODE_USE_MANTLE=1 AWS_REGION=us-east-1 pick)"; code=$?
equal "Mantle with an empty map: exit 8" 8 "$code"
check "says no launcher is mapped" 'and FSH_LAUNCHERS maps no launcher to this route' "$out"
out="$(FSH_LAUNCHERS='bedrock=claude-bedrock mantle=yuma' CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 pick)"; code=$?
equal "a mapped Bedrock launcher: exit 0" 0 "$code"
check "uses the mapped launcher" 'launcher: claude-bedrock, because this session is on Bedrock Runtime [CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1], which FSH_LAUNCHERS maps to claude-bedrock' "$out"
out="$(FSH_LAUNCHERS='endpoint=claude-proxy' ANTHROPIC_BASE_URL=http://127.0.0.1:8317/v1 pick)"
check "endpoint= maps any custom endpoint" 'launcher: claude-proxy, because this session is on a custom endpoint at 127.0.0.1:8317' "$out"
out="$(FSH_LAUNCHERS='mantle=yuma;rm' CLAUDE_CODE_USE_MANTLE=1 pick)"; code=$?
equal "a mapped launcher with shell syntax: exit 2" 2 "$code"
out="$(CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 ANTHROPIC_DEFAULT_OPUS_MODEL='us.anthropic.claude-opus-5-5[1m]' pick)"; code=$?
equal "Bedrock Runtime where claude is the Anthropic API: exit 8" 8 "$code"
check "names both routes" \
  'Bedrock Runtime [CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1], but claude on this machine starts the Anthropic API' "$out"
out="$(HOME="$tmp/home-bedrock" CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 ANTHROPIC_DEFAULT_OPUS_MODEL='global.anthropic.claude-opus-5-5[1m]' pick)"; code=$?
equal "Bedrock Runtime where claude is Bedrock: exit 0" 0 "$code"
check "Bedrock Runtime: claude with its Bedrock id" 'claude --model "global.anthropic.claude-opus-5-5[1m]"' "$out"
mkdir -p "$HOME/repo/.claude"
printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}\n' > "$HOME/repo/.claude/settings.json"
out="$(CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 pick)"
check "the repo's own settings count" 'launcher: claude, because this session is on Bedrock Runtime' "$out"
printf '{"env":{"CLAUDE_CODE_USE_BEDROCK":""}}\n' > "$HOME/repo/.claude/settings.local.json"
out="$(CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 pick)"; code=$?
equal "settings.local.json wins over settings.json: exit 8" 8 "$code"
rm -rf "$HOME/repo/.claude"
out="$(HOME="$tmp/home-none" CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 pick)"; code=$?
equal "Bedrock Runtime when claude's route cannot be read: exit 8" 8 "$code"
check "says it could not be read" 'what claude starts on this machine could not be read' "$out"
out="$(HOME="$tmp/home-none" pick)"
check "no flag, claude's route unreadable: claude" \
  'launcher: claude, because this session is on the Anthropic API (Claude subscription or API key), the default route' "$out"
out="$(HOME="$tmp/home-bedrock" pick)"; code=$?
equal "no flag where claude is Bedrock: exit 8" 8 "$code"
check "says claude would move it" 'but claude on this machine starts Bedrock Runtime' "$out"
out="$(HOME="$tmp/home-bedrock" RUN_EFFORT=xhigh env -u CLAUDECODE CLAUDE_CODE_SESSION_ID=sess-G CLAUDE_PID="$(claude_pid_of "$pG")" TMUX_PANE="$pG" CLAUDE_EFFORT=xhigh "$CCH" launch --print "$briefG" 2>&1)"
check "no flag outside Claude Code: claude, the machine default" 'launcher: claude, because this was not run from a Claude Code session' "$out"
out="$(CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_MANTLE=1 AWS_REGION=us-east-1 pick)"; code=$?
equal "Bedrock and Mantle together: exit 8" 8 "$code"
check "names the mixed route" 'Bedrock with Mantle serving the anthropic.* ids' "$out"
out="$(CLAUDE_CODE_USE_VERTEX=1 pick)"; code=$?
equal "Vertex: exit 8" 8 "$code"
out="$(ANTHROPIC_BASE_URL="http://user:""s3cret@127.0.0.1:8317/v1" pick)"; code=$?   # built from pieces: no credential URL literal
equal "custom endpoint: exit 8" 8 "$code"
check "names the endpoint's host" 'a custom endpoint at 127.0.0.1:8317' "$out"
lacks "does not print the endpoint's credentials" 's3cret' "$out"
out="$(CLAUDE_CODE_USE_MANTLE=1 AWS_REGION=us-east-1 ANTHROPIC_DEFAULT_OPUS_MODEL=anthropic.claude-opus-5-5 FSH_LAUNCH_CMD=yu pick)"
check "FSH_LAUNCH_CMD: another launcher gets the opus alias, not this route's id" 'yu --model "opus"' "$out"
check "says what it overrode" 'launcher: yu, set by FSH_LAUNCH_CMD (detection would pick yuma, because' "$out"
out="$(CLAUDE_CODE_USE_MANTLE=1 AWS_REGION=us-east-1 ANTHROPIC_DEFAULT_OPUS_MODEL=anthropic.claude-opus-5-5 FSH_LAUNCH_CMD=yuma pick)"
check "naming the detected launcher keeps this session's id" 'yuma --model "anthropic.claude-opus-5-5"' "$out"
out="$(CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 FSH_LAUNCH_CMD=yuma pick)"; code=$?
equal "FSH_LAUNCH_CMD overrides a route no launcher reproduces: exit 0" 0 "$code"
check "says detection found none" 'launcher: yuma, set by FSH_LAUNCH_CMD (detection found no launcher:' "$out"
out="$(CLAUDE_CODE_USE_MANTLE=1 AWS_REGION=us-east-1 FSH_LAUNCH_CMD=yu FSH_MODEL=claude-opus-5-5 pick)"
check "FSH_MODEL still pins the model" 'yu --model "claude-opus-5-5"' "$out"
out="$(FSH_MODEL='us.anthropic.claude-opus-5-5[1m]' pick)"
check "the model flag is quoted ([1m] would glob in zsh)" '--model "us.anthropic.claude-opus-5-5[1m]"' "$out"
out="$(FSH_MODEL='' pick)"
lacks "an empty FSH_MODEL omits the flag" '--model' "$out"
out="$(FSH_MODEL='bad model;x' pick)"; code=$?
equal "a bad FSH_MODEL: exit 2" 2 "$code"
out="$(RUN_EFFORT=max pick)"
check "inherits max effort" '--effort max' "$out"
out="$(RUN_EFFORT=max FSH_EFFORT=high pick)"
check "FSH_EFFORT overrides the inherited effort" '--effort high' "$out"
out="$(RUN_EFFORT=turbo pick)"
check "an effort the CLI does not accept falls back to xhigh" '--effort xhigh' "$out"
out="$(FSH_BYPASS=yes pick)"; code=$?
equal "FSH_BYPASS other than 0/1: exit 2" 2 "$code"
n_before="$(tsb list-windows -a | wc -l | xargs)"
out="$(CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1 as_session sess-G "$pG" "$CCH" launch "$briefG" 2>&1)"; code=$?
equal "no launcher for the route on a real launch: exit 8" 8 "$code"
check "says nothing was started" 'Nothing was started.' "$out"
equal "and no window opened" "$n_before" "$(tsb list-windows -a | wc -l | xargs)"
out="$(FSH_LAUNCH_CMD='yu;rm' pick)"; code=$?
equal "a launcher with shell syntax: exit 2" 2 "$code"
out="$(FSH_AUTHORIZED=2 pick)"; code=$?
equal "FSH_AUTHORIZED other than 0/1: exit 2" 2 "$code"

printf 'permission checks: a successor gets no more than its passer had\n'
pY="$(tsb new-window -d -P -F '#{pane_id}' -t '=origin:' -n bypass -c "$HOME/repo" \
  "exec $tmp/bin/fake-claude --dangerously-skip-permissions --session-id sess-Y -n bypass")"
until_true 5 test -s "$FSH_TEST_LOG/sess-Y.argv"
out="$(cd "$HOME/repo" && as_session sess-Y "$pY" "$CCH" init --name bypass-chain 2>&1)"
briefY="$(head -n 1 <<<"$out")"; chainY="$(dirname "$(dirname "$briefY")")"
fill_brief "$briefY" bypass
FSH_KILL=0 as_session sess-Y "$pY" "$CCH" launch "$briefY" >/dev/null 2>&1
sidY2="$(python3 "$LIB" get "$chainY" 2 session_id)"
check "a passer in bypass mode hands it on" '--dangerously-skip-permissions' "$(argv_of "$sidY2")"
equal "and the record says so" "True" "$(python3 "$LIB" get "$chainY" 2 bypass)"
python3 "$LIB" prepare --chain-dir "$chainY" --gen 1 --successor-sid y3 --successor-name y --successor-host h \
  --successor-cwd "$HOME/repo" --launcher claude >/dev/null
equal "a launch without --bypass records none" "False" "$(python3 "$LIB" get "$chainY" 2 bypass)"

printf 'carried flags: the passer'"'"'s MCP config travels with it\n'
pH="$(tsb new-window -d -P -F '#{pane_id}' -t '=origin:' -n carry -c "$HOME/repo" \
  "exec $tmp/bin/fake-claude --strict-mcp-config --mcp-config $tmp/lean.json --session-id sess-H -n carry")"
until_true 5 test -s "$FSH_TEST_LOG/sess-H.argv"
out="$(cd "$HOME/repo" && as_session sess-H "$pH" "$CCH" init --name carry-chain 2>&1)"
briefH="$(head -n 1 <<<"$out")"
fill_brief "$briefH" carry
if [[ -r /proc/self/cmdline ]]; then
  out="$(as_session sess-H "$pH" "$CCH" launch --print --claude-arg --verbose "$briefH" 2>&1)"
  check "keeps --strict-mcp-config and --mcp-config" "'--strict-mcp-config' '--mcp-config' '$tmp/lean.json' '--verbose'" "$out"
  out="$(as_session sess-H "$pH" "$CCH" launch --print --host remote-box "$briefH" 2>&1)"
  check "another host gets none of this host's paths" "carried flags left behind for remote-box" "$out"
else
  ok "carried flags (exact argv needs /proc; ps fallback only on this OS)"
fi

printf 'cross-host: --host remote-box over ssh\n'
pR="$(start_passer sess-R travel "$HOME/repo")"
out="$(cd "$HOME/repo" && as_session sess-R "$pR" "$CCH" init --name travel-chain 2>&1)"
briefR="$(head -n 1 <<<"$out")"; chainR="$(dirname "$(dirname "$briefR")")"
equal "the chain directory is owner-only" 700 "$(mode_of "$chainR")"
fill_brief "$briefR" travel
out="$(REMOTE_IDENTITY=work as_session sess-R "$pR" "$CCH" launch --host remote-box "$briefR" 2>&1)"; code=$?
equal "a target of the other identity: exit 9" 9 "$code"
check "says why" "identity:work!=personal" "$out"
out="$(as_session sess-R "$pR" "$CCH" launch --host nowhere "$briefR" 2>&1)"; code=$?
equal "an unreachable host: exit 9" 9 "$code"
out="$(as_session sess-R "$pR" "$CCH" launch --host self-box --print "$briefR" 2>&1)"; code=$?
equal "an alias that is this machine, same briefs dir: exit 9" 9 "$code"
out="$(FSH_REMOTE_BRIEFS_DIR="$(dirname "$chainR")" as_session sess-R "$pR" "$CCH" launch --host self-box --print "$briefR" 2>&1)"; code=$?
equal "the same machine through FSH_REMOTE_BRIEFS_DIR pointing at this chain's dir: exit 9" 9 "$code"
check "says the copy would overwrite the chain" "copying the chain would overwrite it in place" "$out"
mv "$REMOTE_HOME/.claude.json" "$REMOTE_HOME/.claude.json.off"
out="$(as_session sess-R "$pR" "$CCH" launch --host remote-box --print "$briefR" 2>&1)"; code=$?
mv "$REMOTE_HOME/.claude.json.off" "$REMOTE_HOME/.claude.json"
equal "an untrusted remote dir: exit 9 (its trust dialog would stall the successor)" 9 "$code"
check "says which dir and what to do" "untrusted:$REMOTE_HOME/repo(run claude there once" "$out"
out="$(REMOTE_UID=0 as_session sess-R "$pR" "$CCH" launch --host remote-box --print "$briefR" 2>&1)"; code=$?
equal "a target that runs Claude as root, without IS_SANDBOX: exit 9" 9 "$code"
check "says what it needs" "rerun with FSH_SUCCESSOR_ENV=IS_SANDBOX=1" "$out"
out="$(REMOTE_UID=0 FSH_SUCCESSOR_ENV=IS_SANDBOX=1 as_session sess-R "$pR" "$CCH" launch --host remote-box --print "$briefR" 2>&1)"; code=$?
equal "with FSH_SUCCESSOR_ENV=IS_SANDBOX=1 it goes ahead" 0 "$code"
out="$(IS_SANDBOX=1 REMOTE_UID=0 as_session sess-R "$pR" "$CCH" launch --host remote-box --print "$briefR" 2>&1)"; code=$?
equal "this session's own IS_SANDBOX does not mark another host: exit 9" 9 "$code"
mkdir -p "$tmp/self-briefs"
out="$(IS_SANDBOX='' REMOTE_UID=0 FSH_REMOTE_BRIEFS_DIR="$tmp/self-briefs" as_session sess-R "$pR" "$CCH" launch --host self-box --print "$briefR" 2>&1)"; code=$?
equal "an alias for this machine as root, without IS_SANDBOX: exit 9" 9 "$code"
out="$(IS_SANDBOX=1 REMOTE_UID=0 FSH_REMOTE_BRIEFS_DIR="$tmp/self-briefs" as_session sess-R "$pR" "$CCH" launch --host self-box --print "$briefR" 2>&1)"; code=$?
equal "the same alias with this session's IS_SANDBOX: the same machine, it goes ahead" 0 "$code"
out="$(FSH_SUCCESSOR_ENV='IS_SANDBOX=1 IS_SANDBOX=0' as_session sess-R "$pR" "$CCH" launch --print "$briefR" 2>&1)"; code=$?
equal "FSH_SUCCESSOR_ENV naming a variable twice: exit 2" 2 "$code"
check "says which" "FSH_SUCCESSOR_ENV names IS_SANDBOX twice" "$out"
mkdir -p "$tmp/globdir" && : > "$tmp/globdir/IS_SANDBOX=1"   # a file a glob in the value would match
out="$(cd "$tmp/globdir" && FSH_SUCCESSOR_ENV='IS_SANDBOX=?' as_session sess-R "$pR" "$CCH" launch --print "$briefR" 2>&1)"; code=$?
equal "a glob in FSH_SUCCESSOR_ENV is not expanded against files: exit 2" 2 "$code"
out="$(FSH_SUCCESSOR_ENV='X=$(id)' as_session sess-R "$pR" "$CCH" launch --print "$briefR" 2>&1)"; code=$?
equal "FSH_SUCCESSOR_ENV with shell syntax: exit 2" 2 "$code"
out="$(FSH_SUCCESSOR_ENV=IS_SANDBOX=1 as_session sess-R "$pR" "$CCH" launch --host remote-box "$briefR" 2>&1)"; code=$?
equal "exit 0" 0 "$code"
check "preflight passed" "preflight: remote-box ok (machine remote-box" "$out"
check "reports the remote window" "in tmux window remote-box:handoffs:travel-2" "$out"
check "attach over ssh" "ssh -t remote-box tmux attach -t handoffs:travel-2" "$out"
rchain="$REMOTE_HOME/code/.briefs/$(basename "$chainR")"
if [[ -r "$rchain/gen-01/brief.md" && -r "$rchain/gen-01/transcript.md" ]]; then ok "the brief and rendered transcript travelled"
else bad "chain copied" "$rchain/gen-01/{brief,transcript}.md" "$(ls -R "$rchain" 2>&1 | head)"; fi
if gzip -dc "$rchain/gen-01/session.jsonl.gz" 2>/dev/null | grep -q 'Build the widget'; then ok "the raw JSONL travelled (gzipped)"
else bad "raw JSONL copied" "session.jsonl.gz" "$(ls "$rchain/gen-01" 2>&1)"; fi
equal "only its owner can read the raw JSONL copy (it is not redacted)" 600 "$(mode_of "$rchain/gen-01/session.jsonl.gz")"
equal "and the copied chain directory is owner-only" 700 "$(mode_of "$rchain")"
check "the copy is unpacked as the target's own user, not this host's uid" "tar --no-same-owner -C" \
  "$(grep -F "remote-box mkdir -p" "$FSH_TEST_LOG/ssh.log" 2>/dev/null)"
if [[ ! -e "$chainR/gen-01/session.jsonl.gz" ]]; then ok "no local copy of the gzip is left"; else bad "local gz removed" "absent" "present"; fi
sidR2="$(python3 "$LIB" get "$chainR" 2 session_id)"
equal "the successor runs on the remote box, in its repo" "$REMOTE_HOME/repo" "$(cat "$FSH_TEST_LOG/$sidR2.cwd" 2>/dev/null)"
equal "with the successor environment it was given" "1" "$(cat "$FSH_TEST_LOG/$sidR2.is_sandbox" 2>/dev/null)"
check "its prompt names the remote brief path" "The brief is the source of truth: $rchain/gen-01/brief.md" "$(argv_of "$sidR2")"
if ls "$REMOTE_HOME"/.claude/projects/*/"$sidR2".jsonl >/dev/null 2>&1; then ok "its transcript is on the remote box"; else bad "remote transcript" "present" "missing"; fi
equal "the remote statusline marker" '{"gen":2,' "$(head -c 9 "$REMOTE_HOME/.claude/state/handoff-chain/$sidR2.json" 2>/dev/null)"
rscreen="$(tsb_at "$REMOTE_SOCK" capture-pane -p -J -S - -t '=handoffs:=travel-2' 2>&1)"
check "the remote window echoes the history" "generation 1 transcript · session sess-R" "$rscreen"
until_true 20 window_gone "$pR"
if window_gone "$pR"; then ok "the local passer closed after the remote reply"; else bad "local passer closed" "gone" "$(kill_state "$chainR" 1)"; fi
out="$(as_session sess-R "$pR" "$CCH" launch --host remote-box "$briefR" 2>&1)"; code=$?
equal "relaunching a cross-host handoff whose successor replied: exit 4" 4 "$code"
check "the remote was asked" "on remote-box, responded" "$out"
until_true 10 test "$(kill_state "$rchain" 1)" = killed
equal "the remote copy of the passer's record says it closed" "killed" "$(kill_state "$rchain" 1)"
check "and when the successor replied" "replied" "$("$CCH" status "$rchain")"

printf '%s\n' '--host auto asks fleet-place; anything but a host falls back to this one'
pA2="$(start_passer sess-P place "$HOME/repo")"
out="$(cd "$HOME/repo" && as_session sess-P "$pA2" "$CCH" init --name place-chain 2>&1)"
briefP="$(head -n 1 <<<"$out")"
fill_brief "$briefP" place
out="$(as_session sess-P "$pA2" "$CCH" launch --host auto --print "$briefP" 2>&1)"
check "placement unavailable (exit 3): this host" "placement: this host" "$out"
out="$(FAKE_PLACE=local as_session sess-P "$pA2" "$CCH" launch --host auto --print "$briefP" 2>&1)"
check "fleet-place says local: this host" "placement: this host (fleet-place picked local" "$out"
out="$(FAKE_PLACE=remote-box as_session sess-P "$pA2" "$CCH" launch --host auto --away --print "$briefP" 2>&1)"
check "fleet-place picks a host: it is used" "placement: remote-box (picked by fleet-place" "$out"
check "--away excludes this host" "fleet-place --exclude test-box claude-session" "$(cat "$FSH_TEST_LOG/fleet-place.log")"

printf 'the macOS clipboard gets the rendered transcript\n'
pM="$(start_passer sess-M mac "$HOME/repo")"
out="$(cd "$HOME/repo" && as_session sess-M "$pM" "$CCH" init --name mac-chain 2>&1)"
briefM="$(head -n 1 <<<"$out")"; chainM="$(dirname "$(dirname "$briefM")")"
fill_brief "$briefM" mac
tsb set-environment -g FAKE_UNAME Darwin
FSH_KILL=0 as_session sess-M "$pM" "$CCH" launch "$briefM" >/dev/null 2>&1
tsb set-environment -gu FAKE_UNAME
check "pbcopy got the rendered transcript" "Tests pass (42)" "$(cat "$FSH_TEST_LOG/clipboard" 2>/dev/null)"
check "the echo says so" "and to the macOS clipboard" "$(tsb capture-pane -p -J -S - -t "$(python3 "$LIB" get "$chainM" 2 tmux.pane)")"

printf 'the watcher notifies the manager named with --notify\n'
pN="$(start_passer sess-N notify "$HOME/repo")"
out="$(cd "$HOME/repo" && as_session sess-N "$pN" "$CCH" init --name notify-chain 2>&1)"
briefN="$(head -n 1 <<<"$out")"
fill_brief "$briefN" notify
as_session sess-N "$pN" "$CCH" launch --notify ocean "$briefN" >/dev/null 2>&1
until_true 15 test -s "$FSH_TEST_LOG/drover.log"
check "drover sessions.message to the manager" 'op sessions.message {"id": "ocean", "text": "[cc-handoff] notify handed off to notify-2' "$(cat "$FSH_TEST_LOG/drover.log" 2>/dev/null)"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
