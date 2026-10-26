#!/usr/bin/env bash
# subagent-context-hook — SubagentStart: give every subagent the leaf-worker
# contract (CLAUDE.base.md "Parallelism and delegation" and "Communication"), which
# coordinators often forget to restate in the prompt they write.
#
# Delegation is allowed when the agent's own definition asks for it, so orchestrator
# agents keep their parallel audits. Claude Code's internal agents
# (prompt suggestions, /btw) arrive with an empty agent_type and get nothing. The text
# is injected once per subagent and stays cached across its turns.
set -u
command -v jq >/dev/null 2>&1 || exit 0
agent=$(jq -r '.agent_type // ""' 2>/dev/null)
[[ -n "$agent" ]] || exit 0
jq -nc '{hookSpecificOutput: {hookEventName: "SubagentStart", additionalContext: (
  "This agent runs as a subagent of a coordinating Claude Code session. Complete the assignment " +
  "directly and return concrete results: file paths with line numbers, commands run with their " +
  "output, what was verified and what could not be. Start further subagents only when this " +
  "agent'"'"'s own instructions call for it. When naming code as a cause, state whether it was " +
  "read or run.")}}'
