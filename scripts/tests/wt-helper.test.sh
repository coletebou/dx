#!/usr/bin/env bash
# wt-helper trusts its cached default branch only while that branch's ref still exists. A remote that renamed
# main -> master left the 7-day cache naming origin/main, and `wt <branch> --from fresh` failed with
# "invalid reference: origin/main". Scratch repos (a bare origin whose HEAD is master, a clone of it, a repo
# with no origin) live in a temp dir and HOME points there too, so the real cache and git config are never
# read or written. WT_HELPER runs another copy, e.g. the previous version to see the failure.
#
# It also ignored the repo's worktree.baseDirectory setting, so a repo that pointed its worktrees at an
# external drive still filled the root disk. The second half covers that setting:
# local over shared, absolute / ~ / relative values, unreadable files and a missing jq (warn, fall back),
# the env levers above it, and a volume that is not mounted (refused, nothing created). It reads paths
# through --print-base-dir and also creates real worktrees, all inside the scratch repo. The setting is
# the main checkout's, found from a subdirectory, in a submodule and with a separate git dir too.
#
# And it ran `git worktree prune` on every call, so while an external drive was unplugged git forgot
# every worktree on it. The last part covers the guard: prune waits while an unlocked registered worktree
# is on a volume that is not mounted, recorded there or at a symlink into it, and runs as before otherwise.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WT="${WT_HELPER:-$ROOT/scripts/wt-helper}"
TMP="$(mktemp -d)"
# A never-mounted volume: a fresh name under a mount container that is not itself a mount point (on some
# Linux hosts /mnt is a disk). wt-helper must refuse it; should it ever create it, the trap removes it.
UNMOUNTED=""
for c in /Volumes /mnt /media /run/media; do
  [[ -d "$c" && ! -L "$c" ]] || continue
  [[ "$(df -P "$c" 2>/dev/null | awk 'NR == 2 { print $NF }')" == "$c" ]] && continue
  UNMOUNTED="$c/wt-helper-test-$$-$RANDOM"
  break
done
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; find "$TMP" -depth -delete 2>/dev/null || true; [[ -n "$UNMOUNTED" && -d "$UNMOUNTED" ]] && rm -rf "$UNMOUNTED"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
skip() { printf 'ok %d - # SKIP %s\n' "$((PASS + FAIL + 1))" "$1"; PASS=$((PASS + 1)); }
assert_eq() { if [[ "$1" == "$2" ]]; then ok "$3"; else not_ok "$3 (got [$1], expected [$2])"; fi; }
assert_has() { if [[ "$1" == *"$2"* ]]; then ok "$3"; else not_ok "$3 ([$1] lacks [$2])"; fi; }

export HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1
# The layout levers would move every worktree below (some remote dev boxes export WT_BASE_DIR).
unset XDG_CONFIG_HOME WT_BASE_DIR WT_LAYOUT WT_NESTED_SUBDIR
mkdir -p "$HOME"
G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=master "$@"; }

# The cache file wt-helper keeps for the repo at $1 (same key: sha1 of the toplevel path).
cache_file() {
  local top hash
  top="$(git -C "$1" rev-parse --show-toplevel)"
  if command -v sha1sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$top" | sha1sum | cut -c1-12)"
  else
    hash="$(printf '%s' "$top" | shasum | cut -c1-12)"
  fi
  printf '%s/.cache/wt-helper/%s/default-branch' "$HOME" "$hash"
}
set_cache() { mkdir -p "$(dirname "$(cache_file "$1")")" && printf '%s' "$2" > "$(cache_file "$1")"; }
run_wt() { # dir branch from -> OUT, RC
  OUT="$(cd "$1" && "$WT" "$2" --from "$3" --no-cd 2>&1)"
  RC=$?
}

