#!/usr/bin/env bash
# shellcheck shell=bash
# dotsync-runtime.sh: dotsync's helpers that touch nothing on their own (parsing, validation,
# bounded commands, staging and the secret gate, hooks, heartbeats). Sourced by scripts/dotsync
# before a run starts, and by the test suites. Bash 3.2 compatible.

# Ceiling on each Git network call (ls-remote, fetch, push). A ceiling, not a delay.
DOTSYNC_GIT_TIMEOUT="${DOTSYNC_GIT_TIMEOUT:-120}"
# The ref every machine publishes its latest heartbeat to, one per machine.
DOTSYNC_HEARTBEAT_REFS=refs/dotsync/heartbeats
DOTSYNC_HEARTBEAT_FETCH="+$DOTSYNC_HEARTBEAT_REFS/*:$DOTSYNC_HEARTBEAT_REFS/*"

# ── names ────────────────────────────────────────────────────────────────
# A machine name or ssh alias: it is interpolated into ssh and git ref names, so only a safe
# charset passes (no leading dash, no shell metacharacters, no user@ or :port).
dotsync_valid_host() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$1" != *..* ]]
}

dotsync_valid_identity() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

dotsync_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

dotsync_same_host() {
  [[ "$(dotsync_lower "$1")" == "$(dotsync_lower "$2")" ]]
}

# ── ~/.df-profile, read as data ──────────────────────────────────────────
# Literal KEY=VALUE records, optionally prefixed with `export ` and simply quoted. Never
# sourced or evaluated: a line that runs a command yields nothing. Prints KEY=value for each
# key in `keys` that has a valid value. No single quote appears in the program, so it can be
# embedded in a single-quoted shell word on a peer.
DOTSYNC_PROFILE_AWK='
  BEGIN { n = split(keys, want, " ") }
  { sub(/\r$/, ""); sub(/^export[ \t]+/, "") }
  {
    for (i = 1; i <= n; i++) {
      key = want[i]
      if (index($0, key "=") != 1) continue
      value = substr($0, length(key) + 2)
      quote = substr(value, 1, 1)
      if ((quote == "\"" || quote == sprintf("%c", 39)) && length(value) >= 2 && substr(value, length(value), 1) == quote)
        value = substr(value, 2, length(value) - 2)
      found[key] = (value ~ /^[A-Za-z0-9][A-Za-z0-9._:-]*$/) ? value : ""
    }
  }
  END { for (i = 1; i <= n; i++) if (found[want[i]] != "") print want[i] "=" found[want[i]] }'

dotsync_profile_value() {  # dotsync_profile_value PROFILE KEY
  local profile="$1" key="$2"
  case "$key" in DF_MACHINE|DF_IDENTITY|DF_ROLE) ;; *) return 2 ;; esac
  [[ -r "$profile" ]] || return 1
  awk -v keys="$key" "$DOTSYNC_PROFILE_AWK" "$profile" | sed -n "s/^$key=//p"
}

# This machine's identity (the directory under identities/ it installed): DF_IDENTITY from the
# environment, else ~/.df-profile. Fails when neither holds a valid one.
dotsync_identity() {
  local identity="${DF_IDENTITY:-}"
  [[ -n "$identity" ]] || identity="$(dotsync_profile_value "$1" DF_IDENTITY 2>/dev/null)" || true
  dotsync_valid_identity "$identity" || return 1
  printf '%s\n' "$identity"
}

# This machine's name for heartbeats and self-detection: DF_MACHINE from the environment,
# else ~/.df-profile, else the short hostname. Lowercase; unknown-local when none is usable.
dotsync_machine() {
  local profile="$1" machine="${DF_MACHINE:-}"
  [[ -n "$machine" ]] || machine="$(dotsync_profile_value "$profile" DF_MACHINE 2>/dev/null)" || true
  if [[ -z "$machine" ]]; then
    machine="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
    machine="${machine%%.*}"
  fi
  machine="$(dotsync_lower "$machine")"
  dotsync_valid_host "$machine" || machine=unknown-local
  printf '%s\n' "$machine"
}

