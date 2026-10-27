---
name: reflect
description: Repo-agnostic end-of-session retrospective. Detects which codebase(s) the session touched, reviews what was accomplished, captures durable learnings into auto-memory, updates project rules/docs/CLAUDE.md when conventions changed, identifies skill gaps, proposes toolchain improvements, and records open follow-ups in the reflections store. Use after shipping work, after long debugging sessions, or when the user says "reflect", "retro", "what did we learn", "session handoff", "capture this". Does NOT run automatically — only when invoked.
---

# Reflect

End-of-session retrospective. Review what was accomplished, capture durable learnings, update documentation where needed, and propose toolchain improvements — so the next session starts from a better place than this one ended.

## When To Use

- After shipping a feature or opening a PR
- After a long debugging session that produced non-obvious findings
- After work that surfaced new conventions or gotchas
- When the user says "reflect", "retro", "what did we learn", "session handoff", "capture this"
- NOT automatically — always user-initiated

## What This Skill Does (overview)

0. **Detect session scope** — which codebase(s) got touched? Drives where to write.
1. **Review** — summarize what the session accomplished, tie to issues/PRs/branches
2. **Capture durable learnings** — write/update files in auto-memory
3. **Update docs when conventions changed** — scope-appropriate (see Phase 0)
4. **Identify skill gaps** — propose new skills, hooks, or agent improvements
5. **Session handoff** — leave a short note the next session can pick up cold
6. **Record rows in the reflections store** — open follow-ups, proposals and decisions as searchable, closable rows (`reflections` CLI), and close the ones this session finished

Every step is optional and evidence-driven. If nothing in the session merits writing memory, don't write memory. If no conventions changed, don't touch any docs. Writing reflexively is noise; writing only when a future session would be measurably better for it is signal.

## Phase 0: Scope Detection (RUN FIRST)

Before gathering session facts, figure out WHICH codebase the work happened in. A session that was 95% in your dotfiles and 0% in the product repo should not update the product's `CLAUDE.md` as if the work were there — it should update the dotfiles-side docs (inline comments, READMEs, follow-up notes) instead.

Run these in parallel:

```bash
# The repo this session started in
git log --oneline --since="12 hours ago" --author="$(git config user.email)" 2>/dev/null | head -5
# Dotfiles?
git -C ~/.dotfiles log --oneline --since="12 hours ago" 2>/dev/null | head -5
# Personal skills / Claude config?
find ~/.claude/skills -name SKILL.md -mmin -720 2>/dev/null | head -5
# Other repos?
for r in ~/code/*/; do
    [[ -d "$r/.git" ]] || continue
    n=$(git -C "$r" log --oneline --since="12 hours ago" --author="$(git config user.email)" 2>/dev/null | wc -l)
    (( n > 0 )) && echo "$(basename "$r"): $n commits"
done
```

Based on results, the **scope set** is one of:

| Scope | Memory target | Doc target (Phase 3) |
|---|---|---|
| **Project repo** (the common case) | that repo's memory dir | its `CLAUDE.md`, `.claude/rules/*`, `docs/` |
| **Dotfiles / tooling** | the memory dir of the repo you were working for | inline script comments, the dotfiles README or follow-up notes |
| **Personal skills** (`~/.claude/skills/*`) | same | the skill's own `SKILL.md`, committed in the repo the symlink points at (`readlink ~/.claude/skills/<name>`) |
| **Another repo** | that repo's memory dir | that repo's README / `docs/` / CLAUDE.md |
| **Mixed** | split: each scope handled separately | ditto — don't bleed rules across |

Memory lives in the directory Claude Code loads as this repo's auto-memory. With this repo's memory setup that is the repo's memory home from `claude/memory-homes.conf` (Claude Code's `autoMemoryDirectory`; the load-memory SessionStart hook prints its handoff and topic files at the top of the session); otherwise it is `~/.claude/projects/<encoded cwd>/memory/`. If neither is in context, run `ls -d ~/.claude/projects/*/memory/` and pick the repo you worked in. Only the DOC update phase is scope-sensitive.

When in doubt, ask the user: "this session touched X and Y — which scope should I update?"

## Phase 1: Session Review

Run these in parallel to gather the facts:

