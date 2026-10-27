#!/usr/bin/env bash
# dotsync.test.sh: dotsync across a small fleet of throwaway machines, for real.
#
# A bare repository is the origin. Each machine is a throwaway HOME holding a clone of this
# checkout (as it is on disk, uncommitted work included) at ~/.dotfiles, a ~/.df-profile, and
# the sync component installed by the real install.sh. A fake `ssh` maps the aliases box-b,
# box-other and box-hang to their HOMEs and runs the command there with nothing but that HOME's
# environment; any other alias is unreachable. So box-a's fan-out really runs box-b's dotsync.
# Network tools dotsync must never call here (tailscale, rsync, curl, ...) are guards that log
# and fail; systemctl and launchctl only answer the timer query `dotsync status` makes. Needs
# git, python3 and gitleaks (the secret gate runs for real).
#
#   bash scripts/tests/dotsync.test.sh
#   DOTSYNC_TEST_ONLY="basic secret" bash scripts/tests/dotsync.test.sh    (some sections only:
#     basic background identity secret pause session replace hang conflict readonly)
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "# SKIP gitleaks is not installed (dotsync's secret gate needs it; CI installs it)"
  exit 0
fi
in_repo=0
command git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_repo=1
before_status="$([[ "$in_repo" -eq 0 ]] || (cd "$root" && command git status --porcelain))"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/dotsync-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
cleanup() {
  local pid
  for pid in $(cat "$tmp"/*/hang.pid 2>/dev/null); do kill "$pid" 2>/dev/null || true; done
  if [[ -n "${DOTSYNC_TEST_KEEP:-}" ]]; then echo "# kept $tmp"; else rm -rf "$tmp"; fi
}
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
differ() { if [[ "$3" != "$2" ]]; then ok "$1"; else bad "$1" "not $2" "$3"; fi; }
want() { [[ -z "${DOTSYNC_TEST_ONLY:-}" || " $DOTSYNC_TEST_ONLY " == *" $1 "* ]]; }

# The harness's own git commands ignore this box's git config and hooks.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
hg() { command git -c user.name=harness -c user.email=harness@example.com -c commit.gpgsign=false "$@"; }
# A fingerprint of every file under a directory: path, size and modification time.
snapshot() {
  python3 -c '
import hashlib, os, sys
h = hashlib.sha256()
for base, dirs, files in sorted(os.walk(sys.argv[1])):
    dirs.sort()
    for name in sorted(files):
        st = os.lstat(os.path.join(base, name))
        h.update(("%s %d %d\n" % (os.path.join(base, name), st.st_size, st.st_mtime_ns)).encode())
print(h.hexdigest())' "$1"
}

# ── the tools every machine sees ─────────────────────────────────────────
# The real PATH without any directory holding a dotsync (this box's own must never run here).
base_path=""
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [[ -n "$d" && -d "$d" && ! -e "$d/dotsync" ]] || continue
  base_path="${base_path:+$base_path:}$d"
done
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
for t in tailscale rsync scp curl wget claude codex osascript notify-send brew; do
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s/forbidden"\nexit 99\n' "$t" "$tmp" >"$fakebin/$t"
  chmod +x "$fakebin/$t"
done
for t in systemctl launchctl; do
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s/scheduler"\necho inactive\nexit 3\n' "$t" "$tmp" >"$fakebin/$t"
  chmod +x "$fakebin/$t"
done
cat >"$fakebin/ssh" <<'EOF'
#!/bin/bash
# The fake network: an alias with a HOME under $FAKE_SSH_ROOT is a machine; anything else is
# unreachable. Each connection's command and script are logged per machine.
while [ $# -gt 0 ]; do
  case "$1" in
    -[opilFEcJSbmwLRDOQW]) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
host="${1:-}"; shift
case "$host" in
  box-b|box-other|box-hang|box-gone) peer="$FAKE_SSH_ROOT/$host" ;;
  *) echo "ssh: Could not resolve hostname $host: Name or service not known" >&2; exit 255 ;;
esac
[ -d "$peer" ] || { echo "ssh: connect to host $host port 22: Connection refused" >&2; exit 255; }
input="$(cat)"
printf '%s\n---\n%s\n===\n' "$*" "$input" >>"$FAKE_SSH_ROOT/ssh-$host.log"
printf '%s\n' "$input" | exec env -i HOME="$peer" PATH="$FAKE_PEER_PATH" TMPDIR="$peer/tmp" LANG=C \
  GIT_CONFIG_NOSYSTEM=1 DOTSYNC_NOTIFY=0 /bin/sh -c "$*"
EOF
chmod +x "$fakebin/ssh"
machine_path="$fakebin:$base_path"
# The same tools without gitleaks, for the fail-closed check.
nogl="$tmp/no-gitleaks-bin"
mkdir -p "$nogl"
for d in "${path_dirs[@]}"; do
  [[ -n "$d" && -d "$d" && ! -e "$d/dotsync" ]] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    [[ "$n" != gitleaks && -x "$f" && ! -e "$nogl/$n" ]] && ln -s "$f" "$nogl/$n"
  done
done

# on NAME COMMAND...: run on a machine, with only its own environment.
on() {
  local h="$tmp/$1"
  shift
  env -i HOME="$h" PATH="${ON_PATH:-$machine_path}" TMPDIR="$h/tmp" LANG=C GIT_CONFIG_NOSYSTEM=1 \
    DOTSYNC_NOTIFY=0 FAKE_SSH_ROOT="$tmp" FAKE_PEER_PATH="$machine_path" "$@"
}
dotsync_on() {  # dotsync_on NAME [VAR=value ...] ARGS...: that machine's installed dotsync
  local name="$1" vars=()
  shift
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  on "$name" ${vars[@]+"${vars[@]}"} "$tmp/$name/.local/bin/dotsync" "$@" 2>&1
}
g() { local name="$1"; shift; on "$name" git -C "$tmp/$name/.dotfiles" "$@"; }
origin_head() { command git -C "$tmp/origin.git" rev-parse master; }
origin_show() { command git -C "$tmp/origin.git" show "master:$1"; }
gone() { [[ -e "$1" ]] && echo present || echo absent; }

# ── the fleet ────────────────────────────────────────────────────────────
echo "the fleet"
seed="$tmp/seed"
mkdir -p "$seed"
if [[ "$in_repo" -eq 1 ]]; then
  (cd "$root" && command git ls-files -co --exclude-standard -z | xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$seed"
else
  (cd "$root" && tar --exclude=./.git -cf - .) | tar -xf - -C "$seed"
fi
cp -R "$seed/identities/example" "$seed/identities/other"
hg -C "$seed" init -q -b master
hg -C "$seed" add -A
hg -C "$seed" commit -q -m "seed"
hg init -q --bare -b master "$tmp/origin.git"
hg -C "$seed" push -q "$tmp/origin.git" master

mkmachine() {  # mkmachine NAME IDENTITY
  local h="$tmp/$1"
  mkdir -p "$h/tmp" "$h/.config/dotsync"
  printf '[user]\n\tname = %s\n\temail = %s@example.com\n[commit]\n\tgpgsign = false\n' "$1" "$1" >"$h/.gitconfig"
  printf 'export DF_MACHINE=%s\nexport DF_IDENTITY=%s\nexport DF_ROLE=local\n' "$1" "$2" >"$h/.df-profile"
  on "$1" git clone -q "$tmp/origin.git" "$h/.dotfiles"
  on "$1" bash "$h/.dotfiles/install.sh" --with sync >"$h/tmp/install-first.log" 2>&1
}
mkmachine box-a example
mkmachine box-b example
mkmachine box-other other
mkmachine box-hang example
A="$tmp/box-a" B="$tmp/box-b"
equal "install.sh --with sync links dotsync into ~/.local/bin" "$B/.dotfiles/scripts/dotsync" \
  "$(readlink "$B/.local/bin/dotsync")"
check "...and records the component for --installed" "sync" "$(cat "$B/.local/state/dx/components" 2>&1)"
# box-hang answers the identity probe, then its dotsync never returns.
rm -f "$tmp/box-hang/.local/bin/dotsync"
printf '#!/bin/sh\necho $$ > "$HOME/hang.pid"\nexec sleep 300\n' >"$tmp/box-hang/.local/bin/dotsync"
chmod +x "$tmp/box-hang/.local/bin/dotsync"
peers() { printf '%s\n' "$@" >"$A/.config/dotsync/peers"; }

# ── a change on one machine reaches the other ────────────────────────────
if want basic; then
echo "a change on box-a reaches box-b in one run"
peers "# my machines" "box-b"
printf 'hello from box-a\n' >"$A/.dotfiles/base/e2e-note.txt"
before_b="$(g box-b rev-parse HEAD)"
out="$(dotsync_on box-a --wait)"; rc=$?
equal "dotsync --wait succeeds" 0 "$rc"
equal "box-a's commit is on the origin" "$(g box-a rev-parse HEAD)" "$(origin_head)"
equal "...with the generic subject naming the machine and the area" "chore(sync): box-a update base" \
  "$(command git -C "$tmp/origin.git" log -1 --format=%s master)"
equal "box-b pulled it" "$(origin_head)" "$(g box-b rev-parse HEAD)"
differ "...moving box-b's checkout" "$before_b" "$(g box-b rev-parse HEAD)"
equal "...file and all" "hello from box-a" "$(cat "$B/.dotfiles/base/e2e-note.txt" 2>&1)"
check "box-b's run is reported" "box-b: result=ok exit=0" "$out"
check "install.sh reran on box-b, from box-b's checkout" "Installing from $B/.dotfiles" \
  "$(cat "$B/.local/state/dotsync/install.log" 2>&1)"
check "...with the components box-b installed" "): sync" "$(cat "$B/.local/state/dotsync/install.log" 2>&1)"
hb_a="$(cat "$A/.local/state/dotsync/heartbeat.json" 2>&1)"
hb_b="$(cat "$B/.local/state/dotsync/heartbeat.json" 2>&1)"
check "box-a wrote its heartbeat" '"host":"box-a"' "$hb_a"
check "...ok" '"result":"ok"' "$hb_a"
check "box-b wrote its heartbeat, triggered by box-a" '"triggered_by":"box-a"' "$hb_b"
equal "both heartbeats are published on the origin" "refs/dotsync/heartbeats/box-a refs/dotsync/heartbeats/box-b" \
  "$(command git -C "$tmp/origin.git" for-each-ref --format='%(refname)' refs/dotsync/heartbeats | tr '\n' ' ' | sed 's/ $//')"
status="$(dotsync_on box-a status)"
check "dotsync status on box-a shows box-a" "box-a " "$status"
check "...marked as this machine" "(this machine)" "$status"
check "...and box-b, from its published heartbeat" "box-b " "$status"
equal "...both ok" 2 "$(printf '%s\n' "$status" | grep -cE '^  box-(a|b) .* ok')"
lacks "...nothing stale" "STALE" "$status"
status_b="$(dotsync_on box-b status --refresh)"
check "box-b sees box-a's heartbeat after a refresh" "box-a " "$status_b"
fi

# ── the default: peers update in the background ──────────────────────────
if want background; then
echo "a manual run returns before the peers, which finish in the background"
peers "box-b"
printf 'second change\n' >>"$A/.dotfiles/base/e2e-note.txt"
out="$(dotsync_on box-a)"; rc=$?
equal "dotsync succeeds" 0 "$rc"
check "...and says the peers update in the background" "peers updating in the background" "$out"
for _ in $(seq 1 240); do
  [[ -s "$A/.local/state/dotsync/fanout-result" ]] && break
  sleep 0.5
done
check "the background fan-out records its result" "result=ok incomplete=0 dispatched=1" \
  "$(cat "$A/.local/state/dotsync/fanout-result" 2>&1)"
equal "box-b caught up" "$(origin_head)" "$(g box-b rev-parse HEAD)"
check "dotsync status reports the finished fan-out" "fan-out:   last finished" "$(dotsync_on box-a status)"
out="$(dotsync_on box-a --local)"; rc=$?
equal "the background child released the lock" 0 "$rc"
fi

# ── another identity is never synced ─────────────────────────────────────
if want identity; then
echo "a peer with another identity is skipped and never written to"
peers "box-b" "box-other"
other_before="$(snapshot "$tmp/box-other")"
: >"$tmp/ssh-box-other.log"
printf 'third change\n' >>"$A/.dotfiles/base/e2e-note.txt"
out="$(dotsync_on box-a --wait)"; rc=$?
equal "the run succeeds (a policy skip is not a failure)" 0 "$rc"
check "box-other is reported as skipped" "box-other: skipped (identity other differs from example)" "$out"
equal "box-other's home, checkout included, is untouched" "$other_before" "$(snapshot "$tmp/box-other")"
check "box-other was only asked for its profile" "DF_IDENTITY DF_MACHINE" "$(cat "$tmp/ssh-box-other.log")"
lacks "...its dotsync never ran" "--one-line" "$(cat "$tmp/ssh-box-other.log")"
equal "...and it holds no dotsync state" "absent" "$(gone "$tmp/box-other/.local/state/dotsync")"
out="$(dotsync_on box-a --host box-other)"; rc=$?
check "naming it with --host does not override the identity check" "box-other: skipped (identity other" "$out"
# The receiving side guards too: a peer command sent anyway refuses before anything runs.
script="$(on box-a bash -c 'source "$1/scripts/lib/dotsync-runtime.sh"; dotsync_peer_script "$2" example box-a "\$HOME/.local/bin/dotsync"' \
  _ "$A/.dotfiles" "$(origin_head)")"
rc=0; printf '%s\n' "$script" | on box-a ssh box-other sh -s >/dev/null 2>&1 || rc=$?
equal "the peer command itself refuses a peer of another identity (exit 4)" 4 "$rc"
equal "...still without running anything there" "absent" "$(gone "$tmp/box-other/.local/state/dotsync")"
equal "...or touching anything" "$other_before" "$(snapshot "$tmp/box-other")"
fi

# ── the secret gate ──────────────────────────────────────────────────────
if want secret; then
echo "a secret-shaped change is refused, and nothing is pushed"
peers "box-b"
token="ghp_$(python3 -c 'import secrets, string; print("".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36)))')"
printf 'export GITHUB_TOKEN=%s\n' "$token" >"$A/.dotfiles/base/leaky.env.sh"
origin_before="$(origin_head)" a_before="$(g box-a rev-parse HEAD)" b_before="$(g box-b rev-parse HEAD)"
out="$(dotsync_on box-a --wait)"; rc=$?
equal "the run fails" 1 "$rc"
check "...at the secret scan" "phase=secret-scan" "$out"
check "...saying gitleaks found it" "gitleaks found a potential secret" "$out"
lacks "...without printing the secret" "$token" "$out"
equal "nothing was committed on box-a" "$a_before" "$(g box-a rev-parse HEAD)"
equal "nothing was pushed" "$origin_before" "$(origin_head)"
equal "box-b was not contacted" "$b_before" "$(g box-b rev-parse HEAD)"
equal "the change is still in box-a's working tree, unstaged" "?? base/leaky.env.sh" "$(g box-a status --porcelain)"
# A commit made by hand with every hook skipped is scanned again before any push.
g box-a add base/leaky.env.sh
g box-a -c core.hooksPath=/dev/null commit -q --no-verify -m "a hand-made commit"
out="$(dotsync_on box-a --local)"; rc=$?
equal "a hand-made commit holding a secret is not pushed" "$origin_before" "$(origin_head)"
check "...the push is refused at the secret scan" "refusing to push" "$out"
equal "...exit 1" 1 "$rc"
lacks "...and the secret is not printed" "$token" "$out"
g box-a reset -q --hard "$origin_before"
printf 'harmless\n' >>"$A/.dotfiles/base/e2e-note.txt"
out="$(ON_PATH="$fakebin:$nogl" dotsync_on box-a --local)"; rc=$?
equal "without gitleaks the gate fails closed" 1 "$rc"
check "...saying gitleaks is required" "gitleaks is required" "$out"
equal "...and pushes nothing" "$origin_before" "$(origin_head)"
g box-a checkout -q -- base/e2e-note.txt
fi

# ── pause and resume ─────────────────────────────────────────────────────
if want pause; then
echo "pause stops unattended runs; resume re-enables them"
peers "box-b"
printf 'paused change\n' >>"$B/.dotfiles/base/e2e-note.txt"
b_before="$(g box-b rev-parse HEAD)" origin_before="$(origin_head)"
check "dotsync pause" "paused" "$(dotsync_on box-b pause)"
check "status says paused" "scheduled: paused" "$(dotsync_on box-b status)"
out="$(dotsync_on box-b DOTSYNC_QUIET_MINUTES=0 --local --scheduled)"; rc=$?
equal "a scheduled run while paused exits 0" 0 "$rc"
check "...deferred" "deferred: paused" "$out"
equal "...committing nothing" "$b_before" "$(g box-b rev-parse HEAD)"
equal "...pushing nothing" "$origin_before" "$(origin_head)"
check "...and its heartbeat says deferred" '"result":"deferred"' "$(cat "$B/.local/state/dotsync/heartbeat.json")"
out="$(dotsync_on box-a --wait)"; rc=$?
check "a run box-a starts on a paused box-b defers there too" "box-b: result=deferred" "$out"
equal "...box-b is untouched" "$b_before" "$(g box-b rev-parse HEAD)"
equal "...and box-a's run is partial, not failed" 0 "$rc"
check "dotsync resume" "resumed" "$(dotsync_on box-b resume)"
out="$(dotsync_on box-b DOTSYNC_QUIET_MINUTES=0 --local --scheduled)"; rc=$?
equal "after resume the scheduled run syncs" 0 "$rc"
differ "...committing box-b's change" "$b_before" "$(g box-b rev-parse HEAD)"
equal "...and pushing it" "$(g box-b rev-parse HEAD)" "$(origin_head)"
# The quiet window: an uncommitted file edited a moment ago defers a scheduled run.
printf 'fresh edit\n' >>"$B/.dotfiles/base/e2e-note.txt"
out="$(dotsync_on box-b --local --scheduled)"; rc=$?
check "a scheduled run defers while a file is being edited" "deferred: 1 uncommitted file edited in the last 10 minutes" "$out"
out="$(dotsync_on box-b --local)"; rc=$?
equal "a dotsync run by hand still syncs it" 0 "$rc"
equal "...pushed" "$(g box-b rev-parse HEAD)" "$(origin_head)"
dotsync_on box-a --wait >/dev/null
fi

# ── an agent working in a peer's checkout ────────────────────────────────
if want session; then
echo "a peer with an agent session in its checkout is not rebased under it"
peers "box-b"
slug="$(printf '%s' "$B/.dotfiles" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$B/.claude/projects/$slug"
printf '{"type":"user","cwd":"%s","message":"edit the zshrc"}\n' "$B/.dotfiles" >"$B/.claude/projects/$slug/session.jsonl"
printf 'while an agent works on box-b\n' >>"$A/.dotfiles/base/e2e-note.txt"
b_before="$(g box-b rev-parse HEAD)"
out="$(dotsync_on box-a --wait)"; rc=$?
check "box-b defers" "box-b: result=deferred" "$out"
equal "...its checkout does not move" "$b_before" "$(g box-b rev-parse HEAD)"
check "...naming the session in its log" "a Claude Code session is working in the checkout" \
  "$(cat "$B/.local/state/dotsync/last-run.log")"
touch -t 202001010000 "$B/.claude/projects/$slug/session.jsonl"
out="$(dotsync_on box-a --wait)"; rc=$?
equal "once the session goes quiet, box-b syncs" "$(origin_head)" "$(g box-b rev-parse HEAD)"
fi

# ── the script replaced by its own pull ──────────────────────────────────
if want replace; then
echo "a pull that replaces dotsync itself finishes on the code it started with"
writer="$tmp/writer"
hg clone -q "$tmp/origin.git" "$writer"
cp "$writer/scripts/dotsync" "$tmp/dotsync.original"
# Longer than the real script, so a shell that kept reading the file after the pull would land
# on one of these lines wherever it resumed.
{ echo '#!/bin/bash'; for _ in $(seq 1 30000); do echo 'echo replaced; exit 88'; done; } >"$writer/scripts/dotsync"
hg -C "$writer" commit -qam "replace dotsync"
hg -C "$writer" push -q origin master
out="$(dotsync_on box-b --local)"; rc=$?
equal "box-b's run that pulled the replacement still succeeds" 0 "$rc"
check "...and the replacement arrived" "exit 88" "$(head -n 2 "$B/.dotfiles/scripts/dotsync")"
lacks "...without running it" "replaced" "$out"
lacks "...or any part of it" "command not found" "$out"
# Put the real one back (box-b now runs the replacement, so the harness pulls for it).
cp "$tmp/dotsync.original" "$writer/scripts/dotsync"
hg -C "$writer" commit -qam "restore dotsync"
hg -C "$writer" push -q origin master
g box-b pull -q --rebase
dotsync_on box-a --local >/dev/null
fi

# ── a peer that hangs ────────────────────────────────────────────────────
if want hang; then
echo "a peer that hangs is cut off at the timeout, and the lock is released"
peers "box-hang"
started=$SECONDS
out="$(dotsync_on box-a DOTSYNC_PEER_TIMEOUT=3 --wait)"; rc=$?
elapsed=$((SECONDS - started))
equal "the run fails" 1 "$rc"
check "box-hang is reported as timed out" "box-hang: timed out after 3s" "$out"
if [[ "$elapsed" -lt 120 ]]; then ok "...cut off, not waited out (${elapsed}s for a 300s hang)"; else bad "...cut off" "<120s" "${elapsed}s"; fi
hang_pid="$(cat "$tmp/box-hang/hang.pid" 2>/dev/null)"
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$hang_pid" 2>/dev/null || break; sleep 0.5; done
equal "the hung process was stopped" "gone" "$(kill -0 "$hang_pid" 2>/dev/null && echo alive || echo gone)"
equal "the lock is free afterwards" "free" "$(python3 -c '
import fcntl, sys
with open(sys.argv[1]) as f:
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB); print("free")
    except OSError:
        print("held")' "$A/.local/state/dotsync/lock" 2>&1)"
check "the heartbeat records the incomplete peer" '"peers_failed":1' "$(cat "$A/.local/state/dotsync/heartbeat.json")"
check "...and the published one too" '"peers_failed":1' \
  "$(command git -C "$tmp/origin.git" cat-file -p refs/dotsync/heartbeats/box-a:heartbeat.json 2>&1)"
out="$(dotsync_on box-a DOTSYNC_LOCK_WAIT=0 --local)"; rc=$?
equal "...so the next run gets it at once" 0 "$rc"
peers "box-b" "box-gone"
out="$(dotsync_on box-a --wait)"; rc=$?
check "an unreachable listed peer is reported" "box-gone: unreachable" "$out"
equal "...and is incomplete, not a failure, without --strict-peers" 0 "$rc"
out="$(dotsync_on box-a --wait --strict-peers)"; rc=$?
equal "...but fails a --strict-peers run" 1 "$rc"
peers "box-gone"
out="$(dotsync_on box-a --wait)"; rc=$?
equal "reaching no peer at all fails the run" 1 "$rc"
check "...saying so" "no peer was reachable" "$out"
fi

# ── a conflict ───────────────────────────────────────────────────────────
if want conflict; then
echo "conflicting edits on both machines stop cleanly, losing neither"
peers "box-b"
printf 'line from box-b\n' >"$B/.dotfiles/base/e2e-note.txt"
touch -t 202001010000 "$B/.dotfiles/base/e2e-note.txt"   # not mid-edit: box-b's run commits it
printf 'line from box-a\n' >"$A/.dotfiles/base/e2e-note.txt"
out="$(dotsync_on box-a --wait)"; rc=$?
equal "box-a's run fails because box-b's did" 1 "$rc"
check "box-b's conflict is reported" "box-b: sync incomplete (its dotsync exited 1); result=failed exit=1 phase=git-rebase" "$out"
equal "box-a's edit is on the origin" "line from box-a" "$(origin_show base/e2e-note.txt)"
equal "box-b's edit is kept in box-b's own commit" "line from box-b" "$(g box-b show HEAD:base/e2e-note.txt)"
equal "...its tree clean" "" "$(g box-b status --porcelain)"
equal "...no rebase left in progress" "absent absent" \
  "$(gone "$B/.dotfiles/.git/rebase-merge") $(gone "$B/.dotfiles/.git/rebase-apply")"
lacks "...and no conflict markers anywhere" "<<<<<<<" "$(cat "$B/.dotfiles/base/e2e-note.txt"; origin_show base/e2e-note.txt)"
fi

# ── the read-only commands ───────────────────────────────────────────────
if want readonly; then
echo "peers, the plan and doctor"
peers "box-b" "box-other other server" "-bad"
out="$(dotsync_on box-a peers)"
check "dotsync peers lists the file's peers" "box-b" "$out"
check "...marks another identity's" "(skipped: another identity)" "$out"
check "...and skips an invalid name" "skipping an invalid peer name: -bad" "$out"
out="$(on box-a "$A/.local/bin/dotsync" --dry-run --json 2>/dev/null)"; rc=$?
equal "the JSON plan names the machine and its first peer" "box-a box-b" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["machine"], d["peers"][0]["alias"])' 2>&1)"
out="$(on box-a "$A/.local/bin/dotsync" doctor --json 2>/dev/null)"; rc=$?
equal "doctor --json reports" 0 "$rc"
equal "...the peers it reads (listed, another identity, invalid)" "1 1 1" \
  "$(printf '%s' "$out" | python3 -c 'import json,sys; p=json.load(sys.stdin)["peers"]; print(p["peers"], p["other_identity"], p["invalid"])' 2>&1)"
fi

echo "nothing it must never call"
equal "no tailscale, rsync, curl, ... ran" "" "$(cat "$tmp/forbidden" 2>/dev/null)"
equal "the schedulers were only asked whether the timer is loaded" "" \
  "$(grep -v 'is-active dotsync.timer\|^launchctl list' "$tmp/scheduler" 2>/dev/null)"
if [[ "$in_repo" -eq 1 ]]; then
  equal "nothing was written into this checkout" "$before_status" "$(cd "$root" && command git status --porcelain)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
