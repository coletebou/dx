#!/usr/bin/env bash
# shellcheck disable=SC2088  # test labels name paths with a literal ~
# codesync.test.sh: codesync between throwaway machines. Each machine is a throwaway HOME with
# clones of the same local bare "GitHub" remotes, and a fake ssh maps an alias (box-b, ...) to
# "run the command with HOME=<that machine's HOME>", refusing any other name, so no real
# machine, HOME, ~/code or remote is ever touched.
#
# It proves: uncommitted work on box-a becomes a WIP commit, is pushed, and box-b gets it (as the
# real commit "sync: apply codesync changes"); a second run on one machine replaces its own WIP;
# a peer of another identity is skipped and never written to; the guarded force-push refuses
# when the remote moved, a background fetch included; a dirty repository on box-b, a conflict and
# a refused commit are left with the changes uncommitted; an unfinished merge (and the like) is
# left alone; nothing passes the secret scan; URLs are printed without credentials; a hung peer
# is cut off at the timeout; a paused peer's real dotsync defers; plus the peers file, the
# profile parser, the config file and dry runs. Needs gitleaks (skips without it).
#
#   bash scripts/tests/codesync.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "# SKIP gitleaks is not installed (codesync's secret scan needs it; CI installs it)"
  exit 0
fi
codesync="$root/scripts/codesync"
real_home="$HOME"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
# Nothing below may reach the real HOME: every run gets its own, and git its own config. No
# setting of the caller's leaks in.
export HOME="$tmp/nobody" GIT_CONFIG_NOSYSTEM=1 LC_ALL=C
unset XDG_CONFIG_HOME GIT_DIR GIT_WORK_TREE DF_IDENTITY DF_MACHINE DF_ROLE CODE_DIR DOTFILES_DIR
for _v in $(env | sed -n 's/^\(CODESYNC_[A-Z_]*\)=.*/\1/p; s/^\(DOTSYNC_[A-Z_]*\)=.*/\1/p'); do unset "$_v"; done
mkdir -p "$HOME" "$tmp/bin" "$tmp/t"
bash_bin="$(command -v bash)"
before_status="$(git -C "$root" status --porcelain)"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# The PATH every machine gets: this one without anything under the real HOME, so neither an
# installed codesync nor an installed dotsync can ever be the one that runs.
clean_path=""
IFS=: read -r -a _parts <<<"$PATH"
for _p in "${_parts[@]}"; do
  case "$_p" in ""|.|"$real_home"|"$real_home"/*) continue ;; esac
  clean_path="${clean_path:+$clean_path:}$_p"
done
# gitleaks may live under the real HOME (CI unpacks it in $RUNNER_TEMP, under the runner's
# HOME): every machine gets it through a directory of its own that holds nothing else.
if _gl="$(command -v gitleaks 2>/dev/null)"; then
  mkdir -p "$tmp/gitleaks-bin" && ln -sf "$_gl" "$tmp/gitleaks-bin/gitleaks"
  clean_path="${clean_path:+$clean_path:}$tmp/gitleaks-bin"
fi
for _c in codesync dotsync; do
  if PATH="$clean_path" command -v "$_c" >/dev/null 2>&1; then
    echo "refusing to run: a $_c outside this checkout is on PATH ($(PATH="$clean_path" command -v "$_c"))" >&2
    exit 1
  fi
done
# The fake ssh below comes first for everything this test runs, so no real ssh is ever reached.
export PATH="$tmp/bin:$clean_path"

# Functions are only ever called from a codesync that sources without running (main guard).
sourceable=no
if grep -q '^if \[\[ "\${BASH_SOURCE\[0\]}" == "\$0" \]\]; then$' "$codesync"; then sourceable=yes; fi
cs_fn() {  # cs_fn FUNCTION ARGS...: one function of scripts/codesync, in a child bash
  if [[ "$sourceable" != yes ]]; then echo "scripts/codesync runs when sourced; not calling $1"; return 99; fi
  "$bash_bin" -c 'source "$1"; shift; "$@"' _ "$codesync" "$@"
}

# The fake ssh. Options are logged (BatchMode, ConnectTimeout); the command runs under the
# machine's HOME with an empty environment, as a login over ssh would, so a peer sees only its
# own config file and profile. Like a dropped connection, a TERM ends the whole remote session.
cat > "$tmp/bin/ssh" <<EOF
#!/usr/bin/env bash
set -m
opts="" host=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) opts="\$opts -o \$2"; shift 2 ;;
    -[a-zA-Z]) opts="\$opts \$1"; shift ;;
    *) host="\$1"; shift; break ;;
  esac
done
printf '%s\t%s\t%s\n' "\$host" "\$opts" "\$*" >> "$tmp/ssh.log"
home="\$(awk -F'\t' -v h="\$host" '\$1 == h { print \$2 }' "$tmp/ssh-map")"
if [ -z "\$home" ]; then
  echo "ssh: Could not resolve hostname \$host: Name or service not known" >&2
  exit 255
fi
env -i HOME="\$home" PATH="$clean_path" GIT_CONFIG_NOSYSTEM=1 LC_ALL=C TMPDIR="$tmp/t" sh -c "\$*" &
child=\$!
trap 'kill -TERM -- "-\$child" 2>/dev/null; exit 143' TERM INT HUP
wait "\$child"
EOF
chmod +x "$tmp/bin/ssh"
: > "$tmp/ssh.log"
: > "$tmp/ssh-map"

remotes="$tmp/remotes/github.com/someone"
seed_home="$tmp/seed-home"
mkdir -p "$remotes" "$seed_home"
gitcfg() { printf '[user]\n\tname = Test User\n\temail = test@example.com\n[init]\n\tdefaultBranch = master\n[advice]\n\tdetachedHead = false\n' > "$1/.gitconfig"; }
gitcfg "$seed_home"
sg() { HOME="$seed_home" git "$@"; }

# new_remote NAME: a bare "GitHub" repository with one commit (f holds "base") and a reflog of
# every push it takes, plus a seed clone at $tmp/seed/NAME that plays a third machine.
new_remote() {
  sg init -q --bare "$remotes/$1.git"
  sg -C "$remotes/$1.git" config core.logAllRefUpdates always
  sg clone -q "$remotes/$1.git" "$tmp/seed/$1" 2>/dev/null
  printf 'base\n' > "$tmp/seed/$1/f"
  sg -C "$tmp/seed/$1" add f
  sg -C "$tmp/seed/$1" commit -qm "base"
  sg -C "$tmp/seed/$1" push -q origin master
}

# machine ALIAS IDENTITY: a throwaway HOME reachable as ALIAS, with a profile, a codesync config
# that counts the stand-in remotes as GitHub, and ~/.local/bin/codesync linked to this checkout.
machine() {
  local h="$tmp/$1"
  mkdir -p "$h/code" "$h/.config/codesync" "$h/.local/bin"
  gitcfg "$h"
  printf '# Written by install.sh\nexport DF_MACHINE=%s\nexport DF_IDENTITY=%s\nexport DF_ROLE=local\n' "$1" "$2" > "$h/.df-profile"
  printf 'CODESYNC_REMOTE_MATCH=^%s/remotes/\n' "$tmp" > "$h/.config/codesync/config"
  ln -s "$codesync" "$h/.local/bin/codesync"
  printf '%s\t%s\n' "$1" "$h" >> "$tmp/ssh-map"
}
clone_on() { HOME="$tmp/$1" git clone -q "$remotes/$2.git" "$tmp/$1/code/$2" 2>/dev/null; }
retire() { local m; for m in box-a box-b box-c box-d; do rm -rf "${tmp:?}/$m/code/$1"; done; }
peers() { local m="$1"; shift; mkdir -p "$tmp/$m/.config/dotsync"; printf '%s\n' "$@" > "$tmp/$m/.config/dotsync/peers"; }

# run_on MACHINE [VAR=value...] ARGS...: codesync as that machine. Sets out, rc and secs.
run_on() {
  local envs=() h="$tmp/$1" start
  shift
  while [[ $# -gt 0 && "$1" == [A-Z]*=* ]]; do envs+=("$1"); shift; done
  start=$SECONDS
  out="$(cd "$h" && env -i HOME="$h" PATH="$tmp/bin:$clean_path" GIT_CONFIG_NOSYSTEM=1 LC_ALL=C \
    TMPDIR="$tmp/t" ${envs[@]+"${envs[@]}"} bash "$codesync" "$@" 2>&1)"
  rc=$?
  secs=$((SECONDS - start))
}

at() { HOME="$tmp/$1" git -C "$tmp/$1/code/$2" "${@:3}" 2>&1; }   # at MACHINE REPO GIT-ARGS...
tip() { git -C "$remotes/$1.git" rev-parse master 2>&1; }  # the remote's master
subject() { git -C "$remotes/$1.git" log -1 --format=%s "${2:-master}" 2>&1; }
in_rebase() { local d; d="$(at "$1" "$2" rev-parse --absolute-git-dir)"; if [[ -d "$d/rebase-merge" || -d "$d/rebase-apply" ]]; then echo yes; else echo no; fi; }

machine box-a example
machine box-b example
machine box-c other
machine box-d example
# box-d hangs: its codesync never answers.
rm "$tmp/box-d/.local/bin/codesync"
printf '#!/bin/sh\nexec sleep 120\n' > "$tmp/box-d/.local/bin/codesync"
chmod +x "$tmp/box-d/.local/bin/codesync"

echo "usage"
run_on box-a --help
equal "--help succeeds" 0 "$rc"
check "...and documents the peers file" "CODESYNC_PEERS_FILE" "$out"
check "...and the backup tags it keeps" "codesync-backup-*" "$out"
run_on box-a --bogus
equal "an unknown option is a usage error" 2 "$rc"
run_on box-a --local --host box-b
equal "--local with --host is a usage error" 2 "$rc"
run_on box-a --host -oProxyCommand=touch
equal "an ssh option passed as a host is refused" 2 "$rc"
equal "...before anything reaches ssh" "" "$(cat "$tmp/ssh.log")"

echo "the profile is data"
# The real peer command, against profiles that a shell would execute; a stub codesync logs runs.
peer_script="$(cs_fn codesync_peer_script example box-a codesync)"
ph="$tmp/profile-host"
mkdir -p "$ph/.local/bin"
printf '#!/bin/sh\n[ "$1" = --help ] && { echo "  --peer          a run another machine started"; exit 0; }\nprintf "ran %%s\\n" "$*" >> "%s/runs"\n' "$ph" > "$ph/.local/bin/codesync"
chmod +x "$ph/.local/bin/codesync"
peer_run() { printf '%s\n' "$1" > "$ph/.df-profile"; env -i HOME="$ph" PATH="$clean_path" sh -s <<<"$peer_script" >/dev/null 2>&1; echo $?; }
for p in 'DF_IDENTITY=example' 'export DF_IDENTITY="example"' "DF_IDENTITY='example'" $'export DF_MACHINE=box-q\nexport DF_IDENTITY=example'; do
  equal "a peer accepts the profile [${p//$'\n'/\\n}]" 0 "$(peer_run "$p")"
done
equal "...and runs codesync --local --peer there each time" "4 ran --local --peer" "$(wc -l < "$ph/runs" | tr -d ' ') $(head -n 1 "$ph/runs")"
# shellcheck disable=SC2016  # profiles a shell would execute, kept literal
for p in 'export DF_IDENTITY=other' 'export DF_IDENTITY=$(touch "$HOME/executed")' \
         'DF_IDENTITY=example; touch "$HOME/executed"' 'DF_IDENTITY=`touch "$HOME/executed"`' \
         $'DF_IDENTITY=example\nexport DF_IDENTITY=other' '' 'DF_ROLE=local'; do
  equal "a peer refuses the profile [${p//$'\n'/\\n}]" 77 "$(peer_run "$p")"
done
rm -f "$ph/.df-profile"
equal "a peer without a profile refuses" 77 "$(env -i HOME="$ph" PATH="$clean_path" sh -s <<<"$peer_script" >/dev/null 2>&1; echo $?)"
equal "no profile content was executed" "no" "$(if [[ -e "$ph/executed" ]]; then echo yes; else echo no; fi)"
equal "...and codesync never ran for a refused profile" 4 "$(wc -l < "$ph/runs" | tr -d ' ')"
equal "a peer that is the starting machine steps aside" 78 "$(peer_run $'DF_IDENTITY=example\nDF_MACHINE=Box-A')"
# An older codesync, without --peer (its --help does list --peers): it gets plain --local.
cat > "$ph/.local/bin/codesync" <<EOF
#!/bin/sh
case "\$1" in
  --help) printf 'Usage: codesync [--dry-run] [--local] [--peers]\n  --peers   list the peers\n'; exit 0 ;;
  --local) [ "\$2" = --peer ] && { echo "codesync: unknown option: --peer" >&2; exit 2; }
           printf 'old ran %s\n' "\$*" >> "$ph/runs"; exit 0 ;;
esac
exit 2
EOF
chmod +x "$ph/.local/bin/codesync"
old_err="$(printf 'DF_IDENTITY=example\n' > "$ph/.df-profile"; env -i HOME="$ph" PATH="$clean_path" sh -s <<<"$peer_script" 2>&1 >/dev/null; echo "rc=$?")"
equal "a peer with an older codesync runs it with plain --local" "old ran --local" "$(tail -n 1 "$ph/runs")"
check "...and succeeds" "rc=0" "$old_err"
check "...saying so" "codesync: note: codesync here predates --peer" "$old_err"
rm "$ph/.local/bin/codesync"
equal "a peer without codesync says so" 127 "$(peer_run 'DF_IDENTITY=example')"
run_on box-a DF_IDENTITY=other --peers
check "the installed profile wins over an ambient DF_IDENTITY" "identity: example" "$out"
mv "$tmp/box-a/.df-profile" "$tmp/box-a/df-profile.saved"
run_on box-a DF_IDENTITY=example DF_MACHINE=box-a --peers
check "without a profile, DF_IDENTITY decides" "identity: example" "$out"
# shellcheck disable=SC2016
printf 'export DF_IDENTITY=$(id -un)\n' > "$tmp/box-a/.df-profile"
run_on box-a DF_IDENTITY=example DF_MACHINE=box-a --peers
check "a profile line that would run a command is no identity" "identity: unknown" "$out"
mv "$tmp/box-a/df-profile.saved" "$tmp/box-a/.df-profile"

echo "the peers file"
peers box-a box-b 'BOX-B   # the same machine twice' '-oProxyCommand=evil' 'a..b' 'box-a' 'box-c other' 'box-e - server'
run_on box-a --peers
out="$(tr -s ' ' <<<"$out")"
check "dotsync's peers file is read when codesync has none" " box-b - ~/.config/dotsync/peers" "$out"
lacks "...a name listed twice appears once" "BOX-B" "$out"
lacks "...an ssh option as a name is dropped" " -oProxyCommand=evil -" "$out"
check "...with a warning" "skipping an invalid peer name: -oProxyCommand=evil" "$out"
lacks "...as is a name with .." " a..b -" "$out"
check "...this machine is listed as skipped" " box-a - ~/.config/dotsync/peers (this machine: skipped)" "$out"
check "...another identity's entry is listed as skipped" " box-c other ~/.config/dotsync/peers (identity other: skipped)" "$out"
check "...'-' means an unknown identity" " box-e - ~/.config/dotsync/peers" "$out"
mkdir -p "$tmp/box-a/.dotfiles/identities/example"
printf 'box-f\n' > "$tmp/box-a/.dotfiles/identities/example/dotsync-peers"
run_on box-a --peers
check "...and the identity's list in ~/.dotfiles too" " box-f - identities/example/dotsync-peers" "$(tr -s ' ' <<<"$out")"
printf 'box-g\n' > "$tmp/box-a/.config/codesync/peers"
run_on box-a --peers
check "~/.config/codesync/peers wins over dotsync's" "box-g" "$out"
lacks "...and is the only list read" "box-b" "$out"
printf 'box-h\n' > "$tmp/box-a/alt-peers"
run_on box-a CODESYNC_PEERS_FILE='~/alt-peers' --peers
check "CODESYNC_PEERS_FILE wins over both" " box-h - CODESYNC_PEERS_FILE" "$(tr -s ' ' <<<"$out")"
lacks "...alone" "box-g" "$out"
chmod g+w "$tmp/box-a/.config/codesync/peers"
run_on box-a --peers
check "a peers file others can write is ignored" "ignoring $tmp/box-a/.config/codesync/peers" "$out"
rm -rf "$tmp/box-a/.config/codesync/peers" "$tmp/box-a/alt-peers" "$tmp/box-a/.dotfiles"
equal "nothing above contacted a peer" "" "$(cat "$tmp/ssh.log")"

echo "box-a's work reaches box-b (the two-peer proof)"
new_remote r1
clone_on box-a r1; clone_on box-b r1
base="$(tip r1)"
printf 'from box-a\n' >> "$tmp/box-a/code/r1/f"
printf 'new file\n' > "$tmp/box-a/code/r1/new.txt"
peers box-a box-b
run_on box-a
equal "codesync on box-a succeeds" 0 "$rc"
check "...committing the work as a WIP" "committed WIP" "$out"
check "...and syncing box-b" "box-b: synced" "$out"
equal "the remote took box-a's WIP, then box-b's commit of it" $'sync: apply codesync changes\nWIP: codesync\nbase' \
  "$(git -C "$remotes/r1.git" log -g --format=%s master 2>&1 | sed 's/^\(WIP: codesync\) .*/\1/')"
