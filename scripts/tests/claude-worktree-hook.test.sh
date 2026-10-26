#!/usr/bin/env bash
# claude-worktree-hook is Claude Code's WorktreeCreate / WorktreeRemove hook. It puts Claude
# Code's worktrees where the repo's worktree.baseDirectory says (read through wt-helper), and
# otherwise makes them exactly as Claude Code would: <main>/.claude/worktrees/<name>, branch
# worktree-<name>, the same base commit, CLAUDE_BASE marker and post-checkout steps.
#
# Each case feeds the hook the JSON Claude Code sends on stdin, in scratch repos under a temp
# dir that HOME points into as well, and checks the printed path, the worktree git made, its
# branch and base, and what remove leaves behind. Covered: no setting; absolute, relative,
# ~ and shared settings; a volume that is not mounted, for create and for remove of a worktree
# that is gone; relative worktree links; runs from inside a linked worktree, a submodule and a
# non-git directory; baseRef head, no origin, the day-old fetch, origin/HEAD, pull request
# names and ones that cannot be fetched; .worktreeinclude, symlinkDirectories, sparsePaths,
# filter drivers (on create and reopen, an includeIf that could hide one, and keys naming a
# program git-lfs runs), hooksPath;
# reuse of a name; branches that hold unpushed work, a base nothing else has any more or an
# unrelated history; enable/disable and the command enable registers; stdout hygiene; prune and
# each thing that keeps a worktree from it (changes, commits of its own, a process or a live
# Claude Code lock in it, a recent change, no CLAUDE_BASE, a volume that is not mounted), and
# create's once-a-day background prune.
# HOOK_BASH picks the shell the hook runs under (the suite passes under bash 5 and /bin/bash
# 3.2); CLAUDE_WORKTREE_HOOK runs another copy of the hook.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${CLAUDE_WORKTREE_HOOK:-$ROOT/scripts/claude-worktree-hook}"
HOOK_BASH="${HOOK_BASH:-bash}"
TMP="$(cd -P "$(mktemp -d)" && pwd -P)"
UNMOUNTED=""
for c in /Volumes /mnt /media /run/media; do
  [[ -d "$c" && ! -L "$c" ]] || continue
  [[ "$(df -P "$c" 2>/dev/null | awk 'NR == 2 { print $NF }')" == "$c" ]] && continue
  UNMOUNTED="$c/claude-worktree-hook-test-$$-$RANDOM"
  break
