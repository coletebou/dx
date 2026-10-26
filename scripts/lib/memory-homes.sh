#!/usr/bin/env bash
# memory-homes.sh — shared resolver for "where does a repo's CANONICAL memory
# live" vs "where do that repo's session TRANSCRIPTS live."
#
# Sourced by: dream, dream-prep, session-analyzer, codex-memory-bridge.
#
# Two distinct location questions:
#
#   1. MEMORY HOME  — the dir Claude Code loads as its autoMemoryDirectory
#      (e.g. ~/.dotfiles/identities/example/claude/memory/webapp). This is
#      machine-INDEPENDENT: the dotfiles layout is the same on every machine,
#      so one conf value works everywhere. Defined in claude/memory-homes.conf
#      (template: claude/memory-homes.conf.example). This is where dream
#      promotes and where session-analyzer writes .analysis/. If you sync the
#      dotfiles tree with git (a private repo), every machine sees it.
#
#   2. TRANSCRIPT DIR — where the raw *.jsonl sessions land, i.e.
#      ~/.claude/projects/<escaped-cwd>. This is machine-DEPENDENT (the escaped
#      cwd holds the user name, which differs between machines). Defined in
#      claude/memory-canonicals.conf, keyed by `hostname -s`.
#
# Keeping the two apart is what lets each machine read its own transcripts
# while all of them write to the same synced memory home.

# Resolve the memory home for a repo shortname. Echoes the absolute dir
# ($HOME expanded) or nothing if the repo has no entry. Never fails.
#   memory_home_for webapp → $HOME/.dotfiles/identities/example/claude/memory/webapp
memory_home_for() {
  local repo="$1"
  local conf="${MEMORY_HOMES_CONF:-$HOME/.dotfiles/claude/memory-homes.conf}"
  [[ -f "$conf" ]] || return 0
  local line dir
  line="$(grep -v '^[[:space:]]*#' "$conf" | grep -v '^[[:space:]]*$' \
          | awk -v r="$repo" '$1==r { print $2; exit }')"
  [[ -n "$line" ]] || return 0
  # Expand a leading ~ or literal $HOME to the real home.
  dir="${line/#\~/$HOME}"
  dir="${dir//\$HOME/$HOME}"
  printf '%s\n' "$dir"
}

# Resolve the memory home for a repo, with a fallback to the legacy
# <transcript-dir>/memory layout when the repo isn't in memory-homes.conf.
# Args: <repo> <transcript-dir>. Always echoes a usable dir.
memory_home_or_legacy() {
  local repo="$1" transcript_dir="$2" home
  home="$(memory_home_for "$repo")"
  if [[ -n "$home" ]]; then
    printf '%s\n' "$home"
  else
    printf '%s\n' "$transcript_dir/memory"
  fi
}

# True if $(hostname -s) is in a space/comma-separated allowlist.
# Used to gate "only the hub promotes" behavior.
#   host_in_list "hub-box laptop" && ...
host_in_list() {
  local list="$1" me tok
  me="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  for tok in ${list//,/ }; do
    [[ "$(printf '%s' "$tok" | tr '[:upper:]' '[:lower:]')" == "$me" ]] && return 0
  done
  return 1
}
