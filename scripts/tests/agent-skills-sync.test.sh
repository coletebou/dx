#!/usr/bin/env bash
# agent-skills-sync.test.sh: the guarded updater against local bare repositories only. It clones,
# fast-forwards, and blocks (exit 2, checkout untouched) on dirty, detached, wrong-branch,
# locally-ahead, unexpected-remote and rewritten checkouts; labels and the remote-fetch mode; and
# nothing in the repo runs it on its own. The real HOME is never used.
#
#   bash scripts/tests/agent-skills-sync.test.sh

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$ROOT/scripts/agent-skills-sync"
TMP="$(mktemp -d)"
trap 'find "$TMP" -depth -delete 2>/dev/null || true' EXIT
export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

PASS=0
FAIL=0

ok() {
  PASS=$((PASS + 1))
  printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"
}

not_ok() {
  FAIL=$((FAIL + 1))
  printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"
}

assert_eq() {
  if [[ "$1" == "$2" ]]; then
    ok "$3"
  else
    not_ok "$3 (got [$1], expected [$2])"
  fi
}

assert_contains() {
  case "$1" in
    *"$2"*) ok "$3" ;;
    *) not_ok "$3 (missing [$2] in [$1])" ;;
  esac
}

REMOTE="$TMP/agent-skills.git"
SEED="$TMP/seed"
BRANCH="deploy"

git init --bare -q "$REMOTE"
git init -q "$SEED"
git -C "$SEED" config user.name "Test User"
git -C "$SEED" config user.email "test@example.com"
printf 'v1\n' > "$SEED/payload"
git -C "$SEED" add payload
git -C "$SEED" commit -qm "initial"
git -C "$SEED" branch -M "$BRANCH"
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" -c core.hooksPath=/dev/null push -qu origin "$BRANCH"
git -C "$SEED" branch main
git -C "$SEED" -c core.hooksPath=/dev/null push -qu origin main

run_sync() {
  local checkout="$1"
  set +e
  SYNC_OUTPUT="$(
    AGENT_SKILLS_SYNC_DIR="$checkout" \
    AGENT_SKILLS_SYNC_URL="$REMOTE" \
    AGENT_SKILLS_SYNC_BRANCH="$BRANCH" \
      "$SYNC" --one-line 2>&1
  )"
  SYNC_RC=$?
  set -e
}

run_sync_default_branch() {
  local checkout="$1"
  set +e
  SYNC_OUTPUT="$(
    AGENT_SKILLS_SYNC_DIR="$checkout" \
    AGENT_SKILLS_SYNC_URL="$REMOTE" \
      "$SYNC" --one-line 2>&1
  )"
  SYNC_RC=$?
  set -e
}

DEFAULT_CHECKOUT="$TMP/default-checkout"
run_sync_default_branch "$DEFAULT_CHECKOUT"
assert_eq "$SYNC_RC" "0" "default branch checkout is cloned"
assert_eq "$(git -C "$DEFAULT_CHECKOUT" symbolic-ref --short HEAD)" "main" \
  "default deployment branch is stable main"
assert_contains "$SYNC_OUTPUT" "agent-skills cloned main@" \
  "default branch action is reported"

CHECKOUT="$TMP/checkout"
run_sync "$CHECKOUT"
assert_eq "$SYNC_RC" "0" "missing checkout is cloned"
assert_contains "$SYNC_OUTPUT" "agent-skills cloned" "clone reports its action"
assert_eq "$(git -C "$CHECKOUT" symbolic-ref --short HEAD)" "$BRANCH" \
  "clone checks out the deployment branch"

run_sync "$CHECKOUT"
assert_eq "$SYNC_RC" "0" "current checkout succeeds"
assert_contains "$SYNC_OUTPUT" "agent-skills current" "current checkout is reported"

printf 'v2\n' >> "$SEED/payload"
git -C "$SEED" add payload
git -C "$SEED" commit -qm "advance"
git -C "$SEED" -c core.hooksPath=/dev/null push -q
REMOTE_HEAD="$(git -C "$SEED" rev-parse HEAD)"

run_sync "$CHECKOUT"
assert_eq "$SYNC_RC" "0" "behind checkout fast-forwards"
assert_eq "$(git -C "$CHECKOUT" rev-parse HEAD)" "$REMOTE_HEAD" \
  "fast-forward reaches the deployment head"
assert_contains "$SYNC_OUTPUT" "agent-skills updated" "fast-forward is reported"

DIRTY="$TMP/dirty"
run_sync "$DIRTY"
DIRTY_HEAD="$(git -C "$DIRTY" rev-parse HEAD)"
printf 'local edit\n' >> "$DIRTY/payload"
run_sync "$DIRTY"
assert_eq "$SYNC_RC" "2" "dirty checkout is blocked"
assert_contains "$SYNC_OUTPUT" "dirty checkout" "dirty reason is reported"
assert_eq "$(git -C "$DIRTY" rev-parse HEAD)" "$DIRTY_HEAD" \
  "dirty checkout head is untouched"

