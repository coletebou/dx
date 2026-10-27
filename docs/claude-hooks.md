# Claude Code hooks

`base/claude/settings.base.json` wires these hooks; `install.sh --with claude` merges it into
`~/.claude/settings.json` with your role's, identity's and machine's layers (`scripts/lib/
agent-settings.jq`: a later layer's hooks for an event add to the base ones, they never replace
them). Each hook is a small shell wrapper in `base/claude/`; the larger ones hand off to a Python
module next to it, which documents its design and knobs. The hooks fail open: one that cannot do
its job exits quietly rather than block a session. (The API-error hook's exit 2 is deliberate: as
an async-rewake hook, that is how it wakes Claude to carry on.)

## By event

| Event | Hook | What it does |
|---|---|---|
| `SessionStart` | `load-memory-hook.sh` | Shows the repo's session handoff and lists its other memory files (Claude Code loads `MEMORY.md` itself), from the auto-memory dir Claude Code uses for the cwd, plus the open items in the reflections store. |
| `SessionStart` (async) | `branch-tmux-hook.sh` | After `/branch`, opens a tmux window that resumes the original session, so the fork and its parent both stay at hand. |
| `UserPromptSubmit` | `tmux-rename-hook.sh` | Names the tmux window after the session. |
| `UserPromptSubmit`, `PostToolBatch` | `context-advisor-hook.sh` → `context_advisor.py` | Watches context use against an advisory budget and, past its thresholds, suggests reflecting or handing off to a fresh session. `CONTEXT_ADVISOR_DISABLE=1` turns it off. |
| `UserPromptSubmit`, `Stop`, `StopFailure` | `api-error-recovery-hook.sh` → `api_error_recovery.py` | When a turn dies on a transient API error after Claude Code's own retries, waits with backoff and wakes the session to continue; on an auth, quota or config error it alerts with the fix instead of retrying blindly. |
| `UserPromptSubmit` | `issue-focus-hook.sh` | Remembers which issue the session is about (a GitHub or GitLab reference in the prompt), for the statusline's issue link. |
| `Stop` | `tmux-rename-hook.sh` | Keeps the window name current. |
| `Stop` | `turn-timestamp-hook.sh` | Prints a timestamp line at the end of every turn, so a scrollback shows when each answer came. |
| `PreCompact`, `SessionEnd` | `session-reflector-hook.sh` → `session_reflector.py` | Reflects the transcript in the background into the reflections store: what the session learned, decided and left open. The context advisor also starts it at 20/40/60/80% of its advisory budget (`REFLECTOR_STAGES`). `REFLECTOR_DISABLE=1` turns it off; `MEMORY_BOUNDARY_CMD` keeps chosen sessions away from it. |
| `SubagentStart` | `subagent-context-hook.sh` | Gives every subagent the leaf-worker contract from the rules file: do the work directly, report what was verified. |
| `PostToolUse` (`Bash`) | `track-cwd.sh` | Records the directory the session is really working in, for the statusline. |
| `UserPromptExpansion` (`/handoff`), `PreToolUse` (`Skill`) | `handoff-record-hook.sh` | Adds a recording step to a handoff skill without editing it. |

The statusline (`statusLine` in the same file) runs `base/claude/statusline.sh`; its test is
`base/claude/statusline.test.sh`.

Codex has its own SessionStart hook in this repo: `reflections-context-hook.sh` hands a Codex
session the repo's open reflection items, the way the load-memory hook does for Claude Code.

## Notes

- Hook keys must be real event names: the settings schema enumerates them, and one bad key
  invalidates the whole file. That is why the notes live in the settings' `"//"` array and here,
  not as keys.
- The base settings also blank `BW_SESSION` in `env`, so an unlocked Bitwarden CLI session in
  your shell never reaches an agent.
- Tests: `scripts/tests/context-advisor.test.py`, `api-error-recovery.test.py`,
  `session-reflector.test.py`, `load-memory-hook.test.sh`.
