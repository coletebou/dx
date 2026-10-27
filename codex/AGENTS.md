# Global Codex Rules

Global instructions for Codex across repositories and machines. install.sh (the codex component)
links this file to `~/.codex/AGENTS.md`; edit it here.

## Scope

- Applies to all repos unless a closer `AGENTS.md` / `CLAUDE.md` in the project overrides it.
- Project-local instructions always win over this file.

## Working Style

When in doubt, ship first and ask questions later. A wrong call is cheap to correct or restart,
but a user who comes back an hour later to find the work blocked on a question asked five minutes
in has lost that hour. That doesn't mean never ask: but if the task is small or quick, or you have
already started implementing, don't stop; pick the best recommended action as if you were in the
user's shoes. At the start of a complex task, ask a few questions if you really need to.

- Keep responses concise and concrete.
- Prefer minimal, reversible changes over broad refactors.
- Ask a few necessary clarifying questions at the start of complex work; otherwise choose the best recommended action and keep going.
- State assumptions explicitly when they affect implementation choices.
- `wwa` = "where we at". Re-check the latest state of everything still running
  (background agents, tmux windows, deploys, daemons: look, don't recall), then
  answer in a few lines: done so far, in flight, left to do, and anything that
  needs the user. Stay very succinct. `wwa deep` (or "wwa full") = the long
  version with per-item detail, evidence and next steps.
- `wwa fleet` = `wwa` plus everything else recent across machines and sessions,
  when the Drover MCP tools are loaded (see Drover below): which sessions are
  waiting on the user, working, or recently stopped on each machine, background
  agents, deploys and daemons. Group by host, flag waiting/dead items first, a
  line or two per host, then the same done / in flight / left / needs the user.
  `wwa fleet deep` adds per-session detail.

## Todo list

- At the start of each session, and again after every handoff, create or update a
  todo list from the prompt and any previous handoff briefs, then keep it current
  as work moves: mark items in progress and done as they happen, and add new ones
  as they surface. Preferred for anything larger than a single task, not mandatory;
  skip it for one-shot questions and single quick edits.
- Use the plan tool (`update_plan`) when it is available; otherwise (for example in
  `codex exec`) keep a `TODO.md` next to the session's brief (or in the working
  directory). A successor starts from the passer's list and carries the unfinished
  items forward.

## Definition of done

- Never edit, skip, or delete tests just to make them pass. Fix the real defect;
  change a test only when the intended behavior changed, and explain why.
- Done means running and verifying the real flow end-to-end. Passing builds,
  unit tests, or source inspection alone do not establish that the flow works.
- The final report must state what was verified, how it was verified, and what
  was not verified. If the real flow could not run, report the blocker and leave
  that verification explicitly incomplete.

## Safety

- Never run destructive git/file commands without explicit user approval.
- Never commit secrets or API keys.
- Before transferring secrets to a remote host, verify the host's identity using a trusted source, preserve its existing credentials, and verify the copied bytes and private permissions.
- Prefer root-cause fixes over superficial patches.
- Preserve concurrent edits and assess whether they affect the current task. Leave unrelated changes alone and continue authorized work; unrelated tool configuration or hook edits are not by themselves a reason to stop. Pause only the affected operation when changes overlap files you must edit, alter the runtime or evidence being verified, create a concrete conflict or safety risk, or cannot be safely isolated. Inspect ownership and scope first, and ask only when a material ambiguity remains; continue independent work while waiting. Never overwrite or revert another actor's changes without authorization.

## Architecture — humans own the big picture

- Treat polling and new distributed orchestration as architecture decisions, not implementation details. Before adding distributed locks or leases, ownership/driving keys, cross-service resume coordination, or a new persistence/communication layer, state the concrete failure mode and get explicit human design review.
- Map and reuse the system's existing primitives first (for example pub/sub, routing/affinity, and lifecycle behavior). Do not design around assumed gaps without proving them from code or runtime evidence.
- Use the smallest coordination primitive that satisfies the demonstrated invariant—often one scoped mutex for mutual exclusion. Extra state or signaling requires a concrete failure mode, not speculative robustness.

## Git Rules

- Use `git switch` for branch changes.
- Use `git restore` for file restoration.
- Avoid `git checkout` for branch/file switching.
- Use Conventional Commits when creating commits.
- No internal-tooling names or review provenance in repository-facing text (commit messages,
  MR/PR and issue descriptions, comments): summarize review evidence as "Extensive multi-model
  review" plus concrete outcomes, without tool or reviewer names, provider routes, exact model
  versions, or reasoning/effort levels.

## Tooling Defaults

- Run only the formatters a repository already uses, and preserve existing formatting otherwise; don't reformat files you were not asked to touch.
- Search content with `rg`.
- Find files/directories with `fd`.
- Parse JSON with `jq`.
- Read only relevant sections of large files first; avoid full-file reads when unnecessary.

