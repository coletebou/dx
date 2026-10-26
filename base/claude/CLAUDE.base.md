# Claude Code — Universal Rules

These rules apply to every Claude Code session on every machine, regardless
of identity (for example personal vs work) or role (local vs server).
Identity-specific context (machine tables, workspace paths, company-specific
conventions) lives in the identity CLAUDE.md files sourced alongside this one
via `@-imports` from `~/.claude/CLAUDE.md`, which install.sh generates.

## Communication

- Keep RESPONSES tight — telegraph style is fine when clarity survives. This is
  about output length, not effort: read as much as correctness needs, and don't
  sample to save tokens (a repo whose rules say otherwise wins).
- Quote exact errors when searching/debugging.
- Leave breadcrumb notes for context continuity.
- When naming code as a cause, say whether you read it or ran it ("deploy.ts:2608
  does X; I read it, didn't run it").
- A user detour ("fix X first") doesn't cancel the original task: when the detour
  closes, go back to it and report its status unprompted.
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
- Use the harness's todo/task tool when it has one; otherwise keep a `TODO.md` next
  to the session's brief (or in the working directory). A successor starts from the
  passer's list and carries the unfinished items forward.

## Definition of done

- Never edit, skip, or delete tests just to make them pass. Fix the real defect;
  change a test only when the intended behavior changed, and explain why.
- Done means running and verifying the real flow end-to-end. Passing builds,
  unit tests, or source inspection alone do not establish that the flow works.
- The final report must state what was verified, how it was verified, and what
  was not verified. If the real flow could not run, report the blocker and leave
  that verification explicitly incomplete.

## Safety

- Run only the formatters a repository already uses, and preserve existing
  formatting otherwise; don't reformat files you were not asked to touch.
- Fix root cause, not band-aids.
- No repo-wide search/replace; keep edits small and reviewable.
- Don't delete/rename unexpected files; stop and ask first.
- Destructive git ops forbidden unless explicitly requested.

## Architecture — humans own the big picture

- Treat polling and new distributed orchestration as architecture decisions,
  not implementation details. Before adding distributed locks or leases,
  ownership/driving keys, cross-service resume coordination, or a new
  persistence/communication layer, state the concrete failure mode and get
  explicit human design review.
- Map and reuse the system's existing primitives first (for example pub/sub,
  routing/affinity, and lifecycle behavior). Do not design around assumed gaps
  without proving them from code or runtime evidence.
- Use the smallest coordination primitive that satisfies the demonstrated
  invariant—often one scoped mutex for mutual exclusion. Extra state or
  signaling requires a concrete failure mode, not speculative robustness.

## Parallelism and delegation

Use subagents when a substantial task splits into independent side work. Keep
the coordinator on the immediate critical path and available to the user.
Sequential work is appropriate for trivial, tightly coupled, or immediately
blocking tasks. Picking the right axis matters more than the worker count.

**Decision tree:**
1. **In-session local subagents first.** When the work splits into independent
   chunks (research multiple files, audit several modules, draft N variants,
   review by domain), spawn parallel subagents in a single message. Cap routine
   fan-out at three children so the coordinator remains part of the working
   set. Same working tree, no branch coordination, no infra cost.
2. **Worktree fan-out when isolation is required.** If parallel work would
   write to the same files, share build state, or collide on `dist/`,
   `node_modules`, `docker compose`, or DB migrations, escalate to the
   `parallel-worktrees` skill. Each worker gets its own branch + worktree +
   tmux window + Claude Code session, with hard isolation.
3. **Both, in conjunction.** A worktree's session is itself a Claude Code
   instance — it can spawn local subagents inside its own context. Use this
   when each worktree's work is non-trivial enough to warrant parallel
   research/review *within* it. Common pattern: N worktrees fixing N
   independent bug clusters, each running parallel reviewers on its own diff.

**Conflict signals that mean "go to worktrees":**
- Two workers would edit overlapping files or the same package's `package.json`
- Two workers would each run `npm install` / `docker compose up` against the
  same checkout (shared `dist/` and `node_modules` are the usual culprits)
- Two workers would each create a branch from the same starting point and
  diverge — git itself has nothing to merge if they share a worktree
- Two workers would each touch DB migrations / Compose state

**No conflict → in-session subagents win:** read-only research, multi-file
codebase audits, generating N independent prompts/specs/MR descriptions,
running independent reviewers on the same diff, drafting alternatives that the
parent then picks between.

**Key rules** (apply to subagents either way):
- Launch parallel subagents in a SINGLE message — multiple tool calls in one
  block. Sending them in separate messages serializes them.
- Match reasoning cost to the assignment: use a fast/light scout for bounded
  read-only discovery, the normal worker for routine implementation, and the
  strongest reasoning only for difficult ambiguity.