NESTED="$TMP/nested"
run_sync "$NESTED"
git -C "$NESTED" reset -q --hard HEAD~1
mkdir -p "$NESTED/.claude/worktrees/feature"
printf 'another checkout\n' > "$NESTED/.claude/worktrees/feature/file"
run_sync "$NESTED"
assert_eq "$SYNC_RC" "0" "a nested worktree under .claude/worktrees does not block"
assert_eq "$(git -C "$NESTED" rev-parse HEAD)" "$REMOTE_HEAD" "a checkout holding a nested worktree fast-forwards"
assert_eq "$(cat "$NESTED/.claude/worktrees/feature/file")" "another checkout" "the nested worktree is untouched"
printf 'scratch\n' > "$NESTED/scratch.txt"
git -C "$NESTED" reset -q --hard HEAD~1
run_sync "$NESTED"
assert_eq "$SYNC_RC" "2" "any other untracked file still blocks"
rm -f "$NESTED/scratch.txt"

IN_PROGRESS="$TMP/in-progress"
run_sync "$IN_PROGRESS"
IN_PROGRESS_GIT_DIR="$(git -C "$IN_PROGRESS" rev-parse --absolute-git-dir)"
printf '%s\n' "$(git -C "$IN_PROGRESS" rev-parse HEAD)" > "$IN_PROGRESS_GIT_DIR/MERGE_HEAD"
run_sync "$IN_PROGRESS"
assert_eq "$SYNC_RC" "2" "in-progress Git operation is blocked"
assert_contains "$SYNC_OUTPUT" "Git operation in progress" \
  "in-progress operation reason is reported"

WRONG_BRANCH="$TMP/wrong-branch"
run_sync "$WRONG_BRANCH"
git -C "$WRONG_BRANCH" switch -qc topic
run_sync "$WRONG_BRANCH"
assert_eq "$SYNC_RC" "2" "wrong branch is blocked"
assert_contains "$SYNC_OUTPUT" "expected branch $BRANCH, found topic" \
  "wrong branch names both refs"

LOCAL_AHEAD="$TMP/local-ahead"
run_sync "$LOCAL_AHEAD"
git -C "$LOCAL_AHEAD" config user.name "Test User"
git -C "$LOCAL_AHEAD" config user.email "test@example.com"
printf 'local\n' > "$LOCAL_AHEAD/local-only"
git -C "$LOCAL_AHEAD" add local-only
git -C "$LOCAL_AHEAD" commit -qm "local work"
LOCAL_HEAD="$(git -C "$LOCAL_AHEAD" rev-parse HEAD)"
run_sync "$LOCAL_AHEAD"
assert_eq "$SYNC_RC" "2" "locally-ahead checkout is blocked"
assert_contains "$SYNC_OUTPUT" "local commits are ahead" \
  "local-ahead reason is reported"
assert_eq "$(git -C "$LOCAL_AHEAD" rev-parse HEAD)" "$LOCAL_HEAD" \
  "local commit is preserved"

NO_UPSTREAM="$TMP/no-upstream"
run_sync "$NO_UPSTREAM"
git -C "$NO_UPSTREAM" branch --unset-upstream
run_sync "$NO_UPSTREAM"
assert_eq "$SYNC_RC" "2" "missing upstream is blocked"
assert_contains "$SYNC_OUTPUT" "no usable upstream" \
  "missing-upstream reason is reported"

OTHER_REMOTE="$TMP/other.git"
git init --bare -q "$OTHER_REMOTE"
MISMATCH="$TMP/mismatch"
run_sync "$MISMATCH"
git -C "$MISMATCH" remote set-url origin "$OTHER_REMOTE"
run_sync "$MISMATCH"
assert_eq "$SYNC_RC" "2" "unexpected upstream repository is blocked"
assert_contains "$SYNC_OUTPUT" "does not match the managed repository" \
  "repository mismatch is reported"

run_sync_with() {
  local checkout="$1"
  shift
  set +e
  SYNC_OUTPUT="$(
    env AGENT_SKILLS_SYNC_DIR="$checkout" \
      AGENT_SKILLS_SYNC_BRANCH="$BRANCH" \
      "$@" "$SYNC" --one-line 2>&1
  )"
  SYNC_RC=$?
  set -e
}

LABELED="$TMP/labeled"
run_sync_with "$LABELED" AGENT_SKILLS_SYNC_URL="$REMOTE" \
  AGENT_SKILLS_SYNC_LABEL=my-skills
