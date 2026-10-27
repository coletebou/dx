#!/usr/bin/env bash
# pw.test.sh: pw puts its worktrees where wt-helper says (wt-helper --print-base-dir),
# so a repo's worktree.baseDirectory setting, which once only `wt` would have
# honored, moves pw's worktrees too, and a setting on a volume that is not mounted
# stops a launch before anything is created. Teardown removes the worktrees where
# launch recorded them, even after the setting moved, and those of a run in the other
# mode, but never a directory git does not list as a worktree of the repo, nor one a
# line appended to the log names. Hermetic: a scratch origin and
# clone, HOME in a temp dir (pw's logs, wt-helper's cache), a private tmux server (its
# own TMUX_TMPDIR, no config, /bin/sh panes) and a fake `claude`, pinned through
# PW_ENGINE and PW_CLAUDE_CMD and checked to be what runs, so nothing touches the
# user's repos, tmux or sessions or starts a real agent. Uses this repo's own
# scripts/wt-helper (put first on PATH). Also: the transcript path pw records
# matches Claude Code's encoding, PW_BOOTSTRAP_HOOK runs (and a failing one only
# warns), PW_NPM_INSTALL=0 skips npm, and a dry-run broadcast lists every
# window and types into none.
#
#   bash scripts/tests/pw.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
pw="$root/plugins/worktrees/bin/pw"
export PATH="$root/scripts:$PATH"
tmp="$(mktemp -d)"
# A never-mounted volume: a fresh name under a mount container that is not itself
# a mount point (on some Linux hosts /mnt is a disk).
unmounted=""
for c in /Volumes /mnt /media /run/media; do
  [[ -d "$c" && ! -L "$c" ]] || continue
  [[ "$(df -P "$c" 2>/dev/null | awk 'NR == 2 { print $NF }')" == "$c" ]] && continue
  unmounted="$c/pw-test-$$-$RANDOM"
  break
done
export TMUX_TMPDIR="$tmp/sock" HOME="$tmp/home" SHELL=/bin/sh GIT_CONFIG_NOSYSTEM=1
mkdir -p "$TMUX_TMPDIR" "$HOME" "$tmp/bin"
unset TMUX WT_BASE_DIR WT_LAYOUT WT_NESTED_SUBDIR XDG_CONFIG_HOME
trap 'tmux kill-server 2>/dev/null; rm -rf "$tmp"; [[ -n "$unmounted" && -d "$unmounted" ]] && rm -rf "$unmounted"' EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# Without tmux or wt-helper there is nothing to run. CI sets PW_TEST_REQUIRE_DEPS=1, so a
# missing one fails the run there instead of passing it as a skip.
missing() {
  if [[ "${PW_TEST_REQUIRE_DEPS:-0}" == 1 ]]; then echo "FAIL: $1"; exit 1; fi
  echo "skip: $1"
  exit 0
}
command -v tmux >/dev/null 2>&1 || missing "tmux not installed"
command -v wt-helper >/dev/null 2>&1 || missing "scripts/wt-helper not found"
help="$(wt-helper --help 2>&1 || true)"
[[ "$help" == *--print-base-dir* ]] || { echo "FAIL: wt-helper on PATH predates --print-base-dir"; exit 1; }

# The fake claude is the only agent that may start, whatever the caller exports: an inherited
# PW_ENGINE=codex or PW_CLAUDE_CMD (a wrapper or an absolute path) would start a real one in
# every window. It logs each run, so the test can see it is what ran.
calls="$tmp/claude-calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexit 0\n' "'$calls'" > "$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH" PW_ENGINE=claude PW_CLAUDE_CMD="$tmp/bin/claude"
unset PW_CODEX_MODEL PW_CODEX_EFFORT PW_CODEX_SANDBOX
# stub_runs N: how many times the fake claude has run, after waiting (10 s at most) for N.
stub_runs() {
  local i n=0
  for ((i = 0; i < 50; i++)); do
    n="$(cat "$calls" 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$n" -ge "$1" ]] && break
    sleep 0.2
  done
  printf '%s' "$n"
}

G() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=master "$@"; }
G init -q --bare "$tmp/origin.git"
G init -q "$tmp/seed"
: > "$tmp/seed/f"
G -C "$tmp/seed" add f
G -C "$tmp/seed" commit -qm c1
G -C "$tmp/seed" push -q "$tmp/origin.git" master
G clone -q "$tmp/origin.git" "$tmp/proj"
repo="$tmp/proj"
prepo="$(cd "$repo" && pwd -P)"   # the physical path pw and wt-helper report
mkdir -p "$repo/.claude"
setting() { printf '{"worktree":{"baseDirectory":"%s"}}\n' "$1" > "$repo/.claude/settings.local.json"; }
manifest() { printf '%s\tfeat/%s\tnothing to do\n' "$2" "$2" > "$tmp/$1.tsv"; }
# wt-helper writes to /dev/tty when there is one: detach so its messages reach the captured stderr.
detached() {
  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX=setsid -e 'setsid(); exec @ARGV or die "exec $ARGV[0]: $!\n"' -- "$@"
  else
    "$@"
  fi
}
in_repo() { (cd "$repo" && detached env "$@"); }
session_up() { tmux has-session -t "=proj-parallel" 2>/dev/null && echo up || echo down; }

echo "worktree.baseDirectory moves pw's worktrees"
setting "$tmp/ext"
manifest one alpha
out="$(in_repo "$pw" launch "$tmp/one.tsv" --no-bootstrap 2>&1)"
equal "launch succeeds" 0 "$?"
equal "the worktree is <setting>/<repo>-<tag>" "feat/alpha" "$(git -C "$tmp/ext/proj-alpha" branch --show-current 2>&1)"
check "the merged log records that path" "worktree=$tmp/ext/proj-alpha" "$(cat "$(cat "$tmp/one.tsv.log-path")")"
equal "the agent window opens there" "$(cd "$tmp/ext/proj-alpha" && pwd -P)" \
  "$(cd "$(tmux display-message -p -t "=proj-parallel:alpha" '#{pane_current_path}')" && pwd -P)"
equal "nothing lands inside the repo" "absent" "$([[ -e "$repo/.claude/worktrees" ]] && echo present || echo absent)"
equal "the agent window runs the fake claude" 1 "$(stub_runs 1)"
check "...with the session id launch recorded" "--session-id $(awk '/^#   session_id=/ { sub(/^#   session_id=/, ""); print; exit }' "$(cat "$tmp/one.tsv.log-path")")" "$(cat "$calls")"

out="$(in_repo "$pw" teardown "$tmp/one.tsv" 2>&1)"
equal "teardown succeeds" 0 "$?"
check "teardown removes the worktree at the setting's path" "Removing worktree $tmp/ext/proj-alpha" "$out"
equal "the worktree is gone" "gone" "$([[ -e "$tmp/ext/proj-alpha" ]] && echo present || echo gone)"
equal "the session is gone" "down" "$(session_up)"
out="$(in_repo "$pw" teardown "$tmp/one.tsv" 2>&1)"
equal "a second teardown finds nothing" 1 "$?"
check "...having looked at the setting's path" "tried worktree $tmp/ext/proj-alpha" "$out"

echo "the env levers still win"
manifest two beta
out="$(in_repo WT_LAYOUT=nested "$pw" launch "$tmp/two.tsv" --no-bootstrap 2>&1)"
equal "WT_LAYOUT=nested launch succeeds" 0 "$?"
equal "WT_LAYOUT=nested keeps the worktree in the repo" "feat/beta" \
  "$(git -C "$prepo/.claude/worktrees/proj-beta" branch --show-current 2>&1)"
enc="$(printf '%s' "$prepo/.claude/worktrees/proj-beta" | sed 's/[^A-Za-z0-9]/-/g')"
check "the transcript path encodes every non-alphanumeric as Claude Code does" \
  "transcript=$HOME/.claude/projects/$enc/" "$(cat "$(cat "$tmp/two.tsv.log-path")")"