check "...the WIP names the machine that made it" "Codesync-Machine: box-a" "$(git -C "$remotes/r1.git" log -1 --format=%b 'master@{1}')"
check "...and holds the untracked file" "new.txt" "$(git -C "$remotes/r1.git" show --stat --format= 'master@{1}')"
check "box-b keeps a backup tag of the WIP it replaced" "$(git -C "$remotes/r1.git" rev-parse 'master@{1}')" \
  "$(at box-b r1 for-each-ref --format='%(objectname)' 'refs/tags/codesync-backup-*')"
equal "box-a unwrapped its WIP: HEAD is back on the base" "$base" "$(at box-a r1 rev-parse HEAD)"
equal "...its work is uncommitted again" $' M f\n?? new.txt' "$(at box-a r1 status --porcelain)"
equal "box-b has the work" $'base\nfrom box-a' "$(cat "$tmp/box-b/code/r1/f")"
equal "...and the new file" "new file" "$(cat "$tmp/box-b/code/r1/new.txt" 2>&1)"
equal "...as the real commit box-b made of it" "sync: apply codesync changes" "$(at box-b r1 log -1 --format=%s)"
equal "...which box-b pushed" "$(at box-b r1 rev-parse HEAD)" "$(tip r1)"
equal "...on the same base" "$base" "$(at box-b r1 rev-parse HEAD~1)"
equal "...with a clean tree there" "" "$(at box-b r1 status --porcelain)"
check "ssh ran box-b's codesync over sh, never prompting" $'box-b\t -o ConnectTimeout=5 -o BatchMode=yes\tsh -s' "$(cat "$tmp/ssh.log")"
run_on box-a --local
equal "box-a's next run succeeds" 0 "$rc"
equal "...and box-a now matches the remote" "$(tip r1)" "$(at box-a r1 rev-parse HEAD)"
equal "...with nothing left uncommitted" "" "$(at box-a r1 status --porcelain)"
retire r1

