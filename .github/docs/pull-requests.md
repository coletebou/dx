# Pull requests: what a good one carries, its labels, evidence and stacked PRs

The rules the pull request template, the PR Labels workflow and the review
workflows assume. Installed with the kit as `.github/docs/pull-requests.md`.

## Before you open one

- **One change per pull request**, small enough to review in one sitting.
  `size/XL` is a prompt to split it.
- **A title that says what changes**, in the
  [Conventional Commits](https://www.conventionalcommits.org) form when the
  repository uses it (`fix(api): retry a dropped upload`).
- **Open it as a draft while it is in progress.** Marking it ready for review
  is the signal that it is done: that is when the full CI lane and a review
  round run.
- **Fill in the template**: Summary (what and why, with the issue it settles),
  Testing (what you ran), Evidence (the real run, below) and Risk (what could
  break, and how you would notice).

## Labels

Every PR carries three kinds of labels. Two are kept current automatically by
`.github/workflows/pr-labels.yml` (logic in `.github/scripts/pr-labels.mjs`);
the third is a reviewer's call.

| Family | Set by | Labels |
|--------|--------|--------|
| Size | automation, every push | `size/XS` under 20 lines, `size/S` 20-99, `size/M` 100-499, `size/L` 500-999, `size/XL` 1000+ |
| Proof | automation, every push, edit or human comment | `proof: ✅ sufficient`, `proof: 📸 needs screenshots`, `proof: 🧪 needs e2e`, `proof: ➖ not needed`, plus the manual `proof: 🙋 override` |
| Merge risk | a reviewer | `merge-risk: 🚨 security`, `breaking`, `data`, `availability`, `automation` |

The automation owns only `size/*` and the four automatic `proof:` labels. It
never adds or removes `merge-risk:`, `ci:full`, `proof: 🙋 override` or any
topic label. The whole label set, with colors and descriptions, is the kit's
`labels.yml` (`.github/labels.yml` once installed); the kit's `sync-labels.sh`
applies it to a repository.

## Size

Lines added plus lines removed, not counting lockfiles (`package-lock.json`,
`Cargo.lock`, `go.sum` and friends), generated output (`dist/`, `build/`,
snapshots, `*.generated.*`) or binary assets (images, fonts). A
lock-maintenance PR with 2,000 lockfile lines and 30 lines of code is
`size/S`.

## Proof: what counts as evidence

The bar: **screenshots for any UI change, and an end-to-end or live run for
anything where one is possible.** Unit tests, mocks, typecheck, lint and CI
are necessary, but on their own they are mock-only proof.

| The PR changes | It needs | Counts as evidence |
|----------------|----------|--------------------|
| UI a user sees: `.tsx`, `.jsx`, `.css`, `.html`, `.vue`, `.svelte`, `.swift` and similar files, or images, under the paths the repository variable `PR_LABELS_UI_PATHS` names (anywhere when it is unset), minus `PR_LABELS_NOT_UI` | screenshots | an image or recording attached to the PR body, or to a comment or review by the author or a collaborator |
| Behavior: any code, script, workflow, Dockerfile, build file, runtime dependency (`package.json`, `requirements.txt`, `constraints.txt`) or lockfile | an E2E or live run | in the body's `## Evidence` (or `## Proof`) section, or a comment that starts with "Evidence": a code block with the command and its output, a recording or screenshot, or a link to the run |
| Only docs (Markdown, reStructuredText or AsciiDoc files, anything under `docs/`, LICENSE-style files; other `.txt` files count as behavior), only tests, or only `@types/*` packages | nothing | `proof: ➖ not needed` |

So a PR gets `proof: 📸 needs screenshots` and/or `proof: 🧪 needs e2e` until
each needed kind of evidence is attached, then `proof: ✅ sufficient`.

Things that do **not** count:

- A `## Testing` section listing test runs. That is CI-level proof; put
  real-run output under `## Evidence`.
- Images and comments from bots (deploy cards, review bots, dependency bots).
- Prose such as "tested locally, works".

For a CI or workflow change, the evidence is the run that exercised the new
path: link it under `## Evidence`.

### When the automation is wrong

The rules are path-based, so they are deliberately strict: a `.tsx` change
that only rewires state still asks for screenshots, and a change whose proof
is its own CI run still asks for an E2E link. Either attach the evidence, or
add `proof: 🙋 override` and set the proof label you judged correct by hand.
While the override is on, the automation leaves proof labels alone; remove it
to hand the decision back.

## Merge risk

A reviewer adds a `merge-risk:` label when there is a concrete way the merge
breaks something, with the failure mode written in the review:

- `merge-risk: 🚨 security`: could weaken auth, sessions, secrets, sandboxing,
  isolation or permissions, or expose private data (including a security fix
  that is incomplete).
- `merge-risk: 🚨 breaking`: could break existing users, API contracts,
  config, defaults, migrations or upgrades.
- `merge-risk: 🚨 data`: could lose, corrupt or wrongly delete user data,
  files, sessions or history.
- `merge-risk: 🚨 availability`: could crash, hang or take down a service,
  host or deploy.
- `merge-risk: 🚨 automation`: could break CI, deploys, scheduled jobs or
  other automation.

Failing checks and merge conflicts are not merge-risk labels; GitHub already
shows them.

## Reviews

When the repository runs `.github/workflows/claude-code-review.yml`, a review
round starts when a PR is opened or reopened while ready, or marked ready for
review. Pushes do not start another: work through the comments, then convert
the PR to draft and mark it ready again for the next round. `@claude` in a
comment asks for an on-demand run (`.github/workflows/claude.yml`).

## The full CI lane, drafts and `ci:full`

In a repository that splits CI into a fast lane and a full lane (the kit's
README describes the contract), a ready PR runs the full lane on every push,
and a draft runs the fast lane only. Add `ci:full` to a draft to run the full
lane on its head (`.github/workflows/ci-full-label.yml`); that run shows on the
head commit and in the Actions tab, not among the PR's checks. Approving a ready
PR whose full lane failed or was cancelled on its head reruns the PR's own run
(`.github/workflows/ci-full-on-approval.yml`), which is what its required checks
read.

## Stacked PRs

A stacked PR targets another PR's branch instead of the default branch. It
gets the same CI as any other PR: the workflows run for PRs into any base,
and each run tests the PR merged onto its own base.

When a parent PR merges, GitHub retargets its children to the parent's base.
That arrives as an `edited` event, which the CI workflow should ignore (an
edit must never cancel a run), so `.github/workflows/stacked-pr-retarget.yml`
dispatches a full run of the child's head merged onto its new base instead.
That run shows on the head commit and in the Actions tab, not among the PR's
checks, so read it there before merging. Drafts follow the usual rule: they
get that run only with `ci:full`.