```bash
# What branches/commits/PRs were touched
git branch --show-current
git log --all --oneline -20 --since="12 hours ago" --author="$(git config user.email)"
git log origin/HEAD..HEAD --oneline 2>/dev/null

# Any open PRs or MRs from this session
gh pr list --author @me --state all --limit 5 2>/dev/null
glab mr list --author @me --state all --per-page 5 2>/dev/null | head -20

# Any branches currently checked out on disk
git worktree list 2>/dev/null
```

Ask yourself:
- What was the actual goal? (Check the first user message for this session.)
- What was shipped vs. what was deferred? (Deferred items = follow-up issues.)
- What blocked us, and how long did each blocker last?
- Were there decisions the user had to correct? (Those are feedback memories.)
- Were there decisions the user validated? (Those are also feedback memories — confirmations matter as much as corrections.)

Output: a 3–6 bullet summary of what happened. This is NOT the final user-facing report yet — it's your own working notes to drive Phases 2–5.

## Phase 2: Capture Learnings in Auto-Memory

Memory lives in the per-repo directory identified in Phase 0. See the auto-memory section of the system prompt for the types (`user`, `feedback`, `project`, `reference`) and the format.

**Reconcile before you add.** Other sessions write to the same directory in parallel and the index goes stale fast. Before writing anything:
1. Read `MEMORY.md` and every file your session touched. A pointer that says "NOT deployed" or "open" for something you know shipped is a bug to fix now, not a new file to add.
2. Check the other agents' memory too (for example `grep -ril <topic> ~/.codex/memories`): a fact you are about to "discover" may already be settled.
3. Check the size: Claude Code loads at most 200 lines / 25000 bytes of `MEMORY.md`, and the dreaming sweep keeps it under 24000 bytes. Bulk detail goes in the linked file, never in the index line.
4. `reflections list --status open` (run in the repo) shows open action items — some written by earlier `/reflect` runs, some by the automatic PreCompact/SessionEnd reflector. Anything this session finished gets closed in Phase 5B, not re-recorded. `reflections search <topic>` also searches the memory files.

