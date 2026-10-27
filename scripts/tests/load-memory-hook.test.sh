#!/usr/bin/env bash
# load-memory-hook.test.sh: base/claude/load-memory-hook.sh finds the auto-memory dir Claude Code
# uses for the cwd, encoded the way Claude Code encodes it (every non-alphanumeric to "-", so a
# dotted or underscored repo path works), maps a linked worktree to its main repo's dir, honors an
# autoMemoryDirectory setting, and stays silent where there is no memory. Hermetic: HOME and the
# repos in a temp dir, and DOTFILES_DIR points where no reflections CLI exists.
#
#   bash scripts/tests/load-memory-hook.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$root/base/claude/load-memory-hook.sh"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" DOTFILES_DIR="$tmp/no-dotfiles" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
mkdir -p "$HOME"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
run_in() { (cd "$1" && bash "$hook" < /dev/null 2>&1); }

repo="$tmp/work/my.repo_x"
mkdir -p "$repo"
git -C "$repo" init -q -b master
git -C "$repo" commit -q --allow-empty -m init
mem="$HOME/.claude/projects/$(enc "$repo")/memory"
mkdir -p "$mem"
printf 'resume from step 3\n' > "$mem/session-handoff.md"
printf 'topic\n' > "$mem/topic.md"
printf 'index\n' > "$mem/MEMORY.md"

echo "a repo whose path has a dot and an underscore"
out="$(run_in "$repo")"
check "the handoff is shown" "## Session Handoff" "$out"
check "...with its text" "resume from step 3" "$out"
check "other topic files are listed" "  - topic.md" "$out"
case "$out" in *"- MEMORY.md"*) bad "MEMORY.md is not listed (Claude Code loads it)" "no MEMORY.md" "$out" ;; *) ok "MEMORY.md is not listed (Claude Code loads it)" ;; esac

echo "a linked worktree uses its main repo's memory"
git -C "$repo" worktree add -q "$tmp/work/wt.one" -b wt
check "the worktree sees the main repo's handoff" "resume from step 3" "$(run_in "$tmp/work/wt.one")"

echo "autoMemoryDirectory wins"
mkdir -p "$repo/.claude" "$HOME/mem"
printf '{"autoMemoryDirectory": "~/mem"}\n' > "$repo/.claude/settings.local.json"
printf 'override handoff\n' > "$HOME/mem/session-handoff.md"
out="$(run_in "$repo")"
check "the override dir's handoff is shown" "override handoff" "$out"
case "$out" in *"resume from step 3"*) bad "...instead of the default dir's" "only the override" "$out" ;; *) ok "...instead of the default dir's" ;; esac

echo "nothing to show"
mkdir -p "$tmp/plain"
out="$(cd "$tmp/plain" && bash "$hook" < /dev/null 2>&1)"
equal "a non-git dir without memory exits 0" 0 "$?"
equal "...and prints nothing" "" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
