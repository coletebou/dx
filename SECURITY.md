# Security

## Reporting a vulnerability

Please report it privately through GitHub: the repository's **Security** tab, then **Report a
vulnerability**. Don't open a public issue for it, and don't include real credentials in the
report: a description and the steps to reproduce are enough.

Reports are read on a best-effort basis, usually within a week. Fixes land on `master`; there are
no maintained release branches.

## What counts

Anything in this repo that could leak a secret, run something you didn't ask for, or destroy
data: an installer step that overwrites without a backup, a hook that sends a transcript
somewhere, a tool that types into the wrong pane, a scrub or boundary check that fails open.

## What this repo does about secrets

- It holds none. Keys belong in `~/.env_secrets`, which is yours and never committed.
- The git hooks (`base/git/hooks/`) scan every commit and push with gitleaks and fail closed.
- The memory tools ask `MEMORY_BOUNDARY_CMD` before any transcript or file reaches a model
  (see [docs/memory/README.md](docs/memory/README.md)).
