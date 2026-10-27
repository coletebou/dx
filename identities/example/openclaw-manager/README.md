# openclaw-manager: an example overlay for Drover's fleet manager

[Drover](https://github.com/coletebou/drover) can run a fleet manager: an OpenClaw gateway on loopback that sweeps
your hosts every few minutes, drives stopped agent sessions forward, pins what waits on you, and writes a daily
digest. `drover manager setup` installs it from `web/openclaw-manager/` in the Drover checkout, plus an optional
**overlay**: a directory laid out the same way whose files are used first. The overlay is where one fleet's own
settings live: which endpoints and secret sources the gateway uses, what the manager is told about you, and any
change to its standing orders.

This directory is a working overlay for the example identity. It travels with the identity: copy
`identities/example` to `identities/<you>`, edit the files below, and `./install.sh --identity <you> --with manager`
points Drover at `identities/<you>/openclaw-manager`.

| File | What it is |
|---|---|
| `profiles/mine.json` | The profile: the gateway's port, the config template and its values (`OTEL_ENDPOINT`, `CLIPROXY_API_KEY`), where each secret comes from, extra environment, the egress allowlist `drover manager check` holds the config to, and the `github` flag the orders read. A copy of Drover's `profiles/default.json` with the flag turned on. |
| `roles/manager/role.json` | The role: its default profile (`mine`, so setup needs no `--profile`), the heartbeat prompt, the sweep's thinking level, and the `digest` duty with its `fleet-digest` automation. Everything but `profile` matches Drover's own `role.json`; the automation's `model` must name a model row of the config template, and this is the row Drover's role uses. |
| `roles/manager/AGENTS.md` | The standing orders: Drover's, plus a pull-request watch through `gh` when the profile sets `github` (Program 1 step 6 and the digest), instead of a forge tool from a plugin. |
| `roles/manager/MEMORY.md` | The seed of the manager's long-term memory: empty. |
| `workspace/SOUL.md` | The manager's voice. |
| `workspace/USER.md` | What the manager knows about you before its first sweep: a fill-in template. |
| `env.example` | The secret names `~/.openclaw-manager/.env` gets from this profile, and where each comes from. Documentation only; nothing reads it. |

## How Drover finds the overlay

Read from Drover's `web/core/openclaw-install.js` and `web/core/env.js`. The first of these that names one wins:

1. `drover manager setup --overlay DIR` (or `--overlay none`).
2. `DROVER_OPENCLAW_OVERLAY`, from the environment or from a `KEY=value` line in `~/.config/drover/*.env`. Every
   `drover` command loads those files first, in name order, and a name already set (in the environment or by an
   earlier file) is not overwritten. `DROVER_CONFIG_DIR` moves the directory.
3. The `overlay` the last setup recorded in `~/.openclaw-manager/drover-install.json`, so later runs,
   `drover manager status`, `drover manager check` and the daemon read the same files without the variable.

A leading `~/` is your home. A relative path resolves against the directory you run `drover` in, so name the
overlay with `~/` or an absolute path. An empty value or `none` means no overlay. A named overlay that is not a
directory fails setup before anything is read.

`./install.sh --with manager` writes `~/.config/drover/dx-openclaw-manager.env` (or under `DROVER_CONFIG_DIR`)
with one line, `DROVER_OPENCLAW_OVERLAY=~/.dotfiles/identities/<identity>/openclaw-manager`. It is not part of
`--all`. Files load in name order and the first to set a name wins, so a `00-*.env` of your own overrides it.

## What the overlay can supply

For each of these, setup uses the overlay's file when it has one, else Drover's; each file stands on its own, so an
overlay can replace the orders and keep Drover's `role.json`, or the reverse. A profile or role only the overlay
has is added.

| Path | Read | Notes |
|---|---|---|
| `profiles/<p>.json` | every run | The profile chosen at the first install is kept in the manifest; `--profile` changes it. |
| the config template a profile names (`openclaw.json` unless `config` says otherwise) | every run | This overlay keeps Drover's. |
| `roles/<r>/role.json` | every run | Must have `profile` and `heartbeatPrompt`. |
| `roles/<r>/AGENTS.md` | every run | Rendered into `~/.openclaw-manager/workspace/AGENTS.md` each time. |
| `roles/<r>/MEMORY.md`, `workspace/IDENTITY.md` | first install only | Seeds: written only when the workspace has no such file. |
| `workspace/<profile>/SOUL.md` or `USER.md`, else `workspace/SOUL.md` or `USER.md` | first install only | A profile can carry its own seeds; this overlay's apply to every profile. |

The lockfile and patches, `bin/`, `exec-approvals.json` and the systemd unit always come from Drover. Each setup run
names the files the overlay supplied in its `overlay` step.

The role files and seeds are templates. Setup fills `{{ACTOR}}`, `{{HOST}}`, `{{SCOPE}}`, `{{SCOPE_SHORT}}`,
`{{HOME}}`, `{{OWNER}}`, `{{OWNER_NAME}}` and `{{DROVER_REPO}}`, and keeps a `{{#name}}...{{/name}}` section when
`name` is on (`{{^name}}...{{/name}}` when it is off), for `local` and `all` (the scope), each duty (`digest`) and
each of the profile's flags. A `{{NAME}}` it does not know fails the run. `DROVER_OWNER` and `DROVER_OWNER_NAME`
(in `~/.config/drover/*.env`) say who the owner is; unset, the orders say "the owner".

## Make it yours

1. **The profile.** Rename `profiles/mine.json` if you like (and the `profile` in `role.json`), then change what
   differs on your machines: `port` when another OpenClaw already holds 18789; `vars.OTEL_ENDPOINT` for your
   Langfuse (or drop the optional `OTEL_EXPORTER_OTLP_HEADERS` secret); each secret's `from` (a file holding a
   `NAME=value` line); and `egress.allow`, which must list every host the config's endpoints name, or
   `drover manager check` reports them. The allowlist checks the gateway's configured endpoints, not what the
   manager's shell reaches. Set `flags.github` to `false` if your merge requests live in a forge a Drover plugin
   serves.
2. **`workspace/USER.md`.** Fill in the template before the first install: it is copied once, and the manager keeps
   its own copy afterwards (edit `~/.openclaw-manager/workspace/USER.md` from then on).
3. **The orders.** `roles/manager/AGENTS.md` replaces Drover's whole file and does not follow Drover's later
   changes. After updating Drover, compare it with Drover's `web/openclaw-manager/roles/manager/AGENTS.md`, or delete
   it here to run Drover's own orders (the `gh` pull-request watch goes with it).
4. **Check, then install.** `drover manager profiles` and `drover manager roles` mark what comes from the overlay;
   `drover manager setup --scope local --dry-run` shows the whole plan and changes nothing. Then
   `drover manager setup --scope local` on a machine that covers only itself, or
   `drover manager setup --scope all --exclude <laptop> --digest --actor manager` on the always-on box that covers the
   rest and owns the digest.

The manager needs a Drover checkout with `~/.local/bin/drover` linked to its `web/bin/drover`, a Node in
OpenClaw's range (24.16 or newer) installed through fnm or passed with `--node`, the profile's secrets in
`~/.env_secrets`, and for the `github` flag a `gh auth login` on the machine it runs on. Drover's `web/openclaw-manager/README.md` covers the rest: what setup installs, the scopes,
the models, `drover manager status` and `check`.

What you write in `USER.md` is as public as the repository it is in. If your fork is public, keep your real overlay
in a private repository and name it with `DROVER_OPENCLAW_OVERLAY` in a `00-*.env` of your own, or with `--overlay`.
