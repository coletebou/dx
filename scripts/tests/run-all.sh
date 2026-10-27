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
run() {  # run NAME COMMAND...
  local name="$1" start=$SECONDS; shift
  printf '%-48s ' "$name"
  if "$@" >"$log" 2>&1; then
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
