#!/usr/bin/env bash
# reflections-context-hook — Codex SessionStart: hand the session this repo's open
# reflection items, the way load-memory-hook.sh does for Claude Code.
#
# Codex's SessionStart output schema (codex-cli 0.157, from the binary's embedded
# JSON schema) is exactly {hookEventName: "SessionStart", additionalContext}; extra
# keys are rejected (additionalProperties: false), so nothing else is emitted.
# stdin is read first: Codex logs a broken pipe when a hook exits without reading it.
set -u
command -v jq >/dev/null 2>&1 || exit 0
payload=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null)
if [[ -n "$cwd" && -d "$cwd" ]]; then cd "$cwd" || exit 0; fi
refl="${DOTFILES_DIR:-$HOME/.dotfiles}/scripts/reflections"
[[ -x "$refl" ]] || exit 0
ctx=$("$refl" context 2>/dev/null) || exit 0
[[ -n "$ctx" ]] || exit 0
jq -nc --arg c "$ctx" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