echo "a second run on one machine"
new_remote r2
clone_on box-a r2
base="$(tip r2)"
printf 'one\n' >> "$tmp/box-a/code/r2/f"
run_on box-a --local
equal "the first run succeeds" 0 "$rc"
first_wip="$(tip r2)"
printf 'two\n' >> "$tmp/box-a/code/r2/f"
run_on box-a --local
equal "a second run, before any machine pulled the first WIP, succeeds too" 0 "$rc"
equal "...its WIP replaced the first one (one WIP on the base)" "$base" "$(git -C "$remotes/r2.git" rev-parse master~1)"
equal "...holding both edits" $'base\none\ntwo' "$(git -C "$remotes/r2.git" show master:f)"
check "...the replaced WIP keeps a backup tag" "codesync-backup-" "$(at box-a r2 tag --points-at "$first_wip")"
equal "...and the work is uncommitted on box-a" " M f" "$(at box-a r2 status --porcelain)"
# A run cut off between its commit and its unwrap leaves its WIP committed; the next one unwraps it.
at box-a r2 add -A >/dev/null
at box-a r2 commit -qm "WIP: codesync 2000-01-01 00:00:00" -m "Codesync-Machine: box-a" >/dev/null
run_on box-a --local
equal "a WIP an earlier run left committed is pushed and unwrapped by the next" "0 $base  M f" \
  "$rc $(at box-a r2 rev-parse HEAD) $(at box-a r2 status --porcelain)"
