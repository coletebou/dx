---
name: shipped-but-open
description: "Find OPEN GitLab issues that already have a MERGED merge request: work that shipped but whose issue was never closed (common when someone other than the author merges). Use when the user says 'what shipped but is still open', 'find forgotten issues', 'shipped-but-open', 'issues I forgot to close', 'backlog rot', or wants to reconcile merged work against open issues. Read-only sweep; closing is a separate, explicitly approved step."
allowed-tools:
  - Bash(glab issue view *)
  - Bash(glab issue list *)
---

# shipped-but-open

Surface OPEN issues assigned to you that already have a MERGED MR. These are the backlog's
"done but never closed" items. They pile up wherever the author is often NOT the one who
merges, so the closing step never happens.

## Run the sweep

Set `SKILL` to this skill's directory first (`SKILL=${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/shipped-but-open}`),
then run it from inside a checkout of the GitLab project, with `glab` authenticated:

```bash
bash "$SKILL/scripts/sweep.sh"            # issues assigned to you
bash "$SKILL/scripts/sweep.sh" sam        # issues assigned to the user "sam"
PROJECT=group/project bash "$SKILL/scripts/sweep.sh"   # another project (GITLAB_HOST for its host)
```

The project comes from `glab repo view` unless `PROJECT` names one. Calls are serial by default;
`PARALLEL=N` runs N at a time, but some self-hosted instances behind slow links or VPNs stall
under parallel API load, so raise it only on a fast link. An issue whose lookup fails or times
out is listed as UNCHECKED and the sweep exits 1: never read a missing row as "not shipped".

## What runs without asking

Only `glab issue view` and `glab issue list` are pre-approved, both read-only (read-only forms
of `git` need no rule). Everything else asks first, on purpose:

- **The sweep** asks once to run. Every call it makes is `glab api --method GET ...`, fixed in
  the script and covered by its tests, so it cannot close, comment or label anything.
- **`glab api` by hand** always asks, reads included. No allowed-tools prefix can confine it to
  reads: Claude Code matches a rule as a prefix, and glab sends the last method flag it is given,
  so `glab api --method GET ... -X PUT -f state_event=close` matches a `glab api --method GET`
  rule and still closes the issue. Write the reads you need as `glab api --method GET ...`
  so the prompt shows plainly what will run.
- **Closing and comments** (`glab issue close`, `glab issue note`) always ask: they are the
  explicitly approved step below.

## Reading the output: STRONG vs WEAK (this is the whole point)

GitLab's `related_merge_requests` returns MRs that merely **mention** the issue number, not only
MRs that fixed it. A merged sibling MR that says `Refs #a #b #c` shows up under all three
issues. So "has a merged MR" is **not** proof of "shipped".

The script splits hits into two buckets by a **strong signal**:

- **STRONG**: a merged MR whose *source branch* starts with `<issue>-` (the name GitLab gives a
  branch or MR created from the issue) **or** whose title or description closes the issue with
  one of GitLab's default closing keywords (`Closes #N`, `Fixes #M, #N and #O`, `Resolves: #N`,
  `Implements #N`). That MR was built *for* this issue: very likely done.
- **WEAK**: the only merged MR referenced the issue as a sibling. A false-positive candidate:
  the issue may well still be open for real. **A human must read the issue against the MR
  before closing.**

## Before closing ANYTHING

Closing an issue is outward-facing and needs explicit approval per action or per batch. Never
bulk-close the raw list. Even STRONG hits can be umbrellas, or enforcement issues where a merged
MR only shipped observability or scaffolding (a "warn on X so the metric isn't blind" MR does
NOT mean the enforcement landed). Read the merged MR's actual title and diff, not just its
number.

Recommended flow:

1. Run the sweep.
2. For each STRONG hit, read the issue body and the merged MR (`glab issue view N`,
   `glab api --method GET projects/:fullpath/merge_requests/M`). Judge: did the merge
   substantially satisfy the issue?
3. Present a close list with a one-line justification each; get approval.
4. Close approved issues **with a comment linking the merged MR**:
   `glab issue close N`, after `glab issue note N -m "Shipped in !M: <what landed>."`.
5. **Deltas policy:** if an issue is *substantially* shipped but has small leftovers, close it
   anyway and add the leftover to a running list. At the end, file ONE new scoped follow-up
   issue for all the deltas rather than leaving N issues open for scraps.

The inverse question, merged work that is closed-in-fact but open-on-paper, is this skill;
"what is open and actionable" belongs to your backlog view, and broader grooming can use this
sweep as its "reconcile merged work" input.
