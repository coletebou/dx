#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOOK="$ROOT/base/git/hooks/pre-push"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pre-push-gitleaks-test.XXXXXX")
cleanup() { chmod -R u+w "$TMP" 2>/dev/null || true; command rm -R "$TMP"; }
trap cleanup EXIT

git -C "$TMP" init -q
git -C "$TMP" config user.name 'Hook Test'
git -C "$TMP" config user.email 'hook-test@example.invalid'
printf 'safe\n' > "$TMP/file.txt"
git -C "$TMP" add file.txt
git -C "$TMP" commit -qm 'test: safe commit'
first_sha=$(git -C "$TMP" rev-parse HEAD)
printf 'still safe\n' >> "$TMP/file.txt"
git -C "$TMP" add file.txt
git -C "$TMP" commit -qm 'test: second safe commit'
head_sha=$(git -C "$TMP" rev-parse HEAD)
zero_sha=0000000000000000000000000000000000000000
zero_sha256=0000000000000000000000000000000000000000000000000000000000000000
unknown_sha=1111111111111111111111111111111111111111

cat > "$TMP/fake-gitleaks" <<'FAKE'
#!/usr/bin/env bash
# With GITLEAKS_RENDEZVOUS, pass only if the memory gate starts while this runs.
if [[ -n "${GITLEAKS_RENDEZVOUS:-}" ]]; then
  for _ in $(seq 300); do [[ -e "$GITLEAKS_RENDEZVOUS" ]] && break; sleep 0.1; done
  [[ -e "$GITLEAKS_RENDEZVOUS" ]] || exit 9
fi
printf '%s\n' "$*" > "$GITLEAKS_FAKE_LOG"
exit "${GITLEAKS_FAKE_EXIT:-0}"
FAKE
chmod +x "$TMP/fake-gitleaks"

run_hook() {
  local remote_sha="$1"
  printf 'refs/heads/master %s refs/heads/master %s\n' "$head_sha" "$remote_sha" |
    (cd "$TMP" && GITLEAKS_BIN="$TMP/fake-gitleaks" GITLEAKS_FAKE_LOG="$TMP/args" "$HOOK" origin unused)
}

GITLEAKS_FAKE_EXIT=0 run_hook "$zero_sha"
grep -qF -- "--log-opts=$head_sha --not --remotes=origin ." "$TMP/args"


GITLEAKS_FAKE_EXIT=0 run_hook "$first_sha"
# $2 is not a reachable URL here, so the advertisement is unavailable and
# the existing-ref scan keeps its original range.
grep -qF -- "--log-opts=$first_sha..$head_sha ." "$TMP/args"

GITLEAKS_FAKE_EXIT=0 run_hook "$unknown_sha"
grep -qF -- "--log-opts=$head_sha ." "$TMP/args"
if grep -qF -- '--not' "$TMP/args"; then
  echo "pre-push test: missing remote tip did not scan the full tip" >&2
  exit 1
fi

command rm -f "$TMP/args"
printf 'refs/heads/master %s refs/heads/master %s\n' "$zero_sha256" "$head_sha" |
  (cd "$TMP" && GITLEAKS_BIN="$TMP/fake-gitleaks" GITLEAKS_FAKE_LOG="$TMP/args" "$HOOK" origin unused)
[[ ! -e "$TMP/args" ]]

if GITLEAKS_FAKE_EXIT=1 run_hook "$zero_sha"; then
  echo "pre-push test: leak result did not block" >&2
  exit 1
fi

if printf 'refs/heads/master %s refs/heads/master %s\n' "$head_sha" "$zero_sha" |
    (cd "$TMP" && GITLEAKS_BIN="$TMP/missing" "$HOOK" origin unused); then
  echo "pre-push test: missing gitleaks did not block" >&2
  exit 1
fi

