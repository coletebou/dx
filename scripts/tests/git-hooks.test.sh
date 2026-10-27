#!/usr/bin/env bash
# git-hooks.test.sh: with core.hooksPath on base/git/hooks, git never looks in .git/hooks, so the
# shared hooks must run what it would have: the repository's own hook of the same name (commit-msg,
# pre-commit without a .pre-commit-config.yaml, pre-push with the same arguments and ref lines,
# from a linked worktree too), and Git LFS's hooks in a repository whose .gitattributes uses the
# lfs filter, blocking the push the way Git LFS does when git-lfs is missing. Hermetic: temp
# repos and a local bare remote; gitleaks and git-lfs are fakes that only log.
#
#   bash scripts/tests/git-hooks.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
hooks="$root/base/git/hooks"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$HOME" "$tmp/bin" "$tmp/lfsbin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/gitleaks"
# The fake git-lfs logs its arguments and the stdin it got.
printf '#!/bin/sh\n{ echo "git-lfs $*"; cat; } >> "%s"\n' "$tmp/lfs.log" > "$tmp/lfsbin/git-lfs"
chmod +x "$tmp/bin/gitleaks" "$tmp/lfsbin/git-lfs"
export GITLEAKS_BIN="$tmp/bin/gitleaks"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# newrepo NAME: a repo using the shared hooks, with one commit and a bare remote "origin".
newrepo() {
  local r="$tmp/$1"
  git init -q -b master "$r"
  git -C "$r" config core.hooksPath "$hooks"
  git init -q --bare "$tmp/$1.git"
  git -C "$r" remote add origin "$tmp/$1.git"
  git -C "$r" commit -q --allow-empty -m init
  printf '%s\n' "$r"
}
# own REPO NAME BODY: the repo's own hook.
own() { printf '#!/bin/sh\n%s\n' "$3" > "$1/.git/hooks/$2"; chmod +x "$1/.git/hooks/$2"; }

echo "the repo's own hooks still run"
r="$(newrepo own)"
own "$r" commit-msg "echo commit-msg > '$tmp/own.log'"
git -C "$r" commit -q --allow-empty -m second 2>/dev/null
check "commit-msg" "commit-msg" "$(cat "$tmp/own.log" 2>&1)"
own "$r" pre-commit 'echo "own pre-commit says no" >&2; exit 1'
git -C "$r" commit -q --allow-empty -m third 2>/dev/null; rc=$?
equal "pre-commit (no .pre-commit-config.yaml), and it can block" 1 "$rc"
rm "$r/.git/hooks/pre-commit"
own "$r" pre-push "{ echo \"args \$*\"; cat; } > '$tmp/push.log'; exit 1"
git -C "$r" push -q origin master 2>/dev/null; rc=$?
equal "pre-push, and it can block" 1 "$rc"
check "...with git's arguments" "args origin $tmp/own.git" "$(cat "$tmp/push.log" 2>&1)"
check "...and the ref lines the scan read" "refs/heads/master $(git -C "$r" rev-parse HEAD) refs/heads/master" \
  "$(cat "$tmp/push.log" 2>&1)"
rm "$r/.git/hooks/pre-push"
git -C "$r" push -q origin master 2>/dev/null; rc=$?
equal "with no hook of its own the push goes through" 0 "$rc"

echo "a linked worktree"
git -C "$r" worktree add -q "$tmp/own-wt" -b wt
rm -f "$tmp/own.log"
git -C "$tmp/own-wt" commit -q --allow-empty -m from-worktree 2>/dev/null
check "runs the main checkout's own hooks" "commit-msg" "$(cat "$tmp/own.log" 2>&1)"

echo "a Git LFS repo"
r="$(newrepo lfs)"
printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' > "$r/.gitattributes"
git -C "$r" add .gitattributes && git -C "$r" commit -q -m attrs 2>/dev/null
PATH="$tmp/lfsbin:$PATH" git -C "$r" push -q origin master 2>/dev/null; rc=$?
equal "the push succeeds" 0 "$rc"
check "...after git lfs pre-push uploaded the objects" "git-lfs pre-push origin $tmp/lfs.git" "$(cat "$tmp/lfs.log" 2>&1)"
check "...given the ref lines" "refs/heads/master $(git -C "$r" rev-parse HEAD)" "$(cat "$tmp/lfs.log" 2>&1)"
PATH="$tmp/lfsbin:$PATH" git -C "$r" switch -q -c other 2>/dev/null
check "post-checkout reaches git lfs too" "git-lfs post-checkout" "$(cat "$tmp/lfs.log" 2>&1)"
git -C "$r" commit -q --allow-empty -m more 2>/dev/null
# This PATH minus git-lfs, which CI images ship: links to every other command on it.
mkdir -p "$tmp/nolfs"
IFS=: read -ra path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  for f in "$d"/*; do
    n="${f##*/}"
    [[ "$n" == git-lfs || -e "$tmp/nolfs/$n" || ! -x "$f" || -d "$f" ]] && continue
    ln -s "$f" "$tmp/nolfs/$n"
  done
done
out="$(PATH="$tmp/nolfs" git -C "$r" push origin other 2>&1)"; rc=$?
equal "without git-lfs the push is blocked, as Git LFS's own hook does" 2 "$([[ $rc -ne 0 ]] && echo 2 || echo "$rc")"
check "...saying why" "configured for Git LFS but 'git-lfs' was not found" "$out"

echo "a repo without LFS"
r="$(newrepo plain)"
rm -f "$tmp/lfs.log"
PATH="$tmp/lfsbin:$PATH" git -C "$r" push -q origin master 2>/dev/null
equal "never calls git lfs" "" "$(cat "$tmp/lfs.log" 2>/dev/null)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
