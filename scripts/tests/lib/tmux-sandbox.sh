# shellcheck shell=bash
# tmux-sandbox.sh: private tmux servers for tests, built so a test can never reach a
# real one. Source it from a bash test:
#
#   . "$here/lib/tmux-sandbox.sh"
#   tsb_init "$tmp"                    # unsets TMUX/TMUX_PANE, puts a guarded `tmux` first on PATH
#   tsb_own origin handoffs            # session names this test may create
#   tsb new-session -d -s origin ...   # every harness call: -S <private socket>, explicitly
#   tsb_teardown                       # kills only servers it created, only if all their sessions are ours
#
# Why: inside a tmux pane $TMUX names that server's socket, and tmux prefers it to
# TMUX_TMPDIR. `TMUX_TMPDIR=/tmp/x tmux kill-server` typed from an agent's pane once killed
# a REAL server and every Claude session on it with it.
#
# The layers:
#   - tsb_init unsets TMUX and TMUX_PANE, remembers the server it was started inside, and
#     picks a socket inside the test's own temp dir; tsb_socket_ok refuses any socket in a
#     real tmux socket directory (/tmp/tmux-$UID, $TMUX_TMPDIR/tmux-$UID, /private/tmp on a
#     Mac), the socket this shell was started in, or anything outside the sandbox root.
#   - Every harness call goes through tsb (or tsb_at <socket>), which passes -S explicitly.
#   - Code under test runs `tmux` from PATH, which is the guard script installed here: it
#     always passes -S $TSB_SOCK, ignores $TMUX, refuses a caller's own -S/-L, refuses a
#     socket outside the sandbox, and refuses kill-server outright (only tsb_teardown may).
#   - TMUX_TMPDIR points inside the sandbox too, so even the real binary called by
#     absolute path with TMUX unset lands in it.
#   - tsb_teardown kills a server only when it created that socket and every session on it
#     is one the test declared with tsb_own; anything else means the socket is not ours.

tsb_refuse() { printf 'tmux-sandbox: refused: %s\n' "$*" >&2; return 97; }