# ── the config file ──────────────────────────────────────────────────────
# Owned by this user and writable by nobody else: dotsync runs commands named in the config
# file and executables in the hooks directory, so another user must not be able to plant one.
dotsync_private_path() {
  local mode
  [[ -e "$1" ]] || return 0
  [[ -O "$1" && ! -L "$1" ]] || return 1
  mode="$(ls -ld "$1" 2>/dev/null)" || return 1
  [[ "${mode:5:1}" != w && "${mode:8:1}" != w ]]
}

# dotsync_load_config FILE: literal DOTSYNC_*=value lines. The environment wins over the file,
# so a timer drop-in or a one-off `DOTSYNC_X=1 dotsync` still decides. Never sourced.
dotsync_load_config() {
  local file="$1" line key value quote
  [[ -f "$file" ]] || return 0
  if ! dotsync_private_path "$file"; then
    printf 'dotsync: ignoring %s: it must be owned by you and writable only by you\n' "$file" >&2
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -n "$line" && "$line" != '#'* ]] || continue
    line="${line#export }"
    key="${line%%=*}"
    [[ "$line" == *=* && "$key" =~ ^DOTSYNC_[A-Z0-9_]+$ ]] || continue
    case "$key" in DOTSYNC_CONFIG_DIR|DOTSYNC_LOCK_HELD|DOTSYNC_EXPECTED_HEAD|DOTSYNC_TRIGGERED_BY) continue ;; esac
    value="${line#*=}"
    quote="${value:0:1}"
    if [[ ( "$quote" == '"' || "$quote" == "'" ) && ${#value} -ge 2 && "${value: -1}" == "$quote" ]]; then
      value="${value:1:${#value}-2}"
    fi
    [[ -z "${!key+set}" ]] || continue
    printf -v "$key" '%s' "$value"
    # shellcheck disable=SC2163  # exporting the variable the key names
    export "$key"
  done < "$file"
}

# ── bookkeeping ──────────────────────────────────────────────────────────
dotsync_fail() {
  # shellcheck disable=SC2034  # read by dotsync's EXIT handler
  EXIT_CODE=1
  # Later steps must not erase where the run first failed.
  [[ -n "${DOTSYNC_FAILED_PHASE:-}" ]] || DOTSYNC_FAILED_PHASE="$1"
  return 0
}

# A scratch file under $TMPDIR on every platform (macOS mktemp without a template ignores it).
dotsync_mktemp() {
  local dir="${TMPDIR:-/tmp}"
  mktemp "${dir%/}/dotsync.XXXXXX"
}

# A private scratch directory inside this repository's git dir. The caller removes it.
dotsync_scratch_dir() {
  local base
  base="$(git rev-parse --git-path dotsync-scratch)" || return 1
  mkdir -p "$base" && mktemp -d "$base/run.XXXXXX"
}

# dotsync_timeout SECONDS COMMAND...: never an unbounded command, even on a stock macOS
# without GNU timeout, and never a survivor: on expiry the command's whole process tree goes.
dotsync_timeout() {
  local seconds="$1" bin="" pid rc=0
  shift
  if [[ ! "$seconds" =~ ^[0-9]+([.][0-9]+)?$ || "$seconds" =~ ^0+([.]0+)?$ ]]; then
    printf 'dotsync: invalid timeout: %s\n' "$seconds" >&2
    return 2
  fi
  if command -v timeout >/dev/null 2>&1; then
    bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    bin=gtimeout
  fi
  if [[ -n "$bin" ]]; then
    # GNU timeout leads a process group of its own and signals all of it on expiry, but it
    # returns as soon as the command itself exits, so a descendant that ignores TERM would
    # live on, holding the caller's pipes and the lock. Started in the background (stdin kept)
    # only to learn its pid, which is that group's id: on expiry, whatever is left of the group
    # gets the same five seconds, then KILL.
    command "$bin" --kill-after=5 "$seconds" "$@" <&0 &
    pid=$!
    # A run interrupted while it waits here stops this group too (dotsync_timeout_cleanup).
    DOTSYNC_TIMEOUT_PGID="$pid"
    wait "$pid" || rc=$?
    DOTSYNC_TIMEOUT_PGID=""
    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
      for _ in 1 2 3 4 5; do
        kill -0 -- "-$pid" 2>/dev/null || break
        sleep 1
      done
      kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    return "$rc"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os, signal, subprocess, sys
try:
    child = subprocess.Popen(sys.argv[2:], start_new_session=True)
except OSError as exc:
    print("dotsync: command could not start: " + str(exc), file=sys.stderr)
    sys.exit(127)
def stop_group():
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    # The leader may exit on TERM while a grandchild ignores it: reap the group anyway.
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()
def interrupted(signum, _frame):
    stop_group()
    sys.exit(128 + signum)
for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, interrupted)
try:
    rc = child.wait(timeout=float(sys.argv[1]))
except subprocess.TimeoutExpired:
    stop_group()
    sys.exit(124)
sys.exit(rc if rc >= 0 else 128 - rc)
' "$seconds" "$@"
  else
    printf 'dotsync: cannot enforce timeout; install coreutils or Python 3\n' >&2
    return 127
  fi
}

# A signal ends a run while dotsync_timeout waits; its command must not outlive the run.
DOTSYNC_TIMEOUT_PGID=""
dotsync_timeout_cleanup() {
  local pgid="${DOTSYNC_TIMEOUT_PGID:-}"
  [[ -n "$pgid" ]] || return 0
  DOTSYNC_TIMEOUT_PGID=""
  kill -TERM -- "-$pgid" 2>/dev/null || return 0
  # What ignores TERM gets KILL five seconds later, from a detached helper (the run is ending).
  ( sleep 5; kill -KILL -- "-$pgid" 2>/dev/null ) </dev/null >/dev/null 2>&1 3>&- 9>&- &
}

# ── staging and the secret gate ──────────────────────────────────────────
# Read NUL-separated paths on stdin; write "<status>\0<path>\0" per path: 0 ignored, 1 not
# ignored, exactly as `git check-ignore --no-index -q` decides one path at a time, in one git
# process. $1 is a scratch directory.
dotsync_ignore_status() {
  local rc=0 ign_source ign_line pattern path
  git check-ignore --no-index --stdin -z --verbose --non-matching >"$1/check-ignore" || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 1 ]] || return 1
  # shellcheck disable=SC2034  # source and line are read only to advance the record
  while IFS= read -r -d '' ign_source && IFS= read -r -d '' ign_line \
      && IFS= read -r -d '' pattern && IFS= read -r -d '' path; do
    if [[ -n "$pattern" && "$pattern" != '!'* ]]; then
      printf '0\0%s\0' "$path"
    else
      printf '1\0%s\0' "$path"
    fi
  done <"$1/check-ignore"
}

