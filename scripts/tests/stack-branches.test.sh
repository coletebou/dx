#!/usr/bin/env bash
# stack-branches and stack-claude (plugins/worktrees/bin): a new branch from origin/HEAD with a
# profile's branches octopus-merged on top, a sequential fallback that stops at the first conflict,
# and a squashed "[REMOVE-BEFORE-MR]" commit on HEAD that unstack removes. Both refuse a dirty
# tracked file and never discard one (no lockfile exceptions). Hermetic: a scratch bare origin and
# clone, HOME and the profile dir in a temp dir, nothing touches the user's repos.
#
#   bash scripts/tests/stack-branches.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
sb="$root/plugins/worktrees/bin/stack-branches"
sc="$root/plugins/worktrees/bin/stack-claude"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 STACK_BRANCHES_CONFIG="$tmp/config"
mkdir -p "$HOME" "$STACK_BRANCHES_CONFIG/profiles.d"
unset STACK_BRANCHES_BASE STACK_BRANCHES_REMOTE STACK_BRANCHES_NO_FETCH STACK_CLAUDE_BRANCH \
  STACK_CLAUDE_REMOTE STACK_CLAUDE_NO_FETCH
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

G() { git -c init.defaultBranch=master "$@"; }
G init -q --bare "$tmp/origin.git"
G init -q "$tmp/seed"
printf 'one\n' > "$tmp/seed/f"
printf '{}\n' > "$tmp/seed/package-lock.json"
G -C "$tmp/seed" add f package-lock.json
G -C "$tmp/seed" commit -qm c1
G -C "$tmp/seed" push -q "$tmp/origin.git" master
# Four WIP branches: a and b touch separate files; c and d change the same line of f.
branch() {  # branch NAME FILE CONTENT
  G -C "$tmp/seed" switch -q -c "$1" master
  printf '%s\n' "$3" > "$tmp/seed/$2"
  G -C "$tmp/seed" add "$2"
  G -C "$tmp/seed" commit -qm "$1"
  G -C "$tmp/seed" push -q "$tmp/origin.git" "$1"
}
branch wip-a a.txt a
branch wip-b b.txt b
branch wip-c f c
branch wip-d f d
branch tooling CLAUDE.md "rules"
G clone -q "$tmp/origin.git" "$tmp/proj"
repo="$tmp/proj"
profile() {  # profile NAME BRANCH...
  local name="$1"; shift
  printf '{"name":"%s","description":"test","branches":[%s]}\n' "$name" \
    "$(printf '"%s",' "$@" | sed 's/,$//')" > "$STACK_BRANCHES_CONFIG/profiles.d/$name.json"
}
in_repo() { (cd "$repo" && "$@"); }

echo "stack-branches stacks a profile onto origin/HEAD"
profile pair origin/wip-a wip-b
out="$(in_repo "$sb" profiles list 2>&1)"
check "profiles list shows the profile and its branch count" "pair" "$out"
check "...with two branches" "2" "$(grep '^pair' <<<"$out")"
out="$(in_repo "$sb" -p pair -n new1 2>&1)"
equal "a clean octopus succeeds" 0 "$?"
check "...from origin/HEAD, logged as the branch it stands for" "base: origin/master" "$out"
equal "...onto a new branch" "new1" "$(G -C "$repo" branch --show-current)"
equal "...holding both branches' files" "a b" "$(cat "$repo/a.txt" "$repo/b.txt" | tr '\n' ' ' | sed 's/ $//')"
equal "...as one octopus commit with three parents" "3" "$(G -C "$repo" log -1 --format=%P | wc -w | tr -d ' ')"
check "...named after the profile" "stack(pair): origin/wip-a + origin/wip-b" "$(G -C "$repo" log -1 --format=%s)"
G -C "$repo" switch -q master

echo "stack-branches refuses a dirty tree and discards nothing"
printf 'local edit\n' > "$repo/package-lock.json"
out="$(in_repo "$sb" -p pair -n new2 2>&1)"
equal "a modified lockfile stops the run" 1 "$?"
check "...saying why" "commit or stash your changes" "$out"
equal "...without creating the branch" "none" "$(G -C "$repo" show-ref -q --verify refs/heads/new2 && echo made || echo none)"
equal "...and the edit is still there" "local edit" "$(cat "$repo/package-lock.json")"
G -C "$repo" restore package-lock.json
printf 'untracked\n' > "$repo/scratch.txt"
out="$(in_repo "$sb" -p pair -n new2 2>&1)"
equal "an untracked file is fine" 0 "$?"
rm -f "$repo/scratch.txt"
G -C "$repo" switch -q master

