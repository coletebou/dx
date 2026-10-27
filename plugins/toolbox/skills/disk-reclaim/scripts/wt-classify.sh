#!/usr/bin/env bash
# wt-classify.sh: classify every git checkout (worktree or standalone clone) directly under each
# DIR, and the worktrees nested in each checkout's .claude/worktrees/. Read-only.
#
#   wt-classify.sh [DIR...]                       (default: ~/code)
#   ssh <host> 'bash -s' < wt-classify.sh         (on a remote host, nothing installed there)
#
# One tab-separated row per checkout, after a header row that starts with "#":
#   dir  kind  branch  dirty  unpushed  on_remote  last_commit_days  live
# kind is worktree, standalone or nogit. unpushed counts commits ahead of the upstream ("-" without
# one); for a standalone clone it is "<ahead>/<local-only>", the second number counting commits on
# any local branch that no remote has. live means a process's working directory or a tmux pane is
# inside the checkout: never move or delete those. dirty is "?" when git cannot report the status
# (an unreadable index, say): unknown, so never a removal candidate.
set -u
# git status may otherwise refresh a checkout's index, a write: this survey makes none.
export GIT_OPTIONAL_LOCKS=0

# Working directories of this user's processes (Linux: /proc; macOS: lsof), plus tmux panes.
live_paths() {
  local p
  if [[ -d /proc/self ]]; then
    for p in /proc/[0-9]*/cwd; do readlink "$p" 2>/dev/null; done
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -a -u "$(id -u)" -d cwd -F n 2>/dev/null | sed -n 's/^n//p'
  fi
  tmux list-panes -a -F '#{pane_current_path}' 2>/dev/null
}
LIVE="$(live_paths | sort -u)"

is_live() {  # is_live DIR: a live path is DIR or inside it (component-wise, not a string prefix)
  local p
  while IFS= read -r p; do
    [[ -n "$p" && ( "$p" == "$1" || "$p" == "$1"/* ) ]] && return 0
  done <<<"$LIVE"
  return 1
}

classify() {  # classify DIR: one row
  local d="$1" real kind br st dirty unp onr local_only lc days live=idle
  # Process working directories are physical paths: a checkout behind a symlink is live when
  # either its own path or the one it resolves to holds one.
  real="$(cd "$d" 2>/dev/null && pwd -P)" || real="$d"
  if is_live "$d" || is_live "$real"; then live=live; fi
  if [[ ! -e "$d/.git" ]]; then
    printf '%s\tnogit\t-\t-\t-\t-\t-\t%s\n' "$d" "$live"
    return 0
  fi
  kind=standalone; [[ -f "$d/.git" ]] && kind=worktree
  br="$(git -C "$d" symbolic-ref --short -q HEAD 2>/dev/null \
    || echo "detached@$(git -C "$d" rev-parse --short HEAD 2>/dev/null)")"
  # A status git cannot produce (an unreadable index, say) is unknown, never 0 dirty files.
  if st="$(git -C "$d" status --porcelain --untracked-files=normal 2>/dev/null)"; then
    dirty="$(printf '%s' "$st" | grep -c . || true)"
  else
    dirty="?"
  fi
  if git -C "$d" rev-parse -q --verify '@{u}' >/dev/null 2>&1; then
    unp="$(git -C "$d" rev-list --count '@{u}..HEAD' 2>/dev/null)"
  else
    unp=-
  fi
  onr="$(git -C "$d" branch -r --contains HEAD 2>/dev/null | head -n 1 | tr -d ' ')"
  [[ -n "$onr" ]] && onr=yes || onr=no
  if [[ "$kind" == standalone ]]; then
    local_only="$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
    unp="${unp}/${local_only}"
  fi
  lc="$(git -C "$d" log -1 --format=%ct 2>/dev/null)" || lc=""
  [[ -n "$lc" ]] || lc=0
  days=$(( ($(date +%s) - lc) / 86400 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$kind" "$br" "$dirty" "$unp" "$onr" "$days" "$live"
}

[[ $# -gt 0 ]] || set -- "$HOME/code"
printf '#dir\tkind\tbranch\tdirty\tunpushed\ton_remote\tlast_commit_days\tlive\n'
for root in "$@"; do
  for d in "$root"/* "$root"/*/.claude/worktrees/*; do
    [[ -d "$d" ]] || continue
    classify "$d"
  done
done