# origin: HEAD -> master at c1, dev one commit ahead at c2. The clone's origin/HEAD -> origin/master.
G init -q --bare "$TMP/origin.git"
G init -q "$TMP/seed"
printf '1\n' > "$TMP/seed/f"
G -C "$TMP/seed" add f
G -C "$TMP/seed" commit -qm c1
G -C "$TMP/seed" push -q "$TMP/origin.git" master
printf '2\n' > "$TMP/seed/f"
G -C "$TMP/seed" commit -qam c2
G -C "$TMP/seed" push -q "$TMP/origin.git" HEAD:dev
G clone -q "$TMP/origin.git" "$TMP/clone"
c1="$(git -C "$TMP/clone" rev-parse origin/master)"
c2="$(git -C "$TMP/clone" rev-parse origin/dev)"
assert_eq "$(git -C "$TMP/clone" symbolic-ref refs/remotes/origin/HEAD)" "refs/remotes/origin/master" "fixture: origin/HEAD points at master"

# A cache left at main from before the rename; a local main branch lingers too, as it does after a rename.
set_cache "$TMP/clone" main
G -C "$TMP/clone" branch main
run_wt "$TMP/clone" feat-a fresh
assert_eq "$RC" "0" "a stale cached main does not fail --from fresh"
[[ "$RC" -eq 0 ]] || printf '# %s\n' "$OUT"
assert_eq "$(git -C "$TMP/clone" rev-parse --verify -q feat-a)" "$c1" "the new branch starts at origin/master"
assert_eq "$([[ -d "$TMP/clone/.claude/worktrees/feat-a" ]] && echo yes)" "yes" "the worktree is created"
assert_eq "$(cat "$(cache_file "$TMP/clone")")" "master" "the cache is rewritten with master"

# A cached name whose remote-tracking ref exists is still used as is, even when origin/HEAD says otherwise.
set_cache "$TMP/clone" dev
run_wt "$TMP/clone" feat-b fresh
assert_eq "$RC" "0" "a valid cached branch works"
assert_eq "$(git -C "$TMP/clone" rev-parse --verify -q feat-b)" "$c2" "the valid cached dev is used, not origin/HEAD"
assert_eq "$(cat "$(cache_file "$TMP/clone")")" "dev" "a valid cache is left alone"

# No origin: the cached name must be a local branch.
G init -q "$TMP/local"
: > "$TMP/local/f"
G -C "$TMP/local" add f
G -C "$TMP/local" commit -qm l1
set_cache "$TMP/local" main
run_wt "$TMP/local" feat-c head
assert_eq "$RC" "0" "a repo with no origin still makes the worktree"
assert_eq "$(cat "$(cache_file "$TMP/local")")" "master" "without origin, a cached name with no local branch is recomputed"
G -C "$TMP/local" branch trunk
set_cache "$TMP/local" trunk
run_wt "$TMP/local" feat-d head
assert_eq "$(cat "$(cache_file "$TMP/local")")" "trunk" "without origin, a cached name that is a local branch is kept"

# ── worktree.baseDirectory ───────────────────────────────────────────
# wt-helper writes its messages to /dev/tty when it has one. Detach from the controlling terminal so they
# land on stderr, where these assertions read them. stderr is a file here, which on Linux also checks that
# a message of several lines survives whole (writing to /dev/stderr per line truncated it to the last).
detached() {
  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX=setsid -e 'setsid(); exec @ARGV or die "exec $ARGV[0]: $!\n"' -- "$@"
  else
    "$@"
  fi
}
# base_dir <dir> [VAR=value ...] -> OUT, ERR, RC of `wt-helper --print-base-dir` run in <dir>.
base_dir() {
  local dir="$1"; shift
  OUT="$(cd "$dir" && detached env "$@" "$WT" --print-base-dir 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}
# make_wt <dir> <branch> [VAR=value ...] [-- extra wt-helper args] -> OUT (the printed path), ERR, RC.
make_wt() {
  local dir="$1" branch="$2"; shift 2
  local -a envs=() extra=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] && { shift; extra=("$@"); }
  OUT="$(cd "$dir" && detached env ${envs[@]+"${envs[@]}"} "$WT" "$branch" --from head --no-cd --print-target --no-fetch ${extra[@]+"${extra[@]}"} 2>"$TMP/stderr")"
  RC=$?
  ERR="$(cat "$TMP/stderr")"
}
# setting <local|shared> <json|-> writes (or with -, removes) the scratch repo's settings file.
setting() {
  local file="$P/.claude/settings.json"
  [[ "$1" == local ]] && file="$P/.claude/settings.local.json"
  if [[ "$2" == - ]]; then rm -f "$file"; else printf '%s\n' "$2" > "$file"; fi
}
base_json() { printf '{"worktree":{"baseDirectory":"%s","cleanupEmpty":true}}' "$1"; }

