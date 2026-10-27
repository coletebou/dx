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
# a 200k-window session still gets its 20% checkpoint. A smaller advisory budget
# (CONTEXT_ADVISOR_WINDOW, else the smallest one in the budgets file) can put its first band
# under that floor; below the floor one more jq read finds that band, so it still fires on
# time. Claude's count and window are one
# small jq read of the statusline's context sensor; Codex has no sensor, so both come from
# the newest token_count event in the last MiB of the rollout.
# Fails open: disabled, a hook child, missing tools, any error → exit 0, no output.
set -u
[[ "${CONTEXT_ADVISOR_DISABLE:-0}" == "1" || "${AGENT_HOOK_CHILD:-0}" == "1" ]] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
# The first band of the smallest advisory budget configured, in tokens, or nothing. Taking the
# smallest one anywhere (not the cwd's) avoids matching paths here; it can only start Python
# early, never late. Bands and budgets are validated the way context_advisor.py does.
budget_floor() {
  local file="${CONTEXT_ADVISOR_BUDGETS:-$HOME/.config/context-advisor/budgets.json}"
  [[ -n "${CONTEXT_ADVISOR_WINDOW:-}" || -r "$file" ]] || return 0
  { [[ -z "${CONTEXT_ADVISOR_WINDOW:-}" && -r "$file" ]] && cat "$file" || echo '{}'; } \
    | jq -r --arg w "${CONTEXT_ADVISOR_WINDOW:-}" --arg b "${CONTEXT_ADVISOR_BANDS:-}" '
        ([$b | gsub("\\s"; "") | splits(",") | tonumber?]
          | if length == 3 and all(. > 0 and . <= 1) then min else 0.55 end) as $band
        | (if $w != "" then [$w | tonumber?] else [objects | .[] | tonumber?] end
          | map(select(. > 0)) | min) as $budget
        | if $budget then $budget * $band | floor else empty end' 2>/dev/null
}
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
    bf=$(budget_floor)
    [[ "$bf" =~ ^[0-9]+$ ]] && (( bf < floor )) && floor=$bf
  fi
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
