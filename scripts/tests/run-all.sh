#!/usr/bin/env bash
# run-all.sh: every test suite in the repo, one after another, then a summary. A failing suite
# prints its failing checks and the end of its output. Exit 1 if any failed.
#
#   bash scripts/tests/run-all.sh [PATTERN...]     (only suites whose path contains a PATTERN)
#
# The tmux suites start private servers and refuse to run while a real tmux server's socket is
# visible: run this where none is (CI), or under a private /tmp (see lib/tmux-sandbox.sh).
# mcp-agent-safety's suite needs Node 21 or newer; with an older node it is skipped, said so.
# With RUN_ALL_LOG_DIR set, each failing suite's whole output is also saved there (CI keeps it).
# RUN_ALL_SUITE_TIMEOUT bounds each suite (default 30 min); past it, its whole process tree is
# killed, not just the one process that started it, so an orphaned child can never hold a CI
# step's log pipe open and wedge the job the way a plain `kill` or signal-only timeout would.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$root" || exit 1

selected() {
  local p
  (( $# > 1 )) || return 0
  for p in "${@:2}"; do [[ "$1" == *"$p"* ]] && return 0; done
  return 1
}

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
passed=0 failed=0 failures=""
suite_timeout="${RUN_ALL_SUITE_TIMEOUT:-1800}"

# kill_tree SIGNAL PID: that process and every descendant it has forked, deepest first. Killing
# only the named process (as a single `kill PID`, or a SIGALRM delivered to it by an exec'd
# timer) leaves its children running as orphans: one still holding this step's stdout or stderr
# open (a CI log pipe, a terminal) blocks whoever reads it long after the named process is gone
# — which is what actually turned one hung suite into a job that never finished. `ps -A -o
# pid=,ppid=` is the one table format POSIX guarantees on both GNU and BSD ps (BSD's `-e` means
# something else, so `-A` is used for "every process"; the empty `=` suppresses the header).
kill_tree() {
  local sig="$1" pid="$2" table kid
  # Find descendants on a best-effort basis: without ps, there is nothing to walk, but PID
  # itself must still be signaled either way.
  table="$(ps -A -o pid=,ppid= 2>/dev/null)" || table=""
  if [[ -n "$table" ]]; then
    while IFS= read -r kid; do
      [[ -n "$kid" && "$kid" != "$pid" ]] || continue
      kill_tree "$sig" "$kid"
    done <<<"$(printf '%s\n' "$table" | awk -v p="$pid" '$2 == p { print $1 }')"
  fi
  kill -s "$sig" "$pid" 2>/dev/null || true
}

run() {  # run NAME COMMAND...
  local name="$1" start=$SECONDS rc=0 pid watchdog marker; shift
  printf '%-48s ' "$name"
  marker="$(mktemp)"
  "$@" </dev/null >"$log" 2>&1 &
  pid=$!
  (
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    sleep "$suite_timeout" & s=$!
    wait "$s"
    if kill -0 "$pid" 2>/dev/null; then
      : >"$marker"
      kill_tree TERM "$pid"
      sleep 5 & s=$!
      wait "$s"
      kill_tree KILL "$pid"
    fi
  ) </dev/null >/dev/null 2>&1 &
  watchdog=$!
  # bash 3.2 reports a job it waited on and that died by signal ("Terminated") on its own
  # stderr, even outside an interactive shell; braces keep that out of the suite's own log.
  { wait "$pid" || rc=$?; } 2>/dev/null
  kill -TERM "$watchdog" 2>/dev/null || true
  { wait "$watchdog" || true; } 2>/dev/null
  if [[ -s "$marker" ]]; then
    rc=1
    kill_tree KILL "$pid"
    printf '\nrun-all: %s did not finish within %ss; its whole process tree was killed\n' \
      "$name" "$suite_timeout" >>"$log"
  fi
  rm -f "$marker"
  if (( rc == 0 )); then
    printf 'ok    %3ss\n' "$((SECONDS - start))"; passed=$((passed + 1))
  else
    printf 'FAIL  %3ss\n' "$((SECONDS - start))"; failed=$((failed + 1)); failures="$failures $name"
    # Every failing check with its want/got lines (the suites' formats: FAIL, not ok, unittest),
    # then the end of the output.
    grep -E -A3 '^[[:space:]]*FAIL|^not ok|^(FAIL|ERROR):' "$log" | head -n 80 | sed 's/^/  ! /'
    # Python tracebacks whole, through the exception line.
    awk '/^Traceback/ { t = 1 } t { print } t && /^[^ \t]/ && !/^Traceback/ { t = 0 }' "$log" | head -n 60 | sed 's/^/  ! /'
    tail -n 25 "$log" | sed 's/^/    /'
    if [[ -n "${RUN_ALL_LOG_DIR:-}" ]] && mkdir -p "$RUN_ALL_LOG_DIR"; then
      cp "$log" "$RUN_ALL_LOG_DIR/$(printf '%s' "$name" | tr '/ ' '__').log"
    fi
  fi
}

for s in base/claude/statusline.test.sh scripts/tests/*.test.sh scripts/tests/*.test.py; do
  selected "$s" "$@" || continue
  case "$s" in
    *.py) run "$s" python3 "$s" ;;
    *) run "$s" bash "$s" ;;
  esac
done

safety=plugins/review/skills/mcp-agent-safety
if selected "$safety" "$@"; then
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if (( major >= 21 )); then
    # The glob, quoted: node --test given a directory runs it as a module on Node 21+.
    run "$safety" sh -c "cd '$safety' && node --test 'test/*.test.mjs'"
  else
    printf '%-48s skip  (needs Node 21+, found %s)\n' "$safety" "$(node --version 2>/dev/null || echo none)"
  fi
fi

printf '\n%d passed, %d failed%s\n' "$passed" "$failed" "${failures:+:$failures}"
(( failed == 0 ))
