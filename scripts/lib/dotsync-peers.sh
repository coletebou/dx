#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2154  # strict_peers, sender_identity and the paths are scripts/dotsync's
# dotsync-peers.sh: which machines dotsync updates, and how it updates one. Sourced by
# scripts/dotsync (after dotsync-runtime.sh) before a run starts. Bash 3.2 compatible.
#
# Peers come from configuration, never from a built-in list:
#   - the peers file, $DOTSYNC_PEERS_FILE (default ~/.config/dotsync/peers): one ssh alias per
#     line, optionally followed by the identity and the role that machine runs (`-` for unknown);
#   - identities/<identity>/dotsync-peers in the checkout, the same format, so one list can
#     travel with the repository;
#   - with DOTSYNC_TAILSCALE_TAG set, the online tailnet machines carrying that tag (opt-in).
# An identity in a list only pre-filters; every peer's own ~/.df-profile is read before anything
# runs there, and a peer whose identity differs, or cannot be read, is never synced.

# dotsync_peers_read FILE SOURCE: valid entries as alias<TAB>identity<TAB>role<TAB>source.
dotsync_peers_read() {
  local file="$1" source="$2" line alias identity role
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    alias="" identity="" role=""
    read -r alias identity role _ <<<"$line" || true
    [[ -n "$alias" ]] || continue
    if ! dotsync_valid_host "$alias"; then
      printf 'dotsync: %s: skipping an invalid peer name: %s\n' "$file" "$alias" >&2
      continue
    fi
    [[ "$identity" != - ]] || identity=""
    [[ "$role" != - ]] || role=""
    if [[ -n "$identity" ]] && ! dotsync_valid_identity "$identity"; then
      printf 'dotsync: %s: skipping %s: invalid identity %s\n' "$file" "$alias" "$identity" >&2
      continue
    fi
    printf '%s\t%s\t%s\t%s\n' "$alias" "${identity:--}" "${role:--}" "$source"
  done <"$file"
}

# dotsync_peers_list IDENTITY: the configured peers, the peers file first, deduplicated
# case-insensitively. IDENTITY selects the repository's list.
dotsync_peers_list() {
  local identity="$1" seen="|" alias rest key
  {
    dotsync_peers_read "$DOTSYNC_PEERS_FILE" peers-file
    if [[ -n "$identity" ]]; then
      dotsync_peers_read "$DOTFILES_DIR/identities/$identity/dotsync-peers" "identities/$identity/dotsync-peers"
    fi
  } | while IFS=$'\t' read -r alias rest; do
    key="$(dotsync_lower "$alias")"
    [[ "$seen" != *"|$key|"* ]] || continue
    seen="$seen$key|"
    printf '%s\t%s\n' "$alias" "$rest"
  done
}

