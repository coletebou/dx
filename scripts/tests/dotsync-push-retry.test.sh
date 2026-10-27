#!/usr/bin/env bash
# dotsync-push-retry.test.sh: dotsync's push recovers when other machines win the push race,
# more than once in a row (each lost race needs a fresh fetch, rebase and push), and its early
# race check rebases before the one push. Runs the functions extracted from scripts/dotsync
# against throwaway repositories.
#
#   bash scripts/tests/dotsync-push-retry.test.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dotsync-push-retry-test.XXXXXX")
cleanup() { command rm -R "$TMP"; }
trap cleanup EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# git itself, except that the next $fail_rebases rebases fail (the live-writer race below).
fail_rebases=0
git() {
  if [[ "$1" == rebase && "${2:-}" != --abort && "$fail_rebases" -gt 0 ]]; then
    fail_rebases=$((fail_rebases - 1))
    return 1
  fi
  command git "$@"
}

git init -q --bare -b master "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/peer" 2>/dev/null
git -C "$TMP/peer" commit -q --allow-empty -m base
git -C "$TMP/peer" push -q origin master
git clone -q "$TMP/remote.git" "$TMP/local"
git -C "$TMP/local" commit -q --allow-empty -m local

# The peer pushes again before each of the first two pushes from local.
peer_pushes=0
peer_push() {
  peer_pushes=$((peer_pushes + 1))
  git -C "$TMP/peer" commit -q --allow-empty -m "peer $peer_pushes"
  git -C "$TMP/peer" push -q origin master
}
local_pushes=0
dotsync_timeout() {
  shift
  if [[ "$1 $2" == "git push" ]]; then
    local_pushes=$((local_pushes + 1))
    [[ "$local_pushes" -le 2 ]] && peer_push
  fi
  "$@"
}
sleep() { :; }

eval "$(sed -n '/^    push_preflight_ls_remote() {/,/^    }/p; /^    push_preflight_start() {/,/^    }/p;
               /^    push_preflight() {/,/^    }/p; /^    push_with_retry() {/,/^    }/p' "$ROOT/scripts/dotsync")"
eval "$(sed -n '/^dotsync_mktemp() {/,/^}/p' "$ROOT/scripts/lib/dotsync-runtime.sh")"
for f in push_preflight_ls_remote push_preflight_start push_preflight push_with_retry dotsync_mktemp; do
  declare -F "$f" >/dev/null || { echo "FAIL: $f not found where this test extracts it" >&2; exit 1; }
done

cd "$TMP/local"
# shellcheck disable=SC2034  # read by the functions eval'd above
verbose=0 upstream=origin/master DOTSYNC_GIT_TIMEOUT=5 dotsync_ssh_command=""
# shellcheck disable=SC2034
TIMING_LOG_DIR="$TMP" preflight_pid="" preflight_out=""
push_with_retry 2>"$TMP/stderr"
! grep -qE 'rejected|failed to push|^hint:' "$TMP/stderr" || { echo "FAIL: a recovered race printed git's rejection:" >&2; cat "$TMP/stderr" >&2; exit 1; }
[[ "$(grep -c 'lost a race' "$TMP/stderr")" -eq 2 ]] || { echo "FAIL: expected two race notes" >&2; cat "$TMP/stderr" >&2; exit 1; }
[[ "$local_pushes" -eq 3 ]] || { echo "FAIL: expected 3 pushes, got $local_pushes" >&2; exit 1; }
git fetch -q
[[ "$(git log -1 --format=%s origin/master)" == local ]] || { echo "FAIL: the local commit is not on the remote" >&2; exit 1; }
[[ "$(git rev-list --count origin/master)" -eq 4 ]] || { echo "FAIL: peer commits lost" >&2; exit 1; }
echo "ok the push survives two lost races"

# The race check started early still sees a peer that pushed first: one push, after a rebase.
git commit -q --allow-empty -m "local 2"
git -C "$TMP/peer" pull -q --rebase origin master
peer_push
local_pushes=2
push_preflight_start
[[ -n "$preflight_pid" ]] || { echo "FAIL: the race check did not start" >&2; exit 1; }
push_with_retry 2>/dev/null
[[ "$local_pushes" -eq 3 ]] || { echo "FAIL: expected one push, got $((local_pushes - 2))" >&2; exit 1; }
[[ -z "$preflight_pid" && ! -e "$TMP/preflight.$$" ]] || { echo "FAIL: the race check's result was left behind" >&2; exit 1; }
git fetch -q
[[ "$(git log -1 --format=%s origin/master)" == "local 2" ]] || { echo "FAIL: local 2 is not on the remote" >&2; exit 1; }
echo "ok the early race check rebases before the push"

# A rebase that fails because a live writer dirtied a tracked file mid-rebase does not fail the
# push: the race check falls through to the retry loop, and a failed retry rebase tries again.
git commit -q --allow-empty -m "local 3"
git -C "$TMP/peer" pull -q --rebase origin master
peer_push
fail_rebases=2
local_pushes=2
push_with_retry 2>"$TMP/stderr"
[[ "$local_pushes" -eq 3 && "$fail_rebases" -eq 0 ]] || { echo "FAIL: expected one push after the failed rebases" >&2; cat "$TMP/stderr" >&2; exit 1; }
git fetch -q
[[ "$(git log -1 --format=%s origin/master)" == "local 3" ]] || { echo "FAIL: local 3 is not on the remote" >&2; exit 1; }
echo "ok the push survives failed race rebases"