retire r2
# Another machine's WIP that is HEAD here (pulled by hand) stays a commit: it is not ours.
new_remote r2b
clone_on box-a r2b
printf 'from box-b\n' > "$tmp/seed/r2b/f"
sg -C "$tmp/seed/r2b" commit -qam "WIP: codesync 2000-01-01 00:00:00" -m "Codesync-Machine: box-b"
sg -C "$tmp/seed/r2b" push -q origin master
at box-a r2b pull -q origin master >/dev/null
run_on box-a --local
equal "another machine's WIP at HEAD is left a commit" "0 $(tip r2b) " \
  "$rc $(at box-a r2b rev-parse HEAD) $(at box-a r2b status --porcelain)"
retire r2b

echo "a peer of another identity"
new_remote r3
clone_on box-a r3; clone_on box-c r3
printf 'box-c work\n' >> "$tmp/box-c/code/r3/f"
c_head="$(at box-c r3 rev-parse HEAD)" c_reflog="$(at box-c r3 reflog | wc -l)" c_status="$(at box-c r3 status --porcelain)"
printf 'from box-a\n' >> "$tmp/box-a/code/r3/f"
peers box-a box-c
: > "$tmp/ssh.log"
run_on box-a
check "box-c is contacted and refuses" "box-c: refused: it runs another identity" "$out"
equal "...without failing box-a's run" 0 "$rc"
equal "box-c's HEAD did not move" "$c_head" "$(at box-c r3 rev-parse HEAD)"
equal "...its uncommitted work is as it was" "$c_status" "$(at box-c r3 status --porcelain)"
equal "...its reflog has no new entry" "$c_reflog" "$(at box-c r3 reflog | wc -l)"
equal "...no codesync tag was made there" "" "$(at box-c r3 tag --list)"
lacks "...and none of its work reached the remote" "box-c work" "$(git -C "$remotes/r3.git" log -p master 2>&1)"
peers box-a 'box-c other'
: > "$tmp/ssh.log"
run_on box-a
check "listed with its identity, box-c is skipped" "box-c: skipped (listed as identity other" "$out"
equal "...without even an ssh connection" "" "$(cat "$tmp/ssh.log")"
mv "$tmp/box-a/.df-profile" "$tmp/box-a/df-profile.saved"
run_on box-a DF_MACHINE=box-a
check "a machine whose identity is unknown syncs no peer" "this machine's identity is unknown" "$out"
equal "...and opens no ssh connection" "" "$(cat "$tmp/ssh.log")"
mv "$tmp/box-a/df-profile.saved" "$tmp/box-a/.df-profile"
retire r3

echo "a dirty repository on box-b"
new_remote r4
clone_on box-a r4; clone_on box-b r4
printf 'box-b edit\n' > "$tmp/box-b/code/r4/g"
at box-b r4 add g >/dev/null; at box-b r4 commit -qm "g" >/dev/null; at box-b r4 push -q origin master >/dev/null
b_head="$(at box-b r4 rev-parse HEAD)"
printf 'box-b uncommitted\n' >> "$tmp/box-b/code/r4/g"
at box-a r4 pull -q --rebase origin master >/dev/null
printf 'from box-a\n' >> "$tmp/box-a/code/r4/f"
peers box-a box-b
run_on box-a
a_wip="$(tip r4)"
check "box-b reports it could not sync" "box-b: sync incomplete (codesync exited 1 there)" "$out"
check "...because both machines have a WIP" "refusing to drop remote WIP" "$out"
equal "...so box-a's run fails" 1 "$rc"
equal "box-b's uncommitted work is intact" $'box-b edit\nbox-b uncommitted' "$(cat "$tmp/box-b/code/r4/g")"
equal "...still uncommitted" " M g" "$(at box-b r4 status --porcelain)"
equal "...on the HEAD it had" "$b_head" "$(at box-b r4 rev-parse HEAD)"
equal "...not mid-rebase" "no" "$(in_rebase box-b r4)"
equal "box-a's WIP is still the remote's tip" "WIP: codesync" "$(subject r4 | cut -c1-13)"
check "...it is box-a's" "Codesync-Machine: box-a" "$(git -C "$remotes/r4.git" log -1 --format=%b "$a_wip")"
retire r4

