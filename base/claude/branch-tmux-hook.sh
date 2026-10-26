#!/usr/bin/env bash
# SessionStart(source=fork) -> open a new tmux window resuming the ORIGINAL session.
# /branch replaces the current session in-place with the new fork; this puts the
# pre-branch conversation back in front of you in its own window.
set -uo pipefail

payload=$(cat)
source=$(printf '%s' "$payload" | jq -r '.source // empty')
[[ $source == "fork" ]] || exit 0
[[ -n ${TMUX:-} ]] || exit 0

transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty')
[[ -n $transcript ]] || exit 0

# The fork transcript is written concurrently with session start; poll briefly.
orig=""
for _ in $(seq 1 40); do
  if [[ -s $transcript ]]; then
    orig=$(jq -r 'select(.forkedFrom?.sessionId) | .forkedFrom.sessionId' "$transcript" 2>/dev/null | head -1)
    [[ -n $orig ]] && break
  fi
  sleep 0.1
done
[[ -n $orig ]] || exit 0
# The id goes into a shell command line below, so accept only an id's shape.
[[ $orig =~ ^[A-Za-z0-9_-]{1,64}$ ]] || exit 0

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty')
[[ -d ${cwd:-} ]] || cwd=$PWD

# CLAUDE_BRANCH_RESUME_CMD is the command that resumes the original session,
# e.g. "claude --dangerously-skip-permissions" if that is how you run Claude.
tmux new-window -a -c "$cwd" -n "orig:${orig:0:6}" \
  "${CLAUDE_BRANCH_RESUME_CMD:-claude} -r $orig"
printf '{"systemMessage":"Original session %s reopened in a new tmux window."}\n' "${orig:0:8}"
