# GitHub repo kit

The `.github/` a repository needs to take issues and pull requests well: issue forms, a pull
request template with the rules behind it, a label set with an idempotent sync, and workflows
that label PRs by size and evidence, scan for secrets, run Claude Code on demand and as a
reviewer, and keep a two-lane CI honest across drafts and stacked PRs.

Every file here except this README and `sync-labels.sh` lands at the same path under the target
repository's `.github/`. Every workflow that needs a secret or a variable does nothing (and says
why) until it is set, so the whole kit can go in at once and be turned on piece by piece.

## What's in it

| File | Installed as | What it does |
|---|---|---|
| `ISSUE_TEMPLATE/bug_report.yml`, `feature_request.yml` | `.github/ISSUE_TEMPLATE/` | Issue forms: what happened, steps, version and logs for a bug; the problem, proposal and alternatives for a feature. Both ask the reporter to remove secrets and personal data. |
| `ISSUE_TEMPLATE/config.yml` | `.github/ISSUE_TEMPLATE/config.yml` | Turns blank issues off and sends security reports to the security policy (`SECURITY.md`) instead of a public issue. |
| `pull_request_template.md` | `.github/pull_request_template.md` | Summary, Testing, Evidence and Risk sections. |
| `docs/pull-requests.md` | `.github/docs/pull-requests.md` | The rules: one change per PR, drafts, the label families, what counts as evidence, merge risk, reviews, the full CI lane and stacked PRs. |
| `labels.yml` | `.github/labels.yml` | The label set: GitHub's defaults, kind and priority, `ci:full`, and the `size/*`, `proof: *` and `merge-risk: *` families. |
| `sync-labels.sh` | (stays here) | Applies `labels.yml` to a repository through `gh`. |
| `workflows/pr-labels.yml`, `scripts/pr-labels.mjs` | `.github/workflows/`, `.github/scripts/` | Keeps `size/*` and `proof: *` current on every PR. |
| `workflows/secret-scan.yml` | `.github/workflows/` | gitleaks over each PR's commits and each push to `main` or `master`. |
| `workflows/claude.yml` | `.github/workflows/` | `@claude` in an issue or a comment runs Claude Code on it, for collaborators. |
| `workflows/claude-code-review.yml` | `.github/workflows/` | A Claude Code review when a PR is opened or marked ready, or by hand for a given PR. |
| `workflows/ci-full-label.yml` | `.github/workflows/` | `ci:full` on a draft PR dispatches the full CI lane for its head. |
| `workflows/ci-full-on-approval.yml` | `.github/workflows/` | An approval of a head whose full lane failed or was cancelled reruns the PR's own run. |
| `workflows/stacked-pr-retarget.yml` | `.github/workflows/` | When a stacked PR is retargeted (its parent merged), dispatches a full run against the new base. |
| `actionlint.yaml` | `.github/actionlint.yaml` | actionlint's configuration: self-hosted runner labels and the variables the workflows read. |

## Install

With this repository's installer, from its checkout:

```bash
./install.sh --with github-kit --target ~/code/myrepo --dry-run   # what it would write
./install.sh --with github-kit --target ~/code/myrepo
```

It copies the kit into the target's `.github/` (the top of the git repository `--target` is in),
fills the security link in `ISSUE_TEMPLATE/config.yml` from the target's `github.com` origin,
and moves any file it would replace to `~/.dotfiles-backup/<time>/` first. A second run changes
nothing. It touches nothing else: no `~/.dotfiles` link, no home directory files, no commits.

By hand: copy everything but this README and `sync-labels.sh` into `.github/`, keeping the
paths, and replace `OWNER/REPO` in `.github/ISSUE_TEMPLATE/config.yml`.

Then, in the target repository:

1. Review the files, delete the workflows you do not want, and commit.
2. Sync the labels (below).
3. Set the secrets and variables of the workflows you keep (below).

## Labels

```bash
github-kit/sync-labels.sh --repo OWNER/NAME --dry-run   # the plan: creates, edits, extras
github-kit/sync-labels.sh --repo OWNER/NAME             # apply it
github-kit/sync-labels.sh --repo OWNER/NAME --file .github/labels.yml   # another label file
github-kit/sync-labels.sh --repo OWNER/NAME --prune     # also delete labels the file lacks
github-kit/sync-labels.sh --print                       # the parsed file as JSON
```