# Stage what git reports as changed or new and not ignored, tracked deletions included, in one
# check-ignore and one add. --no-index also catches an ignored path someone force-added.
dotsync_stage_changes() {
  local scratch rc=0 path ignored added=0
  scratch="$(dotsync_scratch_dir)" || return 1
  : >"$scratch/add"
  git ls-files -z --deduplicate --modified --deleted --others --exclude-standard >"$scratch/paths" || rc=$?
  [[ "$rc" -eq 0 ]] && { dotsync_ignore_status "$scratch" <"$scratch/paths" >"$scratch/classified" || rc=$?; }
  if [[ "$rc" -ne 0 ]]; then
    echo 'dotsync: ignore check failed; refusing to stage' >&2
    rm -rf "$scratch"
    return 1
  fi
  while IFS= read -r -d '' ignored && IFS= read -r -d '' path; do
    # A deleted tracked file is staged even when an ignore rule now matches it.
    if [[ ! -e "$path" && ! -L "$path" ]] && git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      GIT_LITERAL_PATHSPECS=1 git rm -q --cached -- "$path" || { rc=1; break; }
      continue
    fi
    [[ "$ignored" -eq 1 ]] || continue
    printf '%s\0' "$path" >>"$scratch/add"
    added=1
  done <"$scratch/classified"
  if [[ "$rc" -eq 0 && "$added" -eq 1 ]]; then
    GIT_LITERAL_PATHSPECS=1 git add --pathspec-from-file="$scratch/add" --pathspec-file-nul || rc=$?
  fi
  rm -rf "$scratch"
  return "$rc"
}