nwin="$(tmux list-windows -t "=proj-parallel" 2>/dev/null | wc -l | tr -d ' ')"
out="$(in_repo "$pw" broadcast proj-parallel "hello" --dry-run 2>&1)"
equal "a dry-run broadcast succeeds" 0 "$?"
check "...listing every window of the session" "proj-parallel, $nwin window(s)" "$out"
check "...and typing into none of the shell panes" "0 engaged, $nwin skipped" "$out"
out="$(in_repo WT_LAYOUT=nested "$pw" teardown "$tmp/two.tsv" 2>&1)"
check "teardown with the same lever finds it" "Removing worktree $prepo/.claude/worktrees/proj-beta" "$out"

echo "PW_BOOTSTRAP_HOOK runs in each new worktree"
setting "$tmp/ext"
manifest hook iota
# shellcheck disable=SC2016  # expanded by the hook's own shell, not here
out="$(in_repo PW_BOOTSTRAP_HOOK='printf "%s|%s|%s\n" "$PW_TAG" "$PWD" "$PW_SOURCE_REPO" > hook-ran' \
  "$pw" launch "$tmp/hook.tsv" 2>&1)"
equal "a bootstrapped launch succeeds" 0 "$?"
equal "the hook ran in the worktree, with its tag and the source repo" \
  "iota|$(cd "$tmp/ext/proj-iota" && pwd -P)|$prepo" "$(cat "$tmp/ext/proj-iota/hook-ran" 2>&1)"
check "bootstrap still writes .envrc" "COMPOSE_PROJECT_NAME=proj-iota" "$(cat "$tmp/ext/proj-iota/.envrc" 2>&1)"
out="$(in_repo "$pw" teardown "$tmp/hook.tsv" 2>&1)"
manifest hookfail kappa
out="$(in_repo PW_BOOTSTRAP_HOOK='exit 3' "$pw" launch "$tmp/hookfail.tsv" 2>&1)"
equal "a failing hook does not stop the launch" 0 "$?"
check "...but says so" "PW_BOOTSTRAP_HOOK failed" "$out"
out="$(in_repo "$pw" teardown "$tmp/hookfail.tsv" 2>&1)"

echo "PW_NPM_INSTALL=0 leaves the install to the hook"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\n' "'$tmp/npm-calls'" > "$tmp/bin/npm"
chmod +x "$tmp/bin/npm"
printf '{"name":"proj"}\n' > "$repo/package.json"
G -C "$repo" add package.json && G -C "$repo" commit -qm pkg && G -C "$repo" push -q origin master
manifest npm1 lambda
out="$(in_repo "$pw" launch "$tmp/npm1.tsv" 2>&1)"
equal "with a package.json, bootstrap runs npm install" "install --prefer-offline --no-audit --no-fund --legacy-peer-deps" \
  "$(cat "$tmp/npm-calls" 2>&1)"
out="$(in_repo "$pw" teardown "$tmp/npm1.tsv" 2>&1)"
: > "$tmp/npm-calls"
manifest npm0 mu
out="$(in_repo PW_NPM_INSTALL=0 PW_BOOTSTRAP_HOOK='echo bun > installed-by' "$pw" launch "$tmp/npm0.tsv" 2>&1)"
equal "PW_NPM_INSTALL=0 launch succeeds" 0 "$?"
equal "...without running npm" "" "$(cat "$tmp/npm-calls" 2>&1)"
equal "...while the hook still runs" "bun" "$(cat "$tmp/ext/proj-mu/installed-by" 2>&1)"
out="$(in_repo "$pw" teardown "$tmp/npm0.tsv" 2>&1)"

echo "teardown removes the worktrees where launch put them"
setting "$tmp/ext"
manifest four delta
out="$(in_repo "$pw" launch "$tmp/four.tsv" --no-bootstrap 2>&1)"
equal "launch succeeds" 0 "$?"
# The setting moves on, and the new place already has a directory of that name.
setting "$tmp/ext2"
mkdir -p "$tmp/ext2/proj-delta"
: > "$tmp/ext2/proj-delta/keep"
out="$(in_repo "$pw" teardown "$tmp/four.tsv" 2>&1)"
equal "teardown succeeds" 0 "$?"
check "...removing the worktree at the path launch recorded" "Removing worktree $tmp/ext/proj-delta" "$out"
equal "...which is gone" "gone" "$([[ -e "$tmp/ext/proj-delta" ]] && echo present || echo gone)"
equal "...while the same-named directory at the new place stays" "present" "$([[ -e "$tmp/ext2/proj-delta/keep" ]] && echo present || echo gone)"
gone() { [[ -e "$1" ]] && echo present || echo gone; }