done
BG_PIDS=""
cleanup() {
  local p
  for p in $BG_PIDS; do kill "$p" 2>/dev/null; done
  chmod -R u+rwx "$TMP" 2>/dev/null
  find "$TMP" -depth -delete 2>/dev/null || true
  [[ -n "$UNMOUNTED" && -d "$UNMOUNTED" ]] && rm -rf "$UNMOUNTED"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
skip() { printf 'ok %d - # SKIP %s\n' "$((PASS + FAIL + 1))" "$1"; PASS=$((PASS + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else not_ok "$3 (got [$1], expected [$2])"; fi; }
assert_has() { if [[ "$1" == *"$2"* ]]; then ok "$3"; else not_ok "$3 ([$1] lacks [$2])"; fi; }
assert_lacks() { if [[ "$1" != *"$2"* ]]; then ok "$3"; else not_ok "$3 ([$1] has [$2])"; fi; }

export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
# create's background prune stays off except where the prune cases turn it on.
export CLAUDE_WORKTREE_AUTO_PRUNE=0
unset XDG_CONFIG_HOME WT_BASE_DIR WT_LAYOUT WT_NESTED_SUBDIR CLAUDE_WORKTREE_PRUNE_DAYS
mkdir -p "$HOME"
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=master "$@"; }
command -v jq >/dev/null 2>&1 || {
  echo "Bail out! jq is required"
  exit 1
}

# create DIR NAME: the hook as Claude Code runs it for a session whose cwd is DIR.
create() {
  local json
  json="$(jq -cn --arg cwd "$1" --arg name "$2" \
    '{session_id: "test", transcript_path: "/dev/null", cwd: $cwd, hook_event_name: "WorktreeCreate", name: $name}')"
  OUT="$(printf '%s' "$json" | (cd "$TMP" && "$HOOK_BASH" "$HOOK" create) 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}
# remove DIR PATH
remove() {
  local json
  json="$(jq -cn --arg cwd "$1" --arg p "$2" \
    '{session_id: "test", transcript_path: "/dev/null", cwd: $cwd, hook_event_name: "WorktreeRemove", worktree_path: $p}')"
  OUT="$(printf '%s' "$json" | (cd "$TMP" && "$HOOK_BASH" "$HOOK" remove) 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}
setting() { # repo file json
  mkdir -p "$1/.claude"
  printf '%s\n' "$3" >"$1/.claude/$2"
}
clear_settings() { rm -f "$1/.claude/settings.local.json" "$1/.claude/settings.json"; }
base_json() { jq -cn --arg d "$1" '{worktree: {baseDirectory: $d}}'; }
marker() { cat "$(git -C "$1" rev-parse --absolute-git-dir)/CLAUDE_BASE" 2>/dev/null; }
registered() { git -C "$1" worktree list --porcelain | grep -qxF "worktree $2" && echo yes || echo no; }
branch_at() { git -C "$1" rev-parse -q --verify "refs/heads/$2" 2>/dev/null || echo none; }
exists() { [[ -e "$1" || -L "$1" ]] && echo present || echo absent; }
lines() { if [[ -z "$1" ]]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

# origin: master at c1 (HEAD), dev at c2. clone: origin/HEAD -> origin/master.
G init -q --bare "$TMP/origin.git"
G init -q "$TMP/seed"
printf '1\n' >"$TMP/seed/f"
printf '.env\nnode_modules/\nsecret.txt\nconfig/*.local\n' >"$TMP/seed/.gitignore"
mkdir -p "$TMP/seed/a" "$TMP/seed/b" "$TMP/seed/config"
printf 'a\n' >"$TMP/seed/a/x"
printf 'b\n' >"$TMP/seed/b/y"
printf 'c\n' >"$TMP/seed/config/base.json"
G -C "$TMP/seed" add -A
G -C "$TMP/seed" commit -qm c1
G -C "$TMP/seed" push -q "$TMP/origin.git" master
printf '2\n' >"$TMP/seed/f"
G -C "$TMP/seed" commit -qam c2
G -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:dev
G clone -q "$TMP/origin.git" "$TMP/clone"
C="$TMP/clone"
c1="$(git -C "$C" rev-parse origin/master)"
c2="$(git -C "$C" rev-parse origin/dev)"
touch "$(git -C "$C" rev-parse --absolute-git-dir)/FETCH_HEAD"
DEFAULT="$C/.claude/worktrees"

# ── no setting: Claude Code's own layout ──────────────────────────────
create "$C" feat/x
assert_eq "$RC:$OUT" "0:$DEFAULT/feat+x" "no setting: the worktree goes in <repo>/.claude/worktrees, / spelled +"
assert_eq "$(lines "$OUT")" "1" "...and stdout is that one line"
assert_eq "$(registered "$C" "$DEFAULT/feat+x")" "yes" "...as a registered git worktree"
assert_eq "$(git -C "$DEFAULT/feat+x" symbolic-ref --short HEAD)" "worktree-feat+x" "...on branch worktree-<name>"
assert_eq "$(git -C "$DEFAULT/feat+x" rev-parse HEAD)" "$c1" "...at origin/master (the target of origin/HEAD)"
assert_eq "$(marker "$DEFAULT/feat+x")" "$c1" "...with CLAUDE_BASE holding the base commit"
assert_eq "$(git -C "$DEFAULT/feat+x" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1 && echo tracking || echo none)" "none" "...and no upstream (--no-track)"
assert_has "$ERR" "created $DEFAULT/feat+x on worktree-feat+x from origin/master" "...saying so on stderr"

create "$C" agent-a0123456789abcdef
assert_eq "$RC:$OUT" "0:$DEFAULT/agent-a0123456789abcdef" "an Agent-isolation name works the same way"

create "$C" feat/x
assert_eq "$RC:$OUT" "0:$DEFAULT/feat+x" "the same name again reopens the existing worktree"
assert_eq "$(git -C "$C" worktree list --porcelain | grep -c '^worktree ')" "3" "...without making another"

# A clean, commit-less reopened worktree moves up to the current base, as Claude Code does.
G -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:master
G -C "$C" fetch -q origin
create "$C" feat/x
assert_eq "$(git -C "$DEFAULT/feat+x" rev-parse HEAD):$(marker "$DEFAULT/feat+x")" "$c2:$c2" "a reopened clean worktree moves to the new origin/master"
printf 'mine\n' >"$DEFAULT/agent-a0123456789abcdef/own"
G -C "$DEFAULT/agent-a0123456789abcdef" add own
G -C "$DEFAULT/agent-a0123456789abcdef" commit -qm own
own="$(git -C "$DEFAULT/agent-a0123456789abcdef" rev-parse HEAD)"
create "$C" agent-a0123456789abcdef
assert_eq "$(git -C "$DEFAULT/agent-a0123456789abcdef" rev-parse HEAD)" "$own" "...but one with a commit of its own stays where it is"

# ── remove ────────────────────────────────────────────────────────────
remove "$C" "$DEFAULT/feat+x"
assert_eq "$RC" "0" "remove: a clean worktree is removed"
assert_eq "$(exists "$DEFAULT/feat+x"):$(registered "$C" "$DEFAULT/feat+x"):$(branch_at "$C" worktree-feat+x)" "absent:no:none" "...directory, registration and worktree-<name> branch all gone"

remove "$C" "$DEFAULT/agent-a0123456789abcdef"
assert_eq "$RC:$(exists "$DEFAULT/agent-a0123456789abcdef")" "0:absent" "a worktree with an unpushed commit is removed"
assert_eq "$(branch_at "$C" worktree-agent-a0123456789abcdef)" "$own" "...but its branch is kept, with the commit"
assert_has "$ERR" "kept branch worktree-agent-a0123456789abcdef" "...and the hook says why"
G -C "$C" branch -q -D worktree-agent-a0123456789abcdef

create "$C" dirty
printf 'x\n' >>"$DEFAULT/dirty/f"
printf 'new\n' >"$DEFAULT/dirty/untracked"
remove "$C" "$DEFAULT/dirty"
assert_eq "$RC:$(exists "$DEFAULT/dirty"):$(branch_at "$C" worktree-dirty)" "0:absent:none" "uncommitted changes do not stop remove (Claude Code confirmed the discard)"

mkdir -p "$TMP/stray"
remove "$C" "$TMP/stray"
assert_eq "$RC:$(exists "$TMP/stray")" "1:present" "remove refuses a directory that is not a git worktree"
remove "$C" "$C"
assert_eq "$RC:$(exists "$C/f")" "1:present" "remove refuses the main checkout"
G -C "$C" worktree add -q -b plain "$TMP/plain-wt" >/dev/null 2>&1
plain="$(git -C "$C" rev-parse plain)"
remove "$C" "$TMP/plain-wt"
assert_eq "$RC:$(exists "$TMP/plain-wt"):$(branch_at "$C" plain)" "1:present:$plain" "remove refuses a worktree no Claude Code made (no CLAUDE_BASE)"
assert_has "$ERR" "no CLAUDE_BASE" "...and says why"
G -C "$C" worktree remove --force "$TMP/plain-wt"
G -C "$C" branch -q -D plain

create "$C" locked-own
G -C "$C" worktree lock --reason "claude agent locked-own (pid 999999 start Mon Jan  1 00:00:00 2024)" "$DEFAULT/locked-own"
remove "$C" "$DEFAULT/locked-own"
assert_eq "$RC:$(exists "$DEFAULT/locked-own")" "0:absent" "remove unlocks a lock Claude Code wrote"
create "$C" locked-user
G -C "$C" worktree lock --reason "keep me" "$DEFAULT/locked-user"
remove "$C" "$DEFAULT/locked-user"
assert_eq "$RC:$(exists "$DEFAULT/locked-user")" "1:present" "remove leaves a worktree someone else locked"
assert_has "$ERR" "keep me" "...naming the lock reason"
G -C "$C" worktree unlock "$DEFAULT/locked-user"
remove "$C" "$DEFAULT/locked-user"

create "$C" gone
rm -rf "$DEFAULT/gone"
remove "$C" "$DEFAULT/gone"
assert_eq "$RC" "0" "remove of a directory already deleted succeeds"
assert_eq "$(registered "$C" "$DEFAULT/gone"):$(branch_at "$C" worktree-gone)" "no:none" "...and drops that registration and branch"
create "$C" parent-gone
mv "$DEFAULT" "$TMP/moved-away"
remove "$C" "$DEFAULT/parent-gone"
assert_eq "$RC:$(registered "$C" "$DEFAULT/parent-gone")" "0:yes" "a worktree whose parent is missing (unmounted volume) keeps its registration"
mv "$TMP/moved-away" "$DEFAULT"
remove "$C" "$DEFAULT/parent-gone"
assert_eq "$RC:$(exists "$DEFAULT/parent-gone")" "0:absent" "...and is removed normally once it is back"

# worktree.useRelativePaths (git 2.48+): git links the worktree and its git dir with relative
# paths, the git dir's gitdir file relative to that git dir. A clone of its own, since the
# setting also turns on a repository extension.
R="$TMP/relclone"
G clone -q "$TMP/origin.git" "$R"
touch "$(git -C "$R" rev-parse --absolute-git-dir)/FETCH_HEAD"
G -C "$R" config worktree.useRelativePaths true
create "$R" rel-links
rel="$OUT"
assert_eq "$RC:$rel" "0:$R/.claude/worktrees/rel-links" "worktree.useRelativePaths: the worktree is made"
if [[ "$(cat "$(git -C "$rel" rev-parse --absolute-git-dir)/gitdir" 2>/dev/null)" == /* ]]; then
  skip "git $(git --version | awk '{ print $3 }') writes absolute worktree links"
else
  create "$R" rel-links
  assert_eq "$RC:$OUT" "0:$rel" "...a worktree linked with relative paths is reopened"
  remove "$R" "$rel"
  assert_eq "$RC:$(exists "$rel"):$(registered "$R" "$rel"):$(branch_at "$R" worktree-rel-links)" "0:absent:no:none" "...and removed"
  create "$R" rel-gone
  rel="$OUT"
  rm -rf "$rel"
  remove "$R" "$rel"
  assert_eq "$RC:$(registered "$R" "$rel"):$(branch_at "$R" worktree-rel-gone)" "0:no:none" "...and one already deleted has its record and branch dropped"
fi

# ── worktree.baseDirectory ────────────────────────────────────────────
setting "$C" settings.local.json "$(base_json "$TMP/wt-abs")"
create "$C" feat/abs
assert_eq "$RC:$OUT" "0:$TMP/wt-abs/feat+abs" "absolute setting: the worktree goes in <dir>/<name>"
assert_eq "$(registered "$C" "$TMP/wt-abs/feat+abs"):$(git -C "$OUT" symbolic-ref --short HEAD):$(marker "$OUT")" "yes:worktree-feat+abs:$c2" "...registered, on worktree-<name>, from origin/master"
assert_eq "$(exists "$DEFAULT/feat+abs")" "absent" "...and nothing in the default place"
remove "$C" "$TMP/wt-abs/feat+abs"
assert_eq "$RC:$(exists "$TMP/wt-abs/feat+abs"):$(branch_at "$C" worktree-feat+abs)" "0:absent:none" "remove cleans up a relocated worktree"

setting "$C" settings.local.json '{"worktree":{"baseDirectory":"../wt-rel"}}'
create "$C" rel
assert_eq "$RC:$OUT" "0:$TMP/wt-rel/rel" "relative setting: resolved from the repo root, printed without .."
remove "$C" "$OUT"
# shellcheck disable=SC2088  # the setting holds a literal ~ for wt-helper to expand
setting "$C" settings.local.json "$(base_json "~/wt-home")"
create "$C" home
assert_eq "$RC:$OUT" "0:$HOME/wt-home/home" "~ setting: under HOME"
remove "$C" "$OUT"
rm -f "$C/.claude/settings.local.json"
setting "$C" settings.json "$(base_json "$TMP/wt-shared")"
create "$C" shared
assert_eq "$RC:$OUT" "0:$TMP/wt-shared/shared" "the shared .claude/settings.json setting is used too"
remove "$C" "$OUT"
setting "$C" settings.local.json "$(base_json "$TMP/wt-local")"
create "$C" both
assert_eq "$RC:$OUT" "0:$TMP/wt-local/both" "...and settings.local.json wins over it"
remove "$C" "$OUT"
clear_settings "$C"
OUT="$(WT_BASE_DIR="$TMP/wt-env" WT_LAYOUT=sibling bash -c 'printf "%s" "$1" | "$2" "$3" create 2>/dev/null' _ \
  "$(jq -cn --arg cwd "$C" '{cwd: $cwd, name: "envlever", hook_event_name: "WorktreeCreate"}')" "$HOOK_BASH" "$HOOK")"
assert_eq "$OUT" "$DEFAULT/envlever" "wt's WT_BASE_DIR and WT_LAYOUT levers do not move Claude Code's worktrees"
remove "$C" "$OUT"

if [[ -n "$UNMOUNTED" ]]; then
  setting "$C" settings.local.json "$(base_json "$UNMOUNTED/wt")"
  create "$C" offline
  assert_eq "$RC:$OUT" "0:$DEFAULT/offline" "a setting on a volume that is not mounted falls back to the default place"
  assert_has "$ERR" "not mounted" "...with a warning on stderr"
  assert_has "$ERR" "goes in the default $DEFAULT" "...naming where it went"
  assert_eq "$(exists "$UNMOUNTED")" "absent" "...and nothing is created on the root disk"
  remove "$C" "$OUT"
  # The worktrees on such a volume only look deleted, and the directory it mounts on (a Linux
  # /mnt/<disk>) stays when it is not mounted, so remove keeps their records and branches
  # while it is not. A test cannot unmount a volume: the worktree's directory goes away with
  # its parent left, and the setting moves to the volume that is not mounted.
  setting "$C" settings.local.json "$(base_json "$TMP/vol")"
  create "$C" offvol
  vol_wt="$OUT"
  vol_head="$(git -C "$vol_wt" rev-parse HEAD)"
  mv "$vol_wt" "$TMP/offvol-aside"
  setting "$C" settings.local.json "$(base_json "$UNMOUNTED/wt")"
  remove "$C" "$vol_wt"
  assert_eq "$RC:$(registered "$C" "$vol_wt"):$(branch_at "$C" worktree-offvol)" "0:yes:$vol_head" "a worktree that is gone while the setting's volume is not mounted keeps its record and branch"
  assert_has "$ERR" "not mounted" "...saying why"
  setting "$C" settings.local.json "$(base_json "$TMP/vol")"
  mv "$TMP/offvol-aside" "$vol_wt"
  remove "$C" "$vol_wt"
  assert_eq "$RC:$(exists "$vol_wt"):$(branch_at "$C" worktree-offvol)" "0:absent:none" "...and is removed once the volume is back"
  clear_settings "$C"
else
  skip "no unmounted volume container on this host"
fi

mkdir -p "$TMP/readonly"
chmod 555 "$TMP/readonly"
setting "$C" settings.local.json "$(base_json "$TMP/readonly/wt")"
create "$C" ro
if [[ -w "$TMP/readonly" ]]; then
  skip "running as a user who can write a read-only directory"
  remove "$C" "$OUT"
else
  assert_eq "$RC:$OUT" "0:$DEFAULT/ro" "a setting that cannot be created falls back to the default place"
  assert_has "$ERR" "could not be used" "...with a warning"
  remove "$C" "$OUT"
fi
chmod 755 "$TMP/readonly"
clear_settings "$C"

# ── from inside a linked worktree ─────────────────────────────────────
G -C "$C" worktree add -q -b side "$TMP/side" >/dev/null 2>&1
printf 'side\n' >"$TMP/side/side"
G -C "$TMP/side" add side
G -C "$TMP/side" commit -qm side
side_head="$(git -C "$TMP/side" rev-parse HEAD)"
create "$TMP/side" from-side
assert_eq "$RC:$OUT" "0:$DEFAULT/from-side" "from a linked worktree: the main checkout's .claude/worktrees, not the linked one's"
assert_eq "$(marker "$OUT")" "$c2" "...based on origin/master"
remove "$TMP/side" "$OUT"
setting "$C" settings.local.json "$(base_json "$TMP/wt-abs")"
create "$TMP/side" side-rel
assert_eq "$RC:$OUT" "0:$TMP/wt-abs/side-rel" "...and the main checkout's setting applies there"
remove "$TMP/side" "$OUT"
setting "$C" settings.local.json '{"worktree":{"baseDirectory":"'"$TMP"'/wt-abs","baseRef":"head"}}'
create "$TMP/side" side-head
assert_eq "$RC:$(marker "$OUT"):$(git -C "$OUT" rev-parse HEAD)" "0:$side_head:$side_head" "baseRef head: the linked worktree's own HEAD"
remove "$TMP/side" "$OUT"
assert_eq "$RC:$(branch_at "$C" worktree-side-head)" "0:none" "...and its branch goes with it (the base already has the commit)"
clear_settings "$C"

# ── in a submodule ────────────────────────────────────────────────────
# Its git dir is the superproject's .git/modules/<name>, and `git worktree list` names that
# as the main worktree; the main checkout, its settings and .claude/worktrees are the
# submodule's own directory.
G init -q "$TMP/super"
: >"$TMP/super/s"
G -C "$TMP/super" add s
G -C "$TMP/super" commit -qm s
G -c protocol.file.allow=always -C "$TMP/super" submodule add -q "$TMP/origin.git" sub >/dev/null 2>&1
S="$TMP/super/sub"
touch "$(git -C "$S" rev-parse --absolute-git-dir)/FETCH_HEAD"
create "$S" in-sub
assert_eq "$RC:$OUT" "0:$S/.claude/worktrees/in-sub" "in a submodule: the worktree goes in the submodule's .claude/worktrees"
assert_eq "$(registered "$S" "$OUT"):$(exists "$TMP/super/.claude/worktrees")" "yes:absent" "...as one of its worktrees, with nothing in the superproject's"
remove "$S" "$OUT"
assert_eq "$RC:$(exists "$S/.claude/worktrees/in-sub")" "0:absent" "...and remove takes it away"
setting "$S" settings.local.json "$(base_json "$TMP/wt-sub")"
create "$S" sub-set
assert_eq "$RC:$OUT" "0:$TMP/wt-sub/sub-set" "...and the submodule's own worktree.baseDirectory applies"
remove "$S" "$OUT"
clear_settings "$S"

# ── not a repository, bad input ───────────────────────────────────────
mkdir -p "$TMP/notgit"
create "$TMP/notgit" x
assert_eq "$RC:$OUT" "1:" "a non-git directory fails, printing no path"
assert_has "$ERR" "is not in a git repository" "...with Claude Code's message"
create "$C" "../escape"
assert_eq "$RC:$OUT" "1:" "a name with .. is refused"
create "$C" "a//b"
assert_eq "$RC" "1" "a name with an empty segment is refused"
OUT="$(printf 'not json' | "$HOOK_BASH" "$HOOK" create 2>/dev/null)"
RC=$?
assert_eq "$RC:$OUT" "1:" "input that is not JSON fails"
OUT="$(jq -cn '{name: "no-cwd", hook_event_name: "WorktreeCreate"}' | (cd "$C" && "$HOOK_BASH" "$HOOK" create 2>/dev/null))"
RC=$?
assert_eq "$RC:$OUT" "0:$DEFAULT/no-cwd" "input without cwd: the directory the hook runs in"
remove "$C" "$OUT"
G init -q --bare "$TMP/bare.git"
create "$TMP/bare.git" x
assert_eq "$RC:$OUT" "1:" "a bare repository fails, as Claude Code refuses it"
G -C "$C" branch -q worktree-busy
G -C "$C" worktree add -q "$TMP/busy" worktree-busy >/dev/null 2>&1
create "$C" busy
assert_eq "$RC:$OUT" "1:" "a worktree-<name> branch checked out elsewhere fails"
assert_has "$ERR" "already checked out elsewhere" "...saying so"
G -C "$C" worktree remove "$TMP/busy"
G -C "$C" branch -q -D worktree-busy
mkdir -p "$TMP/elsewhere"
mv "$C/.claude" "$TMP/claude-dir-aside" 2>/dev/null
ln -s "$TMP/elsewhere" "$C/.claude"
create "$C" via-link
assert_eq "$RC:$OUT:$(ls -A "$TMP/elsewhere")" "1::" "a symlinked .claude is refused, as Claude Code refuses it, and nothing is written through it"
rm -f "$C/.claude"
[[ -d "$TMP/claude-dir-aside" ]] && mv "$TMP/claude-dir-aside" "$C/.claude"

# ── base commit ───────────────────────────────────────────────────────
printf 'local\n' >"$C/localfile"
G -C "$C" add localfile
G -C "$C" commit -qm local
local_head="$(git -C "$C" rev-parse HEAD)"
setting "$C" settings.local.json '{"worktree":{"baseRef":"head"}}'
create "$C" head-base
assert_eq "$RC:$(marker "$OUT")" "0:$local_head" "baseRef head: local HEAD, with its unpushed commit"
remove "$C" "$OUT"
assert_eq "$(branch_at "$C" worktree-head-base)" "none" "...its branch goes on remove (master has the commit)"
clear_settings "$C"

# A day-old FETCH_HEAD makes create fetch origin first; a fresh one does not.
G -C "$TMP/seed" commit -q --allow-empty -m c3
G -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:master
c3="$(git -C "$TMP/seed" rev-parse HEAD)"
touch "$(git -C "$C" rev-parse --absolute-git-dir)/FETCH_HEAD"
create "$C" fresh-fetch-head
assert_eq "$(marker "$OUT")" "$c2" "a FETCH_HEAD from today: no fetch, the local origin/master"
remove "$C" "$OUT"
touch -t 202001010000 "$(git -C "$C" rev-parse --absolute-git-dir)/FETCH_HEAD"
create "$C" stale-fetch-head
assert_eq "$(marker "$OUT")" "$c3" "a FETCH_HEAD over a day old: origin is fetched first"
remove "$C" "$OUT"

G -C "$C" remote set-head origin dev >/dev/null
create "$C" on-dev
assert_eq "$(marker "$OUT")" "$c2" "the default branch is the target of origin/HEAD"
remove "$C" "$OUT"
G -C "$C" remote set-head origin master >/dev/null

G init -q "$TMP/lonely"
printf 'l\n' >"$TMP/lonely/l"
G -C "$TMP/lonely" add l
G -C "$TMP/lonely" commit -qm l
create "$TMP/lonely" solo
assert_eq "$RC:$OUT" "0:$TMP/lonely/.claude/worktrees/solo" "no origin: still made"
assert_eq "$(marker "$OUT")" "$(git -C "$TMP/lonely" rev-parse HEAD)" "...from local HEAD"
assert_has "$ERR" "basing the worktree on local HEAD" "...after saying the fetch failed"
remove "$TMP/lonely" "$OUT"

pr7="$(G -C "$TMP/seed" commit-tree -p "$c1" -m pr7 "$(git -C "$TMP/seed" rev-parse "$c1^{tree}")")"
G -C "$TMP/seed" push -q "$TMP/origin.git" "$pr7:refs/pull/7/head"
create "$C" pr-7
assert_eq "$RC:$OUT:$(marker "$OUT")" "0:$DEFAULT/pr-7:$pr7" "pr-<N> (from --worktree \"#N\"): the pull request's head"
assert_eq "$(git -C "$OUT" symbolic-ref --short HEAD)" "worktree-pr-7" "...on branch worktree-pr-<N>"
remove "$C" "$OUT"
assert_eq "$RC:$(branch_at "$C" worktree-pr-7)" "0:none" "...and remove deletes that branch (origin keeps the pull request's commits)"
# remove leaves a pull request's base out of the branch's own commits, so a worktree-pr-<N>
# branch attached with a history unrelated to the request must not have its own tip as base.
prorphan="$(G -C "$C" commit-tree -m pr-orphan "$(git -C "$C" rev-parse "$c1^{tree}")")"
G -C "$C" branch -q worktree-pr-7 "$prorphan"
create "$C" pr-7
assert_eq "$RC:$(git -C "$OUT" rev-parse HEAD):$(marker "$OUT")" "0:$prorphan:$pr7" "a worktree-pr-<N> branch unrelated to the pull request is attached, the request's head as CLAUDE_BASE"
remove "$C" "$OUT"
assert_eq "$(branch_at "$C" worktree-pr-7)" "$prorphan" "...and remove keeps that branch"
G -C "$C" branch -q -D worktree-pr-7
# Claude Code fails the creation when the pull request cannot be fetched; a worktree on the
# default branch instead would put the caller in code that is not the pull request's.
create "$C" pr-99
assert_eq "$RC:$OUT" "1:" "a pull request origin does not have fails the creation, printing no path"
assert_has "$ERR" "Failed to fetch PR/MR #99" "...with Claude Code's message"
assert_eq "$(exists "$DEFAULT/pr-99"):$(branch_at "$C" worktree-pr-99)" "absent:none" "...and makes no worktree or branch"
create "$TMP/lonely" pr-3
assert_eq "$RC:$OUT" "1:" "...as does a pull request name in a repository without origin"

# ── branches holding work ─────────────────────────────────────────────
G -C "$C" branch -q worktree-keep "$c3"
G -C "$C" worktree add -q "$TMP/tmp-keep" worktree-keep >/dev/null 2>&1
printf 'k\n' >"$TMP/tmp-keep/k"
G -C "$TMP/tmp-keep" add k
G -C "$TMP/tmp-keep" commit -qm keep
keep="$(git -C "$TMP/tmp-keep" rev-parse HEAD)"
G -C "$C" worktree remove "$TMP/tmp-keep"
create "$C" keep
assert_eq "$RC:$(git -C "$OUT" rev-parse HEAD)" "0:$keep" "an existing worktree-<name> branch with its own commits is attached, not reset"
assert_eq "$(marker "$OUT")" "$c3" "...with CLAUDE_BASE at its merge base"
remove "$C" "$OUT"
assert_eq "$(branch_at "$C" worktree-keep)" "$keep" "...and remove keeps that branch"
G -C "$C" branch -q -D worktree-keep
G -C "$C" branch -q worktree-behind "$c1"
create "$C" behind
assert_eq "$(git -C "$OUT" rev-parse HEAD)" "$c3" "a worktree-<name> branch behind the base is moved up to it (-B)"
remove "$C" "$OUT"
# CLAUDE_BASE names a commit, not something that keeps it: once nothing else has the base, it
# is the branch's own. Here master drops the unpushed commit a baseRef head worktree began at.
printf 'unpushed\n' >"$C/unpushed"
G -C "$C" add unpushed
G -C "$C" commit -qm unpushed
unpushed="$(git -C "$C" rev-parse HEAD)"
setting "$C" settings.local.json '{"worktree":{"baseRef":"head"}}'
create "$C" lost-base
assert_eq "$RC:$(marker "$OUT")" "0:$unpushed" "setup: a baseRef head worktree based on an unpushed commit"
G -C "$C" reset -q --hard HEAD~1
remove "$C" "$OUT"
assert_eq "$(branch_at "$C" worktree-lost-base)" "$unpushed" "remove keeps a branch whose base no remote or other branch has any more"
G -C "$C" branch -q -D worktree-lost-base
clear_settings "$C"
# A worktree-<name> branch whose history is unrelated to the base is attached; with no merge
# base, CLAUDE_BASE is the base it was opened on, so all of it counts as its own, and it is kept.
orphan="$(G -C "$C" commit-tree -m orphan "$(git -C "$C" rev-parse "$c1^{tree}")")"
G -C "$C" branch -q worktree-orphan "$orphan"
create "$C" orphan
assert_eq "$RC:$(git -C "$OUT" rev-parse HEAD):$(marker "$OUT")" "0:$orphan:$c3" "a worktree-<name> branch with an unrelated history is attached as it is, the base as CLAUDE_BASE"
remove "$C" "$OUT"
assert_eq "$(branch_at "$C" worktree-orphan)" "$orphan" "...and remove keeps it"
G -C "$C" branch -q -D worktree-orphan

# ── Claude Code's post-checkout steps ─────────────────────────────────
mkdir -p "$C/node_modules/pkg" "$C/config"
printf 'TOKEN=1\n' >"$C/.env"
printf 'nested\n' >"$C/node_modules/pkg/.env"
printf 'secret\n' >"$C/secret.txt"
printf 'cfg\n' >"$C/config/dev.local"
mkdir -p "$C/secrets" "$C/cache/deep"
printf 'k=v\n' >"$C/secrets/app.env"
printf 'other\n' >"$C/secrets/other.env"
printf 'keep\n' >"$C/cache/deep/keep.txt"
mkdir -p "$C/vault/deep"
printf 'skip\n' >"$C/vault/deep/skip.txt"
printf 'secrets/\ncache/\nvault/\n' >>"$C/.git/info/exclude"
printf '.env\nconfig/*.local\nf\nsecrets/app.env  \n**/cache/deep/keep.txt\n**/deep/skip.txt\n' >"$C/.worktreeinclude"
create "$C" include
assert_eq "$(cat "$OUT/.env" 2>/dev/null)" "TOKEN=1" ".worktreeinclude: a gitignored file it names is copied"
assert_eq "$(cat "$OUT/config/dev.local" 2>/dev/null)" "cfg" "...so is one a pattern reaches inside a directory"
assert_eq "$(exists "$OUT/secret.txt")" "absent" "...a gitignored file it does not name is not"
assert_eq "$(exists "$OUT/node_modules/pkg/.env")" "absent" "...nor a match inside an ignored directory no pattern reaches"
assert_eq "$(cat "$OUT/f")" "$(git -C "$C" show "$c3:f")" "...and a tracked file it names keeps the checked-out content"
assert_eq "$(cat "$OUT/secrets/app.env" 2>/dev/null):$(exists "$OUT/secrets/other.env")" "k=v:absent" "...a file inside a wholly ignored directory a pattern names (trailing spaces ignored)"
assert_eq "$(cat "$OUT/cache/deep/keep.txt" 2>/dev/null)" "keep" "...one a **/ pattern reaches when its first name is the ignored directory's"
assert_eq "$(exists "$OUT/vault/deep/skip.txt")" "absent" "...but not when no pattern names the wholly ignored directory (Claude Code's rule)"
remove "$C" "$OUT"
rm -f "$C/.worktreeinclude"

setting "$C" settings.local.json '{"worktree":{"symlinkDirectories":["node_modules","missing"]}}'
create "$C" linked
assert_eq "$(readlink "$OUT/node_modules")" "$C/node_modules" "symlinkDirectories: the directory is a symlink to the main checkout's"
remove "$C" "$OUT"
assert_eq "$(exists "$C/node_modules/pkg/.env")" "present" "...and remove leaves the main checkout's copy alone"
clear_settings "$C"

setting "$C" settings.local.json '{"worktree":{"sparsePaths":["a"]}}'
create "$C" sparse
assert_eq "$(exists "$OUT/a/x"):$(exists "$OUT/b/y"):$(exists "$OUT/f")" "present:absent:present" "sparsePaths: only the listed directory plus root files"
assert_eq "$(git -C "$C" config --local --get extensions.worktreeConfig)" "true" "...with extensions.worktreeConfig on while it exists"
sparse1="$OUT"
create "$C" sparse2
sparse2="$OUT"
remove "$C" "$sparse1"
assert_eq "$(git -C "$C" config --local --get extensions.worktreeConfig)" "true" "...still on while another linked worktree remains"
git -C "$C" worktree remove --force "$TMP/side"
remove "$C" "$sparse2"
assert_eq "$(git -C "$C" config --local --get extensions.worktreeConfig || echo unset)" "unset" "...and back off once the last linked worktree is gone"
clear_settings "$C"

G -C "$C" config filter.mark.smudge "touch '$TMP/smudged'; cat"
G -C "$C" config filter.mark.clean cat
create "$C" refiltered
refiltered="$OUT"
create "$C" cond-reuse
cond_reuse="$OUT"
printf 'f filter=mark\n' >"$C/.git/info/attributes"
create "$C" filtered
assert_eq "$RC:$(exists "$TMP/smudged")" "0:absent" "the repo's own filter drivers do not run in the checkout"
remove "$C" "$OUT"
# Reopening moves a worktree up to the new base: a checkout too, with the drivers off as well.
printf '4\n' >"$TMP/seed/f"
G -C "$TMP/seed" commit -qam c4
G -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:master
c4="$(git -C "$TMP/seed" rev-parse HEAD)"
G -C "$C" fetch -q origin
create "$C" refiltered
assert_eq "$RC:$(git -C "$refiltered" rev-parse HEAD):$(exists "$TMP/smudged")" "0:$c4:absent" "a reopened worktree moves up to the new base with those drivers off"
remove "$C" "$refiltered"
# A conditional include can hide a driver from the main checkout that loads in a worktree
# (gitdir: matches each worktree's own git dir), so, like Claude Code, create refuses one and
# a reopened worktree stays where it is.
printf '[filter "hidden"]\n\tsmudge = touch %s; cat\n\tclean = cat\n' "'$TMP/hidden-smudged'" >"$TMP/hidden.gitconfig"
G -C "$C" config 'includeIf.gitdir:**/worktrees/**.path' "$TMP/hidden.gitconfig"
printf 'f filter=hidden\n' >"$C/.git/info/attributes"
create "$C" hidden
assert_eq "$RC:$OUT:$(exists "$TMP/hidden-smudged"):$(branch_at "$C" worktree-hidden)" "1::absent:none" "a conditional include in the repo's git config is refused, so the driver it hides cannot run"
assert_has "$ERR" "conditional include" "...saying why"
create "$C" cond-reuse
assert_eq "$RC:$OUT:$(git -C "$cond_reuse" rev-parse HEAD):$(exists "$TMP/hidden-smudged")" "0:$cond_reuse:$c3:absent" "...and a worktree reopened then is used as it is"
remove "$C" "$cond_reuse"
G -C "$C" config --unset 'includeIf.gitdir:**/worktrees/**.path'
rm -f "$C/.git/info/attributes"
G -C "$C" config --remove-section filter.mark
# Nor can -c switch off a program git-lfs runs for any LFS path, on checkout and on status,
# that a key of the repo's config names, so Claude Code refuses those keys too: in any case,
# for any URL, and on a line of a value of its own (git-lfs reads `git config -l` a line at a
# time; the value's first line shares the key's).
for k in lfs.customtransfer.evil.path lfs.CustomTransfer.Evil.path lfs.standalonetransferagent \
  'lfs.https://example.invalid/.standalonetransferagent' lfs.extension.evil.smudge; do
  G -C "$C" config "$k" "$TMP/evil"
  create "$C" lfs-key
  assert_eq "$RC:$OUT:$(branch_at "$C" worktree-lfs-key)" "1::none" "the repo config key $k (a program git-lfs runs) is refused"
  assert_has "$ERR" "sets $k, which names a program git-lfs would run" "...naming it"
  G -C "$C" config --unset "$k"
done
G -C "$C" config x.y "$(printf 'a\nlfs.customtransfer.evil.path=%s' "$TMP/evil")"
create "$C" lfs-key
assert_eq "$RC:$OUT" "1:" "...as is a value with such a key on a line of its own"
assert_has "$ERR" "sets x.y, an entry git-lfs reads as lfs.customtransfer.evil.path" "...naming both"
G -C "$C" config x.y "lfs.customtransfer.evil.path=$TMP/evil"
G -C "$C" config lfs.concurrenttransfers 3
create "$C" lfs-key
assert_eq "$RC:$OUT" "0:$DEFAULT/lfs-key" "...but not one on the key's own line, nor another lfs key"
lfs_reuse="$OUT"
G -C "$TMP/seed" commit -q --allow-empty -m c5
G -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:master
G -C "$C" fetch -q origin
G -C "$C" config lfs.extension.evil.clean "$TMP/evil"
create "$C" lfs-key
assert_eq "$RC:$OUT:$(git -C "$lfs_reuse" rev-parse HEAD)" "0:$lfs_reuse:$c4" "...and a worktree reopened while one is set is used as it is"
G -C "$C" config --unset lfs.extension.evil.clean
G -C "$C" config --unset lfs.concurrenttransfers
G -C "$C" config --unset x.y
remove "$C" "$lfs_reuse"
# Nor do the repo's hooks (from core.hooksPath or set in config) or its fsmonitor command run in
# the git the hook runs on its own account: reading and moving a reopened worktree, and removing
# a worktree and its branch, as Claude Code keeps them out of its own.
mkdir -p "$TMP/quiet-hooks"
for h in post-merge reference-transaction post-index-change; do
  printf '#!/bin/sh\necho "%s $*" >>%s\n' "$h" "'$TMP/quiet-ran'" >"$TMP/quiet-hooks/$h"
done
printf '#!/bin/sh\necho "fsmonitor $*" >>%s\nexit 1\n' "'$TMP/quiet-ran'" >"$TMP/quiet-fsmonitor"
chmod +x "$TMP/quiet-hooks/"* "$TMP/quiet-fsmonitor"
create "$C" quiet
quiet="$OUT"
G -C "$TMP/seed" commit -q --allow-empty -m c6
G -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:master
c6="$(git -C "$TMP/seed" rev-parse HEAD)"
G -C "$C" fetch -q origin
G -C "$C" config core.hooksPath "$TMP/quiet-hooks"
G -C "$C" config core.fsmonitor "$TMP/quiet-fsmonitor"
G -C "$C" config hook.quiet.command "echo config hook >>'$TMP/quiet-ran'"
G -C "$C" config hook.quiet.event post-merge
rm -f "$TMP/quiet-ran"
create "$C" quiet
assert_eq "$RC:$(git -C "$quiet" rev-parse HEAD):$(cat "$TMP/quiet-ran" 2>/dev/null)" "0:$c6:" "a reopened worktree moves up with none of the repo's hooks or its fsmonitor command run"
remove "$C" "$quiet"
assert_eq "$RC:$(exists "$quiet"):$(branch_at "$C" worktree-quiet):$(cat "$TMP/quiet-ran" 2>/dev/null)" "0:absent:none:" "...nor when remove takes the worktree and its branch"
G -C "$C" config --unset core.hooksPath
G -C "$C" config --unset core.fsmonitor
G -C "$C" config --remove-section hook.quiet
# Under extensions.worktreeConfig git copies the main checkout's worktree config into the new
# worktree's git dir, where a relative include in it resolves from there: here to a file in the
# main checkout that defines a driver, which the main checkout's own listing never sees. The
# drivers are read in the new worktree before it is checked out, so that one is off too.
W="$TMP/wtconfig"
G clone -q "$TMP/origin.git" "$W"
touch "$(git -C "$W" rev-parse --absolute-git-dir)/FETCH_HEAD"
G -C "$W" config core.repositoryformatversion 1
G -C "$W" config extensions.worktreeConfig true
create "$W" wtc-plain
assert_eq "$RC:$OUT:$(cat "$OUT/f" 2>/dev/null)" "0:$W/.claude/worktrees/wtc-plain:$(git -C "$W" show origin/master:f)" "extensions.worktreeConfig: the worktree is made and checked out"
remove "$W" "$OUT"
printf '[filter "copied"]\n\tsmudge = touch %s; cat\n\tclean = cat\n' "'$TMP/copied-smudged'" >"$W/copied.gitconfig"
printf '[include]\n\tpath = ../../../copied.gitconfig\n' >>"$(git -C "$W" rev-parse --absolute-git-dir)/config.worktree"
printf 'f filter=copied\n' >"$(git -C "$W" rev-parse --absolute-git-dir)/info/attributes"
create "$W" wtc-include
assert_eq "$RC:$(cat "$OUT/f" 2>/dev/null):$(exists "$TMP/copied-smudged")" "0:$(git -C "$W" show origin/master:f):absent" "...and a driver its copied worktree config includes from elsewhere does not run in the checkout"
remove "$W" "$OUT"

mkdir -p "$C/.husky"
G -C "$C" config core.hooksPath .husky
create "$C" husky
assert_eq "$(git -C "$OUT" config --get core.hooksPath)" "$C/.husky" "a relative core.hooksPath points at the main checkout's hooks"
remove "$C" "$OUT"
G -C "$C" config --unset core.hooksPath

# ── stdout stays the path ─────────────────────────────────────────────
mkdir -p "$TMP/githooks"
printf '#!/bin/sh\necho noise from post-checkout\necho more noise >&2\nsleep 30 &\n' >"$TMP/githooks/post-checkout"
chmod +x "$TMP/githooks/post-checkout"
G -C "$C" config core.hooksPath "$TMP/githooks"
start="$(date +%s)"
create "$C" noisy
took=$(($(date +%s) - start))
assert_eq "$RC:$OUT" "0:$DEFAULT/noisy" "a chatty post-checkout hook does not reach stdout"
assert_has "$ERR" "noise from post-checkout" "...its output goes to stderr"
if ((took < 15)); then ok "...and a process it leaves behind does not hold the hook's output open (${took}s)"; else not_ok "the hook took ${took}s: a leftover process held its output"; fi
G -C "$C" config --unset core.hooksPath
remove "$C" "$OUT"

# ── prune ─────────────────────────────────────────────────────────────
# A clone of its own; every worktree there links node_modules from it (symlinkDirectories).
run_prune() {
  OUT="$(cd "$TMP" && "$HOOK_BASH" "$HOOK" prune "$@" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}
OLD=202001010000
# age WORKTREE: make it, its git dir and its branch's reflog look years old.
age() {
  local gd br
  gd="$(git -C "$1" rev-parse --absolute-git-dir)"
  br="$(git -C "$1" symbolic-ref -q --short HEAD)"
  find "$1" "$gd" -exec touch -h -t "$OLD" {} + 2>/dev/null
  [[ -z "$br" ]] || touch -h -t "$OLD" "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/logs/refs/heads/$br"
}
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
gitdir_of() { git -C "$1" rev-parse --absolute-git-dir; }
# wait_log LOG: until the background prune that writes LOG prints its summary (30 s at most).
wait_log() {
  local i
  for ((i = 0; i < 150; i++)); do
    grep -q '^claude-worktree-hook: prune: ' "$1" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}
P="$TMP/pclone"
PB="$TMP/pbase"
G clone -q "$TMP/origin.git" "$P"
touch "$(gitdir_of "$P")/FETCH_HEAD"
mkdir -p "$P/node_modules/pkg"
printf 'keep\n' >"$P/node_modules/pkg/keep"
PSET='{"worktree":{"baseDirectory":"'"$PB"'","symlinkDirectories":["node_modules"]}}'
setting "$P" settings.local.json "$PSET"
# pmake NAME: a hook worktree in the prune base directory.
pmake() {
  create "$P" "$1"
  [[ "$RC:$OUT" == "0:$PB/$1" ]] || not_ok "setup: create $1 (rc $RC, out [$OUT], err [$ERR])"
}
pcommit() { # worktree file
  printf '%s\n' "$2" >"$1/$2"
  G -C "$1" add "$2"
  G -C "$1" commit -qm "$2"
}
for n in p-clean p-ignored p-modified p-untracked p-staged p-commit p-pushed p-detached p-new \
  p-inuse p-live-lock p-stale-lock p-user-lock p-rebase p-missing; do
  pmake "$n"
done
assert_eq "$(readlink "$PB/p-clean/node_modules")" "$P/node_modules" "prune setup: create linked node_modules into the worktrees"
printf 'TOKEN=1\n' >"$PB/p-ignored/.env"
printf 'x\n' >>"$PB/p-modified/f"
printf 'x\n' >"$PB/p-untracked/new"
printf 'x\n' >"$PB/p-staged/staged"
G -C "$PB/p-staged" add staged
pcommit "$PB/p-commit" mine
pcommit "$PB/p-pushed" pushed
G -C "$PB/p-pushed" push -q origin HEAD:refs/heads/p-pushed-remote
G -C "$PB/p-detached" checkout -q --detach
pcommit "$PB/p-detached" detached
G -C "$P" worktree lock --reason "claude agent p-live-lock (pid $$ start Mon Jan  1 00:00:00 2024)" "$PB/p-live-lock"
sleep 0 &
dead=$!
wait "$dead"
G -C "$P" worktree lock --reason "claude agent p-stale-lock (pid $dead start Mon Jan  1 00:00:00 2024)" "$PB/p-stale-lock"
G -C "$P" worktree lock --reason "keep me" "$PB/p-user-lock"
mkdir "$(gitdir_of "$PB/p-rebase")/rebase-merge"
G -C "$P" worktree add -q -b p-plain "$PB/p-plain" >/dev/null 2>&1
clear_settings "$P"
create "$P" p-outside
assert_eq "$RC:$OUT" "0:$P/.claude/worktrees/p-outside" "prune setup: a hook worktree in the default place, made while the setting was off"
setting "$P" settings.local.json "$PSET"
for n in p-clean p-ignored p-modified p-untracked p-staged p-commit p-pushed p-detached p-inuse \
  p-live-lock p-stale-lock p-user-lock p-rebase p-plain; do
  age "$PB/$n"
done
age "$P/.claude/worktrees/p-outside"
rm -rf "$PB/p-missing"
(cd "$PB/p-inuse/a" && exec sleep 300) &
INUSE=$!
BG_PIDS="$BG_PIDS $INUSE"
for ((i = 0; i < 50; i++)); do
  [[ "$(lsof -a -p "$INUSE" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')" == "$PB/p-inuse/a" ||
    "$(readlink "/proc/$INUSE/cwd" 2>/dev/null)" == "$PB/p-inuse/a" ]] && break
  sleep 0.1
done
before="$(git -C "$P" worktree list --porcelain | grep -c '^worktree ')"

run_prune --dry-run "$P"
assert_eq "$RC" "0" "prune --dry-run runs"
assert_has "$OUT" "would remove $PB/p-clean (branch worktree-p-clean)" "...and would remove a clean, idle hook worktree with no commits of its own"
assert_has "$OUT" "would remove $PB/p-ignored " "...one with only ignored files in it"
assert_has "$OUT" "would remove $PB/p-pushed " "...one whose commit a remote has"
assert_has "$OUT" "would remove $PB/p-stale-lock " "...one whose Claude Code lock names a process that is gone"
assert_has "$OUT" "kept $PB/p-modified: uncommitted or untracked changes" "...but keeps one with a modified file"
assert_has "$OUT" "kept $PB/p-untracked: uncommitted or untracked changes" "...one with an untracked file"
assert_has "$OUT" "kept $PB/p-staged: uncommitted or untracked changes" "...one with a staged file"
assert_has "$OUT" "kept $PB/p-commit: 1 commit(s) that no remote or other branch has" "...one whose branch has a commit nothing else has"
assert_has "$OUT" "kept $PB/p-detached: 1 commit(s) that no remote or other branch has" "...one with such a commit on a detached HEAD"
assert_has "$OUT" "kept $PB/p-new: last changed less than a day ago" "...one changed recently"
assert_has "$OUT" "kept $PB/p-inuse: in use (process $INUSE" "...one a running process works in"
assert_has "$OUT" "kept $PB/p-live-lock: in use (locked by a Claude Code process that is still running" "...one Claude Code holds locked from a live process"
assert_has "$OUT" "kept $PB/p-user-lock: locked (keep me)" "...one locked by anyone else"
assert_has "$OUT" "kept $PB/p-rebase: a rebase is in progress" "...one with a rebase under way"
assert_has "$OUT" "kept $PB/p-plain: not made by this hook (no CLAUDE_BASE" "...one the hook did not make"
assert_has "$OUT" "kept $PB/p-missing: its directory is missing" "...and the record of one whose directory is gone"
assert_lacks "$OUT" "p-outside" "...and does not look outside the base directory"
assert_has "$OUT" "prune --dry-run: 4 would be removed, 12 kept, in $PB" "...summing up"
assert_eq "$(exists "$PB/p-clean"):$(registered "$P" "$PB/p-clean"):$(git -C "$P" worktree list --porcelain | grep -c '^worktree ')" "present:yes:$before" "...while changing nothing"
OUT="$(cd "$TMP" && CLAUDE_WORKTREE_PRUNE_DAYS=100000 "$HOOK_BASH" "$HOOK" prune --dry-run "$P" 2>/dev/null)"
assert_has "$OUT" "kept $PB/p-clean: last changed " "CLAUDE_WORKTREE_PRUNE_DAYS sets how long a worktree must be idle"
assert_has "$OUT" "idle for over 100000 days" "...and the reason says so"
OUT="$(cd "$TMP" && CLAUDE_WORKTREE_PRUNE_DAYS=week "$HOOK_BASH" "$HOOK" prune "$P" 2>&1)"
RC=$?
assert_eq "$RC:$(exists "$PB/p-clean")" "1:present" "...and a value that is not a number of days is refused"

run_prune "$PB/p-new"
assert_eq "$RC" "0" "prune (given a linked worktree: the main checkout's worktrees) removes"
assert_has "$OUT" "removed $PB/p-clean (branch worktree-p-clean)" "...saying what it removed"
assert_eq "$(exists "$PB/p-clean"):$(registered "$P" "$PB/p-clean"):$(branch_at "$P" worktree-p-clean)" "absent:no:none" "...the directory, its registration and its worktree-<name> branch"
assert_eq "$(exists "$PB/p-ignored"):$(exists "$PB/p-pushed"):$(branch_at "$P" worktree-p-pushed)" "absent:absent:none" "...and the others it listed"
assert_eq "$(exists "$PB/p-stale-lock"):$(branch_at "$P" worktree-p-stale-lock)" "absent:none" "...unlocking a stale Claude Code lock first"
assert_eq "$(cat "$P/node_modules/pkg/keep" 2>/dev/null)" "keep" "...and leaves the main checkout's linked node_modules alone"
assert_eq "$(exists "$PB/p-modified"):$(exists "$PB/p-commit"):$(exists "$PB/p-inuse"):$(exists "$PB/p-live-lock"):$(exists "$PB/p-user-lock"):$(exists "$PB/p-plain"):$(exists "$PB/p-new")" \
  "present:present:present:present:present:present:present" "...but none of the ones it keeps"
assert_eq "$(registered "$P" "$PB/p-missing"):$(exists "$P/.claude/worktrees/p-outside")" "yes:present" "...nor git's record of a missing one, nor a worktree outside the base directory"
assert_has "$OUT" "prune: 4 removed, 12 kept, 0 failed, in $PB" "...summing up"
kill "$INUSE" 2>/dev/null
wait "$INUSE" 2>/dev/null
run_prune "$P"
assert_eq "$RC:$(exists "$PB/p-inuse")" "0:absent" "once the process is gone, the next prune removes it"

clear_settings "$P"
run_prune "$P"
assert_eq "$RC:$(exists "$P/.claude/worktrees/p-outside")" "1:present" "prune refuses a repo without worktree.baseDirectory"
assert_has "$ERR" "no worktree.baseDirectory of its own" "...saying why"
setting "$P" settings.local.json "$(base_json "$TMP/pbase-missing")"
run_prune "$P"
assert_eq "$RC:$(exists "$TMP/pbase-missing")" "0:absent" "a base directory that does not exist: nothing to prune, and it is not created"
assert_has "$OUT" "nothing to prune" "...saying so"
mkdir -p "$TMP/notgit"
run_prune "$TMP/notgit"
assert_eq "$RC" "1" "prune refuses a directory outside a repository"
if [[ -n "$UNMOUNTED" ]]; then
  # A worktree git has on the unmounted volume: its directory only looks missing.
  G -C "$P" worktree add -q -b p-ghost "$TMP/ghost-wt" >/dev/null 2>&1
  ghost="$(gitdir_of "$TMP/ghost-wt")"
  printf '%s\n' "$UNMOUNTED/wt/p-ghost/.git" >"$ghost/gitdir"
  printf '%s' "$c1" >"$ghost/CLAUDE_BASE"
  rm -rf "$TMP/ghost-wt"
  setting "$P" settings.local.json "$(base_json "$UNMOUNTED/wt")"
  run_prune "$P"
  assert_eq "$RC" "1" "prune refuses while the base directory's volume is not mounted"
  assert_has "$ERR" "not mounted" "...saying why"
  assert_eq "$(exists "$ghost"):$(registered "$P" "$UNMOUNTED/wt/p-ghost"):$(exists "$P/.claude/worktrees/p-outside")" "present:yes:present" "...keeping git's record of a worktree on that volume and everything else"
  assert_eq "$(exists "$UNMOUNTED")" "absent" "...and creating nothing on the root disk"
  rm -rf "$ghost"
  G -C "$P" branch -q -D p-ghost
else
  skip "no unmounted volume container on this host"
fi

# prune reads trees and removes worktrees on its own account, so the repo's drivers, hooks and
# fsmonitor command stay out of its git status and git worktree remove as they stay out of
# create's: here a clean filter that git status runs on aged (so stat-dirty) files.
setting "$P" settings.local.json "$PSET"
for n in q-filtered q-refused q-sub; do pmake "$n"; done
G -c protocol.file.allow=always -C "$PB/q-sub" submodule add -q "$TMP/origin.git" sm >/dev/null 2>&1
G -C "$PB/q-sub" commit -qm "add sm"
G -C "$PB/q-sub" push -q origin HEAD:refs/heads/q-sub-remote
G -C "$P" config filter.qmark.clean "touch '$TMP/prune-cleaned'; cat"
G -C "$P" config filter.qmark.smudge cat
printf 'f filter=qmark\n' >"$(gitdir_of "$P")/info/attributes"
G -C "$P" config core.fsmonitor "$TMP/quiet-fsmonitor"
G -C "$P" config lfs.extension.evil.clean "$TMP/evil"
for n in q-filtered q-refused q-sub; do age "$PB/$n"; done
rm -f "$TMP/prune-cleaned" "$TMP/quiet-ran"
run_prune "$P"
assert_eq "$RC:$(exists "$PB/q-refused"):$(exists "$PB/q-filtered")" "1:present:present" "past a repo config key that names a git-lfs program, prune removes nothing"
assert_has "$ERR" "names a program git-lfs would run" "...saying why"
G -C "$P" config --unset lfs.extension.evil.clean
run_prune "$P"
assert_eq "$RC:$(exists "$PB/q-filtered"):$(exists "$PB/q-refused"):$(exists "$TMP/prune-cleaned"):$(cat "$TMP/quiet-ran" 2>/dev/null)" "0:absent:absent:absent:" \
  "prune removes idle worktrees with none of the repo's drivers, hooks or fsmonitor command run"
assert_has "$OUT" "kept $PB/q-sub: it has a submodule checked out" "...and keeps one with a submodule checked out, which git worktree remove refuses"
G -C "$P" worktree remove --force "$PB/q-sub"
G -C "$P" branch -q -D worktree-q-sub
G -C "$P" config --unset core.fsmonitor
G -C "$P" config --remove-section filter.qmark
rm -f "$(gitdir_of "$P")/info/attributes"

# create's background prune: at most once a day, never in the way of the creation.
setting "$P" settings.local.json "$PSET"
PGD="$(gitdir_of "$P")"
STAMP="$PGD/claude-worktree-prune.stamp"
PLOG="$PGD/claude-worktree-prune.log"
pmake a-old
age "$PB/a-old"
rm -f "$STAMP" "$PLOG"
export CLAUDE_WORKTREE_AUTO_PRUNE=1
create "$P" a-new
assert_eq "$RC:$OUT:$(lines "$OUT")" "0:$PB/a-new:1" "create with no prune today: prints only the path"
assert_eq "$(exists "$STAMP")" "present" "...stamps the day"
wait_log "$PLOG" || not_ok "the background prune did not finish: $(cat "$PLOG" 2>/dev/null)"
assert_has "$(cat "$PLOG" 2>/dev/null)" "removed $PB/a-old" "...and prunes in the background, logging to the git dir"
assert_eq "$(exists "$PB/a-old"):$(exists "$PB/a-new")" "absent:present" "...removing the idle worktree, not the new one"

pmake b-old
age "$PB/b-old"
rm -f "$PLOG"
create "$P" b-new
sleep 2
assert_eq "$RC:$(exists "$PLOG"):$(exists "$PB/b-old")" "0:absent:present" "a second create the same day starts no prune"

touch -t "$OLD" "$STAMP"
rm -f "$PLOG"
create "$P" b-old
assert_eq "$RC:$OUT" "0:$PB/b-old" "reopening an idle worktree when the day's prune is due"
wait_log "$PLOG" || not_ok "the background prune did not finish: $(cat "$PLOG" 2>/dev/null)"
assert_has "$(cat "$PLOG" 2>/dev/null)" "kept $PB/b-old: last changed less than a day ago" "...counts as use, so the prune it starts keeps it"
assert_eq "$(exists "$PB/b-old")" "present" "...and it is still there"

mkdir -p "$TMP/slowbin"
printf '#!/bin/sh\nsleep 6\nexit 1\n' >"$TMP/slowbin/lsof"
chmod +x "$TMP/slowbin/lsof"
pmake c-old
age "$PB/c-old"
touch -t "$OLD" "$STAMP"
rm -f "$PLOG"
start="$(date +%s)"
both="$(jq -cn --arg cwd "$P" '{cwd: $cwd, name: "slow", hook_event_name: "WorktreeCreate"}' |
  PATH="$TMP/slowbin:$PATH" "$HOOK_BASH" "$HOOK" create 2>&1)"
took=$(($(date +%s) - start))
assert_eq "$(printf '%s\n' "$both" | tail -n 1)" "$PB/slow" "a slow background prune: create still prints the path"
if ((took < 5)); then ok "...without waiting for it or leaving it on the hook's stdout or stderr (${took}s)"; else not_ok "create took ${took}s: the background prune held it up"; fi
wait_log "$PLOG" || not_ok "the slow background prune did not finish: $(cat "$PLOG" 2>/dev/null)"
if [[ -d /proc/self ]]; then
  assert_eq "$(exists "$PB/c-old")" "absent" "...and when lsof fails, /proc says which processes work where"
else
  assert_has "$(cat "$PLOG" 2>/dev/null)" "kept $PB/c-old: cannot tell whether a process works in it" "...and when no process list can be had, it keeps even an idle clean worktree"
  assert_eq "$(exists "$PB/c-old")" "present" "...which is still there"
fi

if [[ -n "$UNMOUNTED" ]]; then
  touch -t "$OLD" "$STAMP"
  stamped="$(mtime_of "$STAMP")"
  setting "$P" settings.local.json "$(base_json "$UNMOUNTED/wt")"
  create "$P" offline-auto
  assert_eq "$RC:$OUT:$(mtime_of "$STAMP")" "0:$P/.claude/worktrees/offline-auto:$stamped" "while the setting's volume is not mounted, create starts no prune and leaves the day's run due"
  remove "$P" "$OUT"
  setting "$P" settings.local.json "$PSET"
else
  skip "no unmounted volume container on this host"
fi
export CLAUDE_WORKTREE_AUTO_PRUNE=0

# ── enable / disable ──────────────────────────────────────────────────
rm -rf "$C/.claude"
OUT="$("$HOOK_BASH" "$HOOK" enable "$C" </dev/null 2>&1)"
RC=$?
assert_eq "$RC:$(exists "$C/.claude/settings.local.json")" "1:absent" "enable refuses a repo without worktree.baseDirectory"
setting "$C" settings.local.json '{"permissions":{"allow":["Bash(ls)"]},"worktree":{"baseDirectory":"'"$TMP"'/wt-abs"}}'
OUT="$("$HOOK_BASH" "$HOOK" enable "$C" </dev/null 2>&1)"
RC=$?
F="$C/.claude/settings.local.json"
assert_eq "$RC" "0" "enable adds the hooks"
enabled="$OUT"
cmd="$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$F")"
assert_eq "${cmd%% *}:$cmd:$(jq -r '.hooks.WorktreeRemove[0].hooks[0].command' "$F")" "bash:${cmd% create} create:${cmd% create} remove" \
  "...as WorktreeCreate and WorktreeRemove command hooks (bash <hook> create, bash <hook> remove)"
assert_eq "$(jq -c '.permissions' "$F"):$(jq -r '.worktree.baseDirectory' "$F")" '{"allow":["Bash(ls)"]}:'"$TMP"'/wt-abs' "...keeping the file's other settings"
assert_has "$enabled" "go in $TMP/wt-abs" "...and says where worktrees will go"
# The command must reach the hook that wrote it, wherever its checkout is (HOME here has no
# ~/.dotfiles): a WorktreeCreate command that fails fails every worktree creation.
OUT="$(jq -cn --arg cwd "$C" '{session_id: "test", cwd: $cwd, hook_event_name: "WorktreeCreate", name: "via-cmd"}' |
  (cd "$TMP" && bash -c "$cmd") 2>/dev/null)"
assert_eq "$?:$OUT" "0:$TMP/wt-abs/via-cmd" "...and the command it registers runs this copy of the hook"
remove "$C" "$OUT"
before="$(cat "$F")"
"$HOOK_BASH" "$HOOK" enable "$C" </dev/null >/dev/null 2>&1
assert_eq "$(cat "$F")" "$before" "enable twice changes nothing"
G -C "$C" worktree add -q -b side2 "$TMP/side2" >/dev/null 2>&1
"$HOOK_BASH" "$HOOK" disable "$TMP/side2" </dev/null >/dev/null 2>&1
assert_eq "$(jq -r '.hooks // "none"' "$F"):$(jq -c '.permissions' "$F")" 'none:{"allow":["Bash(ls)"]}' "disable (from a linked worktree) takes them out of the main checkout's file"
# A copy under HOME is registered as ~/..., which stays right wherever HOME is.
mkdir -p "$HOME/dots/scripts"
cp "$HOOK" "$HOME/dots/scripts/claude-worktree-hook"
cp "$(dirname "$HOOK")/wt-helper" "$HOME/dots/scripts/wt-helper"
"$HOOK_BASH" "$HOME/dots/scripts/claude-worktree-hook" enable "$C" </dev/null >/dev/null 2>&1
# shellcheck disable=SC2088  # the registered command holds a literal ~ for the hook's shell
assert_eq "$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$F")" "bash ~/dots/scripts/claude-worktree-hook create" "enable from a copy under HOME registers it as ~/..."
"$HOOK_BASH" "$HOOK" disable "$C" </dev/null >/dev/null 2>&1
"$HOOK_BASH" "$HOOK" enable "$TMP/side2" </dev/null >/dev/null 2>&1
assert_eq "$(jq -r '.hooks.WorktreeCreate | length' "$F")" "1" "enable from a linked worktree writes the main checkout's file"
jq '.hooks.WorktreeCreate += [{"hooks":[{"type":"command","command":"other-hook"}]}]' "$F" >"$F.new" && mv "$F.new" "$F"
"$HOOK_BASH" "$HOOK" disable "$C" </dev/null >/dev/null 2>&1
assert_eq "$(jq -c '.hooks.WorktreeCreate' "$F")" '[{"hooks":[{"type":"command","command":"other-hook"}]}]' "disable leaves other WorktreeCreate hooks"
OUT="$("$HOOK_BASH" "$HOOK" enable "$C" </dev/null 2>&1)"
RC=$?
assert_eq "$RC" "1" "enable refuses next to another WorktreeCreate hook"
assert_has "$OUT" "other-hook" "...naming it"
if [[ -n "$UNMOUNTED" ]]; then
  setting "$C" settings.local.json "$(base_json "$UNMOUNTED/wt")"
  OUT="$("$HOOK_BASH" "$HOOK" enable "$C" </dev/null 2>&1)"
  RC=$?
  assert_eq "$RC:$(jq -r '.hooks.WorktreeCreate | length' "$F")" "0:1" "enable works while the setting's volume is not mounted"
  assert_has "$OUT" "cannot be used right now" "...and says the worktrees go in the default place until it is"
else
  skip "no unmounted volume container on this host"
fi

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