# Everything an automatic commit must pass, on the staged index: no unmerged path, no ignored
# content, no conflict markers, and a gitleaks scan that found nothing.
dotsync_check_staged() {
  local scratch rc=0 path ignored
  if [[ -n "$(git ls-files -u 2>/dev/null)" ]]; then
    echo 'dotsync: unmerged paths (an unresolved conflict); refusing to commit' >&2
    return 1
  fi
  scratch="$(dotsync_scratch_dir)" || return 1
  git diff --cached --name-only -z --diff-filter=ACMRT >"$scratch/staged" || rc=$?
  [[ "$rc" -eq 0 ]] && { dotsync_ignore_status "$scratch" <"$scratch/staged" >"$scratch/classified" || rc=$?; }
  if [[ "$rc" -eq 0 ]]; then
    while IFS= read -r -d '' ignored && IFS= read -r -d '' path; do
      [[ "$ignored" -eq 1 ]] || { rc=1; break; }
    done <"$scratch/classified"
  fi
  rm -rf "$scratch"
  if [[ "$rc" -ne 0 ]]; then
    echo 'dotsync: ignored staged content or failed ignore check; refusing to commit' >&2
    return 1
  fi
  if git diff --cached --no-color --no-ext-diff -U0 2>/dev/null | grep -qE '^\+(<{7}|>{7}) '; then
    echo 'dotsync: staged changes hold conflict markers; refusing to commit' >&2
    return 1
  fi
  dotsync_scan_staged
}

# The secret gate fails closed: no gitleaks, a finding, or a scanner error all refuse. Raw
# scanner output never reaches dotsync's output, so a secret value is never printed.
dotsync_scan_staged() {
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo 'dotsync: gitleaks is required to commit (https://github.com/gitleaks/gitleaks); refusing to commit' >&2
    return 1
  fi
  if ! gitleaks git --pre-commit --staged --redact --no-banner . >/dev/null 2>&1; then
    echo 'dotsync: gitleaks found a potential secret in the changes (or could not finish); refusing to commit' >&2
    echo 'dotsync:   run: gitleaks git --pre-commit --staged --redact --verbose .   (false positive: .gitleaksignore)' >&2
    return 1
  fi
}

# dotsync_merge_diffs: the git log option that shows gitleaks what each merge commit adds. Plain
# `git log -p` shows no diff for a merge, so a conflict resolution could add a secret unseen.
# remerge (git 2.36+) shows only what the resolution changed against git's own merge of the
# parents; -m, the fallback, shows each parent's whole side again (safe, but noisier).
dotsync_merge_diffs() {
  if git log -1 --format= --diff-merges=remerge HEAD >/dev/null 2>&1; then
    echo --diff-merges=remerge
  else
    echo -m
  fi
}

# dotsync_scan_outgoing RANGE: the commits a push would publish, including ones made by hand
# with hooks skipped, and what any merge among them adds.
dotsync_scan_outgoing() {
  local opts
  if ! command -v gitleaks >/dev/null 2>&1; then
    echo 'dotsync: gitleaks is required to push; refusing to push' >&2
    return 1
  fi
  opts="$(dotsync_merge_diffs) $1"
  if ! gitleaks git --redact --no-banner --log-opts="$opts" . >/dev/null 2>&1; then
    echo "dotsync: gitleaks found a potential secret in the commits to push ($1), or could not finish; refusing to push" >&2
    echo "dotsync:   run: gitleaks git --redact --verbose --log-opts='$opts' ." >&2
    return 1
  fi
}