echo "teardown removes the worktrees of both modes of a manifest"
setting "$tmp/ext"
manifest five eps
out="$(in_repo "$pw" launch "$tmp/five.tsv" --test --no-bootstrap 2>&1)"
equal "a --test launch succeeds" 0 "$?"
out="$(in_repo "$pw" launch "$tmp/five.tsv" --no-bootstrap 2>&1)"
equal "...and then a real one, whose log the sidecar now names" 0 "$?"
out="$(in_repo "$pw" teardown "$tmp/five.tsv" 2>&1)"
equal "teardown succeeds" 0 "$?"
equal "...removing the real run's worktree" "gone" "$(gone "$tmp/ext/proj-eps")"
equal "...and the test run's" "gone" "$(gone "$tmp/ext/proj-test-eps")"

echo "teardown goes by the launch header alone, and removes only worktrees of the repo"
manifest six zeta
out="$(in_repo "$pw" launch "$tmp/six.tsv" --no-bootstrap 2>&1)"
equal "launch succeeds" 0 "$?"
mkdir -p "$tmp/precious"
: > "$tmp/precious/keep"
# What an agent appends to the log through pw-append, not launch.
printf '# tag=zeta branch=feat/zeta worktree=%s\n' "$tmp/precious" >> "$(cat "$tmp/six.tsv.log-path")"
out="$(in_repo "$pw" teardown "$tmp/six.tsv" 2>&1)"
equal "teardown succeeds" 0 "$?"
equal "...removing the launched worktree" "gone" "$(gone "$tmp/ext/proj-zeta")"
equal "...but not a directory a line appended to the log names" "present" "$(gone "$tmp/precious/keep")"

echo "without the launch record teardown looks where the layout says"
manifest seven eta
out="$(in_repo "$pw" launch "$tmp/seven.tsv" --no-bootstrap 2>&1)"
equal "launch succeeds" 0 "$?"
rm -f "$tmp/seven.tsv.log-path"
out="$(in_repo "$pw" teardown "$tmp/seven.tsv" 2>&1)"
equal "teardown succeeds" 0 "$?"
check "...removing the worktree at the layout's path" "Removing worktree $tmp/ext/proj-eta" "$out"
if [[ -n "$unmounted" ]]; then
  manifest eight theta
  out="$(in_repo "$pw" launch "$tmp/eight.tsv" --no-bootstrap 2>&1)"
  setting "$unmounted/wt"
  out="$(in_repo "$pw" teardown "$tmp/eight.tsv" 2>&1)"
  equal "with the record, a setting on a volume that is not mounted does not stop teardown" 0 "$?"
  equal "...which removes what launch recorded" "gone" "$(gone "$tmp/ext/proj-theta")"
  check "...and says it looked nowhere else" "removing only the worktrees the launch recorded" "$out"
fi

echo "a setting on a volume that is not mounted stops the launch"
if [[ -n "$unmounted" ]]; then
  setting "$unmounted/wt"
  manifest three gamma
  out="$(in_repo "$pw" launch "$tmp/three.tsv" --no-bootstrap 2>&1)"
  equal "launch fails" 1 "$?"
  check "wt-helper says why" "is on a volume that is not mounted" "$out"
  check "pw says what it was doing" "could not say where worktrees go" "$out"
  equal "no tmux session was started" "down" "$(session_up)"
  equal "no run log was recorded" "none" "$([[ -e "$tmp/three.tsv.log-path" ]] && echo written || echo none)"
  equal "no branch was made" "none" "$(git -C "$repo" show-ref --verify -q refs/heads/feat/gamma && echo made || echo none)"
  equal "nothing was created on the root disk" "absent" "$([[ -e "$unmounted" ]] && echo created || echo absent)"
else
  echo "  skip no mount container that is not itself a mount point"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