echo "stack-branches stops at the first conflict"
profile clash wip-c wip-d
out="$(in_repo "$sb" -p clash -n new3 2>&1)"
equal "a conflicting stack exits 2" 2 "$?"
check "...after falling back to sequential merges" "falling back to sequential merges" "$out"
check "...naming the branch that conflicted" "conflict on origin/wip-d" "$out"
check "...and how to abandon it" "git branch -D new3" "$out"
equal "...leaving the new branch for a manual resolve" "new3" "$(G -C "$repo" branch --show-current)"
G -C "$repo" merge --abort
G -C "$repo" switch -q master

echo "stack-branches bases and profiles"
out="$(in_repo env STACK_BRANCHES_BASE=origin/wip-a "$sb" -p pair -n new4 2>&1)"
equal "STACK_BRANCHES_BASE picks another base" 0 "$?"
check "...which the log names" "base: origin/wip-a" "$out"
G -C "$repo" switch -q master
G -C "$repo" remote set-head origin -d
out="$(in_repo "$sb" -p pair -n new5 2>&1)"
equal "without origin/HEAD the run fails" 1 "$?"
check "...saying how to set it" "git remote set-head origin --auto" "$out"
G -C "$repo" remote set-head origin master
out="$(in_repo "$sb" -p nope -n new6 2>&1)"
equal "an unknown profile fails" 1 "$?"
check "...by name" "profile not found: nope" "$out"

echo "stack-claude squashes a branch onto HEAD and unstacks it"
G -C "$repo" switch -q -c feature master
printf 'feature\n' > "$repo/feature.txt"
G -C "$repo" add feature.txt
G -C "$repo" commit -qm feature
pre="$(G -C "$repo" rev-parse HEAD)"
out="$(in_repo "$sc" -b origin/tooling 2>&1)"
equal "stacking succeeds" 0 "$?"
equal "...as one marker commit" "chore: claude tooling stack [REMOVE-BEFORE-MR]" "$(G -C "$repo" log -1 --format=%s)"
equal "...with one parent (a squash, not a merge)" "1" "$(G -C "$repo" log -1 --format=%P | wc -w | tr -d ' ')"
equal "...carrying the branch's files" "rules" "$(cat "$repo/CLAUDE.md" 2>&1)"
check "status says it is stacked" "stacked (HEAD)" "$(in_repo "$sc" status 2>&1)"
out="$(in_repo "$sc" -b origin/tooling 2>&1)"
equal "a second stack is refused" 1 "$?"
check "...pointing at unstack" "unstack first" "$out"

printf 'local edit\n' > "$repo/package-lock.json"
out="$(in_repo "$sc" unstack 2>&1)"
equal "unstack refuses a dirty lockfile (its hard reset would wipe it)" 1 "$?"
equal "...and the edit survives" "local edit" "$(cat "$repo/package-lock.json")"
G -C "$repo" restore package-lock.json
out="$(in_repo "$sc" unstack 2>&1)"
equal "a clean unstack succeeds" 0 "$?"
equal "...back to the pre-stack commit" "$pre" "$(G -C "$repo" rev-parse HEAD)"
equal "...without the stacked files" "gone" "$([[ -e "$repo/CLAUDE.md" ]] && echo present || echo gone)"
equal "...and the record is removed" "gone" "$([[ -e "$repo/.git/stack-claude-head" ]] && echo present || echo gone)"
check "status says it is not stacked" "not stacked" "$(in_repo "$sc" status 2>&1)"

echo "stack-claude refusals"
printf 'local edit\n' > "$repo/package-lock.json"
out="$(in_repo "$sc" -b origin/tooling 2>&1)"
equal "stack refuses a dirty lockfile" 1 "$?"
equal "...and the edit survives" "local edit" "$(cat "$repo/package-lock.json")"
G -C "$repo" restore package-lock.json
out="$(in_repo "$sc" 2>&1)"
equal "no branch is a refusal" 1 "$?"
check "...saying how to name one" "pass -b <branch> or set STACK_CLAUDE_BRANCH" "$out"
out="$(in_repo "$sc" -b origin/master 2>&1)"
equal "a branch already in HEAD is a no-op" 0 "$?"
check "...that says so" "nothing to stack" "$out"
equal "...and records nothing" "gone" "$([[ -e "$repo/.git/stack-claude-head" ]] && echo present || echo gone)"
G -C "$repo" switch -q --detach HEAD
out="$(in_repo "$sc" -b origin/tooling 2>&1)"
equal "a detached HEAD is refused" 1 "$?"
check "...saying why" "detached HEAD" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