P="$TMP/proj"
G init -q "$P"
: > "$P/f"
G -C "$P" add f
G -C "$P" commit -qm p1
mkdir -p "$P/.claude"
TOP="$(git -C "$P" rev-parse --show-toplevel)"   # physical path, as wt-helper derives it
DEFAULT="$TOP/.claude/worktrees"

base_dir "$P"
assert_eq "$RC:$OUT:$ERR" "0:$DEFAULT:" "no settings: the nested default, silently"

setting local "$(base_json "$TMP/ext/wt")"
base_dir "$P"
assert_eq "$RC:$OUT:$ERR" "0:$TMP/ext/wt:" "an absolute setting is used as written"
assert_eq "$([[ -e "$TMP/ext" ]] && echo created || echo absent)" "absent" "--print-base-dir creates nothing"
setting local "$(base_json "$TMP/ext/wt/")"
base_dir "$P"
assert_eq "$OUT" "$TMP/ext/wt" "a trailing slash is dropped"
setting local "$(base_json "wt-rel")"
base_dir "$P"
assert_eq "$OUT" "$TOP/wt-rel" "a relative setting resolves against the repo root"
setting local "$(base_json ".claude/worktrees")"
base_dir "$P"
assert_eq "$OUT" "$DEFAULT" "the documented relative default resolves to the nested default"
# shellcheck disable=SC2088  # the setting holds a literal ~ for wt-helper to expand
setting local "$(base_json "~/wt-home")"
base_dir "$P"
# shellcheck disable=SC2088  # the ~ is literal text in the assertion message
assert_eq "$OUT" "$HOME/wt-home" "~/ expands to HOME"
setting local "$(base_json "~")"
base_dir "$P"
assert_eq "$OUT" "$HOME" "a bare ~ is HOME"

setting local "$(base_json "$TMP/local-wins")"
setting shared "$(base_json "$TMP/shared")"
base_dir "$P"
assert_eq "$OUT" "$TMP/local-wins" "settings.local.json wins over settings.json"
setting local -
base_dir "$P"
assert_eq "$RC:$OUT:$ERR" "0:$TMP/shared:" "settings.json applies when there is no local file"
setting local '{"permissions":{"allow":[]}}'
base_dir "$P"
assert_eq "$OUT" "$TMP/shared" "a local file without the key falls through to settings.json"
setting local '{"worktree":{"baseDirectory": "/nope"'
base_dir "$P"
assert_eq "$OUT" "$TMP/shared" "an unparseable local file falls through to settings.json"
assert_has "$ERR" "settings.local.json is not valid JSON" "...and says the local setting was not read"
setting shared -
base_dir "$P"
assert_eq "$RC:$OUT" "0:$DEFAULT" "an unparseable setting with nothing below it falls back to the default"
assert_has "$ERR" "falling back to the default: $DEFAULT" "...and says so"
setting local '{"permissions": '
base_dir "$P"
assert_eq "$RC:$OUT:$ERR" "0:$DEFAULT:" "a broken file that never mentions the key is not worth a warning"
setting local '{"worktree":{"baseDirectory":42}}'
base_dir "$P"
assert_eq "$OUT" "$DEFAULT" "a non-string value is ignored"
assert_has "$ERR" "is a number, not a path" "...with a warning"
setting local '{"worktree":{"baseDirectory":""}}'
base_dir "$P"
assert_eq "$RC:$OUT:$ERR" "0:$DEFAULT:" "an empty value means unset"
setting local "$(base_json "~someone/wt")"
base_dir "$P"
assert_eq "$OUT" "$DEFAULT" "~user is not expanded"
assert_has "$ERR" "uses ~user" "...and is reported"
setting local '["not", "an", "object", "baseDirectory"]'
base_dir "$P"
assert_eq "$RC:$OUT:$ERR" "0:$DEFAULT:" "a JSON array is a file without the setting"
setting local "$(base_json "$TMP/first") {}"
base_dir "$P"
assert_eq "$OUT" "$DEFAULT" "a file of two JSON documents is not read"
assert_has "$ERR" "more than one JSON document" "...and says why"

