---
name: adversarial-review
description: Multi-lens review of a diff or a small set of files where every finding must survive three independent refuters before it counts. Use before merging infrastructure, deploy, CI/CD, auth, or data-migration changes; when the user asks for a "thorough", "adversarial", or "multi-model" review of uncommitted work; or after a first review round produced fixes that themselves need checking. Runs as a Workflow (ultracode or explicit opt-in). Never used for style review.
---

# Adversarial review

Reviewers are cheap and wrong often. A single reviewer over a CI/CD workflow produced 31 "confirmed"
findings in one session; after three independent refuters per finding, 8 distinct real defects
remained and one major "finding" turned out to rest on a false premise. This skill encodes that shape:
**fan out by lens, then try to kill every finding, then fix only what survives.**

## When to use

- Deploy scripts, CI workflows, systemd units, sudoers, runner registration, anything that runs as root on a host.
- Schema or data-ownership migrations, auth and token handling, anything with a one-time irreversible step.
- A second round after you fixed a first round's findings (the fixes are new code).
- The user asks for a thorough, adversarial, or multi-model review of uncommitted or branch work.

Do not use for style, naming, or formatting. Do not use as a substitute for running the tests.

## Preconditions

1. **Freeze the scope.** Note the worktree path, branch, base ref, and `git status --short`. No edits while the review runs; reviewers read the tree, and edits mid-run make findings unverifiable.
2. **Lint first.** Run the cheap deterministic checks yourself (actionlint, shellcheck, tsc, biome, unit tests). Reviewers should hunt semantics, not typos.
3. **Write the fact sheet.** Everything you verified that reviewers cannot see from the diff: host facts, account permissions, service names, what other files (unchanged) do, what the plan allows. A reviewer without facts guesses, and guesses look exactly like findings.
4. **State the no-touch rule in the shared CONTEXT, not only in one lens.** Reviewers with tools will otherwise SSH into production and run experiments. In one run, round-one reviewers ran `sudo sleep` processes and `kill` on the production host to test signal semantics. Say, verbatim: *"Do NOT edit anything in the worktree. Do NOT run any command on <host> (no ssh to it); reason from the verified facts and from local experiments only."*

## Shape

```
phase Review:   one agent per lens, all over the same frozen files  -> findings[]
phase Verify:   for each finding, three refuters with distinct perspectives, each told to
                REFUTE and to default to refuted=true when unsure       -> stands if >= 2 say it stands
result:         { confirmed: [...with corrected fixes], refuted: [...with why] }
```

Lenses that earned their keep on infrastructure changes:

| Lens | Hunts for |
|---|---|
| platform-semantics | how the runtime actually behaves: Actions contexts and `needs`/`if`, systemd unit and `systemd-run` semantics, sudo env handling, checkout credential lifecycle |
| shell | `set -euo pipefail` traps, pipelines with `grep`, heredoc vs stdin, quoting, exit-status capture, `[[ ]]` as bare statements |
| security-supply-chain | pinning and checksum correctness, token scope, what can reach privileged runners, secrets in logs |
| operations | walk the failure scenarios: two merges in a row, cancel mid-run, re-run after partial failure, service down, force-push, first run with nothing set up |
| docs | every claim in changed docs and comments versus what the code does and versus the fact sheet |

For app and UI diffs (SwiftUI, server contract, shared types) the lenses that earned their keep were:
runtime semantics (view lifecycle, concurrency, hit-testing), accessibility and theming, server and
contract parity across languages, pure-logic equivalence against the code it replaced, and product
fidelity against the acceptance criteria plus docs. A second three-lens round over the fixes found two
more real defects; budget for it.

Refuter perspectives (keep them distinct; redundancy catches less than diversity):

1. Platform semantics: does the runtime behave as the finding assumes? Cite docs or the pinned action source.
2. Bash/Linux semantics: reproduce with a **safe local** experiment. Never the host, never the worktree.
3. Operational reality: given the fact sheet, would this occur, and would the proposed fix make it worse?

## Script scaffold

Pass this inline to the Workflow tool. Fill `ROOT`, `CONTEXT` (goal + fact sheet + no-touch rule), and the
`LENSES` prompts. Schemas force structured output, so no parsing.

```js
export const meta = {
  name: 'adversarial-review',
  description: 'Multi-lens review with three refuters per finding',
  phases: [{ title: 'Review' }, { title: 'Verify' }],
}
const ROOT = '<absolute worktree path>'
const CONTEXT = `You are reviewing uncommitted work in ${ROOT} (branch X, based on Y). Read files with Read;
run \`git -C ${ROOT} diff <base>\` to see the change. Do NOT edit anything. Do NOT run any command on <host>.
<goal in two sentences>
Verified facts (do not re-probe): <fact sheet>
Report only defects that would cause wrong behaviour, a failed or unsafe deployment, a security weakness,
or a false statement in docs. Style is out of scope. For each finding give file, line, a precise claim and a
concrete failure scenario. If a fact you need is not listed and cannot be verified locally, say so instead of assuming.`
const LENSES = [ { key: 'platform-semantics', prompt: '...' }, /* ... */ ]
const FINDINGS = { type: 'object', properties: { findings: { type: 'array', items: { type: 'object', properties: {
  file: { type: 'string' }, line: { type: 'integer' }, claim: { type: 'string' }, scenario: { type: 'string' },
  severity: { type: 'string', enum: ['blocker', 'major', 'minor'] }, fix: { type: 'string' } },
  required: ['file', 'line', 'claim', 'scenario', 'severity', 'fix'] } } }, required: ['findings'] }
const VERDICT = { type: 'object', properties: { refuted: { type: 'boolean' }, reasoning: { type: 'string' },
  corrected_fix: { type: 'string' } }, required: ['refuted', 'reasoning'] }