echo "a pull that conflicts"
new_remote r5
clone_on box-b r5
printf 'box-b line\n' > "$tmp/box-b/code/r5/f"
printf 'seed line\n' > "$tmp/seed/r5/f"
sg -C "$tmp/seed/r5" commit -qam "seed edit"; sg -C "$tmp/seed/r5" push -q origin master
b_head="$(at box-b r5 rev-parse HEAD)"
run_on box-b --local
equal "the run fails" 1 "$rc"
check "...saying how to resolve it" "pull failed; resolve it by hand" "$out"
equal "...the repository is not left mid-rebase" "no" "$(in_rebase box-b r5)"
equal "...its file has no conflict markers, only its own edit" "box-b line" "$(cat "$tmp/box-b/code/r5/f")"
equal "...uncommitted again" " M f" "$(at box-b r5 status --porcelain)"
equal "...on its old HEAD" "$b_head" "$(at box-b r5 rev-parse HEAD)"
equal "...the seed's commit stays the remote's tip" "seed edit" "$(subject r5)"
check "...and the WIP it unwrapped keeps a tag" "codesync-unwrap-" "$(at box-b r5 tag --list)"
retire r5

echo "the guarded force-push"
new_remote r6
clone_on box-a r6
base="$(tip r6)"
# Another machine pushes right after box-a's fetch: box-a's pre-commit hook does it, once.
mkdir -p "$tmp/race-hooks"
cat > "$tmp/race-hooks/pre-commit" <<EOF
#!/bin/sh
[ -e "$tmp/raced" ] && exit 0
: > "$tmp/raced"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
cd "$tmp/seed/r6" && printf 'racer\n' > racer && HOME="$seed_home" git add racer \\
  && HOME="$seed_home" git commit -qm "racer" && HOME="$seed_home" git push -q origin master
EOF
chmod +x "$tmp/race-hooks/pre-commit"
at box-a r6 config core.hooksPath "$tmp/race-hooks" >/dev/null
printf 'from box-a\n' >> "$tmp/box-a/code/r6/f"
run_on box-a --local
racer="$(git -C "$tmp/seed/r6" rev-parse HEAD)"
equal "the race happened" "racer" "$(git -C "$tmp/seed/r6" log -1 --format=%s)"
equal "a push over a commit box-a never fetched fails" 1 "$rc"
check "...refused by the lease" "(stale info)" "$out"
equal "...the other machine's commit is still the remote's tip" "$racer" "$(tip r6)"
equal "...box-a's work is uncommitted again" " M f" "$(at box-a r6 status --porcelain)"
equal "...on its base" "$base" "$(at box-a r6 rev-parse HEAD)"
run_on box-a --local
equal "the next run succeeds" 0 "$rc"
equal "...with box-a's WIP on top of the other machine's commit" "$racer" "$(git -C "$remotes/r6.git" rev-parse master~1)"
equal "...and box-a has that commit" "racer" "$(cat "$tmp/box-a/code/r6/racer" 2>&1)"
retire r6
# The same race, plus a background fetch (an editor's) that moves origin/master to the other
# machine's commit before the push: the lease must still hold codesync's own fetch.
new_remote r6b
clone_on box-a r6b
base="$(tip r6b)"
mkdir -p "$tmp/race-fetch-hooks"
cat > "$tmp/race-fetch-hooks/pre-commit" <<EOF
#!/bin/sh
[ -e "$tmp/raced-fetch" ] && exit 0
: > "$tmp/raced-fetch"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
(cd "$tmp/seed/r6b" && printf 'racer\n' > racer && HOME="$seed_home" git add racer \\
  && HOME="$seed_home" git commit -qm "racer" && HOME="$seed_home" git push -q origin master) \\
  && cd "$tmp/box-a/code/r6b" && git fetch -q origin
EOF
chmod +x "$tmp/race-fetch-hooks/pre-commit"
at box-a r6b config core.hooksPath "$tmp/race-fetch-hooks" >/dev/null
printf 'from box-a\n' >> "$tmp/box-a/code/r6b/f"
run_on box-a --local
racer="$(git -C "$tmp/seed/r6b" rev-parse HEAD)"
equal "the race and the background fetch happened" "racer $racer" \
  "$(git -C "$tmp/seed/r6b" log -1 --format=%s) $(at box-a r6b rev-parse origin/master)"
equal "a push after a background fetch moved origin/master still fails" 1 "$rc"
check "...refused by the lease on the fetched tip" "(stale info)" "$out"
equal "...the other machine's commit stays the remote's tip" "$racer" "$(tip r6b)"
equal "...and box-a's work is uncommitted again, on its base" "$base  M f" \
  "$(at box-a r6b rev-parse HEAD) $(at box-a r6b status --porcelain)"
retire r6b
# The ancestry check on its own: a WIP whose base lacks a remote commit is never force-pushed.
new_remote r7
clone_on box-a r7
printf 'remote only\n' > "$tmp/seed/r7/f"
sg -C "$tmp/seed/r7" commit -qam "remote only"; sg -C "$tmp/seed/r7" push -q origin master
remote_only="$(tip r7)"
printf 'local\n' > "$tmp/box-a/code/r7/f"
at box-a r7 commit -qam "WIP: codesync 2000-01-01 00:00:00" >/dev/null
at box-a r7 fetch -q origin >/dev/null
guard_out="$(cd "$tmp/box-a/code/r7" && HOME="$tmp/box-a" cs_fn safe_force_push master "$remote_only" "remote only" 2>&1; echo "rc=$?")"
check "safe_force_push refuses when the remote has commits the WIP's base lacks" "rc=1" "$guard_out"
check "...saying so" "Remote has commits you don't have" "$guard_out"
equal "...and the remote keeps them" "$remote_only" "$(tip r7)"
retire r7

echo "a peer still on an older codesync"
machine box-e example
rm "$tmp/box-e/.local/bin/codesync"
cat > "$tmp/box-e/.local/bin/codesync" <<EOF
#!/bin/sh
case "\$1" in
  --help) printf 'Usage: codesync [--dry-run] [--local] [--peers]\n  --peers   list the peers\n'; exit 0 ;;
  --local) [ "\$2" = --peer ] && { echo "codesync: unknown option: --peer" >&2; exit 2; }
           printf '%s\n' "\$*" >> "$tmp/old-runs"; echo "[codesync] Done: 0 synced, 0 skipped, 0 failed"; exit 0 ;;