**Decision test before writing**: "If I started a fresh session tomorrow without this memory, would I re-learn this the slow way?" If yes, write it. If no (it's already in the code, a commit message, or CLAUDE.md), skip.

**Do NOT write memory for:**
- Code patterns visible in the diff — those are in the code
- Git history / recent changes — those are in git log
- Debugging solutions — the fix itself is the commit
- Anything already in CLAUDE.md or `.claude/rules/*`
- Ephemeral session state

**DO write memory for:**
- New user preferences surfaced this session (style, workflow, tool choice)
- Non-obvious constraints (an infrastructure limit, an external dependency quirk)
- Validated approaches the user confirmed were the right call
- Corrections the user made to your approach (with reason)
- References to external systems (dashboards, boards, channels)

For each memory, follow the two-step write pattern:
1. Write the memory file with YAML frontmatter (`name`, `description`, `type`)
2. Add a one-line pointer in `MEMORY.md`

Before writing a new memory, check if an existing one should be updated instead — duplicate memories are noise.

## Phase 3: Update Docs (Scope-Aware)

This is the phase most reflect-flavored tools skip. Do not skip it. But DO scope it correctly — see Phase 0's scope decision.

### 3A: Decide scope — memory or docs?

| Learning type | Lives in |
|---|---|
| The user's personal preference ("prefers short commit bodies") | Auto-memory (`feedback_*.md`) |
| A project convention | The project's `CLAUDE.md` or `.claude/rules/*.md` |
| A pattern every developer on the project should follow | `.claude/rules/*.md` (or a new rule file) |
| A dotfiles or tooling convention | Inline comments or the dotfiles README — NOT the project's docs |
| A personal skill improvement | That skill's `SKILL.md` body |
| A one-off bug's root cause | The commit message — nothing else |
| A cross-cutting architectural decision | `CLAUDE.md` top level or `docs/` |
| A runbook for a recurring operation | `docs/`, or inline in the script |

**Key rule**: NEVER write to a project's `CLAUDE.md` / `.claude/rules/*` if the session didn't touch that repo. Team-shared docs polluted with tooling notes become noise for every future session there. Phase 0's scope decision is authoritative here.

### 3B: Identify candidate updates

Ask these questions about the session's work:

1. **Did we codify a new convention?** (e.g., "pages navigate through the router helper, never `window.location`" — is this now the pattern other code should follow?) If yes → consider a note in the matching `.claude/rules/` file.
2. **Did we hit a gotcha that was not documented?** (e.g., "model ids differ between the cloud provider's regions") If yes → add it to CLAUDE.md or the relevant runbook.
3. **Did we change a build/deploy/dev step?** If yes → update the commands table in CLAUDE.md or the setup doc.
4. **Did we discover a rule that already existed but was unclear/wrong?** If yes → edit, not append.
5. **Did we add/modify a package, port, env var, or service name?** If yes → update the table that documents it (config comments, CLAUDE.md tables, compose-file comments).

### 3C: Write the updates

Rules for editing docs:
- **Prefer editing over appending.** Find the existing section that belongs to this topic; refine it rather than adding a duplicate bullet at the bottom.
- **Short diffs.** One-line clarifications beat multi-paragraph explanations. If a rule needs a paragraph, the rule is probably two rules.
- **Cite the evidence in the commit message**, not in the doc itself. The doc says the rule; the commit explains why the rule is there.
- **If multiple doc files cover the same topic, edit the canonical one** and let the others point at it. Avoid rule-splitting across N files.
- **Never write docs "for completeness"** — only when a future reader would hit the same problem.

If a doc file doesn't exist and should, create it — but first check whether an existing file could absorb the content.

### 3D: Commit the doc updates

Docs belong in the repo. Commit with a `docs:` or `chore:` type (Conventional Commits). Reference the session's issue if it applies, otherwise omit the ref.

## Phase 4: Identify Skill & Toolchain Gaps

Ask: "What would have made this session faster?"

Candidates:
- **New skill**: a repeated N-step pattern that could become a single `/command`
- **New hook**: an automated check that would have prevented a mistake
- **New agent**: a specialized reviewer for a domain that keeps getting missed
- **Skill update**: an existing skill had a gap, a wrong instruction, or an outdated reference
- **CLAUDE.md update**: a rule that would have prevented a user correction

For each candidate:
1. Describe the pattern in one sentence
2. Say what it would do differently
3. Estimate the cost of building vs. the cost of one more session doing it manually

Do NOT build the skill right now unless the user asks. The output of this phase is a list of proposals, not implementations. If the user has said in this session that you may update or create skills, build them here, but keep the report's proposal list for anything you chose not to build and say why.

Pattern seen often enough to name: a session that ran the same multi-agent shape two or three times by hand (a review fan-out, a verification sweep, a host probe) is a skill candidate even when each run looked different. Capture the prompt scaffold and the safety rails, not the run.

## Phase 5: Session Handoff

Write a short note the next session can pick up cold:

```
## Session handoff — <date>

### Shipped
- <branch> → PR #<N> (state: Ready / Draft / Merged)
- <issue> closed / will auto-close on merge

### In-flight
- <branch> paused at <step>, next action: <X>

### Open follow-ups
- #<issue> — <description>

### What the next session should know
- <one-line gotcha or context that isn't obvious from git state>
```

If a session-handoff memory file exists, update it. Otherwise write a new one and add it to `MEMORY.md`.

## Phase 5B: Record Rows in the Reflections Store

The `reflections` CLI (`scripts/reflections` in this repo; `install.sh --with memory` puts it on `PATH`, and Codex runs it the same way) keeps per-repo rows that can be searched and marked done. It exists because follow-ups and proposals written only into a chat report or a handoff paragraph get lost. Run it from the repo the work belongs to — it resolves the repo (worktrees included) and the session id itself. Rows are one-line titles plus a short body; never paste a memory file's content into a row (Rule 2: the store already indexes memory files).

1. **Close what this session finished**, with evidence: `reflections done <id> --note "shipped in <sha>/#<PR>"`. Use `reflections drop <id> --note "<why>"` for items that are obsolete.
2. **Record what is still open** in one batch (duplicates of open titles are skipped automatically):

   ```bash
   reflections add --batch - --origin reflect <<'JSON'
   [
     {"kind": "action",   "title": "<In-flight item: next concrete step>", "body": "<branch, where it stopped, how to resume>", "priority": 2},
     {"kind": "action",   "title": "<Open follow-up>", "body": "<issue/PR link, why it matters>"},
     {"kind": "idea",     "title": "<Phase 4 proposal, one line>", "body": "<what it would do differently; cost vs. value>"},
     {"kind": "decision", "title": "<decision made or validated>", "body": "<the reason, so it is not re-litigated>"},
     {"kind": "handoff",  "status": "note", "title": "<topic> — /reflect <date>", "body": "Full note: <Phase 5 handoff memory file name>. <one line: where things stand>"}
   ]
   JSON
   ```

   Kinds: `action` / `question` / `handoff` start open; `learning` / `decision` / `gotcha` / `idea` are notes. `priority` 1 means "blocks other work".
3. **Mixed scope** (Phase 0): run one batch per repo, from that repo's directory (or pass `--repo <name>`).

Each machine appends only to its own `<memory home>/reflections/<host>.jsonl`, so rows travel with your memory repo's sync without conflicts, and the next session in the repo sees the open ones at startup.

## Phase 6: Final Report to User

Present a compact summary:

```
## /reflect — session <date>

### Summary
<1-3 sentences, what happened>

### Memory updates
- [wrote/updated] <file.md> — <one-line reason>
- [wrote/updated] <file.md> — <one-line reason>

### Doc updates
- [edited] CLAUDE.md — <section, one-line reason>
- [edited] .claude/rules/<file>.md — <one-line reason>
- [committed] <commit hash>

### Proposed improvements (not built)
- <one-line proposal>
- <one-line proposal>

### Reflections store
- closed: #<id> <title> (evidence) · recorded: #<id> [action] <title> · …

### Session handoff
<see Phase 5 — repeat here or link to file>

### Nothing updated?
If a phase produced no output, state that explicitly ("No memory updates — nothing in this session was non-obvious from code"). Silence is ambiguous.
```

## Rules

1. **Never write memory reflexively.** The test is "would a future session re-learn this the slow way?" If no, skip.
2. **Never duplicate between memory and docs.** User prefs → memory. Project rules → docs. Never both.
3. **Prefer editing to appending.** Both in memory files and in CLAUDE.md/rules.
4. **Never invent gotchas.** Every rule added to docs must cite a real moment in this session where the absence of the rule caused friction.
5. **Do not auto-run.** User-initiated only. If invoked automatically somehow, stop and ask why.
6. **Do not push commits.** The user controls pushes. Commit locally only.
7. **Do not file issues for proposals.** Proposals go in the final report; let the user decide whether to file them.
8. **Keep the final report tight.** If there's nothing to say, say that. Noise in the retrospective erodes trust in future retrospectives.

## Anti-patterns

- **"Session summary" that just lists commits.** Git log already does that. Reflect should add the *reasoning* between commits.
- **"Lessons learned" that are just restated code.** If the lesson is "we added a click handler," that's not a lesson, that's the diff.
- **"Next steps" that reinvent the backlog.** Open issues already track work. Reflect's output is complementary to the backlog, not a duplicate of it.
- **CLAUDE.md bloat.** Every rule added to CLAUDE.md without a clear trigger becomes noise for every future session. Err on the side of not adding.

## Gotchas

- **Skill description field is the trigger.** The `description:` YAML frontmatter is how Claude decides when to fire this skill. Keep it specific to the retrospective pattern; overly broad descriptions fire on every session-end and become noise.
- **Memory is per repo.** User-level learnings that apply across projects belong in your global rules file (in this repo, `base/claude/CLAUDE.base.md`), proposed in the report rather than edited, unless the user asks.
- **A parallel session may have already shipped what you are documenting.** On a busy day several sessions merge to the same repo; read `git log origin/HEAD` (and any live health endpoint) before writing "not deployed" or "open" anywhere.
- **`.claude/rules/*.md` may not exist yet.** Before writing to `.claude/rules/`, verify the directory exists — if not, put the rule in `CLAUDE.md` or propose creating the rules directory in the final report.
- **Do not edit generated files.** With this repo's installer, `~/.claude/CLAUDE.md` and `~/.claude/settings.json` are generated from the sources they import. If an update belongs there, edit the source or propose it in the final report.
- **The store is also written automatically.** The session reflector (`base/claude/session_reflector.py`) checkpoints long sessions into the same store: a small-model pass at 20% of the context window, larger ones at 40/60/80%, then PreCompact and SessionEnd. It already closes, reopens and edits rows its excerpt settles (notes start `[reflector …]`) and keeps one rolling `session-summary` note per session. Its rows are still a model's first pass: reconcile them here — close what is done, drop what is wrong, keep what is right. Open rows untouched for 7 days (30 for rows a person or `/reflect` wrote) read as `stale` (hidden from lists; `reflections list --status stale`). That automation does not run this skill (Rule 5 holds).
