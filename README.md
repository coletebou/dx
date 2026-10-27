# dx

Dotfiles for running fleets of coding agents. One person's working setup for Claude Code and
Codex, curated for strangers: the shell, git and tmux configuration it runs on, a Claude Code
setup (rules, settings, hooks and a statusline), tools that give agents a memory, and a plugin
marketplace of skills and CLIs for parking and handing off sessions, running agents in parallel
git worktrees, keeping tmux tidy, driving Codex, and reviewing work before it ships.

Everything is opt-in. Take one plugin, one component, or all of it.

## Quick start

**Just the skills.** In Claude Code:

```text
/plugin marketplace add coletebou/dx
/plugin install worktrees@dx
```

Plugins bring their own CLIs: Claude Code puts a plugin's `bin/` on the Bash tool's `PATH` while
the plugin is enabled. A few skills drive CLIs that live in the dotfiles part of this repo; each
plugin's README says which.

**The whole setup.** On macOS or Linux:

```bash
git clone https://github.com/coletebou/dx ~/.dotfiles
cd ~/.dotfiles
./install.sh --list                  # what each component installs
./install.sh --all --dry-run         # every change it would make, making none
./install.sh --all                   # or --with shell,git,tmux,claude,...
```

The installer links files into your home directory. Anything it would replace is moved to
`~/.dotfiles-backup/<time>/` first, with a log of every change, and a second run changes nothing.
A checkout somewhere other than `~/.dotfiles` gets `~/.dotfiles` linked to it, because the shell,
the hooks and the schedules find everything there; if you already have a `~/.dotfiles`, the
installer stops and tells you your options.

## What's inside

### Plugins (the marketplace)

| Plugin | Skills | What they do |
|---|---|---|
| [`session`](plugins/session) | `cc-park`, `fresh-session-handoff` | Park idle Claude Code sessions in tmux to free their memory and resume them with one keypress; hand a long session off to a fresh one through a written brief. |
| [`worktrees`](plugins/worktrees) | `parallel-worktrees`, `contract-fanout`, `stack-branches`, `stack-claude` | Run N Claude Code or Codex sessions in their own worktrees and tmux windows with a merged log; coordinate one issue across workers against versioned contracts; stack WIP branches. |
| [`tmux`](plugins/tmux) | `tmux-archive`, `tmux-organize` | Snapshot every pane with links to its agent and transcript; rename and regroup windows from what is in them, without ever killing a pane. |
| [`memory`](plugins/memory) | `reflect`, `dreaming`, `session-analyzer` | End-of-session retrospectives, nightly memory consolidation, and a transcript scan for unfinished work and repeated corrections. |
| [`codex`](plugins/codex) | `codex-subagents`, `codex-transcripts` | Fan out Codex subagents through tmux; read what a Codex agent really did from its transcript. |
| [`review`](plugins/review) | `adversarial-review`, `mcp-agent-safety`, `fable-second-opinion` | Reviews where every finding must survive refuters; a canary harness proving an MCP server cannot leak its secrets; a second-opinion advisor in its own tmux window. |

### Components (`install.sh`)

| Component | Installs |
|---|---|
| `shell` | zsh entry points (`zshenv`, `zshrc`, `aliases`, `zprofile`, `profile`), the starship prompt, `~/.df-profile` |
| `git` | global git config with identity routing, a global ignore file, gitleaks pre-commit and pre-push hooks |
| `tmux` | `tmux.conf` and its status helpers, Claude Code and Codex resume after a tmux-resurrect restore, the tmux plugin's CLIs |
| `claude` | Claude Code: a generated `settings.json` (hooks, statusline), a `CLAUDE.md` rules stub, MCP servers |
| `codex` | the Codex skills |
| `session`, `worktrees`, `memory`, `review` | each plugin's CLIs in `~/.local/bin` and its skills in `~/.claude/skills` |
| `schedules` | launchd (macOS) or systemd user (Linux) jobs: cc-park autopark, the nightly dream sweep, tmux autosave. Not part of `--all`. |
| `github-kit` | the [GitHub repo kit](github-kit/README.md) (issue forms, a PR template and its rules, a label set with a sync script, PR-labeling, secret-scan, Claude Code and CI-lane workflows), copied into the `.github/` of the repository `--target` names. Not part of `--all`. |

The Claude Code setup in `base/claude/` is the part most people come for:

- **Rules** (`CLAUDE.base.md`): how an agent should communicate, verify, delegate and stay safe.
- **Hooks** ([event-by-event map](docs/claude-hooks.md)): a context advisor that suggests a fresh
  session before the context fills; recovery from transient API errors; tmux window names that
  follow the session; a background reflector that files what a session learned and left open;
  the memory and handoff of a repo surfaced at session start.
- **Statusline** (`statusline.sh`, with its test suite): model, context use, cost, git state,
  host label and the issue the session is about, in one line.