It creates the labels the repository lacks and edits those whose color, description or letter
case differ; a second run changes nothing. Labels the file does not name are listed and kept,
unless `--prune` is given. It needs bash (macOS's 3.2 is fine), python3, and `gh` logged in
with write access to the repository.

`labels.yml` is a YAML list of mappings with the keys `name`, `color` (six hex digits, no `#`)
and `description`, one label each:

```yaml
- name: "area: docs"
  color: "c5def5"
  description: "The documentation"
```

Quote every value: unquoted, a color such as `000000` reads as a number in YAML.
`sync-labels.sh` refuses a file with an unknown key, a bad color, a duplicate name (names are
case-insensitive), or a value it would have to guess about, and says which line.
`scripts/pr-labels.mjs` creates any `size/*` or `proof: *` label it needs with the same colors,
so the PR Labels workflow works before a sync too.

## Workflows: what each needs

| Workflow | Secrets | Variables and inputs | Token permissions |
|---|---|---|---|
| `pr-labels.yml` | none | `PR_LABELS_UI_PATHS`, `PR_LABELS_NOT_UI` (optional) | `contents: read`, `pull-requests: write`, `issues: write` |
| `secret-scan.yml` | none | none; a root `.gitleaks.toml` is used when present | `contents: read` |
| `claude.yml` | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` | `CLAUDE_MODEL` (optional) | read-only, plus `id-token: write` for the Claude GitHub App |
| `claude-code-review.yml` | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` | `CLAUDE_REVIEW_MODEL`, `CLAUDE_MODEL` (optional); inputs `pr`, `model` for a run by hand | `contents: read`, `pull-requests: write`, `issues: write`, `actions: read` |
| `ci-full-label.yml`, `stacked-pr-retarget.yml` | none | `CI_FULL_WORKFLOW` (required to turn them on) | `actions: write` |
| `ci-full-on-approval.yml` | none | `CI_FULL_WORKFLOW`, `CI_FULL_JOB` (default `full`) | `actions: write`, `pull-requests: read` |

Every workflow starts from `permissions: {}` and grants each job only what it uses. Every action
is pinned to a full commit SHA, with its version in a comment; update them together, by hand or
with Dependabot's `github-actions` ecosystem.

Setting them with `gh`, in the target repository:

```bash
gh secret set ANTHROPIC_API_KEY --env claude      # or CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)
gh variable set CLAUDE_MODEL --body "<model id>"  # optional: set this to pin the model
gh variable set PR_LABELS_UI_PATHS --body '^(web|app/views)/'
gh variable set CI_FULL_WORKFLOW --body ci.yml
```

### PR labels

Runs on every PR event, comment and review, with `GITHUB_TOKEN` only. Which changed files count
as UI (and so ask for screenshots) is `PR_LABELS_UI_PATHS`, a regular expression over paths
(unset: a UI-kind file anywhere: `.tsx`, `.css`, `.html`, `.vue`, `.swift`, images and so on),
minus `PR_LABELS_NOT_UI`. On a fork PR the token is read-only, so the run warns and changes
nothing. The rules it applies are in `docs/pull-requests.md`.

### Claude workflows

1. Install the Claude GitHub App on the repository (in Claude Code, `/install-github-app`). `@claude`
   runs exchange their OIDC token for the app's token, which is what comments and pushes branches.
2. Add one credential: `ANTHROPIC_API_KEY` (an API key), or `CLAUDE_CODE_OAUTH_TOKEN` (from
   `claude setup-token`). Put it in the environment `claude`, which both jobs run in, and restrict
   that environment to the default branch (Settings, Environments, Deployment branches), so only
   default-branch runs can read it. A repository secret works too.
3. Optionally set `CLAUDE_MODEL` (and `CLAUDE_REVIEW_MODEL` for reviews) to the model id you want.
   Unset, the action's own default model runs; a run of the review by hand can name one in its
   `model` input.

Trust boundaries: `@claude` runs only for the repository's owner, members and collaborators, and
only from the default branch's copy of `claude.yml` (review-comment events, which would run a
PR's own copy, are not triggers). The review runs on `pull_request_target`, so its workflow file
always comes from the base branch, it never checks out or runs the PR's code, and it skips drafts,
bot PRs and fork PRs, whose text would be untrusted input to a job holding a write token. A run
by hand accepts only an open same-repository PR.

The action can also reach Claude through Amazon Bedrock, Google Vertex AI or Microsoft Foundry
(its `use_bedrock`, `use_vertex` and `use_foundry` inputs, with the provider's credentials step
before it); the kit wires only the two direct credentials.

### The full CI lane

`ci-full-label.yml` and `stacked-pr-retarget.yml` dispatch the repository's full CI workflow,
the one `CI_FULL_WORKFLOW` names, and `ci-full-on-approval.yml` reruns that workflow's run of the
PR; all three stay off until it is set. A dispatched run's checks attach to the head commit and
show in the Actions tab, but never among the PR's checks, which are its pull_request runs and
what its required checks are judged on. So a dispatch is a signal (for a draft, or a retargeted
PR), and a failed or cancelled full lane on a ready PR is repaired by rerunning the PR's own run,
which keeps that run's commit and event: a run started while the PR was a draft stays a fast
lane. That workflow keeps this contract:

- it accepts `workflow_dispatch` with the string inputs `pr` (the PR number) and `base` (the PR's
  base branch, the new one after a retarget), which the dispatching workflows set, and does not
  listen to `pull_request` `edited` or `labeled`;
- when `base` is set, every job that tests code merges `origin/<base>` into its checkout before
  anything else runs (a conflict fails the job), so a dispatched run tests what a pull_request run
  tests, the PR merged onto its base, and a retarget that breaks the integration turns it red;
- it titles a PR's runs with `run-name`, exactly `ci-full #<PR> -> <base>`, from the triggering
  event (the pull request's number and base, or a dispatch's `pr` and `base`). GitHub records no
  triggering PR on a run: a run's `pull_requests` are the PRs open now whose head matches it, so
  two PRs on one head branch appear on each other's runs, and a closed one's runs list only the
  other. The title is fixed when the run is created, so `ci-full-on-approval.yml` ties a run to
  its PR, and to the base it tested, by the title alone. A run titled otherwise (no `run-name`, so
  the PR's title) is never rerun: the step summary says the run-name is missing;
- its concurrency group is keyed by the PR, so a dispatched run and the PR's own runs cancel
  each other like runs of one PR: `ci-${{ inputs.pr || github.event.pull_request.number || github.ref }}`;
- one job, named by `CI_FULL_JOB` (default `full`; the name a run shows for it), has no `needs`
  and decides in its `if:` whether this run is the full lane: skipped on a draft's
  `pull_request` run, run otherwise.

A skeleton:

```yaml
name: ci
run-name: >-
  ${{ (github.event.pull_request.number || inputs.pr) && format('ci-full #{0} -> {1}',
  github.event.pull_request.number || inputs.pr, github.event.pull_request.base.ref || inputs.base)
  || format('ci-full {0}', github.ref_name) }}
on:
  pull_request:
    types: [opened, reopened, synchronize, ready_for_review]
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      pr:
        description: The pull request this run is for (set by the dispatching workflows)
        required: false
        type: string
      base:
        description: The pull request's base branch, merged in before the tests (set with pr)
        required: false
        type: string
concurrency:
  group: ci-${{ inputs.pr || github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
permissions:
  contents: read
jobs:
  fast:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: ${{ inputs.base != '' && '0' || '1' }}
      - name: Merge the base, as a pull_request run would
        if: inputs.base != ''
        env:
          BASE: ${{ inputs.base }}
        run: |
          git fetch --no-tags origin "+refs/heads/$BASE:refs/remotes/origin/$BASE"
          git -c user.name=ci -c user.email=ci@example.invalid merge --no-edit "origin/$BASE"
      - run: make lint unit
  full:
    # Every ready PR, every push and every dispatch; a draft only through ci:full.
    if: github.event_name != 'pull_request' || !github.event.pull_request.draft
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: ${{ inputs.base != '' && '0' || '1' }}
      - name: Merge the base, as a pull_request run would
        if: inputs.base != ''
        env:
          BASE: ${{ inputs.base }}
        run: |
          git fetch --no-tags origin "+refs/heads/$BASE:refs/remotes/origin/$BASE"
          git -c user.name=ci -c user.email=ci@example.invalid merge --no-edit "origin/$BASE"
      - run: make test-all
```

A pull_request run checks out the PR's merge commit already; a dispatched run checks out the
branch tip, which is why it merges `base` itself (with the history the merge needs). It tests the
tip as it is when the run starts, and only same-repository PRs can be dispatched
(`workflow_dispatch` cannot target a fork's branch).

### Secret scan

gitleaks 8.30.1, downloaded and checked against its release checksum, scans a PR's commits
(merges as remerge diffs, octopus merges against the base) or a push's new commits (the whole
history on a new branch or after a force push). A root `.gitleaks.toml` supplies rules and an
allowlist. Make its check required to block merges that add a credential. A repository that
already scans its whole history in CI does not need it.

## Checking the workflows

[actionlint](https://github.com/rhysd/actionlint) reads `.github/actionlint.yaml`: list your
self-hosted runner labels there, and the repository variables your own workflows read (it flags
any `vars.NAME` the list lacks).

```bash
docker run --rm -v "$PWD":/repo -w /repo rhysd/actionlint:1.7.12 -color
```