esac
exit 2
EOF
chmod +x "$tmp/box-e/.local/bin/codesync"
peers box-a box-e
run_on box-a
check "box-e's older codesync still syncs" "box-e: synced" "$out"
equal "...run as plain --local" "--local" "$(cat "$tmp/old-runs" 2>&1)"
check "...and the run says why" "box-e| codesync: note: codesync here predates --peer" "$out"

echo "an unfinished operation"
# conflict_on NAME: the seed pushes "seed side" to f; box-a commits "box-a side" to f.
conflict_on() {
  new_remote "$1"; clone_on box-a "$1"
  printf 'seed side\n' > "$tmp/seed/$1/f"
  sg -C "$tmp/seed/$1" commit -qam "seed side"; sg -C "$tmp/seed/$1" push -q origin master
  printf 'box-a side\n' > "$tmp/box-a/code/$1/f"
  at box-a "$1" commit -qam "box-a side" >/dev/null
  at box-a "$1" fetch -q origin >/dev/null
}
conflict_on u-merge
at box-a u-merge merge -q --no-edit origin/master >/dev/null
conflict_on u-pick
at box-a u-pick cherry-pick origin/master >/dev/null
conflict_on u-am
git -C "$tmp/seed/u-am" format-patch -q -1 --stdout > "$tmp/u-am.patch"
at box-a u-am am -q "$tmp/u-am.patch" >/dev/null
new_remote u-stash; clone_on box-a u-stash
printf 'stashed side\n' > "$tmp/box-a/code/u-stash/f"
at box-a u-stash stash -q >/dev/null
printf 'committed side\n' > "$tmp/box-a/code/u-stash/f"
at box-a u-stash commit -qam "committed side" >/dev/null
at box-a u-stash stash pop -q >/dev/null
new_remote u-bisect; clone_on box-a u-bisect
at box-a u-bisect bisect start >/dev/null
printf 'bisecting\n' >> "$tmp/box-a/code/u-bisect/f"
u_repos=(u-merge u-pick u-am u-stash u-bisect)
u_state() { printf '%s %s %s' "$(tip "$1")" "$(at box-a "$1" rev-parse HEAD)" "$(at box-a "$1" status --porcelain | tr '\n' ' ')"; }
u_before=()
for r in "${u_repos[@]}"; do u_before+=("$(u_state "$r")"); done
equal "the states are set up" "MERGE_HEAD CHERRY_PICK_HEAD rebase-apply unmerged BISECT_LOG" \
  "$(for p in u-merge/.git/MERGE_HEAD u-pick/.git/CHERRY_PICK_HEAD u-am/.git/rebase-apply; do [[ -e "$tmp/box-a/code/$p" ]] && printf '%s ' "${p##*/}"; done; [[ -n "$(at box-a u-stash ls-files -u)" ]] && printf 'unmerged '; [[ -e "$tmp/box-a/code/u-bisect/.git/BISECT_LOG" ]] && printf BISECT_LOG)"
run_on box-a --local
equal "a repository in the middle of an operation fails the run" 1 "$rc"
check "...a merge is named" "u-merge: left alone: a merge is in progress" "$out"
check "...a cherry-pick" "u-pick: left alone: a cherry-pick is in progress" "$out"
check "...a git am" "u-am: left alone: a git am is in progress" "$out"
check "...unmerged paths (a stash that did not apply)" "u-stash: left alone: unmerged paths" "$out"
check "...a bisect" "u-bisect: left alone: a bisect is in progress" "$out"
for i in "${!u_repos[@]}"; do
  equal "...${u_repos[$i]}: nothing committed, staged or pushed" "${u_before[$i]}" "$(u_state "${u_repos[$i]}")"
done
equal "...and the merge is still there to finish" "present" "$(if [[ -e "$tmp/box-a/code/u-merge/.git/MERGE_HEAD" ]]; then echo present; else echo gone; fi)"
run_on box-a --local --dry-run
check "a dry run says it would leave it alone" "u-merge: left alone: a merge is in progress" "$out"
for r in "${u_repos[@]}"; do retire "$r"; done

echo "a hung peer"
new_remote r8
# box-b holds no repository here, so its own run is quick, well inside the timeout.
clone_on box-a r8
printf 'from box-a\n' >> "$tmp/box-a/code/r8/f"
peers box-a box-d box-b
run_on box-a CODESYNC_PEER_TIMEOUT=5
check "box-d is cut off at the timeout" "box-d: timed out after 5s" "$out"
if (( secs < 90 )); then ok "...the run took ${secs}s, not the 120s box-d hangs"; else bad "...promptly" "< 90s" "${secs}s"; fi
check "...and the run goes on to box-b" "box-b: synced" "$out"
equal "...a timed-out peer fails the run" 1 "$rc"
peers box-a box-x
run_on box-a
check "an unreachable peer is reported" "box-x: unreachable" "$out"
equal "...without failing the run (a laptop asleep)" 0 "$rc"
run_on box-a --host box-x
equal "...but a peer named with --host must be reached" 1 "$rc"
retire r8

echo "the watchdog without timeout(1)"
mkdir -p "$tmp/minbin"
for t in sleep mktemp rm sh cat; do ln -s "$(command -v "$t")" "$tmp/minbin/$t"; done
wd_start=$SECONDS
wd_out="$(PATH="$tmp/minbin" cs_fn codesync_timeout 2 sleep 30 2>&1; echo "rc=$?")"
equal "a command past its time is stopped with 124" "rc=124" "$wd_out"
if (( SECONDS - wd_start < 20 )); then ok "...promptly"; else bad "...promptly" "< 20s" "$((SECONDS - wd_start))s"; fi
# shellcheck disable=SC2016  # expanded by the child sh
wd_out="$(PATH="$tmp/minbin" cs_fn codesync_timeout 5 sh -c 'read l; echo "got $l"' <<<"hi" 2>&1; echo "rc=$?")"
equal "...and a command in time keeps its stdin and exit status" $'got hi\nrc=0' "$wd_out"
equal "...or its own exit status" "rc=3" "$(PATH="$tmp/minbin" cs_fn codesync_timeout 5 sh -c 'exit 3' 2>&1; echo "rc=$?")"

echo "a dry run"
new_remote r9
clone_on box-a r9
printf 'pending\n' >> "$tmp/box-a/code/r9/f"
peers box-a box-b
: > "$tmp/ssh.log"
before="$(tip r9) $(at box-a r9 rev-parse HEAD) $(at box-a r9 status --porcelain)"
run_on box-a --dry-run
equal "a dry run succeeds" 0 "$rc"
check "...saying what it would do" "would commit WIP and push" "$out"
check "...and which peer it would sync" "would sync box-b" "$out"
equal "...changing nothing" "$before" "$(tip r9) $(at box-a r9 rev-parse HEAD) $(at box-a r9 status --porcelain)"
equal "...and contacting no peer" "" "$(cat "$tmp/ssh.log")"
retire r9

echo "which directories are repositories"
new_remote r10
clone_on box-a r10
mkdir -p "$tmp/box-a/code/oss" "$tmp/box-a/code/plain-dir"
HOME="$tmp/box-a" git clone -q "$remotes/r10.git" "$tmp/box-a/code/oss/nested" 2>/dev/null
HOME="$tmp/box-a" git clone -q "$remotes/r10.git" "$tmp/box-a/notes" 2>/dev/null
mkdir -p "$tmp/elsewhere"
HOME="$tmp/box-a" git init -q --bare "$tmp/elsewhere/x.git"
HOME="$tmp/box-a" git clone -q "$tmp/elsewhere/x.git" "$tmp/box-a/code/not-github" 2>/dev/null
printf 'stays\n' > "$tmp/box-a/code/not-github/file"
HOME="$tmp/box-a" git clone -q "$remotes/r10.git" "$tmp/box-a/code/detached" 2>/dev/null
at box-a detached switch -q --detach HEAD >/dev/null
url_secret="tok$RANDOM$RANDOM$$"
HOME="$tmp/box-a" git clone -q "$remotes/r10.git" "$tmp/box-a/code/with-token" 2>/dev/null
at box-a with-token remote set-url origin "https://someone:$url_secret@example.com/someone/x.git" >/dev/null
run_on box-a --local --verbose
lacks "a skipped origin's credentials are never printed" "$url_secret" "$out"
check "...its URL is shown without them" "with-token: origin does not match CODESYNC_REMOTE_MATCH (https://***@example.com/someone/x.git)" "$out"
redacted="$(printf 'fatal: unable to access https://u:%s@example.com/x.git/\n' "$url_secret" | cs_fn codesync_redact)"
equal "git output codesync prints is redacted the same way" "fatal: unable to access https://***@example.com/x.git/" "$redacted"
rm -rf "$tmp/box-a/code/with-token"
check "a repository whose origin does not match is skipped" "not-github: origin does not match" "$out"
equal "...untouched" "?? file" "$(at box-a not-github status --porcelain)"
check "a directory that is no repository is skipped" "plain-dir: not a git repo" "$out"
check "a detached HEAD is skipped" "detached: detached HEAD" "$out"
lacks "nested directories are off by default" "oss/nested" "$out"
lacks "...and so are extra ones" "~/notes" "$out"
printf 'CODESYNC_REMOTE_MATCH=^%s/remotes/\nCODESYNC_NESTED_DIRS=oss\nexport CODESYNC_EXTRA_DIRS="~/notes"\n' "$tmp" > "$tmp/box-a/.config/codesync/config"
run_on box-a --local
check "CODESYNC_NESTED_DIRS adds the repositories one level down" "oss/nested (master)" "$out"
check "CODESYNC_EXTRA_DIRS adds others anywhere" "~/notes (master)" "$out"
run_on box-a CODESYNC_REMOTE_MATCH='^/nowhere/' --local
check "the environment wins over the config file" "0 synced" "$out"
chmod g+w "$tmp/box-a/.config/codesync/config"
run_on box-a --local
check "a config file others can write is ignored" "ignoring $tmp/box-a/.config/codesync/config" "$out"
chmod g-w "$tmp/box-a/.config/codesync/config"
# shellcheck disable=SC2016
printf 'CODESYNC_REMOTE_MATCH=^%s/remotes/\nCODESYNC_REMOTE_CMD=$(touch ~/executed)\nCODESYNC_TYPO=1\n' "$tmp" > "$tmp/box-a/.config/codesync/config"
run_on box-a --local
equal "a command in a setting is refused, not run" 2 "$rc"
equal "...nothing executed" "no" "$(if [[ -e "$tmp/box-a/executed" ]]; then echo yes; else echo no; fi)"
check "...and an unknown setting is named" "unknown setting CODESYNC_TYPO" "$out"
printf 'CODESYNC_REMOTE_MATCH=^%s/remotes/\n' "$tmp" > "$tmp/box-a/.config/codesync/config"
rm -rf "$tmp/box-a/code/oss" "$tmp/box-a/code/plain-dir" "$tmp/box-a/notes" "$tmp/box-a/code/not-github" "$tmp/box-a/code/detached"
retire r10

echo "a refused WIP commit"
new_remote r11; new_remote r12
clone_on box-a r11; clone_on box-a r12
mkdir -p "$tmp/refuse-hooks"
printf '#!/bin/sh\necho "secret found" >&2\nexit 1\n' > "$tmp/refuse-hooks/pre-commit"
chmod +x "$tmp/refuse-hooks/pre-commit"
at box-a r11 config core.hooksPath "$tmp/refuse-hooks" >/dev/null
printf 'held back\n' >> "$tmp/box-a/code/r11/f"
printf 'goes through\n' >> "$tmp/box-a/code/r12/f"
run_on box-a --local
equal "a refused commit fails the run" 1 "$rc"
check "...naming the refusal" "the WIP commit was refused" "$out"
check "...with the hook's reason" "secret found" "$out"
equal "...its changes stay uncommitted and unstaged" " M f" "$(at box-a r11 status --porcelain)"
check "...and the run goes on to the next repository" "goes through" "$(git -C "$remotes/r12.git" show master:f 2>&1)"
retire r11; retire r12

echo "the secret scan"
token="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 36)"
new_remote s1
clone_on box-a s1
# A repository-local hooks directory (husky, lefthook) with no secret hook: codesync scans anyway.
mkdir -p "$tmp/empty-hooks"
at box-a s1 config core.hooksPath "$tmp/empty-hooks" >/dev/null
printf 'GITHUB_TOKEN=%s\n' "$token" > "$tmp/box-a/code/s1/.env"
s1_before="$(tip s1)"
run_on box-a --local
equal "an untracked file holding a secret fails the run" 1 "$rc"
check "...at codesync's own scan of the changes" "gitleaks found a potential secret in the changes" "$out"
lacks "...before any commit is made" "committed WIP" "$out"
lacks "...without printing the secret" "$token" "$out"
equal "...the file stays untracked and unstaged" "?? .env" "$(at box-a s1 status --porcelain)"
equal "...nothing was committed" "base" "$(at box-a s1 log -1 --format=%s)"
equal "...or pushed" "$s1_before" "$(tip s1)"
at box-a s1 add .env >/dev/null
at box-a s1 commit -qm "by hand" --no-verify >/dev/null
run_on box-a --local
equal "a commit holding a secret, made by hand, is not pushed" "$s1_before" "$(tip s1)"
check "...refused at the outgoing scan" "refusing to push" "$out"
lacks "...without printing the secret" "$token" "$out"
retire s1
# A merge made here whose conflict resolution alone adds the secret (neither parent has it), in a
# clean checkout: only the outgoing scan stands between it and the remote.
new_remote s4
clone_on box-a s4
printf 'seed side\n' > "$tmp/seed/s4/f"
sg -C "$tmp/seed/s4" commit -qam "seed side"; sg -C "$tmp/seed/s4" push -q origin master
printf 'box-a side\n' > "$tmp/box-a/code/s4/f"
at box-a s4 commit -qam "box-a side" >/dev/null
at box-a s4 pull -q --no-rebase origin master >/dev/null
printf 'resolved\nGITHUB_TOKEN=%s\n' "$token" > "$tmp/box-a/code/s4/f"
at box-a s4 add f >/dev/null
at box-a s4 commit -q --no-edit --no-verify >/dev/null
s4_before="$(tip s4)"
equal "the merge is made, the tree clean" "2 " "$(at box-a s4 log -1 --format=%p | wc -w | tr -d ' ') $(at box-a s4 status --porcelain)"
run_on box-a --local
equal "a merge whose resolution adds a secret is not pushed" "$s4_before" "$(tip s4)"
check "...refused at the outgoing scan" "refusing to push" "$out"
lacks "...without printing the secret" "$token" "$out"
retire s4
# Without gitleaks nothing is committed or pushed, but a clean repository still pulls.
nogl="$tmp/no-gitleaks"
mkdir -p "$nogl"
IFS=: read -r -a _dirs <<<"$clean_path"
for d in "${_dirs[@]}"; do
  for f in "$d"/*; do
    n="${f##*/}"
    if [[ "$n" != gitleaks && -x "$f" && ! -d "$f" && ! -e "$nogl/$n" ]]; then ln -s "$f" "$nogl/$n"; fi
  done