## Identities and roles

Two settings choose what a machine runs, recorded in `~/.df-profile` by the installer:

- **Identity** (`--identity`): who you are on this machine. `identities/<id>/` holds your git
  identity, host labels, Claude Code rules and settings, and shell settings. The repo ships one
  synthetic identity, [`identities/example`](identities/example): copy it to `identities/<you>/`,
  edit it, and install with `--identity <you>`. A second identity (work, a client) is another
  directory, and git picks the commit identity by remote URL.
- **Role** (`--role`): what the machine is for. `local` is a workstation (macOS, Linux or WSL);
  `server` is a box that runs agents, with a leaner shell.

Machine-local overrides that never get committed go in `claude/settings.local.json`,
`claude/mcp.local.json`, `~/.gitconfig.local` and `~/.zshenv.local`.

## Layout

```text
.claude-plugin/marketplace.json   the plugin marketplace
plugins/<name>/                   skills, their CLIs (bin/) and a README per plugin
base/                             shared by every machine: zsh, git, tmux, starship
base/claude/                      Claude Code rules, settings, hooks, statusline
roles/{local,server}/             per-role shell and MCP additions
identities/example/               a synthetic identity to copy
scripts/                          the CLIs (cc-handoff, wt-helper, reflections, dream, ...)
scripts/tests/                    the test suites
claude/*.conf.example             memory tool configuration templates
launchagents/, systemd/user/      schedule templates
docs/                             handoff chains, hooks, memory, workflow, infrastructure
install.sh                        the installer
```

## Docs

| Doc | What it covers |
|---|---|
| [Running fleets of agents](docs/workflow/README.md) | coordinator and worker roles, briefs and handoffs, lane terms, parallel worktrees, review before ship, publishing through a scrub gate |
| [Handoff chains](docs/handoff.md) | how `cc-handoff` moves a long session into a fresh one, on this machine or another |
| [Claude Code hooks](docs/claude-hooks.md) | every hook, event by event |
| [Agent memory](docs/memory/README.md) | reflections, the session reflector, transcript analysis and the nightly dreaming sweep |
| [Infrastructure playbooks](docs/infra/README.md) | a fleet over Tailscale, Cloudflare in front of self-hosted services, a production VPS, Claude Code on Bedrock |

## Requirements

- macOS or Linux (WSL works), zsh, git, and bash (macOS's stock 3.2 is fine for the installer
  and most scripts; `session-analyzer` and `tmux-apply-plan` need bash 4 or newer).
- tmux 3.4 or newer, jq, Python 3, and [Claude Code](https://code.claude.com).
- Optional: Codex CLI, [gitleaks](https://github.com/gitleaks/gitleaks) (the git hooks refuse to
  run without it), starship, fzf, and Node 24 for `mcp-agent-safety`.
- Claude Code on Amazon Bedrock is optional and documented in [docs/infra/aws.md](docs/infra/aws.md).

## Security notes

- **No secrets live here, and none should.** Keys go in `~/.env_secrets` (yours, never committed),
  which `zshenv` sources. The git hooks scan every commit and push with gitleaks and fail closed.
- **Memory is data, not code.** Memory files, reflections, diaries and transcripts belong in a
  private repository; `.gitignore` keeps them out of a fork. A data boundary
  (`MEMORY_BOUNDARY_CMD`) keeps chosen sessions away from every model call the memory tools make,
  and from the context advisor's optional third-party advice call.
- **The installer never deletes.** Everything it replaces is moved into a dated backup with a
  change log, and `--dry-run` shows every change first.
- **Tools that type into other agents' panes check them first.** `pw broadcast` never types into a
  pane at a shell prompt or waiting on a human, the second-opinion relay refuses shell panes, and
  the handoff launcher never kills a tmux server, session, window or pane.
- Report a vulnerability as [SECURITY.md](SECURITY.md) describes.

## The rest of the stack

These are their own repositories:

- [Drover](https://github.com/coletebou/drover): the control plane for a fleet of coding agents.
  cc-park and cc-handoff use it when it is there (session state, messages between sessions).
- [badland-brain](https://github.com/coletebou/badland-brain): one shared, self-hosted memory for
  Claude Code, Codex, ChatGPT and any MCP client.
- [porchlight](https://github.com/coletebou/porchlight): a fleet-aware login dashboard for the terminal.
- [imsg](https://github.com/coletebou/imsg): Messages.app from the command line, for agents.
- [ai-keys](https://github.com/coletebou/ai-keys): API keys across AI providers from one CLI.
- [grok-bot-backup](https://github.com/coletebou/grok-bot-backup): a Grok Bot backed up to git.

Other people's skills this setup uses are linked, not copied; [NOTICE.md](NOTICE.md) lists them
and credits the designs some tools here follow.

## License

[MIT](LICENSE). Contributions are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md).