# dotsync_push_route BRANCH: where dotsync pushes BRANCH, as remote<TAB>ref: its upstream's
# remote and branch, and nowhere else. The outgoing scan compares against that upstream, so a
# push git would route elsewhere (pushRemote, pushDefault, a pushurl or pushInsteadOf rule,
# several URLs) is refused, with the reason: it could publish commits the scan never saw.
dotsync_push_route() {
  local b="$1" remote merge pushremote pushdefault urls pushurls
  remote="$(git config "branch.$b.remote" 2>/dev/null || true)"
  merge="$(git config "branch.$b.merge" 2>/dev/null || true)"
  if [[ -z "$remote" || "$merge" != refs/heads/* ]]; then
    echo "dotsync: refusing to push: branch $b has no upstream branch to push to" >&2
    return 1
  fi
  pushremote="$(git config "branch.$b.pushRemote" 2>/dev/null || true)"
  pushdefault="$(git config remote.pushDefault 2>/dev/null || true)"
  if [[ -n "$pushremote" && "$pushremote" != "$remote" ]]; then
    printf 'dotsync: refusing to push: branch.%s.pushRemote sends pushes to %s, but the secret scan compares against the upstream %s (unset it, or make %s the upstream)\n' \
      "$b" "$pushremote" "$remote" "$pushremote" >&2
    return 1
  fi
  if [[ -z "$pushremote" && -n "$pushdefault" && "$pushdefault" != "$remote" ]]; then
    printf 'dotsync: refusing to push: remote.pushDefault sends pushes to %s, but the secret scan compares against the upstream %s (unset it, or set branch.%s.pushRemote to %s)\n' \
      "$pushdefault" "$remote" "$b" "$remote" >&2
    return 1
  fi
  if [[ "$remote" != . ]]; then
    urls="$(git remote get-url --all "$remote" 2>/dev/null)" || { echo "dotsync: refusing to push: no URL for remote $remote" >&2; return 1; }
    pushurls="$(git remote get-url --push --all "$remote" 2>/dev/null)" || pushurls=""
    if [[ "$(printf '%s\n' "$urls" | wc -l | tr -d ' ')" -ne 1 ]]; then
      echo "dotsync: refusing to push: remote $remote has several URLs, and a push would go to each one; the secret scan compares against the first only" >&2
      return 1
    fi
    if [[ "$pushurls" != "$urls" ]]; then
      echo "dotsync: refusing to push: pushes to $remote go to another URL than its fetches (remote.$remote.pushurl, or a pushInsteadOf rule), which the secret scan never compared against" >&2
      return 1
    fi
  fi
  printf '%s\t%s\n' "$remote" "$merge"
}

# ── commit messages ──────────────────────────────────────────────────────
# The generic subject: who changed which top-level areas.
dotsync_commit_message() {
  local host="$1"
  shift
  python3 -c '
import subprocess, sys
paths = subprocess.check_output(["git", "diff", "--cached", "--name-only", "-z", "--", *sys.argv[2:]]).split(b"\0")
areas = sorted({p.split(b"/", 1)[0].decode("utf-8", "replace") for p in paths if p})
areas = ["".join(c if c.isprintable() else "?" for c in a) for a in areas]
print("chore(sync): " + sys.argv[1] + " update " + ", ".join(areas))
' "$host" "$@"
}

# A described message is opt-in: a provider or a command must be configured.
dotsync_commit_message_helper() {
  local helper="${DOTSYNC_COMMIT_MESSAGE_HELPER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dotsync-commit-message}"
  local provider="${DOTSYNC_COMMIT_MESSAGE_PROVIDER:-}"
  [[ -n "$provider" || -z "${DOTSYNC_COMMIT_MESSAGE_CMD:-}" ]] || provider="command"
  [[ -n "$provider" && "$provider" != off && -x "$helper" ]] || return 1
  printf '%s\n' "$helper"
}

# Print a described message for the staged change, or fail so the caller keeps the generic one.
dotsync_describe_staged() {
  local host="$1" helper message
  shift
  helper="$(dotsync_commit_message_helper)" || return 1
  message="$(dotsync_timeout "${DOTSYNC_COMMIT_MESSAGE_TIMEOUT:-20}" \
    "$helper" describe --host "$host" --staged -- "$@" 2>/dev/null </dev/null)" || return 1
  [[ -n "$message" ]] || return 1
  printf '%s\n' "$message"
}

# Before a push: describe this machine's unpublished commits that still carry a generic subject.
dotsync_reword_unpublished() {
  local host="$1" helper
  helper="$(dotsync_commit_message_helper)" || return 0
  dotsync_timeout "${DOTSYNC_COMMIT_MESSAGE_REWORD_TIMEOUT:-40}" "$helper" reword --host "$host" 2>/dev/null </dev/null || true
}

# ── one SSH connection per host for this run's own git calls ──────────────
# Sets dotsync_ssh_command, which the network git calls pass as `git -c core.sshCommand=...`
# (never exported, so other repositories keep their ssh). Only the plain setup shares: one URL
# per remote, no push-only routing and no submodules, because the socket is keyed on host, user
# and port, not on the ssh alias. An ssh command you chose wins; DOTSYNC_SSH_MUX=0 turns it off.
# shellcheck disable=SC2034  # read by dotsync's network git calls
dotsync_ssh_command=""
dotsync_share_ssh() {
  dotsync_ssh_command=""
  [[ "${DOTSYNC_SSH_MUX:-1}" != 0 && -z "${GIT_SSH_COMMAND:-}" && -z "${GIT_SSH:-}" ]] || return 0
  # OpenSSH binds <path>.<16 random characters> first; the whole must fit the 104-byte sun_path.
  local socket="$HOME/.ssh/ds$$-%C"
  [[ "$HOME" =~ ^/[A-Za-z0-9/._-]+$ ]] || return 0
  (( ${#socket} - 2 + 40 + 17 <= 103 )) || return 0
  # A predictable socket name needs a private directory.
  [[ -d "$HOME/.ssh" ]] && dotsync_private_path "$HOME/.ssh" || return 0
  [[ ! -e .gitmodules ]] || return 0
  local routing rc=0 key value seen="|"
  routing="$(git config --get-regexp \
    '^(core\.sshcommand|remote\.pushdefault|branch\..*\.pushremote|remote\..*\.(url|pushurl|skipfetchall)|url\..*\.pushinsteadof|submodule\..*|fetch\.all)$' \
    2>/dev/null)" || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 1 ]] || return 0
  # shellcheck disable=SC2034  # value is read only to split the line
  while read -r key value; do
    [[ -n "$key" ]] || continue
    [[ "$key" == remote.*.url && "$seen" != *"|${key%.url}|"* ]] || return 0
    seen="$seen${key%.url}|"
  done <<<"$routing"
  dotsync_ssh_command="ssh -o ControlMaster=auto -o ControlPath=$socket -o ControlPersist=10"
}

# ── hooks ────────────────────────────────────────────────────────────────
# dotsync_run_hooks STAGE: every executable in $DOTSYNC_HOOKS_DIR/STAGE.d, in name order, from
# the repository, each bounded by DOTSYNC_HOOK_TIMEOUT. A hook that exits non-zero fails the run
# at phase hook-STAGE; a pre-commit failure also stops the commit (the caller's decision).
# Hooks never inherit the lock or the caller's saved stdout.
dotsync_run_hooks() {
  local stage="$1" dir="${DOTSYNC_HOOKS_DIR:-}/$1.d" hook name rc out line failed=0
  [[ -n "${DOTSYNC_HOOKS_DIR:-}" && -d "$dir" ]] || return 0
  if ! dotsync_private_path "$DOTSYNC_HOOKS_DIR" || ! dotsync_private_path "$dir"; then
    echo "dotsync: refusing the $stage hooks: $dir must be owned by you and writable only by you" >&2
    dotsync_fail "hook-$stage"
    return 1
  fi
  for hook in "$dir"/*; do
    name="${hook##*/}"
    case "$name" in *~|*.disabled|*.sample|.*) continue ;; esac
    [[ -f "$hook" && -x "$hook" ]] || continue
    if ! dotsync_private_path "$hook"; then
      echo "dotsync: skipping hook $stage/$name: it must be owned by you and writable only by you" >&2
      dotsync_fail "hook-$stage"
      failed=1
      continue
    fi
    rc=0
    out="$( (cd "$DOTFILES_DIR" && DOTSYNC_HOOK="$stage" dotsync_timeout "${DOTSYNC_HOOK_TIMEOUT:-120}" "$hook") \
      </dev/null 2>&1 3>&- 9>&- )" || rc=$?
    if [[ -n "$out" ]]; then
      printf '%s\n' "$out" | while IFS= read -r line; do printf 'hook %s/%s: %s\n' "$stage" "$name" "$line"; done
    fi
    if [[ "$rc" -ne 0 ]]; then
      echo "dotsync: hook $stage/$name failed (exit $rc)" >&2
      dotsync_fail "hook-$stage"
      failed=1
      [[ "$stage" != pre-commit ]] || break
    fi
  done
  return "$failed"
}