# tsb_require_private_tmp: call it first. The real server's socket must not even be visible,
# so run the test under a private /tmp. On Linux:
#   sudo systemd-run --wait --pipe --collect --uid="$(id -u)" --gid="$(id -g)" -p PrivateTmp=yes \
#     -E HOME="$HOME" -E PATH="$PATH" --working-directory="$PWD" -- bash <test>
# A Mac has no private /tmp: TSB_ALLOW_SHARED_TMP=1 accepts the guards below on their own.
tsb_require_private_tmp() {
  local d sock
  for d in "/tmp/tmux-$(id -u)" "/private/tmp/tmux-$(id -u)"; do
    for sock in "$d"/*; do
      [[ -S "$sock" ]] || continue
      if [[ "${TSB_ALLOW_SHARED_TMP:-}" == 1 ]]; then
        printf 'tmux-sandbox: note: %s is visible (TSB_ALLOW_SHARED_TMP=1); relying on the guards alone\n' "$sock" >&2
        return 0
      fi
      tsb_refuse "a real tmux socket is visible ($sock). Run this test under a private /tmp (sudo systemd-run ... -p PrivateTmp=yes ..., see tmux-sandbox.sh), or set TSB_ALLOW_SHARED_TMP=1 where none exists (macOS)"
      return
    done
  done
  return 0
}

# tsb_real_dirs: the directories real tmux servers of this user put their sockets in.
tsb_real_dirs() {
  local uid; uid="$(id -u)"
  printf '%s\n' "/tmp/tmux-$uid" "/private/tmp/tmux-$uid" "${TSB_ORIG_TMUX_TMPDIR:-/tmp}/tmux-$uid"
}

# tsb_socket_ok <path>: 0 only for a socket path inside the sandbox root, never a real one.
tsb_socket_ok() {
  local s="$1" d parent
  [[ "$s" == /* ]] || { tsb_refuse "socket path must be absolute: $s"; return; }
  [[ -n "${TSB_ROOT:-}" ]] || { tsb_refuse "tsb_init has not run"; return; }
  parent="$(cd "$(dirname "$s")" 2>/dev/null && pwd -P)" || parent="$(dirname "$s")"
  while IFS= read -r d; do
    case "$s/" in "$d"/*) tsb_refuse "$s is in a real tmux socket directory ($d)"; return ;; esac
    case "$parent/" in "$d"/*) tsb_refuse "$s resolves into a real tmux socket directory ($d)"; return ;; esac
  done < <(tsb_real_dirs)
  if [[ -n "${TSB_ORIG_SOCK:-}" && ( "$s" == "$TSB_ORIG_SOCK" || "$parent/$(basename "$s")" == "$TSB_ORIG_SOCK" ) ]]; then
    tsb_refuse "$s is the server this shell was started in"; return
  fi
  case "$parent/" in "$TSB_ROOT"/*) ;; *) tsb_refuse "$s is outside the sandbox $TSB_ROOT"; return ;; esac
  return 0
}

# tsb_find_real: the first tmux on PATH that is a real binary, not some sandbox's guard.
tsb_find_real() {
  local c
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    head -n 2 "$c" 2>/dev/null | grep -q 'sandboxed by scripts/tests/lib/tmux-sandbox.sh' && continue
    printf '%s\n' "$c"
    return 0
  done < <(type -aP tmux 2>/dev/null)
  return 1
}

# tsb_flag_word WORD: one of tmux's global-flag words, read letter by letter as its getopt
# reads it. Prints S or L when the word selects a socket, 1 when its last letter takes the
# next word as its value (-f, -uf), else 0. A value letter with text after it has its value
# attached (-fconf, -S/path): nothing after it in the word is a flag.
tsb_flag_word() {
  local rest="${1#-}" l
  while [[ -n "$rest" ]]; do
    l="${rest:0:1}" rest="${rest:1}"
    case "$l" in
      S|L) printf '%s\n' "$l"; return 0 ;;
      c|f|T) if [[ -n "$rest" ]]; then printf '0\n'; else printf '1\n'; fi; return 0 ;;
    esac
  done
  printf '0\n'
}

# tsb_init <dir>: the sandbox lives in <dir> (a fresh mktemp -d). Sets TSB_ROOT, TSB_SOCK,
# TSB_REAL and TSB_BIN, and exports what the guard script needs.
tsb_init() {
  local dir="$1" real ambient="${TMUX:-}"
  [[ -d "$dir" ]] || { tsb_refuse "sandbox dir $dir does not exist"; return; }
  # Remember where this shell runs before forgetting it: that server is never a target.
  TSB_ORIG_SOCK="${ambient%%,*}"
  TSB_ORIG_TMUX_TMPDIR="${TMUX_TMPDIR:-}"
  export TSB_ORIG_SOCK TSB_ORIG_TMUX_TMPDIR
  unset TMUX TMUX_PANE
  TSB_ROOT="$(cd "$dir" && pwd -P)"
  real="$(tsb_find_real || true)"
  case "$real" in ""|"$TSB_ROOT"/*) tsb_refuse "no real tmux binary on PATH"; return ;; esac
  TSB_REAL="$real"
  TSB_SOCK="$TSB_ROOT/tsb/main.sock"
  TSB_BIN="$TSB_ROOT/tsb/bin"
  mkdir -p "$TSB_BIN" "$TSB_ROOT/tsb/tmpdir"
  : > "$TSB_ROOT/tsb/owned"
  tsb_socket_ok "$TSB_SOCK" || return
  if "$TSB_REAL" -S "$TSB_SOCK" list-sessions >/dev/null 2>&1; then
    tsb_refuse "a server already answers at $TSB_SOCK; it is not this test's"; return
  fi
  printf '%s\n' "$TSB_SOCK" > "$TSB_ROOT/tsb/created"   # the sockets this sandbox owns
  # The guard script. Values are baked in, so a changed environment cannot widen it.
  {
    printf '#!/usr/bin/env bash\n'
    printf '# tmux, sandboxed by scripts/tests/lib/tmux-sandbox.sh for one test run.\n'
    printf 'real=%q\nroot=%q\n' "$TSB_REAL" "$TSB_ROOT"
    declare -f tsb_flag_word
    cat <<'GUARD'
refuse() { printf 'tmux-sandbox: refused: %s\n' "$*" >&2; exit 97; }
sock="${TSB_SOCK:-}"
[[ -n "$sock" ]] || refuse "TSB_SOCK is unset"
case "$sock" in "$root"/*) ;; *) refuse "socket $sock is outside the sandbox $root" ;; esac
uid="$(id -u)"
for d in "/tmp/tmux-$uid" "/private/tmp/tmux-$uid"; do
  case "$sock" in "$d"/*) refuse "$sock is a real tmux socket" ;; esac
done
grep -Fxq -- "$sock" "$root/tsb/created" 2>/dev/null || refuse "socket $sock was not created by this sandbox"
# Global flags come before the first command; -S or -L there would pick another server.
# Each word is read as tmux's getopt reads it (tsb_flag_word), so neither `-uf /dev/null -S x`
# nor `-fconf -S x` hides the -S.
args=("$@") i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  case "$a" in
    -*) case "$(tsb_flag_word "$a")" in
          S|L) refuse "the caller passed $a; the sandbox owns the socket" ;;
          1) i=$((i + 2)) ;;
          *) i=$((i + 1)) ;;
        esac
        continue ;;
    *) break ;;
  esac
done
# kill-server anywhere (a command after \; counts too) is reserved for tsb_teardown.
for a in "$@"; do
  case "$a" in kill-ser|kill-serv|kill-serve|kill-server) [[ "${TSB_TEARDOWN:-}" == 1 ]] || refuse "kill-server is reserved for tsb_teardown" ;; esac
done
unset TMUX
exec "$real" -S "$sock" "$@"
GUARD
  } > "$TSB_BIN/tmux"
  chmod +x "$TSB_BIN/tmux"
  export TSB_ROOT TSB_REAL TSB_BIN TSB_SOCK
  export TMUX_TMPDIR="$TSB_ROOT/tsb/tmpdir"
  export PATH="$TSB_BIN:$PATH"
}

# tsb_new_socket <name>: another private server's socket (a second "host"); prints its path.
tsb_new_socket() {
  local s="$TSB_ROOT/tsb/$1.sock"
  tsb_socket_ok "$s" || return
  if "$TSB_REAL" -S "$s" list-sessions >/dev/null 2>&1; then tsb_refuse "a server already answers at $s"; return; fi
  grep -Fxq -- "$s" "$TSB_ROOT/tsb/created" || printf '%s\n' "$s" >> "$TSB_ROOT/tsb/created"
  printf '%s\n' "$s"
}

# tsb_at <socket> <tmux args...>: one call to a sandbox server, -S explicit.
tsb_at() {
  local s="$1"; shift
  tsb_socket_ok "$s" || return
  grep -Fxq -- "$s" "$TSB_ROOT/tsb/created" || { tsb_refuse "socket $s was not created by this sandbox"; return; }
  # Global flags come before the first command; a -S or -L there would win over ours. Each
  # word is read as tmux's getopt reads it, as in the guard.
  local a skip=0
  for a in "$@"; do
    if (( skip )); then skip=0; continue; fi
    case "$a" in
      -*) case "$(tsb_flag_word "$a")" in
            S|L) tsb_refuse "the caller passed $a; the sandbox owns the socket"; return ;;
            1) skip=1 ;;
          esac ;;
      *) break ;;
    esac
  done
  for a in "$@"; do
    case "$a" in kill-ser|kill-serv|kill-serve|kill-server) tsb_refuse "kill-server is reserved for tsb_teardown"; return ;; esac
  done
  "$TSB_REAL" -S "$s" "$@"
}
tsb() { tsb_at "$TSB_SOCK" "$@"; }

# tsb_own <session>...: names this test (or the code it runs) may create.
tsb_own() { printf '%s\n' "$@" >> "$TSB_ROOT/tsb/owned"; }

# tsb_teardown: kill each server this sandbox created, but only when every session on it
# is one the test declared. Returns 1 (and kills nothing there) when a socket holds
# anything else.
tsb_teardown() {
  local s sessions foreign rc=0
  [[ -n "${TSB_ROOT:-}" && -r "$TSB_ROOT/tsb/created" ]] || return 0
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    tsb_socket_ok "$s" || { rc=1; continue; }
    sessions="$("$TSB_REAL" -S "$s" list-sessions -F '#{session_name}' 2>/dev/null)" || continue
    foreign="$(grep -vxF -f "$TSB_ROOT/tsb/owned" <<<"$sessions" || true)"
    if [[ -n "$foreign" ]]; then
      tsb_refuse "not killing the server at $s: it holds sessions this test did not create ($(tr '\n' ' ' <<<"$foreign"))"
      rc=1; continue
    fi
    TSB_TEARDOWN=1 TSB_SOCK="$s" "$TSB_BIN/tmux" kill-server 2>/dev/null || true
  done < "$TSB_ROOT/tsb/created"
  return "$rc"
}