done
new_remote s2; clone_on box-a s2; new_remote s3; clone_on box-a s3
printf 'pending\n' >> "$tmp/box-a/code/s2/f"
printf 'seed edit\n' > "$tmp/seed/s3/f"
sg -C "$tmp/seed/s3" commit -qam "seed edit"; sg -C "$tmp/seed/s3" push -q origin master
s2_before="$(tip s2)"
run_on box-a PATH="$nogl" --local
equal "without gitleaks a repository with changes fails" 1 "$rc"
check "...saying gitleaks is required to commit" "gitleaks is required to commit" "$out"
lacks "...before any commit is made" "committed WIP" "$out"
equal "...its changes stay uncommitted" " M f" "$(at box-a s2 status --porcelain)"
equal "...and unpushed" "$s2_before" "$(tip s2)"
equal "...while a clean repository behind its origin still pulls" "$(tip s3)" "$(at box-a s3 rev-parse HEAD)"
retire s2; retire s3

echo "dotsync at the end"
cat > "$tmp/box-a/.local/bin/dotsync" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/dotsync.calls"
EOF
chmod +x "$tmp/box-a/.local/bin/dotsync"
run_on box-a --local
equal "~/.local/bin/dotsync runs once with --local" "--local" "$(cat "$tmp/dotsync.calls" 2>&1)"
run_on box-a CODESYNC_DOTSYNC=0 --local
equal "CODESYNC_DOTSYNC=0 skips it" "1" "$(wc -l < "$tmp/dotsync.calls" | tr -d ' ')"
run_on box-a --local --peer
equal "a run another machine started passes --peer on" "--local --peer" "$(tail -n 1 "$tmp/dotsync.calls" 2>&1)"
rm "$tmp/box-a/.local/bin/dotsync"