# ── heartbeats ───────────────────────────────────────────────────────────
# Each run writes this machine's heartbeat to the state directory and publishes it as a
# one-commit ref, refs/dotsync/heartbeats/<machine>, force-pushed (one writer per ref, so it
# never races another machine and never touches a branch). Every fetch brings the others'.
dotsync_ensure_heartbeat_fetch() {
  local remote="$1"
  [[ -n "$remote" ]] && git remote get-url "$remote" >/dev/null 2>&1 || return 0
  git config --get-all "remote.$remote.fetch" 2>/dev/null | grep -qxF -- "$DOTSYNC_HEARTBEAT_FETCH" \
    || git config --add "remote.$remote.fetch" "$DOTSYNC_HEARTBEAT_FETCH" 2>/dev/null || true
}

# dotsync_heartbeat_publish FILE HOST REMOTE: bounded, best-effort.
dotsync_heartbeat_publish() {
  local file="$1" host="$2" remote="$3" ref blob tree commit
  [[ "${DOTSYNC_HEARTBEAT_PUSH:-1}" != 0 && -s "$file" && -n "$remote" ]] || return 0
  ref="$DOTSYNC_HEARTBEAT_REFS/$host"
  git check-ref-format "$ref" 2>/dev/null || return 0
  blob="$(git hash-object -w -- "$file")" || return 1
  tree="$(printf '100644 blob %s\theartbeat.json\n' "$blob" | git mktree)" || return 1
  commit="$(GIT_AUTHOR_NAME=dotsync GIT_AUTHOR_EMAIL=dotsync@localhost \
    GIT_COMMITTER_NAME=dotsync GIT_COMMITTER_EMAIL=dotsync@localhost \
    git commit-tree --no-gpg-sign -m "dotsync heartbeat: $host" "$tree" </dev/null)" || return 1
  git update-ref "$ref" "$commit" || return 1
  if ! dotsync_timeout "${DOTSYNC_HEARTBEAT_TIMEOUT:-15}" \
      git ${dotsync_ssh_command:+-c "core.sshCommand=$dotsync_ssh_command"} push --quiet "$remote" "+$ref:$ref" \
      </dev/null >/dev/null 2>&1 3>&- 9>&-; then
    echo "dotsync: could not publish the heartbeat to $remote (it is kept locally)" >&2
    return 1
  fi
}

