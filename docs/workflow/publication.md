# Private first, published through a gate

This repository is published from a private one. Everything is written, run and reviewed in
private first; a file reaches the public only by being named for export, and only after a scrub
gate passes on the whole result. Agents work in the private repository by default, because that
is where their memory, briefs and transcripts already are, and where a slip costs nothing.

## The export

The mirror is built from an allowlist. Nothing outside it leaves, so a new private file stays
private until someone decides otherwise.

| Entry | Meaning |
|---|---|
| copy | taken verbatim from the private source (a file, or a directory taken recursively) |
| adapt | a generalized copy that lives in the mirror; a later private change is merged into it three ways from the private version it was generalized from, and a conflict stops the export for a human |
| skip | a path inside a copied directory that stays private |
| public | a file that exists only in the mirror (like these docs) |
| allow | a reviewed false positive of the gate, by rule, path and line hash |

The export stages everything in a temporary directory, reports what would change in the mirror,
runs the gate on the staged tree, and only then writes the files. It never commits or pushes: a
person (or the coordinator) reviews the mirror's diff first.

## The scrub gate

One command, run on the mirror (or any checkout) before every commit and every push:

- **Secret scanners** over the working tree and the whole history.
- **A denylist by shape** over every tracked and untracked file, every file path and every commit
  message: email addresses, phone numbers, private and tailnet addresses, tailnet names, the
  owner's hostnames, home-directory paths, employer and client names, account ids, provider ids,
  API key shapes, the names of private helper tools.
- **Commit identities:** only no-reply addresses.

It **fails closed.** A scanner that is missing or errors, a file it cannot read, a file the export
never classified, a binary nobody allowed: each is a failure, not a skip. A scrub that fails open
publishes exactly the thing it missed.

It **prints `file:line` and the rule name, never the matched text,** so the gate's own output (in
a CI log, a transcript, a chat) cannot leak what it found.

**Reviewed false positives** (a license's copyright line, a documented mount point) are allowed by
rule, path and the hash of the whole line. The value itself is never stored, and the moment the
line changes it needs a new review. Nobody weakens a rule to make a run pass.

**Read its exit status, not a pipe's.** Without `pipefail`, `gate | tail` exits with `tail`'s
status; wrap the gate so the wrapper exits with the gate's own code, and read the last line.

This repository's own layer is smaller: the git hooks in `base/git/hooks/` scan staged changes
and outgoing commits with gitleaks, and the pre-push scan blocks when gitleaks is missing or fails.
See [SECURITY.md](../../SECURITY.md).

## Writing for publication

- **Patterns, not values.** A playbook keeps the shape of a real setup (which port binds where,
  which rule runs first) and none of its facts: no hostnames, addresses, ids, inventories, costs,
  people or incidents.
- **Placeholders that cannot collide with anything real:** `example.com` and its subdomains,
  documentation addresses (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`), documentation
  AS numbers (64496 to 64511), `<TUNNEL-UUID>`-style tokens for ids, `box-a` for machines.
- **Lessons, generalized.** "A tagged node loses its user's ssh rights" carries over; the story of
  which machine, on which day, does not.
- **No review provenance.** Say "extensive multi-model review" and the outcomes, never which tools,
  models or settings ran it.
- **Classify every source** you distill from before writing: one row per source with a verdict
  (patterns only; publish generalized; keep private) and a one-line reason. It is the record of
  what was looked at and why nothing private came out of it.

## Secrets near agents

An agent's transcript persists, gets rendered into handoffs and can be shared, so a secret printed
once is disclosed for good. In this setup:

- **Test presence, never print:** `[ -n "$TOKEN" ] && echo set || echo unset`. Not a masked
  prefix, not `${v:+set}${v}`, not an unsalted hash (a short value's hash is a lookup away).
  Compare two values in a process and print only the names that differ.
- **Test the clean case in a clean environment.** The agent's shell has usually sourced your
  secrets already; `env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c '...'` shows what a process gets
  without them. Run tests that touch live credentials the same way.
- **Check `ps` exposure with a control.** To see whether a value shows up in another process's
  command line, keep it in a `0600` file and match with `grep -cFf <file>`, never with the value on
  the checker's own command line (the checker then matches itself), and add a process that carries
  the value on purpose, so a zero proves something.
- **Keys go in `~/.env_secrets`**, which `zshenv` sources, and the git hooks scan every commit; see
  [aws.md](../infra/aws.md), Credentials, for scheduled jobs and settings files.