## Multi-Machine Rules (macOS, Linux, WSL)

- Use `$HOME` and `$USER` instead of hardcoded usernames and paths.
- Confirm machine context before environment-specific commands: `CLAUDE_MACHINE` (exported by
  this setup's shell from `~/.df-profile`) names the machine; `hostname` can be generic inside
  containers and sandboxes.
- Treat a local checkout and a deploy target as different environments: deploy through the
  repository's CI/CD or deploy scripts, never by copying files into a deploy directory by hand
  unless the user asks for exactly that.

## Validation

- Run the repo’s standard checks after non-trivial changes.
- If full validation cannot run, report exactly what was not verified.

## Review

- After non-trivial changes and before commit or ship, run two independent reviews in parallel
  over the same frozen scope, on two different engines (for example the `autoreview` skill from
  openclaw/agent-skills, once with Codex and once with Claude). Gate on a stated severity, honor
  explicit model, effort, auth and engine overrides, and verify every finding against the real
  code before fixing it. Multi-agent implementation does not replace that independent review.

## AGENTS/CLAUDE Parity

- If a repository uses both `CLAUDE.md` and `AGENTS.md`, update the canonical file and sync mirrors in the same change.
- When a repo has no `AGENTS.md`, Codex is configured to read its `CLAUDE.md` as the project doc (`project_doc_fallback_filenames = ["CLAUDE.md"]` in this setup's `config.toml`). So the instructions you receive may be authored for the Claude harness — read them as guidance, not as literal tool calls.

## Multi-Agent Delegation

- For substantial tasks with independent side work, the coordinator may delegate up to three parallel assignments while keeping immediate critical-path work local and staying available to the user.
- Do not delegate trivial, tightly coupled, or immediately blocking work. A subagent should materially advance a distinct part of the task without duplicating the coordinator or another worker.
- Prefer the inherited model family and vary reasoning by role: lighter for bounded read-only scouts, the default for routine implementation, and the strongest only for difficult ambiguity.
- Use fresh context for narrow scouts when practical. Repeat task scope, safety constraints, and required output because fresh-context agents do not inherit them automatically.
- Give writing agents disjoint file ownership. Tell leaf agents to complete their assignment directly and not spawn more agents.
- Keep user approvals, final integration, and the final answer with the coordinator. Close agents when their work is no longer needed.

## Reading Claude-authored instructions & skills (IMPORTANT)

Much of this setup's tooling was authored for the Claude Code harness. You will encounter
`CLAUDE.md` project docs and `SKILL.md` skills (under `.claude/skills/`, or mirrored into
`.codex/skills/`) that assume Claude-only capabilities. Be smart about the mismatch instead of
following them literally:

- **Skills are guidance, not executables here.** A `SKILL.md` describes a workflow. Its *domain knowledge* (conventions, checklists, file maps, gotchas, commands to run) is fully valid. Its literal harness mechanics may differ: translate Claude `Skill`, `Agent`, `Workflow`, `TodoWrite`, and `/slash-command` syntax to the available Codex tools.
- **Translate without discarding supported orchestration.** "Dispatch N parallel review agents" maps to native Codex subagents when the assignments are independent and the delegation rules above allow it. "Invoke the Workflow tool to fan out" maps to native subagents or inline work depending on coupling. "Use the Skill tool to run /some-review" means read and follow that skill's checklist. Keep the intent and rigor while replacing only unsupported syntax.
- **Project skills encode real conventions** worth honoring (commit trailers, review dimensions, verification gates). Preserve their useful fan-out with native Codex subagents when assignments are independent; otherwise perform the workflow inline.
- **When unsure whether a step applies to you, prefer the underlying goal over the literal instruction, and state the adaptation you made.**
- Anything that runs in a plain shell (`git`, `npm`, `docker`, build/test commands, file edits) works identically — use it as written.

## Instruction Hygiene

- Keep project-specific rules in the project repository, not here.
- Keep this file focused on stable, cross-repo behavior.
- Source of truth is `~/.dotfiles/codex/AGENTS.md` (linked to `~/.codex/AGENTS.md` by the installer).

## Drover (fleet control plane, optional)

When the `drover` MCP server (tools `drover_*`, https://github.com/coletebou/drover) is loaded, it
shows and steers a fleet of agents: `drover_fleet_summary` (who is waiting, working, idle per
host), `drover_sessions` and `drover_send` (message any live Claude Code or Codex session),
`drover_capture` and `drover_tmux_send` (panes, with a dialog guard), `drover_launch` (start
agents), `drover_feature_upsert`, `drover_event_append`, `drover_handoff_write` (the shared truth
file), `drover_op` (any op; resource `drover://ops` lists them). Prefer these over scraping tmux.
CLI: `drover`. Skill: `drover`.