# dotsync_json_field JSON KEY: a number or a simple string from a flat heartbeat, without jq.
dotsync_json_field() {
  printf '%s' "$1" | sed -n "s/.*\"$2\":\"\{0,1\}\([A-Za-z0-9._:-]*\)\"\{0,1\}[,}].*/\1/p" | head -n 1
}

dotsync_age_label() {
  local age="$1"
  if   [[ "$age" -lt 0 ]]; then printf 'in the future'
  elif [[ "$age" -lt 3600 ]]; then printf '%sm ago' "$(( age / 60 ))"
  elif [[ "$age" -lt 172800 ]]; then printf '%sh ago' "$(( age / 3600 ))"
  else printf '%sd ago' "$(( age / 86400 ))"
  fi
}

# ── the peer side of a fan-out ───────────────────────────────────────────
# Both scripts run on the peer as `sh -s` (any login shell can start that), read its profile as
# data, and never source anything.
dotsync_peer_probe_script() {
  printf 'p="$HOME/.df-profile"\n[ -r "$p" ] || exit 0\nawk -v keys="DF_IDENTITY DF_MACHINE" %s "$p"\n' \
    "'$DOTSYNC_PROFILE_AWK'"
}

# dotsync_peer_script EXPECTED_SHA IDENTITY SENDER REMOTE_DOTSYNC: refuses (exit 4, or 5 for no
# identity) before anything runs when the peer's identity is not the sender's, so a profile
# changed after the probe still never gets synced.
dotsync_peer_script() {
  local expected="$1" identity="$2" sender="$3" bin="$4"
  [[ "$expected" =~ ^[0-9a-f]{40,64}$ ]] || return 2
  dotsync_valid_identity "$identity" && dotsync_valid_host "$sender" || return 2
  [[ "$bin" =~ ^(\$HOME/|/)[A-Za-z0-9_./-]+$ ]] || return 2
  printf 'p="$HOME/.df-profile"\n'
  printf 'id=$( [ -r "$p" ] && awk -v keys=DF_IDENTITY %s "$p" | sed -n "s/^DF_IDENTITY=//p" )\n' "'$DOTSYNC_PROFILE_AWK'"
  printf '[ -n "$id" ] || exit 5\n'
  printf '[ "$id" = %s ] || exit 4\n' "$identity"
  printf 'DOTSYNC_EXPECTED_HEAD=%s DOTSYNC_TRIGGERED_BY=%s exec "%s" --local --one-line --peer </dev/null\n' \
    "$expected" "$sender" "$bin"
}