run_sync_with "$LABELED" AGENT_SKILLS_SYNC_URL="$REMOTE" \
  AGENT_SKILLS_SYNC_LABEL=my-skills
assert_eq "$SYNC_RC" "0" "labeled run succeeds"
assert_contains "$SYNC_OUTPUT" "my-skills current" "label prefixes the report"
if git -C "$LABELED" rev-parse -q --verify "refs/dotsync/my-skills/$BRANCH" >/dev/null; then
  ok "label namespaces the private discovery ref"
else
  not_ok "label namespaces the private discovery ref"
fi

run_sync_with "$TMP/bad-label" AGENT_SKILLS_SYNC_URL="$REMOTE" \
  AGENT_SKILLS_SYNC_LABEL='../x'
assert_eq "$SYNC_RC" "1" "invalid label is rejected"
assert_contains "$SYNC_OUTPUT" "agent-skills error: invalid label" \
  "invalid label falls back to the default prefix"

# Private-repo mode: the managed URL ("$REMOTE/") is the same repository
# identity as the checkout's remote ("$REMOTE"), but an insteadOf rule sends
# that URL spelling to a missing path. So only a fetch through the checkout's
# own remote can succeed. (insteadOf also rewrites `git remote get-url`, which
# is why the rule keys on the trailing-slash spelling only.) Fully offline.
PRIVATE="$TMP/private"
run_sync_with "$PRIVATE" AGENT_SKILLS_SYNC_URL="$REMOTE"
git -C "$PRIVATE" config url."$TMP/unreachable.git".insteadOf "$REMOTE/"
printf 'v3\n' >> "$SEED/payload"
git -C "$SEED" add payload
git -C "$SEED" commit -qm "advance for private mode"
git -C "$SEED" -c core.hooksPath=/dev/null push -q
PRIVATE_TARGET="$(git -C "$SEED" rev-parse HEAD)"

run_sync_with "$PRIVATE" AGENT_SKILLS_SYNC_URL="$REMOTE/"
assert_eq "$SYNC_RC" "1" "URL-mode fetch cannot reach a private repo"
assert_contains "$SYNC_OUTPUT" "fetch failed" "URL-mode failure is reported"
assert_contains "$SYNC_OUTPUT" "fetch failed (" "URL-mode failure names git's reason"

run_sync_with "$PRIVATE" AGENT_SKILLS_SYNC_URL="$REMOTE/" \
  AGENT_SKILLS_SYNC_FETCH_REMOTE=1
assert_eq "$SYNC_RC" "0" "remote-mode fetch reaches the private repo"
assert_contains "$SYNC_OUTPUT" "agent-skills updated" "remote-mode fast-forward is reported"
assert_eq "$(git -C "$PRIVATE" rev-parse HEAD)" "$PRIVATE_TARGET" \
  "remote-mode fast-forward reaches the deployment head"

REWRITTEN="$TMP/rewritten"
run_sync "$REWRITTEN"
REWRITTEN_HEAD="$(git -C "$REWRITTEN" rev-parse HEAD)"
EMPTY_TREE="$(git -C "$SEED" mktree </dev/null)"
REPLACEMENT="$(
  printf 'rewritten history\n' |
    git -C "$SEED" commit-tree "$EMPTY_TREE"
)"
git -C "$SEED" -c core.hooksPath=/dev/null push -q --force origin \
  "$REPLACEMENT:refs/heads/$BRANCH"
run_sync "$REWRITTEN"
assert_eq "$SYNC_RC" "2" "rewritten deployment history is blocked"
assert_contains "$SYNC_OUTPUT" "history was rewritten" \
  "rewrite requires manual realignment"
assert_eq "$(git -C "$REWRITTEN" rev-parse HEAD)" "$REWRITTEN_HEAD" \
  "rewritten remote does not move the checkout"

DEFAULTS="$("$SYNC" --help)"
assert_contains "$DEFAULTS" "https://github.com/coletebou/agent-skills.git" \
  "--help names the default repository"
assert_contains "$DEFAULTS" "(default: ~/code/agent-skills)" "--help names the default checkout"
assert_eq "$(ls -A "$HOME")" "" "no run touched HOME: every checkout here was named"

assert_contains "$(grep -F 'scripts/agent-skills-sync' "$ROOT/install.sh")" \
  "link_bins" "installer exposes the updater"
# It runs only when someone runs it: no timer, launch agent, hook, shell file or other script does.
RUNNERS="$(cd "$ROOT" && grep -rl 'agent-skills-sync' systemd launchagents base roles identities \
  plugins zshenv zshrc aliases scripts 2>/dev/null | grep -v -e '^scripts/agent-skills-sync$' \
  -e '^scripts/tests/' || true)"
assert_eq "$RUNNERS" "" "nothing in the repo runs the updater on its own"

printf '1..%d\n' "$((PASS + FAIL))"
printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