setting local "$(base_json "$TMP/ext/wt")"
chmod 000 "$P/.claude/settings.local.json"
if [[ -r "$P/.claude/settings.local.json" ]]; then
  skip "an unreadable settings file (running as root, so it stays readable)"
else
  base_dir "$P"
  assert_eq "$OUT" "$DEFAULT" "an unreadable settings file is skipped"
  assert_has "$ERR" "cannot read .claude/settings.local.json" "...with a warning"
fi
chmod 600 "$P/.claude/settings.local.json"

# A PATH with everything wt-helper calls except jq.
mkdir -p "$TMP/nojq"
for c in bash git grep dirname basename stat cut mkdir find cat sha1sum shasum uname env; do
  p="$(type -P "$c" 2>/dev/null)" && ln -sf "$p" "$TMP/nojq/$c"
done
if PATH="$TMP/nojq" command -v jq >/dev/null 2>&1; then
  not_ok "fixture: the jq-less PATH has no jq"
else
  base_dir "$P" PATH="$TMP/nojq"
  assert_eq "$RC:$OUT" "0:$DEFAULT" "without jq a setting falls back to the default"
  assert_has "$ERR" "jq not found" "...and says jq is missing"
  setting local '{"permissions":{}}'
  base_dir "$P" PATH="$TMP/nojq"
  assert_eq "$RC:$OUT:$ERR" "0:$DEFAULT:" "without jq a file with no setting is silent"
  setting local "$(base_json "$TMP/ext/wt")"
fi

# The env levers stay above the setting, and skip reading it: reading this one would print a warning.
UNPARSEABLE='{"worktree":{"baseDirectory":'
setting local "$UNPARSEABLE"
base_dir "$P" WT_BASE_DIR="$TMP/env-base"
assert_eq "$RC:$OUT:$ERR" "0:$TMP/env-base:" "WT_BASE_DIR beats the setting"
base_dir "$P" WT_LAYOUT=sibling
assert_eq "$RC:$OUT:$ERR" "0:$(dirname "$TOP"):" "WT_LAYOUT=sibling beats the setting"
base_dir "$P" WT_LAYOUT=nested
assert_eq "$RC:$OUT:$ERR" "0:$DEFAULT:" "WT_LAYOUT=nested forces the in-repo default"
base_dir "$P" WT_LAYOUT=nested WT_NESTED_SUBDIR=custom
assert_eq "$OUT" "$TOP/custom" "WT_NESTED_SUBDIR still shapes the nested layout"
setting local "$(base_json "$TMP/ext/wt")"
base_dir "$P" WT_NESTED_SUBDIR=custom
assert_eq "$OUT" "$TMP/ext/wt" "the setting beats WT_NESTED_SUBDIR"
base_dir "$P" WT_LAYOUT=bogus
assert_eq "$OUT" "$TMP/ext/wt" "an unknown WT_LAYOUT is ignored"
assert_has "$ERR" "unknown WT_LAYOUT=bogus" "...with a warning"

