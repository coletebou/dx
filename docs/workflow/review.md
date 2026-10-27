# Review before ship, verification before "done"

Reviewers are cheap and often wrong; tests pass on fixtures nobody sends; a green CI run says the
files arrived, not that the process runs them. This page is the order of operations this setup
uses so that "done" means the real thing works.

## 1. Freeze the scope

Review the exact commit, never a live working tree that someone may still be editing:

```bash
git worktree add --detach ../review-<sha> <sha>
git -C ../review-<sha> rev-parse HEAD          # must print <sha>; a silent failure reviews the wrong tree
```

Run the cheap deterministic checks yourself first (linters, type checks, the unit tests you
touched), so reviewers spend their attention on behaviour, not typos. Write a short fact sheet of
what you verified that the diff does not show (what the host runs, what an unchanged file does,
what the plan allows): a reviewer without facts guesses, and a guess reads exactly like a finding.
Tell every reviewer, in the shared context: do not edit anything, and do not run anything on
production.

## 2. Two independent reviewers, one frozen scope

After any non-trivial change, run two independent reviews in parallel over the same pinned commit,
on two different engines, and gate on a stated severity (for example "nothing at P2 or above").
The mechanics (output directories, status files, follow-up rounds) are in the
[`contract-fanout`](../../plugins/worktrees/skills/contract-fanout/SKILL.md) skill; for changes
that run as root, deploy, migrate data or handle credentials, the
[`adversarial-review`](../../plugins/review/skills/adversarial-review/SKILL.md) skill sends every
finding to three refuters before it counts.

- **A reviewer that did not finish is "no review", not "clean".** Read each reviewer's own status,
  not the exit code of the command that launched them.
- **Later rounds review only the fixes,** with a context file listing earlier rounds' fixes and
  declined findings (with reasons), so nobody re-raises them.
- **A new commit after a clean round voids it.** Review and gate the new SHA before calling it
  ready.
- **Rounds are the norm on privilege boundaries.** Fixes to a change that decides what runs as root
  are new attack surface; expect a second and third round to find real defects in the fixes.

## 3. Verify every finding before fixing it

A plausible finding is not a real one. For each, trace the code path, build the concrete scenario,
and name the invariant it breaks. Then:

| Verdict | Do |
|---|---|
| Real, and it breaks something | fix it, with a test that fails before the fix |
| True in the abstract, a no-op against the real inputs | answer it with the evidence (the live data you checked); no code change |
| Wrong (unreachable, intended, already handled at `file:line`) | decline it, write the reason in the context file |
| The same defect found five ways | fix it once |

Reviewers reason from the repository's text (old docs, migration scripts, unrelated tests), not
from what production holds. One live check per finding (query the real configs, the real rows)
and the question "which way does a wrong guess fail?" settle most of them: breakage gets a fix, a
silent no-op gets a comment.

## 4. A control run for every new test

A regression test proves something only if it fails on the code before the fix. Run it there:

```bash
git worktree add --detach ../control <fix-sha>^                    # the code before the fix
git -C ../control restore --source <fix-sha> -- tests/new.test.ts  # only the new test
(cd ../control && <run that one test>)                            # must FAIL, on the expected assertion
(cd <fix checkout> && <run that one test>)                        # must pass
git worktree remove ../control
```

Record both results. A test that passes on the old code tests nothing, however well it reads.

## 5. Bot reviewers on a pull request

- **Wait for every expected reviewer on the latest head SHA** before merging or before pushing the
  next round of fixes; gather all of a round's findings, then push one round. Some reviewers take
  much longer than others, and some silently skip commits pushed while they were mid-review.
- **A passing check is not a silent review.** Read every place comments land: the conversation,
  inline threads and formal reviews (on GitHub: `issues/<n>/comments`, `pulls/<n>/comments`,
  `pulls/<n>/reviews`). A reviewer that edits its earlier comment shows a different `updated` time
  than `created`; re-read it.
- **Answer every top-level thread** with the commit and `file:line`, or the evidence for declining.
- **A queue of merges makes the rule stricter, not looser.** Read each PR's findings before its
  own merge; never let the next merge start while the previous one's threads are unread.
- **A blocking production fix** may merge without waiting for a slow hosted job when the local
  gates are green, every reviewer has posted and been answered, and a read-only rehearsal passed,
  on the owner's say-so. Not for features, and not for code without tests.

## 6. Verification before "done"

Done means the real flow ran and did the right thing. In order of strength:

1. the unit test passes;
2. the real input (the actual failing payload from the logs, not your fixture's shape) goes through
   the real function and comes out right;
3. the real path (the HTTP endpoint, the deployed process, the device) returns the right thing.

Go all the way to 3 whenever it is reachable, and say so when it is not. Then:

- **Prove the running process is the new one.** A deploy that copies files but never restarts the
  service leaves the old code answering; compare the process start time with the deploy time, or
  read the commit from a health endpoint.
- **Prove where you are before anything destructive.** A script pointed at production through two
  settings (a URI and a database name, a bucket and a prefix) can quietly use one from production
  and one from development. Count a fixture only production has; zero where you expected N means
  stop. Dry-run first, always.
- **Find every caller before adding a side effect.** A delete that now cascades turns a scheduled
  cleanup with an old filter into a data-loss job. Search the schedules, admin scripts and old
  filters, not only the obvious call sites, and add a test that the protected shape survives.
- **A negative result needs controls.** "Rejected", 401, 403, 404 or "doesn't work" is evidence
  only when the same input succeeds on a known-good path and a known-bad input fails the same way.
- **A job is running only when you hold its id.** If the call returned output, it already finished:
  read the output before reporting.

The report says what was verified and how, what was not and why, and what needs the owner:

```text
Done: <one line>
Verified: <what; the command and its result, or the URL and what it returned>
Not verified: <what; the blocker that kept it from running>
Needs the owner: <decision ids, or none>
```

## In repository text

Commit messages, PR descriptions and docs summarize review as "Extensive multi-model review" plus
the concrete outcomes (what was found, what changed). They never name the review tools, the
models, the routes or the effort levels.
