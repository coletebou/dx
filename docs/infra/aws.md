# Claude Code on Amazon Bedrock (optional)

Nothing in this repo needs AWS: every tool defaults to your normal Claude Code login. Bedrock is
a second route for when you want usage billed to an AWS account, or a fallback when a
subscription's allowance runs out mid fan-out. Claude Code reaches Bedrock two ways:

| Route | Switch | Model ids | Credential |
|---|---|---|---|
| **Bedrock Mantle** | `CLAUDE_CODE_USE_MANTLE=1` | single-segment `anthropic.<model>` | `AWS_BEARER_TOKEN_BEDROCK` |
| **Bedrock Runtime** | `CLAUDE_CODE_USE_BEDROCK=1` | inference profiles: `us.anthropic.<model>`, `global.anthropic.<model>` | `AWS_BEARER_TOKEN_BEDROCK`, or the AWS SDK credential chain |

The two routes serve and gate models independently, and an alias (`opus`, `sonnet`, `haiku`)
resolves to whatever the active route's pins say. A pin the route does not serve fails with
`model_not_found`, including in places you do not choose the model yourself (a subagent started
with `model: haiku`, WebFetch's summarizer).

## How this repo routes

- **`yuma`** (in `base/aliases.sh`) starts Claude Code on Mantle with
  `base/claude/mantle.settings.json`, an overlay that switches the route on, switches the others
  off, and pins every alias to an id Mantle serves. `YUMA_SETTINGS` names another overlay. Prefer
  it to a one-key `--settings '{"env":{"CLAUDE_CODE_USE_MANTLE":"1"}}'`, which keeps the machine's
  own alias pins.
- **`base/claude/subscription.settings.json`** is the opposite overlay: every route switch and pin
  blanked, so a session on a Bedrock-configured machine goes back to the subscription login.
- **The memory tools** pick the route per call from the model id: `claude-consolidate` sends an
  `anthropic.*` id to Mantle and a `us.anthropic.*` or `global.anthropic.*` id to Runtime (in
  `$AWS_REGION`, default `us-east-1`), each through a per-call settings file, so one id works on a
  machine whose default route is a subscription. Aliases keep the default route.
- **Fan-outs:** `PW_CLAUDE_CMD=yuma pw launch m.tsv` runs every parallel window on Mantle;
  `FSH_LAUNCHERS` (cc-handoff) maps a passer's route to the launcher its successor starts with;
  the paired reviewer reads its own `AUTOREVIEW_*` settings.

Check what a wrapper really resolves to before launching N sessions on it: a wrapper that blanks
the `ANTHROPIC_DEFAULT_*` pins can turn `--model opus` into a different version than your
interactive shell does.

## Credentials

- Keep `AWS_BEARER_TOKEN_BEDROCK` (and any provider key) in `~/.env_secrets`, which `zshenv`
  sources for every zsh, and never in a settings file, a command line or a log. A value in argv
  is visible to every process on the machine (`ps`), and settings files get committed.
- Scheduled jobs (launchd, systemd) do not read your shell's files. `claude-consolidate` reads
  only `AWS_BEARER_TOKEN_BEDROCK` and `ANTHROPIC_API_KEY` from `CLAUDE_CONSOLIDATE_ENV_FILE`, and
  only when they are not already in the environment.
- `scripts/autoreview-pair` sources `AUTOREVIEW_ENV_FILE` (default `~/.env_secrets`) itself, since a
  bash caller does not get what `zshenv` exports; a missing token otherwise looks like an expired
  one (a 403).
- The base Claude Code settings blank `BW_SESSION`, so an unlocked password-manager CLI session in
  your shell never reaches an agent.

## Codex

Codex CLI has its own provider profiles in `~/.codex/config.toml` (`codex -p <profile>`); the
same rules apply: credentials from the environment, never in the profile or on the command line.
See [Codex's configuration docs](https://developers.openai.com/codex/config-basic).

## See also

The other infrastructure playbooks, all optional: [tailscale.md](tailscale.md) (a personal fleet
over a tailnet), [cloudflare.md](cloudflare.md) (Tunnels, Access, DNS and WAF in front of
self-hosted services) and [vps.md](vps.md) (a production box).