# A volume that is not mounted: refused, nothing created, nothing on stdout.
if [[ -n "$UNMOUNTED" ]]; then
  setting local "$(base_json "$UNMOUNTED/wt")"
  base_dir "$P"
  assert_eq "$RC:$OUT" "1:" "a setting on a volume that is not mounted is refused"
  assert_has "$ERR" "is on a volume that is not mounted" "...with a reason"
  assert_has "$ERR" "$UNMOUNTED/wt" "...naming the path"
  make_wt "$P" feat/unmounted
  assert_eq "$RC:$OUT" "1:" "creating a worktree there fails"
  assert_eq "$(git -C "$P" show-ref --verify -q refs/heads/feat/unmounted && echo made || echo none)" "none" "...before any branch is made"
  assert_eq "$([[ -e "$UNMOUNTED" ]] && echo created || echo absent)" "absent" "...and nothing is created on the root disk"
  base_dir "$P" WT_LAYOUT=nested
  assert_eq "$RC:$OUT" "0:$DEFAULT" "WT_LAYOUT=nested is the way past an unmounted volume"
else
  skip "no mount container that is not itself a mount point, so no unmounted volume to test"
fi

# A mounted volume under the same container is accepted. df is the independent judge of what is mounted.
MOUNTED=""
if [[ "$(uname -s)" == Darwin ]]; then candidates=(/Volumes/*); else candidates=(/mnt /media /mnt/* /media/* /media/*/* /run/media/*/*); fi
for v in "${candidates[@]}"; do
  [[ -d "$v" && ! -L "$v" ]] || continue
  [[ "$(df -P "$v" 2>/dev/null | awk 'NR == 2 { print $NF }')" == "$v" ]] && { MOUNTED="$v"; break; }
done
if [[ -n "$MOUNTED" ]]; then
  setting local "$(base_json "$MOUNTED/wt-helper-test-$$/wt")"
  base_dir "$P"
  assert_eq "$RC:$OUT:$ERR" "0:$MOUNTED/wt-helper-test-$$/wt:" "a setting on a mounted volume ($MOUNTED) is accepted"
  assert_eq "$([[ -e "$MOUNTED/wt-helper-test-$$" ]] && echo created || echo absent)" "absent" "...and --print-base-dir leaves it untouched"
else
  skip "no mounted volume under a mount container to test the accepted case"
fi
if [[ -L "/Volumes/Macintosh HD" ]]; then
  setting local "$(base_json "/Volumes/Macintosh HD$TMP/ext/wt")"
  base_dir "$P"
  assert_eq "$RC:$OUT" "0:/Volumes/Macintosh HD$TMP/ext/wt" "/Volumes/Macintosh HD (a symlink to /) is not an unmounted volume"
fi

# The settings are the main checkout's, which is not always the parent of the git dir: from a
# subdirectory git names that dir relative to the cwd, a submodule's git dir is the
# superproject's .git/modules/<name>, and a separate git dir lives anywhere.
mkdir -p "$P/a/b"
setting local "$(base_json "wt-rel")"
base_dir "$P/a/b"
assert_eq "$RC:$OUT" "0:$TOP/wt-rel" "from a subdirectory the repo's setting applies, relative to the repo root"
setting local -
base_dir "$P/a/b"
assert_eq "$RC:$OUT" "0:$DEFAULT" "...and without one, the nested default in the repo root"
G init -q "$TMP/super"
: > "$TMP/super/s"
G -C "$TMP/super" add s
G -C "$TMP/super" commit -qm s
G -c protocol.file.allow=always -C "$TMP/super" submodule add -q "$TMP/origin.git" sub >/dev/null 2>&1
SUB="$(git -C "$TMP/super/sub" rev-parse --show-toplevel)"
base_dir "$SUB"
assert_eq "$RC:$OUT" "0:$SUB/.claude/worktrees" "in a submodule: the nested default is in the submodule"
mkdir -p "$SUB/.claude"
printf '%s\n' "$(base_json "wt-sub")" > "$SUB/.claude/settings.local.json"
base_dir "$SUB"
assert_eq "$RC:$OUT" "0:$SUB/wt-sub" "...and its own setting applies, relative to the submodule"
G -C "$SUB" worktree add -q -b sub-linked "$TMP/sub-linked" >/dev/null 2>&1
base_dir "$TMP/sub-linked"
assert_eq "$RC:$OUT" "0:$SUB/wt-sub" "...from a linked worktree of the submodule too"
G init -q --separate-git-dir="$TMP/sep.git" "$TMP/sep"
SEP="$(git -C "$TMP/sep" rev-parse --show-toplevel)"
mkdir -p "$SEP/.claude"
printf '%s\n' "$(base_json "wt-sep")" > "$SEP/.claude/settings.local.json"
base_dir "$SEP"
assert_eq "$RC:$OUT" "0:$SEP/wt-sep" "with a separate git dir, the checkout's setting applies"

# Real worktrees, all inside the scratch dirs.
setting local "$(base_json "$TMP/ext/wt")"
make_wt "$P" feat/abs
assert_eq "$RC:$OUT" "0:$TMP/ext/wt/feat-abs" "wt creates the worktree under the absolute setting"
assert_eq "$(git -C "$OUT" branch --show-current 2>/dev/null)" "feat/abs" "...on the new branch"
assert_eq "$(cd "$(git -C "$OUT" rev-parse --git-common-dir)" && pwd -P)" "$(cd "$TOP/.git" && pwd -P)" "...as a worktree of the scratch repo"
assert_has "$ERR" "layout:  worktree.baseDirectory in .claude/settings.local.json" "...and the header says why it went there"
LINKED="$OUT"
base_dir "$LINKED"
assert_eq "$OUT" "$TMP/ext/wt" "from inside a linked worktree the main repo's setting applies"
setting local "$(base_json "wt-rel")"
make_wt "$P" feat/rel
assert_eq "$RC:$OUT" "0:$TOP/wt-rel/feat-rel" "wt creates the worktree under the relative setting"
# shellcheck disable=SC2088  # the setting holds a literal ~ for wt-helper to expand
setting local "$(base_json "~/wt-home")"
make_wt "$P" feat/home
assert_eq "$RC:$OUT" "0:$HOME/wt-home/feat-home" "wt creates the worktree under the ~ setting"
setting local '{"worktree":{"baseDirectory":'
make_wt "$P" feat/fallback
assert_eq "$RC:$OUT" "0:$DEFAULT/feat-fallback" "an unreadable setting still makes the worktree, in the default place"
assert_has "$ERR" "falling back to the default" "...after saying so"
setting local "$UNPARSEABLE"
make_wt "$P" feat/target -- --target "$TMP/explicit/feat-target"
assert_eq "$RC:$OUT" "0:$TMP/explicit/feat-target" "--target needs no setting, even an unreadable one"
assert_eq "$(printf '%s' "$ERR" | grep -c 'wt: ')" "0" "...and does not read it (no setting warnings)"

# ── git worktree prune and volumes that are not mounted ──────────────
# A worktree whose record points at a missing path normally gets pruned. But one on a volume that is not mounted
# is only missing until the volume is back. `git worktree prune` on every wt run made git forget every
# worktree on an unplugged drive, so the next wt run skips prune while any such worktree is registered.
# register <repo> <name> <path> records worktree reg-<name> at <path>, which does not exist.
register() {
  G -C "$1" worktree add -q -b "reg-$2" "$TMP/reg-$2" >/dev/null 2>&1
  printf '%s/.git\n' "$3" > "$1/.git/worktrees/reg-$2/gitdir"
  rm -rf "$TMP/reg-$2"
}
record() { [[ -d "$1/.git/worktrees/reg-$2" ]] && echo kept || echo pruned; }
new_repo() { G init -q "$1" && : > "$1/f" && G -C "$1" add f && G -C "$1" commit -qm r1; }
skips() { printf '%s\n' "$ERR" | grep -c 'skipped git worktree prune'; }
mkdir -p "$TMP/links"

if [[ -n "$UNMOUNTED" ]]; then
  R="$TMP/prune-unmounted"
  new_repo "$R"
  RTOP="$(git -C "$R" rev-parse --show-toplevel)"
  register "$R" direct "$UNMOUNTED/wt/direct"
  ln -s "$UNMOUNTED/wt/linked" "$TMP/links/linked"
  register "$R" linked "$TMP/links/linked"
  register "$R" stale "$TMP/gone/stale"
  make_wt "$R" feat/unplugged
  assert_eq "$RC:$OUT" "0:$RTOP/.claude/worktrees/feat-unplugged" "wt still makes a worktree while one is on a volume that is not mounted"
  assert_eq "$(record "$R" direct)" "kept" "...and the worktree recorded on that volume keeps its record"
  assert_eq "$(record "$R" linked)" "kept" "...as does one recorded at a symlink into that volume"
  assert_eq "$(record "$R" stale)" "kept" "...and prune waits, so a stale record elsewhere stays for now"
  assert_eq "$(skips)" "1" "...with one note that prune was skipped"
  assert_has "$ERR" "2 worktrees are on a volume that is not mounted (one is " "...saying how many and why"
  named="${ERR#*(one is }" named="${named%%)*}"   # git lists worktrees in directory order, so either may come first
  case "$named" in
    "$UNMOUNTED/wt/direct" | "$TMP/links/linked") ok "...naming one of them" ;;
    *) not_ok "...naming one of them (got [$named])" ;;
  esac
  assert_eq "$(git -C "$R" worktree list --porcelain | grep -cxF -e "worktree $UNMOUNTED/wt/direct" -e "worktree $TMP/links/linked")" "2" "...so git still lists both"
  G -C "$R" worktree lock --reason "on a drive" "$UNMOUNTED/wt/direct"
  make_wt "$R" feat/unplugged-2
  assert_eq "$(skips)" "1" "one unlocked worktree on such a volume still makes wt skip prune"
  assert_has "$ERR" "the worktree at $TMP/links/linked is on a volume that is not mounted" "...naming it"
  G -C "$R" worktree lock --reason "on a drive" "$TMP/links/linked"
  make_wt "$R" feat/locked
  assert_eq "$RC:$(skips)" "0:0" "locked worktrees on such a volume do not stop prune (prune keeps locked ones)"
  assert_eq "$(record "$R" stale)" "pruned" "...so the stale record goes"
  assert_eq "$(record "$R" direct):$(record "$R" linked)" "kept:kept" "...and the locked ones stay"
else
  skip "no mount container that is not itself a mount point, so no unmounted volume to test prune against"
fi

# Missing worktrees that are not on an unmounted volume are pruned as before: on the root disk, behind a
# relative symlink to nowhere there, and (when this host has one) on a volume that is mounted.
R="$TMP/prune-mounted"
new_repo "$R"
register "$R" stale "$TMP/gone/stale"
ln -s ../gone/rel "$TMP/links/rel"
register "$R" rel "$TMP/links/rel"
[[ -n "$MOUNTED" ]] && register "$R" vol "$MOUNTED/wt-helper-test-$$/gone/vol"
make_wt "$R" feat/plugged
assert_eq "$RC:$(skips)" "0:0" "with no worktree on an unmounted volume, wt prunes without a note"
assert_eq "$(record "$R" stale):$(record "$R" rel)" "pruned:pruned" "...dropping stale records, a dangling symlink's too"
if [[ -n "$MOUNTED" ]]; then
  assert_eq "$(record "$R" vol)" "pruned" "...and a missing worktree on a mounted volume ($MOUNTED)"
  assert_eq "$([[ -e "$MOUNTED/wt-helper-test-$$" ]] && echo created || echo absent)" "absent" "...without creating anything there"
else
  skip "no mounted volume under a mount container to prune a missing worktree on"
fi

printf '# pass=%d fail=%d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