const REFUTERS = [
  'Platform semantics: does the runtime behave as the finding assumes? Cite documentation or source.',
  'Bash/Linux semantics: reproduce with a safe LOCAL experiment (never the host, never the worktree).',
  'Operational reality given the verified facts: would this occur, and would the fix make it worse?',
]
phase('Review')
const results = await pipeline(
  LENSES,
  (l) => agent(`${CONTEXT}\n\n${l.prompt}\n\nReturn every substantiated defect; an empty list is valid.`,
    { label: `review:${l.key}`, phase: 'Review', schema: FINDINGS, effort: 'xhigh' }),
  (rev, l) => {
    const found = (rev && rev.findings) || []
    log(`${l.key}: ${found.length}`)
    return parallel(found.map((f) => () =>
      parallel(REFUTERS.map((r, i) => () =>
        agent(`${CONTEXT}\n\nFinding (lens ${l.key}):\n${JSON.stringify(f, null, 2)}\n\nREFUTE it if you can, from: ${r}\nRead the files. Default refuted=true if you cannot substantiate the scenario. If it stands, improve the fix.`,
          { label: `verify:${l.key}:${i}`, phase: 'Verify', schema: VERDICT, effort: 'xhigh' })))
        .then((v) => { const vv = v.filter(Boolean); return { ...f, lens: l.key, stands: vv.filter((x) => !x.refuted).length >= 2, votes: vv } })))
  },
)
const all = results.filter(Boolean).flat()
const confirmed = all.filter((f) => f.stands)
log(`confirmed ${confirmed.length}, refuted ${all.length - confirmed.length}`)
return {
  confirmed: confirmed.map((f) => ({ file: f.file, line: f.line, severity: f.severity, claim: f.claim,
    scenario: f.scenario, fix: f.fix, corrected: f.votes.map((v) => v.corrected_fix).filter(Boolean) })),
  refuted: all.filter((f) => !f.stands).map((f) => ({ file: f.file, line: f.line, claim: f.claim })),
}
```

## Reading the result

- The task notification truncates. The output file it names is a JSON object whose `result` field
  holds the script's return value (sometimes as a JSON string): `json.load(f)["result"]`, then
  `json.loads` if it is a string. Parsing the file as the bare return value fails. Per-agent returns
  are in `journal.jsonl` in the transcript directory (`type: result` rows keyed to `started` rows).
- Refuter calls occasionally fail on a model safeguard flag (`[reasoning_extraction]`) on ordinary
  code-review prompts. The scaffold then counts 2 of 2 remaining votes; read those findings yourself
  rather than trusting the thinner vote.
- Refuters judge one finding at a time and can contradict each other on the same platform fact
  across findings (one run refuted "`.task` is cancelled on disappear" for one finding while three
  refuters confirmed it for another). Resolve contradictions from documentation, not by vote count.
- **Dedupe before fixing.** Five lenses find the same defect five ways; 31 confirmed collapsed to 8 real fixes.
- **Verify every confirmed finding against the real code yourself** before changing anything. Refuters
  reduce false positives; they do not eliminate them.
- **Report the refuted ones** with the reason. A rejected finding with evidence is worth as much to the
  user as a fix; it is also what stops the same claim resurfacing next round.
- **Parse the output file, not the notification.** The notification truncates a large `confirmed` list
  after the first entry and it looks like a single finding. `json.load` the file, take `result`
  (`json.loads` it if it is a string), then list `confirmed` and `refuted`; the journal's `type: result`
  rows give each lens's raw findings when the aggregate is in doubt.
- **Pin each round to its own detached checkout.** `git worktree add --detach <scratch>/review-<sha>`
  and point `ROOT` there; the main worktree can then take the next fix commit, a rebase, or a sibling's
  fetch while refuters are still reading. A second pinned checkout at the newer SHA lets the next round
  start before the previous workflow finishes. Remove each checkout when its round is done.
- **Expect scratch noise.** Refuters write `refute-*`, `repro-*` and `harness-*` directories next to the
  pinned checkout and sometimes import pure helpers from the main worktree; a helper you rename mid-run
  surfaces as their compile error in the editor diagnostics, not as a defect in your tree.
- If you fixed anything substantive, run a smaller second round (three lenses) over the fixes.

## Expect several rounds on privilege boundaries

A change that decides what runs as root is not done after one round. On a runner-hardening PR the
first round found two escalation paths in the design, the second found five defects in the fixes
(a symlink race, a retire-before-verify ordering, a journal-group exposure, a login shell, an
install-over-running-service), the third found two more, and the fourth was clean plus a PATH pin.
Each round's fixes were themselves the next round's attack surface. Budget for it, and keep the
frozen-scope rule between rounds: draft fixes outside the repo (a mktemp copy, shellcheck it
there) while a round is still running, then apply all findings in one commit.

## Cost and scale

Five lenses with three refuters ran about 100 agents and 70 minutes at xhigh. Three lenses ran about 50
agents and 25 minutes. A single small script needs three lenses and one round. Do not add a fourth
refuter; add a lens instead.

Three lenses over one app commit take about 6 minutes when the lenses find nothing and 15 to 46
minutes when they do (36 agents for 11 findings). Run the workflow in parallel with the two
independent engines from the start, not after them; on a sixteen-round series the engines went
clean at round 9 while the workflows kept confirming real member-visible gaps until round 14 and
wording-only items after that. Stop when an engine pair is clean and the workflow confirms only
comment or copy fixes.

## What goes in the repo

Commit messages, PR bodies, and docs say "Extensive multi-model review" and the concrete outcomes.
Never the tool, the reviewer names, the model, or the effort level.