# The opt-in tailnet source: online machines tagged $1 that can run sshd. Phones, Windows hosts
# (their dotfiles live in a WSL node of their own), the browser console and machines shared in
# from another tailnet never qualify.
DOTSYNC_TAILNET_FILTER='
  .Peer // {} | to_entries[] | .value
  | select(.Online == true)
  | select(.ShareeNode != true)
  | select((.OS // "") | test("^(iOS|android|windows|js)$"; "i") | not)
  | select((.Tags // []) | index($tag))
  | .HostName // empty'

dotsync_tailnet_peers() {
  local tag="$1" host
  [[ -n "$tag" ]] || return 0
  if ! command -v tailscale >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "dotsync: DOTSYNC_TAILSCALE_TAG is set but tailscale or jq is missing; no tailnet peers" >&2
    return 0
  fi
  dotsync_timeout 10 tailscale status --json 2>/dev/null | jq -r --arg tag "$tag" "$DOTSYNC_TAILNET_FILTER" 2>/dev/null \
    | while IFS= read -r host; do
        if dotsync_valid_host "$host"; then
          printf '%s\n' "$host"
        else
          printf 'dotsync: skipping a tailnet machine with an unsafe name: %s\n' "$host" >&2
        fi
      done
}

# ssh options for every connection to one peer. The first connection opens a control socket
# the rest reuse; BatchMode never waits on a password prompt.
dotsync_ssh_opts() {
  printf '%s' "-o ConnectTimeout=$DOTSYNC_SSH_TIMEOUT -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o ControlMaster=auto -o ControlPath=$SSH_CM_DIR/%C -o ControlPersist=15"
}

# dotsync_mark LIST HOST: record a peer outcome for the fan-out summary.
dotsync_mark() {
  printf '%s\n' "$2" >>"$SSH_CM_DIR/$1"
}

# dotsync_sync_peer HOST DISCOVERED EXPECTED_SHA: verify one peer, then run its own
# `dotsync --local` over ssh, bounded by DOTSYNC_PEER_TIMEOUT. Prints one line. Outcomes land
# in $SSH_CM_DIR: succeeded, failed (incomplete, counted in a partial result) and errors (a
# failure of the run). Neither the lock (fd 9) nor the caller's stdout (fd 3) reaches ssh, so a
# hung peer cannot hold either once its timeout fires.
dotsync_sync_peer() {
  local host="$1" discovered="$2" expected="$3" log opts probe rc=0 identity machine script output summary
  log="$TIMING_LOG_DIR/peer-$host.log"
  (umask 077; : >"$log")
  # shellcheck disable=SC2086  # opts is a list of ssh options
  opts="$(dotsync_ssh_opts)"

  # 1. Read the peer's profile, as data, before anything runs there.
  # shellcheck disable=SC2086
  probe="$(dotsync_timeout "$((DOTSYNC_SSH_TIMEOUT + 10))" ssh $opts "$host" sh -s \
    <<<"$(dotsync_peer_probe_script)" 2>>"$log" 3>&- 9>&-)" || rc=$?
  identity="$(printf '%s\n' "$probe" | sed -n 's/^DF_IDENTITY=//p' | head -n 1)"
  machine="$(printf '%s\n' "$probe" | sed -n 's/^DF_MACHINE=//p' | head -n 1)"
  if [[ "$rc" -ne 0 ]] || ! dotsync_valid_identity "$identity"; then
    dotsync_mark failed "$host"
    # An unreachable listed peer (an asleep laptop) is incomplete, not a failure, unless it was
    # named or the run is strict. A discovered machine that is not a dotfiles peer is neither.
    if [[ "$strict_peers" -eq 1 ]] || { [[ "$rc" -ne 255 ]] && [[ "$discovered" -eq 0 ]]; }; then
      dotsync_mark errors "$host"
    fi
    if [[ "$rc" -eq 255 ]]; then
      dotsync_mark unreachable "$host"
      printf '%s: unreachable (ssh rc=255): %s; details: %s\n' "$host" \
        "$(grep -v '^Pseudo-terminal' "$log" | grep -m1 . | cut -c1-120)" "$log"
    elif [[ "$rc" -eq 124 ]]; then
      printf '%s: no answer within %ss; details: %s\n' "$host" "$((DOTSYNC_SSH_TIMEOUT + 10))" "$log"
    else
      printf '%s: identity not verified (rc=%s, no valid DF_IDENTITY in its ~/.df-profile); not synced%s\n' \
        "$host" "$rc" "$([[ "$discovered" -eq 1 ]] && printf ' (found on the tailnet, not listed: not a failure)')"
    fi
    return 0
  fi
  if [[ "$identity" != "$sender_identity" ]]; then
    printf '%s: skipped (identity %s differs from %s)\n' "$host" "$identity" "$sender_identity"
    return 0
  fi
  if [[ -n "$machine" ]] && dotsync_same_host "$machine" "$_DOTSYNC_HOST"; then
    printf '%s: skipped (that is this machine)\n' "$host"
    return 0
  fi

  # 2. Its own dotsync. The script refuses again on the peer if its identity changed since.
  script="$(dotsync_peer_script "$expected" "$sender_identity" "$_DOTSYNC_HOST" \
    "${DOTSYNC_REMOTE_DOTSYNC:-\$HOME/.local/bin/dotsync}")" || {
    dotsync_mark failed "$host"; dotsync_mark errors "$host"
    printf '%s: cannot build the peer command (check DOTSYNC_REMOTE_DOTSYNC)\n' "$host"
    return 0
  }
  rc=0
  # shellcheck disable=SC2086
  output="$(dotsync_timeout "$DOTSYNC_PEER_TIMEOUT" ssh $opts "$host" sh -s <<<"$script" 2>>"$log" 3>&- 9>&-)" || rc=$?
  printf '%s\n' "$output" >>"$log"
  summary="$(printf '%s\n' "$output" | grep '^result=' | tail -n 1 || true)"
  case "$rc" in
    0)
      if [[ "$summary" == result=deferred* ]]; then
        dotsync_mark failed "$host"
        printf '%s: %s (paused, or someone is editing there; it syncs on its next run)\n' "$host" "$summary"
      else
        dotsync_mark succeeded "$host"
        printf '%s: %s\n' "$host" "${summary:-ok}"
      fi
      ;;
    3) dotsync_mark failed "$host"; dotsync_mark errors "$host"
       printf '%s: CONFIG STALE (it does not hold %s after its sync); %s\n' "$host" "${expected:0:12}" "$summary" ;;
    4) printf '%s: skipped (its identity changed before the sync)\n' "$host" ;;
    5) dotsync_mark failed "$host"; dotsync_mark errors "$host"
       printf '%s: refused (no identity in its ~/.df-profile)\n' "$host" ;;
    75) dotsync_mark failed "$host"
        printf '%s: busy (another dotsync holds its lock); it syncs on its next run\n' "$host" ;;
    124) dotsync_mark failed "$host"; dotsync_mark errors "$host"
         printf '%s: timed out after %ss (its own run continues there); details: %s\n' "$host" "$DOTSYNC_PEER_TIMEOUT" "$log" ;;
    127) dotsync_mark failed "$host"; dotsync_mark errors "$host"
         printf '%s: dotsync is not installed there (install.sh --with sync); details: %s\n' "$host" "$log" ;;
    255) dotsync_mark failed "$host"; dotsync_mark unreachable "$host"
         [[ "$strict_peers" -eq 0 ]] || dotsync_mark errors "$host"
         printf '%s: unreachable (ssh rc=255); details: %s\n' "$host" "$log" ;;
    *) dotsync_mark failed "$host"; dotsync_mark errors "$host"
       printf '%s: sync incomplete (its dotsync exited %s); %s; details: %s\n' "$host" "$rc" "${summary:-no result line}" "$log" ;;
  esac
  return 0
}