- Prefer fresh context for narrow scouts. Repeat task scope, safety constraints,
  and required output because fresh agents do not inherit them automatically.
- Give writing workers disjoint file ownership. Tell leaf workers to complete
  the assignment directly and not delegate further.
- Keep user approvals, final integration, and the final answer with the
  coordinator.
- Use `Explore` for open-ended codebase searches (not Glob/Grep).
- Run `code-simplifier` after writing/modifying code.
- After non-trivial changes and before commit or ship, run two independent
  reviews in parallel over the same frozen scope, on two different engines (for
  example the `autoreview` skill from openclaw/agent-skills, once with Codex and
  once with Claude). Gate on a stated severity (for example "nothing at P2 or
  above"), honor explicit model, effort, auth and engine overrides, and keep the
  run history. **Verify every finding against the real code before fixing it**
  — a plausible-sounding finding is not a real one.
- Reviewer mechanics stay out of repository-facing text (see "No
  internal-tooling names" below); say "Extensive multi-model review" instead.
- Don't use subagents for single-file reads or simple queries.
- Reporting on a *peer* agent (another tmux window/pane): a pane is fine for a
  glance, but its TUI collapses tool output, so don't assert what it's doing
  from pane text alone. Prefer querying ground truth directly, or just asking
  it. Its full session transcript is available too — see `codex-transcripts`.

**Custom agents:** `~/.claude/agents/` (global) or `.claude/agents/` (project).
Manage via `/agents`.

## Git Commands

- Prefer `cd`-then-git over `git -C` for readability.
- Use `git switch` for branches, `git restore` for files (never `git checkout`).
- Use Conventional Commits format: https://www.conventionalcommits.org/en/v1.0.0.
- Primary branch: the repository's default branch; check the repo's own
  CLAUDE.md before assuming one.
- **No internal-tooling names or review provenance in repository-facing text.**
  Personal skill and agent names are fine in private conversation but never in
  commit subjects/bodies, MR or issue titles/descriptions, or comments. Summarize
  review evidence as "Extensive multi-model review" plus concrete outcomes only.
  Never call the review required or expose tool/reviewer names, auth/provider
  routes, exact model/version, or reasoning/effort levels.

### Safe Git Commands

| Task | Use | Avoid |
|------|-----|-------|
| Switch branches | `git switch <branch>` | `git checkout <branch>` |
| Create & switch | `git switch -c <branch>` | `git checkout -b <branch>` |
| Restore file | `git restore <file>` | `git checkout -- <file>` |
| Restore staged | `git restore --staged <file>` | `git checkout HEAD -- <file>` |

**Why:** `git checkout` is overloaded — it switches branches AND restores files.
One mistake can silently discard uncommitted work. The modern alternatives are
explicit about intent.

## Multi-Agent Awareness

- Check `git status/diff` before edits; another agent may have changed files.
- Ship small commits; avoid large batched changes.
- Unrecognized changes: assume other agent; keep going; if issues arise, stop and ask.

## Worktree workflow

Two tools, one path layout. Use them — don't roll your own `git worktree add`.

- **Solo work**: `wt <branch>` (shell function in `base/aliases.sh`, helper at
  `~/.dotfiles/scripts/wt-helper`). State-aware: prompts to branch from
  `origin/HEAD` (fresh) vs. local HEAD when the branch is new; offers
  `cd / copy / recreate` when it's already checked out elsewhere.
- **Fan-out** (N parallel sessions): the `parallel-worktrees` skill — invoke
  via `/parallel-worktrees` or its bundled `pw launch <manifest.tsv>`. Each row
  in the manifest becomes its own worktree + tmux window + Claude Code session.
  `pw` shells out to `wt-helper` for the worktree itself, then layers its
  bootstrap on top (env-file copy, `.envrc` with `COMPOSE_PROJECT_NAME`,
  dependency install).
- **Path layout**: both nest worktrees inside the repo at
  `<repo>/.claude/worktrees/<slug>` by default (e.g.
  `~/code/app/.claude/worktrees/1847-foo`). `.claude/worktrees/` is
  git-ignored (add it to a `.dockerignore` too), so nested worktrees aren't
  tracked or shipped in build context. `wt-helper` (so `wt`, and `pw`, which
  takes its directory from `wt-helper --print-base-dir`) picks the path
  high→low: an explicit `--target <path>`; `WT_BASE_DIR=<dir>` (collected,
  `<dir>/<slug>`); `WT_LAYOUT=sibling` (the old flat siblings,
  `<parent-of-repo>/<repo>-<slug>`); `WT_LAYOUT=nested` (the default, ignoring
  the setting); the repo's `worktree.baseDirectory` in
  `.claude/settings.local.json`, then `.claude/settings.json` (relative →
  resolved against the repo; refused on an unmounted volume); the nested
  default (`WT_NESTED_SUBDIR` changes its subpath).
- **Claude Code's own worktrees** (`--worktree`, `EnterWorktree`, agent and
  workflow isolation) always land in `<repo>/.claude/worktrees/<name>`: Claude
  Code reads no `worktree.baseDirectory`. `claude-worktree-hook enable <repo>`
  makes them follow it (WorktreeCreate/WorktreeRemove hooks in that repo's
  `.claude/settings.local.json`). Once a day the hook also removes its
  worktrees that are clean, unused, a week idle and hold no commits of their
  own (`claude-worktree-hook prune --dry-run` lists them). Keep the hook per
  repo, never in user settings: it replaces Claude Code's creation for every
  worktree it covers.

Two gotchas worth knowing:
1. **Compose project-name collision** — without
   `COMPOSE_PROJECT_NAME=<repo>-<tag>` (or `-<branch>`), `docker compose up`
   in a worktree attaches to the main repo's project and mounts the *main
   repo's* code into the containers. `pw` writes this to `.envrc`
   automatically; `wt`'d solo worktrees need it manually if you'll run
   compose.
2. **Stale migrations** — Compose's `depends_on:
   service_completed_successfully` doesn't re-run when new migration files
   appear on a branch. Diff the repo's migration directories against the
   base branch and re-run the migration service if they changed.

## Dependencies

- New deps: quick health check (recent releases, active commits, adoption).
- Prefer well-maintained packages over clever but abandoned ones.

## Uncertainty

When in doubt, ship first and ask questions later. A wrong call is cheap to
correct or restart, but a user who comes back an hour later to find the work
blocked on a question asked five minutes in has lost that hour. That doesn't
mean never ask: but if the task is small or quick, or you have already started
implementing, don't stop; pick the best recommended action as if you were in
the user's shoes. At the start of a complex task, ask a few questions if you
really need to.

- Unsure: read more code first; if still stuck, ask with 2–3 short options.
- Conflicts: call out; pick safer path.
- When blocked, say what's missing to unblock.
- Before offering a mechanism ("likely because..."), run the cheap discriminating
  check (a version, a file, one command). A guess the user has to refute costs a
  round trip.

## Verification

- Prefer end-to-end verify over partial checks.
- If blocked from verifying, explicitly state what couldn't be verified.
- A `/goal` or stop-hook condition phrased as a real-world outcome ("make it go
  viral", "get it approved") cannot be met or verified inside a session. Deliver
  the best version, say once what only the user can do and that `/goal clear`
  ends it, then answer repeat hook prompts in one line. Never take an unapproved
  outward action (posting, messaging, publishing) to satisfy a goal.
- A negative result ("rejected", 401/403/404, "doesn't work") is evidence only
  with controls: the same input succeeds on a known-good path, and a known-bad
  input fails the same way.
- Report a job as running only when the tool returned a job/task id. If the call
  returned output, it already finished: read it before reporting.

## File Operations

- Stage experimental changes in a `mktemp` file first when modifying tracked
  files. Do NOT use `/tmp/` for worktrees, helper scripts, or any work-in-progress
  you'd mind losing — it's cleared on reboot (Linux) and purged periodically
  (macOS). Nest those under `<repo>/.claude/worktrees/` instead.
- Never overwrite tracked files without reading them first.
- New files: prefer < 1500 LOC; split when approaching limit.

## CLI Tools

| Task | Use | Avoid |
|------|-----|-------|
| Search file contents | Built-in Grep tool | `rg`, `grep` |
| Find files by pattern | Built-in Glob tool | `fd`, `find`, `ls` |
| Find directories | `fd -t d` | `find -type d` |
| Time-based file search | `fd --changed-within 7d` | `find -mtime` |
| Read files | Built-in Read tool | `cat`, `bat` |
| JSON processing | `jq` | — |

## Browser Automation

Use Playwright MCP.

## Slash Commands

Custom prompts: `~/.claude/prompts/` (global) or `docs/slash-commands/` (project).

## Ralph Loop

- **Always set both** `max_iterations` (≥20) AND `completion_promise`.
- Define clear completion condition; use `/cancel-ralph` when done early.

## Drover (fleet control plane, optional)

When the `drover_*` MCP tools (server `drover`, https://github.com/coletebou/drover)
are loaded, they are the way to see and steer the fleet:
`drover_fleet_summary` (who is waiting, working, idle on every host),
`drover_sessions` / `drover_send` (message any live Claude Code or Codex session
as if typed), `drover_capture` / `drover_tmux_send` (panes, with a dialog
guard), `drover_launch` (agents in tmux or headless), `drover_feature_upsert` /
`drover_event_append` / `drover_handoff_write` (the shared truth file, which is
also the log of every write), `drover_op` (any op). Prefer them over scraping
tmux or reading ~/.claude/sessions by hand. CLI: `drover` (`drover op <op>`,
`drover status`). Details: skill `/drover`.