# The memory gate runs alongside the secret scan. A copy of the hook in a
# fixture tree finds a stub gate the way the real hook finds scripts/.
mkdir -p "$TMP/tree/base/git/hooks" "$TMP/tree/scripts" "$TMP/hook-tmp"
cp "$HOOK" "$TMP/tree/base/git/hooks/pre-push"
cat > "$TMP/tree/scripts/pre-push-memory" <<'GATE'
#!/usr/bin/env bash
[[ -z "${GITLEAKS_RENDEZVOUS:-}" ]] || : >"$GITLEAKS_RENDEZVOUS"
sleep "${GATE_SLEEP:-0}"
echo "stub gate checked $1"
exit "${GATE_EXIT:-0}"
GATE
chmod +x "$TMP/tree/scripts/pre-push-memory"
run_tree_hook() {
  printf 'refs/heads/master %s refs/heads/master %s\n' "$head_sha" "$first_sha" |
    (cd "$TMP" && TMPDIR="$TMP/hook-tmp" GITLEAKS_BIN="$TMP/fake-gitleaks" GITLEAKS_FAKE_LOG="$TMP/args" \
      "$TMP/tree/base/git/hooks/pre-push" origin unused) 2>"$TMP/hook-err"
}
# The stub scan passes only if the gate starts while it is still running.
if ! GITLEAKS_RENDEZVOUS="$TMP/gate-started" run_tree_hook; then
  echo "pre-push test: the memory gate waited for the secret scan" >&2
  exit 1
fi
grep -qF "stub gate checked $head_sha" "$TMP/hook-err"
grep -qF -- "--log-opts=$first_sha..$head_sha ." "$TMP/args"
rc=0; GATE_EXIT=3 run_tree_hook || rc=$?
if [[ "$rc" -ne 3 ]] || ! grep -qF "stub gate checked" "$TMP/hook-err"; then
  echo "pre-push test: a failing memory gate did not block with its status and output (rc=$rc)" >&2
  exit 1
fi
if GATE_SLEEP=1 GITLEAKS_FAKE_EXIT=1 run_tree_hook; then
  echo "pre-push test: leak result did not block while the memory gate ran" >&2
  exit 1
fi
if [[ -n "$(ls -A "$TMP/hook-tmp")" ]]; then
  echo "pre-push test: memory gate output left behind" >&2
  exit 1
fi
# The memory gate is optional in this repository: without it the push proceeds
# on the secret scan alone, and a leak still blocks.
command rm -f "$TMP/tree/scripts/pre-push-memory"
if ! run_tree_hook; then
  echo "pre-push test: a missing (optional) memory gate blocked the push" >&2
  exit 1
fi
grep -qF -- "--log-opts=$first_sha..$head_sha ." "$TMP/args"
if grep -qF "stub gate" "$TMP/hook-err"; then
  echo "pre-push test: a removed memory gate still ran" >&2
  exit 1
fi
if GITLEAKS_FAKE_EXIT=1 run_tree_hook; then
  echo "pre-push test: leak result did not block without the memory gate" >&2
  exit 1
fi

