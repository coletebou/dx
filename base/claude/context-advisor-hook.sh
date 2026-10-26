#!/usr/bin/env bash
# context-advisor-hook — PostToolBatch + UserPromptSubmit wrapper for context_advisor.py
# (design there: reflect at 55% of the advisory budget, Jev-backed advice at 70/85%).
# `context-advisor-hook.sh codex` is the Codex form (PostToolUse + UserPromptSubmit):
# reflect at 55%, one factual line at 70/85%, no Jev and no handoff.
#
# PostToolBatch runs before every model call, so the common case must cost nothing:
# below the floor, exit without starting Python. The floor is CONTEXT_ADVISOR_MIN_TOKENS
# (100k — below the lowest band of any budget) or, when the model window is known, the
# first reflection stage (CONTEXT_ADVISOR_MIN_PCT, 20% of the window) if that is lower, so
# a 200k-window session still gets its 20% checkpoint. Claude's count and window are one
# small jq read of the statusline's context sensor; Codex has no sensor, so both come from
# the newest token_count event in the last MiB of the rollout.
# Fails open: disabled, a hook child, missing tools, any error → exit 0, no output.
set -u
[[ "${CONTEXT_ADVISOR_DISABLE:-0}" == "1" || "${AGENT_HOOK_CHILD:-0}" == "1" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
agent="${1:-claude}"
payload=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
[[ -n "$sid" ]] || exit 0
known=0 tokens=0 size=0 usage=""
if [[ "$agent" == "codex" ]]; then
  known=1
  rollout=$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)
  [[ -r "$rollout" ]] && usage=$(tail -c 1048576 "$rollout" 2>/dev/null | grep '"last_token_usage"' | tail -n 1 \
    | jq -r 'select(.payload.type == "token_count") | .payload.info
             | "\(.last_token_usage.total_tokens // 0) \(.model_context_window // 0)"' 2>/dev/null)
else
  sensor="${CONTEXT_SENSOR_DIR:-$HOME/.claude/state/context}/${sid//[^A-Za-z0-9._-]/_}.json"
  [[ -r "$sensor" ]] && known=1 && usage=$(jq -r '"\(.tokens // 0) \(.size // 0)"' "$sensor" 2>/dev/null)
fi
read -r tokens size <<<"$usage"
if (( known )); then
  [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  floor=${CONTEXT_ADVISOR_MIN_TOKENS:-100000}
  stage_floor=$(( size * ${CONTEXT_ADVISOR_MIN_PCT:-20} / 100 ))
  (( size > 0 && stage_floor < floor )) && floor=$stage_floor
  if (( tokens < floor )); then
    # Below the floor nothing can fire, but a cycle that already fired must still
    # re-arm after /compact or /clear, and only Python can do that. So start it
    # only while a live cycle is on record (band >= 0; a builtin read, no fork).
    state="${CONTEXT_ADVISOR_STATE_DIR:-$HOME/.claude/state/context-advisor}/${sid//[^A-Za-z0-9._-]/_}.json"
    line=""
    [[ -r "$state" ]] && IFS= read -r line < "$state"
    [[ -z "$line" || "$line" =~ \"band\":\ -1[,}] ]] && exit 0
  fi
fi
command -v python3 >/dev/null 2>&1 || exit 0
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
if [[ "$agent" == "codex" ]]; then
  exec python3 "$here/context_advisor.py" --agent codex <<<"$payload"
fi
exec python3 "$here/context_advisor.py" <<<"$payload"