# ── the plan (--dry-run) ─────────────────────────────────────────────────
dotsync_print_plan() {  # dotsync_print_plan SELF IDENTITY LOCAL PULL_ONLY JSON PEERS_TSV [HOST...]
  local self="$1" identity="$2" local_only="$3" pull_only="$4" json="$5" peers="$6"
  shift 6
  if [[ "$json" -eq 1 ]]; then
    python3 -c '
import json, os, sys
self, identity, local, pull_only, peers = sys.argv[1:6]
hosts = sys.argv[6:]
listed = [dict(zip(("alias", "identity", "role", "source"), line.split("\t"))) for line in peers.splitlines() if line]
print(json.dumps({"schema_version": 1, "read_only": True, "machine": self, "identity": identity or None,
  "local_only": local == "1", "pull_only": pull_only == "1", "explicit_hosts": hosts,
  "peers": [] if local == "1" else (hosts and [{"alias": h, "source": "--host"} for h in hosts] or listed),
  "tailnet_tag": None if local == "1" or hosts else (os.environ.get("DOTSYNC_TAILSCALE_TAG") or None),
  "steps": ["guard unattended runs", "commit local changes behind the secret scan", "pull and rebase",
            "push behind the secret scan", "rerun install.sh when the pull changed it", "publish the heartbeat"] +
           ([] if local == "1" else ["verify each peer identity", "sync each peer"])}, indent=2))
' "$self" "$identity" "$local_only" "$pull_only" "$peers" "$@"
    return
  fi
  printf 'dotsync plan for %s (identity %s): read-only, no network calls or writes\n' "$self" "${identity:-unknown}"
  [[ "$pull_only" -eq 1 ]] && echo '  mode: pull only (no automatic commits, no push)'
  if [[ "$local_only" -eq 1 ]]; then
    echo '  peers: none (--local)'
  elif [[ "$#" -gt 0 ]]; then
    printf '  peers: %s (named with --host)\n' "$*"
  elif [[ -n "$peers" ]]; then
    echo '  peers:'
    printf '%s\n' "$peers" | awk -F '\t' 'NF { printf "    %-20s identity %-10s role %-8s from %s\n", $1, $2, $3, $4 }'
  else
    echo '  peers: none listed (see dotsync peers)'
  fi
  [[ -z "${DOTSYNC_TAILSCALE_TAG:-}" || "$local_only" -eq 1 || "$#" -gt 0 ]] \
    || printf '  plus online tailnet machines tagged %s (found when the run starts)\n' "$DOTSYNC_TAILSCALE_TAG"
  echo '  steps: guard; commit (secret scan); pull; push (secret scan); install.sh if needed; heartbeat'
  [[ "$local_only" -eq 1 ]] || echo '         then each peer: verify its identity, run its own dotsync --local'
  echo '  a peer whose identity differs, or cannot be read, is never synced'
}