# Real-gitleaks behaviour for an EXISTING ref: merging a branch the remote
# already has (dev -> deploy) must not rescan commits already published, while
# any commit the remote does not have must still be scanned and block.
if command -v gitleaks >/dev/null 2>&1; then
  R="$TMP/real"
  git init -q --bare "$R/remote.git"
  git init -q -b master "$R/work"
  w() { git -C "$R/work" -c core.hooksPath=/dev/null "$@"; }
  w config user.name 'Hook Test'
  w config user.email 'hook-test@example.invalid'
  w remote add origin "$R/remote.git"
  # Built at runtime so this file never contains a token-shaped literal.
  token() { printf 'ghp_%s' "$(openssl rand -hex 18)"; }
  printf 'safe\n' > "$R/work/base.txt"
  w add base.txt && w commit -qm base
  w branch deploy
  w switch -qc dev
  printf 'published = "%s"\n' "$(token)" > "$R/work/published.txt"
  w add published.txt && w commit -qm 'dev: finding already on the remote'
  w push -q origin master dev deploy
  w switch -q deploy
  old_deploy=$(w rev-parse HEAD)
  w merge -q --no-ff -m 'merge dev into deploy' dev
  push_deploy() {
    printf 'refs/heads/deploy %s refs/heads/deploy %s\n' "$(w rev-parse HEAD)" "$old_deploy" |
      (cd "$R/work" && "$HOOK" origin "$R/remote.git") >/dev/null 2>&1
  }
  if ! push_deploy; then
    echo "pre-push test: existing-ref push rescanned commits the remote already has" >&2
    exit 1
  fi
  # Variant 1: a new finding committed directly on the existing ref still blocks.
  printf 'fresh = "%s"\n' "$(token)" > "$R/work/fresh.txt"
  w add fresh.txt && w commit -qm 'deploy: new finding'
  if push_deploy; then
    echo "pre-push test: new finding on an existing ref did not block" >&2
    exit 1
  fi
  w reset -q --hard HEAD~1
  # Variant 2: a finding on an unpublished side branch merged in still blocks.
  w switch -qc side dev
  printf 'side = "%s"\n' "$(token)" > "$R/work/side.txt"
  w add side.txt && w commit -qm 'side: unpublished finding'
  w switch -q deploy
  w merge -q --no-ff -m 'merge side into deploy' side
  if push_deploy; then
    echo "pre-push test: unpublished merged finding on an existing ref did not block" >&2
    exit 1
  fi
  w reset -q --hard HEAD~1
  # Variant 3: stale tracking ref. The remote was reset to drop a leaked commit
  # but this clone still tracks it; re-publishing it must still be scanned.
  w switch -qc leak master
  printf 'leak = "%s"\n' "$(token)" > "$R/work/leak.txt"
  w add leak.txt && w commit -qm 'leak: later removed from the remote'
  w push -q origin leak
  git -C "$R/remote.git" update-ref refs/heads/leak "$(w rev-parse master)"
  if printf 'refs/heads/leak %s refs/heads/leak %s\n' "$(w rev-parse HEAD)" "$(w rev-parse master)" |
      (cd "$R/work" && "$HOOK" origin "$R/remote.git") >/dev/null 2>&1; then
    echo "pre-push test: stale tracking ref let a removed finding be re-published unscanned" >&2
    exit 1
  fi
  # Variant 4: pushurl differs from url. Tracking refs describe the fetch
  # repository; the push destination does not have the finding.
  git init -q --bare "$R/dest.git"
  w push -q "$R/dest.git" master
  if printf 'refs/heads/leak %s refs/heads/leak %s\n' "$(w rev-parse HEAD)" "$(w rev-parse master)" |
      (cd "$R/work" && "$HOOK" origin "$R/dest.git") >/dev/null 2>&1; then
    echo "pre-push test: finding absent from the push destination was not scanned" >&2
    exit 1
  fi
  # Variant 5: new ref whose commits the destination already has passes, and
  # the temporary exclusion refs never outlive the hook.
  w switch -q deploy
  if ! printf 'refs/heads/deploy-copy %s refs/heads/deploy-copy %s\n' "$(w rev-parse origin/dev)" "$zero_sha" |
      (cd "$R/work" && "$HOOK" origin "$R/remote.git") >/dev/null 2>&1; then
    echo "pre-push test: new ref of already-published commits was blocked" >&2
    exit 1
  fi
  # Variant 6: another clone pushed master first, so its tip is absent here.
  # Commits the destination already has stay excluded; a new finding blocks.
  git clone -q "$R/remote.git" "$R/other"
  git -C "$R/other" -c user.name=o -c user.email=o@example.invalid \
    commit -q --allow-empty -m 'other: raced ahead'
  git -C "$R/other" -c core.hooksPath=/dev/null push -q origin master
  raced_tip=$(git -C "$R/other" rev-parse HEAD)
  w switch -q master
  w merge -q --no-ff -m 'merge dev into master' dev
  push_raced() {
    printf 'refs/heads/master %s refs/heads/master %s\n' "$(w rev-parse HEAD)" "$raced_tip" |
      (cd "$R/work" && "$HOOK" origin "$R/remote.git") >/dev/null 2>&1
  }
  if ! push_raced; then
    echo "pre-push test: raced push rescanned commits the remote already has" >&2
    exit 1
  fi
  printf 'raced = "%s"\n' "$(token)" > "$R/work/raced.txt"
  w add raced.txt && w commit -qm 'master: new finding'
  if push_raced; then
    echo "pre-push test: new finding on a raced push did not block" >&2
    exit 1
  fi
  if [[ -n "$(w for-each-ref refs/pre-push-scan/)" ]]; then
    echo "pre-push test: temporary exclusion refs were left behind" >&2
    exit 1
  fi
fi

echo "pre-push gitleaks tests: ok"
