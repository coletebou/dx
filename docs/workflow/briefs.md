# Briefs, decisions and handoffs

A session's memory is its transcript, and transcripts get compacted, cut short and lost with the
process. So everything a session needs to keep going, and everything the next session needs to
take over, lives in files: a **brief** per task, a **TODO tracker** next to it, the owner's words
appended to the brief as **amendments**, and a **decisions list**. Keep these in a private
directory outside the repository (this setup uses `~/code/.briefs/<task>/`), never in a public
checkout.

## The brief

Written by the coordinator before a worker starts, read in full by the worker before it acts.
Workers inherit nothing from the coordinator's conversation, so the brief spells out every rule,
including the ones that "go without saying".

```markdown
# Brief: <task>
Created <UTC time> by <coordinator session>. Source of truth for this task; the chat is not.

## Goal
<two sentences, in the owner's terms>

## Scope
- Owns: <files or directories this worker may change>
- Must not touch: <everything else, especially shared files>
- Branch and worktree: <branch> at <path>, based on <base> @ <sha>

## Constraints
- <no push, no PR, no merge; no production writes; formatter bans; check load before heavy jobs>

## Acceptance
- <the checks that prove it is done: the real flow end to end, not just the unit tests>

## Report
<what the final message contains: SHAs and subjects, files, gate results, verified and not
verified, anything left out and why>

## Amendments
<!-- append only, newest last -->
```

### Amendments

When the owner changes the task, append; never rewrite what was there.

```markdown
### A3, 2026-01-15T14:02Z, turn <turn id>
Owner, verbatim: "<their exact words, nothing trimmed that changes the meaning>"
Reading: <what changes in scope or constraints, one line>
Supersedes: A1 (the line that said to skip the migration)
```

- **Quote, don't paraphrase.** A summary hardens a preference into a rule, or softens a rule into a
  preference, and the reader cannot tell which happened.
- **Keep the UTC time and the turn id** (the id of the owner's message in the transcript), so
  anyone can find the original and read what came before it.
- **Say what it supersedes.** Two amendments that disagree, with neither marked, leave a worker to
  guess.
- **The owner's own words beat a relay of them.** A later direct statement replaces an earlier rule
  that arrived second hand, even when the relay sounded more certain.

## The TODO tracker

One per session, next to its brief (`TODO.md`), or the harness's own task list when it has one.
Create it from the prompt and any earlier brief at the start of the session, then keep it current
as things happen: an item goes in progress when you start it and done when it is verified, and new
work goes in when it surfaces.

```markdown
| # | Item | State | Evidence or next action | Needs the owner |
|---|---|---|---|---|
| 1 | port map row for the new service | done | commit <sha>; `ss -ltnp` shows the unit | no |
| 2 | rate limit on the auth endpoints | blocked | waiting on D2 (the limit) | yes |
| 3 | restore drill | in progress | snapshot restored; row counts next | no |
```

A successor starts from the predecessor's list and carries every unfinished item forward.

## The decisions list

Everything the owner has to decide, numbered so a reply can say "D2: the first one".

```markdown
## D2 (open, blocks items 2 and 5; needed by Thursday)
What goes wrong: <one plain sentence>
Options: (a) <...>; (b) <...>
Recommendation: (a), because <one line>
Decided: <UTC time, turn id, the owner's words verbatim>   <- filled in when it is
```

## Handoff chains

A long session hands its open work to a fresh one before its context runs out, as the next
generation of a chain. The tool is `cc-handoff` (`scripts/cc-handoff`), driven by the
[`fresh-session-handoff`](../../plugins/session/skills/fresh-session-handoff/SKILL.md) skill; the
design (chain layout, the brief's required sections, what the successor's prompt says, when the
old window closes) is in [docs/handoff.md](../handoff.md). What matters for a fleet:

- **Hand off at a natural stopping point**, never in the middle of a rebase, a migration or a
  deploy. Finish or reach a safe pause first.
- **Hand off rather than compact.** A compacted transcript keeps the gist and loses the exact ids
  the next session needs: run ids, PR numbers, background task ids, the gate that triggers the next
  irreversible step. A written brief keeps them verbatim.
- **The brief's Left section is the TODO list** the successor starts from, and its Driver and
  manager section says who to report to, so a coordinator does not lose track of a worker that
  changed sessions.
- **The successor checks the brief against the transcript** and trusts the transcript where they
  disagree: a passer with a degraded context writes a worse summary than the work it did.
- **One session per branch.** After launching a successor, the passer stops working on the task,
  even if a stop hook urges it on.
- **Tell the owner plainly**, in ordinary words: this session ran low on context, the rest moved to
  `<window>`, this is what it will do and what it will ask, and here is how to attach.

## Relaying the owner's decisions

Workers rarely hear the owner directly; the coordinator relays. A relay is only as good as the
original it points to:

```text
Owner decision for slice 2, D2 decided 2026-01-15T14:20Z, turn <turn id>:
  "<the owner's exact words>"
Changes: brief A4 (appended). Supersedes: the 30-requests limit in A2.
Reply with the SHA once the rule matches.
```

- Relay **verbatim**, with the time and the turn id, and append it to the worker's brief as an
  amendment, so it survives the worker's next handoff.
- A relay states which decision it settles and what it replaces. "The owner said to keep it simple"
  settles nothing.
- When two instructions disagree, the newer verbatim one wins; when it is unclear which is newer,
  the worker asks the coordinator instead of picking.
- Relay a correction to every worker the old rule reached, not just the one that asked.

## Lane terms

Every lane (a worker's scope) that touches production, shared infrastructure or anyone else's
resources runs under three terms, written into its brief.

**START and END markers around production writes.** Before the first write, the lane posts a START
line to its status file or log; after the last write, an END line with the result. A START with no
END is an incident to look at, and anyone reading the log knows a write was in flight.

```text
START prod-write: tunnel ingress for new.example.com on box-a   2026-01-15T14:10Z  backup config.yml.bak-20260115T141000Z-new
END   prod-write: ingress live; new name 200, two old names 200  2026-01-15T14:16Z
```

**No defaults on owner decisions.** A decision the brief marks as the owner's has no default. Do
not pick one "to keep moving", and do not build code that quietly assumes one. Work on the items
that do not depend on it, or build both options behind a switch the owner flips.

**Silence is not a yes.** No answer means no. An idle peer, a timeout, a green CI run or a reviewer
that said nothing are not approval either. Re-ask with clearer wording (the consequences, not the
mechanism), keep the deadline visible, and gate each irreversible step on an explicit message
("merge landed <sha>"), never on a notice that a session went idle: sessions go idle for many
reasons other than finishing.

Outward actions (a push, a PR or a comment, a message to a person, a deploy, spending) need the
owner's go unless the brief's Rules grant them. A goal phrased as an outcome in the world ("get it
approved") is never a grant: deliver the best version and say what only the owner can do.
