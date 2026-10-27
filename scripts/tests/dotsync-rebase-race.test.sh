#!/usr/bin/env bash
# dotsync-rebase-race.test.sh: the pull's rebase retries when a live writer dirtied a tracked
# file mid-rebase ("Your local changes ... would be overwritten"), and never retries a real
# conflict. Runs the block extracted from scripts/dotsync against a stub git.
#
#   bash scripts/tests/dotsync-rebase-race.test.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dotsync-rebase-race-test.XXXXXX")
cleanup() { command rm -R "$TMP"; }
trap cleanup EXIT

eval "$(sed -n '/^dotsync_mktemp() {/,/^}/p' "$ROOT/scripts/lib/dotsync-runtime.sh")"
declare -F dotsync_mktemp >/dev/null || { echo "FAIL: dotsync_mktemp not found" >&2; exit 1; }
# shellcheck disable=SC2016  # a literal sed pattern
block="$(sed -n '/^      rebase_err="\$(dotsync_mktemp)"/,/^      \[\[ "\$rebase_err" == \/dev\/null \]\]/p' "$ROOT/scripts/dotsync")"
[[ -n "$block" ]] || { echo "FAIL: the rebase retry block was not found in dotsync" >&2; exit 1; }

sleep() { :; }
calls=0 aborts=0
git() {
  if [[ "$1 $2" == "rebase --autostash" ]]; then
    calls=$((calls + 1))
    if [[ "$calls" -le "$fails" ]]; then echo "$msg" >&2; return 1; fi
    return 0
  fi
  [[ "$1 $2" == "rebase --abort" ]] && aborts=$((aborts + 1))
  [[ "$1 $2" == "rev-parse --git-path" ]] && { echo "$TMP/no-rebase-dir"; return 0; }
  return 0
}

run() {
  fails=$1 msg=$2 calls=0 aborts=0
  # shellcheck disable=SC2034  # read by the eval'd block
  quiet=(--quiet) upstream=origin/master TIMING_LOG_DIR="$TMP" rebase_failed=0
  eval "$block" 2>"$TMP/stderr"
}

race='error: Your local changes to the following files would be overwritten by merge:'
run 0 "$race"
[[ "$rebase_failed" -eq 0 && "$calls" -eq 1 ]] || { echo "FAIL: clean rebase: failed=$rebase_failed calls=$calls" >&2; exit 1; }
run 2 "$race"
[[ "$rebase_failed" -eq 0 && "$calls" -eq 3 && "$aborts" -eq 2 ]] || { echo "FAIL: two races: failed=$rebase_failed calls=$calls aborts=$aborts" >&2; exit 1; }
[[ "$(grep -c 'raced a live write' "$TMP/stderr")" -eq 2 ]] || { echo "FAIL: expected two race notes" >&2; cat "$TMP/stderr" >&2; exit 1; }
run 3 "$race"
[[ "$rebase_failed" -eq 1 && "$calls" -eq 3 ]] || { echo "FAIL: persistent race: failed=$rebase_failed calls=$calls" >&2; exit 1; }
run 1 'CONFLICT (content): Merge conflict in base/zshrc'
[[ "$rebase_failed" -eq 1 && "$calls" -eq 1 && "$aborts" -eq 0 ]] || { echo "FAIL: a real conflict was retried: calls=$calls aborts=$aborts" >&2; exit 1; }
grep -q 'CONFLICT' "$TMP/stderr" || { echo "FAIL: the conflict's stderr was swallowed" >&2; exit 1; }
echo "ok the rebase retries a live write race, not a real conflict"
