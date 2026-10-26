#!/usr/bin/env bash
# issue-focus-hook.sh — UserPromptSubmit hook: remember which issue this session
# is about, for the statusline's clickable issue link.
#
# Records the LAST issue reference in the prompt: a GitHub or GitLab issue URL,
# or a bare #N (2-6 digits; `!N` merge requests and `&#N;` entities are
# ignored). statusline.sh resolves a bare #N against the repo's origin (GitHub
# issues for github.com, GitLab issues for gitlab.com and the hosts in
# STATUSLINE_GITLAB_HOSTS) and prefers a number in the branch name over this file.
#
# Writes /tmp/claude-issue-<session_id> (same sanitizing as statusline.sh).
# Prints nothing: UserPromptSubmit stdout is added to the model's context.
input=$(cat)
IFS=$'\t' read -r session_id ref < <(jq -r '
  (.session_id // "") as $sid
  | (.prompt // "") as $p
  | [$p | match("https?://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+/-/issues/[0-9]+|https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[0-9]+|(?<![A-Za-z0-9_&!#])#[0-9]{2,6}(?![A-Za-z0-9_])"; "g")]
  | if length == 0 then empty else "\($sid)\t\(.[-1].string)" end
' <<<"$input" 2>/dev/null)
[[ -n "${session_id:-}" && -n "${ref:-}" ]] || exit 0
sid_file="${session_id//[^A-Za-z0-9._-]/_}"
out="/tmp/claude-issue-${sid_file}"
printf '%s\n' "${ref#\#}" > "$out.$$" 2>/dev/null && mv -f "$out.$$" "$out" 2>/dev/null
exit 0
