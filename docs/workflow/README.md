# Running fleets of agents

How this setup runs many coding agent sessions on one piece of work without losing what the
owner asked for: who does what, where the truth lives, how work moves between sessions and
machines, and what has to be true before anything ships. The rules behind it are in
[`base/claude/CLAUDE.base.md`](../../base/claude/CLAUDE.base.md); the tools are the plugins in
[`plugins/`](../../plugins) and the CLIs in [`scripts/`](../../scripts).

```text
owner ── goals, decisions, approvals ──▶ coordinator ── brief + TODO, contracts ──▶ worker 1
                                            │   ▲                                  worker 2
                                            │   └──────── pushed SHA + report ───── worker N
                                            ├── reviewers, at a pinned SHA
                                            └── STATUS, decisions list, final report ──▶ owner
```

## Roles

| Role | Owns | Never |
|---|---|---|
| **Owner** (the human) | the goal, every decision marked as theirs, approval of anything irreversible or outward (a push, a PR, a merge, a message, a deploy, spending) | is asked something the agents could find out |
| **Coordinator** (one session) | the brief and its TODO tracker, the split into slices, contracts, reviews, routing findings, gates, integration, the decisions list, the final report | writes a worker's slice; decides for the owner; relays the owner's words in its own |
| **Worker** (a leaf session or subagent) | one slice: the files it was given, its branch, its tests, its report | touches files it does not own; hands its whole assignment to another agent; pushes, merges or opens a PR unless its brief says so |
| **Reviewer** | findings against a frozen scope | edits the tree under review; runs anything on production |
| **Release coordinator** (optional) | merging slices that arrived gated and review-clean | merges a SHA that was not the one reviewed and gated |

One coordinator at a time. A second session that thinks it is the coordinator (a resumed session,
a successor whose predecessor is still alive) is the most common way two agents end up writing
the same files: see [Taking over](parallel.md#taking-over).

## Pages

| Page | Covers |
|---|---|
| [briefs.md](briefs.md) | the brief and TODO tracker as the source of truth, amendments, handoff chains, relaying the owner's decisions, lane terms for production writes |
| [parallel.md](parallel.md) | choosing in-session subagents or worktrees, `wt` and `pw`, disjoint ownership, contracts, load discipline, shared trees, taking over |
| [review.md](review.md) | two independent reviewers over one frozen scope, verifying findings, control runs, verification before "done" |
| [publication.md](publication.md) | private first: publishing from a private source through a scrub gate that fails closed |

Related: [handoff chains](../handoff.md) (the `cc-handoff` design), [memory](../memory/README.md)
(what sessions remember between runs), [hooks](../claude-hooks.md) (the context advisor that says
when to hand off).

## Working principles

- **Fix it, don't hand it back.** A stale git lock, a host key that changed to one already trusted
  for the same machine, a renamed host, a stranded change: diagnose it, fix it, and say what you
  did. Stop for the owner only for a password or login, a physical or GUI action, a decision the
  brief marks as theirs, or a step that is both large and irreversible.
- **Lead with the answer.** One ready-to-use answer and a line of why, with any check run
  beforehand and folded in. Offer a menu only when the choice is genuinely the owner's and no
  option is clearly best.
- **Explain an escalation by its consequences.** What goes wrong, in one plain sentence; when it
  happens and how likely that is; what it costs if left alone; what the fix does, in everyday
  words; the options with a recommendation. Name the mechanism last, if at all.
- **Check live state before recommending.** Configuration says what something is wired to, not
  whether anyone uses it. Query the live inventory and recent usage before recommending a
  purchase or calling a resource taken.
- **Say whether you read it or ran it.** "This function does X (read, not run)" and "this command
  returned Y (ran)" are different kinds of evidence; the report keeps them apart.
- **Ship rather than wait.** On a small task, or once work has started, pick the action the owner
  would most likely pick and keep going; ask a few questions only at the start of a complex task.
  An agent found blocked an hour later on a five-minute question wasted fifty-five. The exception
  is a decision the brief reserves for the owner: that one has no default
  ([lane terms](briefs.md#lane-terms)).
- **Keep the brief current, not the conversation.** Anything the next session needs goes in the
  brief, the TODO tracker or the decisions list, written when it happens, not at the end.
