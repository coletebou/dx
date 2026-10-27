# review

Skills for reviews whose findings are checked before anyone acts on them.

| Skill | What it does | Runs |
|---|---|---|
| `autoreview` | Structured review of a diff, branch, commit or pull request by Codex, Claude, Amp, Pi or OpenClaw through one helper, with a pre-send secret scan, isolated reviewer sandboxes and a JSON status contract. `scripts/autoreview-pair` runs it twice, on Codex and on Claude, over one frozen scope. | `python3 scripts/autoreview` |
| `adversarial-review` | Fans a diff out to one reviewer per lens (platform semantics, shell, supply chain, operations, docs), then sends every finding to three refuters with distinct perspectives, and fixes only what survives. A scaffold for Claude Code's Workflow tool. | the Workflow tool |
| `mcp-agent-safety` | A real-LLM safety test for an MCP server: headless Claude Code with nothing but that server, fresh fake secrets (canaries), and a sweep of every byte the session and the server's own MCP traffic produced, in 14 encodings, judged on ground truth so a refusal cannot pass. Ships a safe/leaky example pair and 54 tests. | `node scripts/run.mjs` (Node 24+) |
| `fable-second-opinion` | Opens a fresh-context advisor in its own tmux window, one-shot or for the whole session; the advisor reads the primary pane and sends advice back through a guarded relay that refuses shell panes. | `scripts/ask-fable`, `scripts/send-to-primary` |

## Install

```text
/plugin marketplace add coletebou/dx
/plugin install review@dx
```

From a clone, `./install.sh --with review` links the skills into `~/.claude/skills` and
`scripts/autoreview-pair` into `~/.local/bin`: two independent runs of the `autoreview` helper, on
Codex and on Claude, over one frozen scope, which `contract-fanout` (the `worktrees` plugin) also
uses. Codex and other agents that read `~/.agents/skills` find the skill once the same directory is
linked there too:

```bash
mkdir -p ~/.agents/skills && ln -s "$PWD/plugins/review/skills/autoreview" ~/.agents/skills/autoreview
```

## Requirements

Python 3.10+, TruffleHog and the CLI of each engine you review with for `autoreview`; tmux for
`fable-second-opinion`; Node 24+ and the `claude` CLI for `mcp-agent-safety`;
the Workflow tool for `adversarial-review`.