echo "dotsync on a paused peer"
# box-b gets this checkout's real dotsync, in a dotfiles clone of its own (never this checkout).
dseed="$tmp/dotfiles-seed"
mkdir -p "$dseed"
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  (cd "$root" && git ls-files -co --exclude-standard -z | xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$dseed"
else
  (cd "$root" && tar --exclude=./.git -cf - .) | tar -xf - -C "$dseed"
fi
sg -C "$dseed" init -q
sg -C "$dseed" add -A
sg -C "$dseed" commit -qm "dotfiles"
sg init -q --bare "$tmp/dotfiles.git"
sg -C "$dseed" push -q "$tmp/dotfiles.git" master
B="$tmp/box-b"
HOME="$B" git clone -q "$tmp/dotfiles.git" "$B/.dotfiles" 2>/dev/null
ln -s "$B/.dotfiles/scripts/dotsync" "$B/.local/bin/dotsync"
dotsync_b() { env -i HOME="$B" PATH="$clean_path" GIT_CONFIG_NOSYSTEM=1 LC_ALL=C TMPDIR="$tmp/t" DOTSYNC_NOTIFY=0 "$B/.local/bin/dotsync" "$@" 2>&1; }
check "box-b's dotsync pauses" "paused" "$(dotsync_b pause)"
# An edit dotsync would commit and push if it ran: old enough that only the pause holds it back.
printf '\npaused change\n' >> "$B/.dotfiles/README.md"
touch -t 202001010000 "$B/.dotfiles/README.md"
dot_before="$(git -C "$tmp/dotfiles.git" rev-parse master)"
peers box-a box-b
run_on box-a --verbose
check "box-b's codesync runs its dotsync as a peer, which defers while paused" "deferred: paused" "$out"
equal "...box-b's dotfiles edit stays uncommitted" " M README.md" "$(git -C "$B/.dotfiles" status --porcelain)"
equal "...and nothing reached the dotfiles origin" "$dot_before" "$(git -C "$tmp/dotfiles.git" rev-parse master)"
dotsync_b resume >/dev/null
rm -rf "$B/.dotfiles" "$B/.local/bin/dotsync"

echo "the checkout"
equal "nothing was written into the repo" "$before_status" "$(git -C "$root" status --porcelain)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
