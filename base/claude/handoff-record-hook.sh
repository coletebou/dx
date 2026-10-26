#!/usr/bin/env bash
# handoff-record-hook — UserPromptExpansion (/handoff typed) and PreToolUse (Skill tool
# invoking handoff): add one step to the handoff skill without editing it.
#
# /handoff lives in the public openclaw/agent-skills repo, so storage specific to this
# setup must not go into its SKILL.md. This hook adds the step only where the reflections
# store is installed: after the prompt is on the clipboard, also record it in the store as
# an open handoff, so the receiving session (and `reflections list`) can find and close it.
set -u
command -v jq >/dev/null 2>&1 || exit 0
command -v reflections >/dev/null 2>&1 || [[ -x "${DOTFILES_DIR:-$HOME/.dotfiles}/scripts/reflections" ]] || exit 0
payload=$(cat)
event=$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null)
case "$event" in
  UserPromptExpansion)
    [[ "$(jq -r '.command_name // ""' <<<"$payload")" == "handoff" ]] || exit 0 ;;
  PreToolUse)
    [[ "$(jq -r '.tool_input.skill // ""' <<<"$payload")" =~ (^|:)handoff$ ]] || exit 0 ;;
  *) exit 0 ;;
esac
jq -nc --arg ev "$event" '{hookSpecificOutput: {hookEventName: $ev, additionalContext: (
  "This setup records handoffs in the reflections store. After the handoff prompt is written " +
  "and copied, also run: reflections add --kind handoff --origin handoff --title \"<the task, one line>\" " +
  "--body - < <the prompt file>  — then include the printed #id in the confirmation so the receiving " +
  "session can close it with `reflections done <id>`.")}}'
