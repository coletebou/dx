# A personal fleet over Tailscale (optional)

Nothing in this repo needs Tailscale. Every tool that reaches another machine takes an **ssh
alias**, and Tailscale is one good way to make every alias resolve and connect: a workstation, a
laptop, a build box and a production server on one private network, each reachable by name from
the others, with no port open to the internet. This page is how this setup runs one, with
templates that use placeholder names only.

| Piece | What it gives you | Where it lives |
|---|---|---|
| **The tailnet** | a private address (100.x.y.z) per machine, reachable from every other machine on it | the Tailscale client on each machine |
| **MagicDNS** | a short name per machine (`box-a`), plus a full name under your tailnet's DNS domain | the admin console's DNS page |
| **The policy file** | who may reach what: groups of people, tags for machines, network and ssh rules, tests | the admin console, or the API from a private repo |
| **`~/.ssh/config`** | one alias per machine, the names scripts call | your dotfiles (private), or `~/.ssh/config.local` |

## How this repo uses the fleet

| Tool | What it needs |
|---|---|
| `cc-handoff launch --host <alias>` | an alias that logs in with no prompt: every remote call runs ssh with `BatchMode=yes` ([handoff chains](../handoff.md), Another host) |
| `pw status` on a peer | `ssh <host> ~/.local/bin/pw status <session>` ([parallel-worktrees](../../plugins/worktrees/skills/parallel-worktrees/SKILL.md)) |
| tmux `prefix + c` | in a pane running ssh, the new window opens on the same host (`base/tmux-ssh-inherit.sh`) |
| `identities/<you>/hosts` | short labels for the status bar and statusline: names only, never addresses |
| `zshenv` | raises the open-file soft limit for every zsh, including the ones sshd starts (`CODEX_FD_SOFT_LIMIT`, default 10240); a tmux server started before keeps its old limit |
| `base/zshrc` | an ssh wrapper that switches mouse and paste modes back off when a session dies inside remote tmux |

`BatchMode=yes` is the constraint that shapes the rest: whatever a script reaches must accept a
key without asking anything. That rules out a password, a passphrase without an agent, and a
Tailscale SSH rule in `check` mode (it asks for a browser login).

## Joining a machine

Mint an auth key in the admin console (Settings, Keys) with the machine's tag already on it,
**pre-approved** if device approval is on, **reusable** only if you will join several machines with
it, **ephemeral** for CI runners and containers (the node is removed once it goes offline). Then,
on the machine:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo install -m 600 /dev/null /etc/tailscale-authkey
sudoedit /etc/tailscale-authkey                           # paste the key, save
sudo tailscale up --auth-key=file:/etc/tailscale-authkey --advertise-tags=tag:server \
  --hostname=box-a
sudo rm /etc/tailscale-authkey
tailscale status --json | jq '.Self.Tags'                 # must print ["tag:server"]
```

`--auth-key=file:` keeps the key out of `ps` and your shell history. Check the tag right after
joining, not later: a `tailscale up` that was interrupted (a dropped ssh session, a mangled
terminal) can leave the machine authorized but untagged, and a policy that grants by tag then
drops every connection to it with nothing but "access revoked" on the client side. Fix that from
the admin console (Machines, Edit ACL tags) or the API (`POST /api/v2/device/<id>/tags` with
`{"tags": ["tag:server"]}`); the machine needs no restart.

**Key expiry.** Node keys expire (180 days unless you shorten it), and a server whose key
expires drops off the tailnet until someone logs it in again. Disable key expiry for every server
(Machines, the machine's menu). Tagging usually does this for you; confirm it on the Machines page.

**Machines that must never join.** Some machines belong to someone else's network (an employer's
laptop, a client's cloud account) and must stay off a personal tailnet. If an installer of yours
turns Tailscale on, have it decide from local evidence and refuse when it cannot tell: an
unanswered metadata check is a "no", not a "probably fine".

## The policy file

The policy is HuJSON (JSON with comments and trailing commas). Keep it in a private repo, and
apply it with the API (`POST /api/v2/tailnet/-/acl/validate`, then `POST /api/v2/tailnet/-/acl`)
or Tailscale's GitOps action, so every change is a reviewed diff. A template:

```hujson
// Tailnet policy. Every user, tag and port below is a placeholder.
{
  // People, by the login your identity provider gives them.
  "groups": {
    "group:admins": ["you@example.com"],
    "group:collab": ["friend@example.com"],
  },

  // Who may put each tag on a machine. A tagged machine belongs to its tag, not to a person.
  "tagOwners": {
    "tag:server": ["group:admins"],   // production and always-on boxes
    "tag:dev":    ["group:admins"],   // build boxes and agent hosts
    "tag:ci":     ["group:admins"],   // runners that deploy
  },

  // Network rules: nothing flows unless a grant allows it.
  "grants": [
    // You reach everything you own.
    {"src": ["group:admins"], "dst": ["*"], "ip": ["*"]},
    // Dev boxes reach servers for ssh and the services they call.
    {"src": ["tag:dev"], "dst": ["tag:server"], "ip": ["tcp:22", "tcp:8443"]},
    // CI reaches servers over ssh only.
    {"src": ["tag:ci"], "dst": ["tag:server"], "ip": ["tcp:22"]},
    // Servers call each other on one service port.
    {"src": ["tag:server"], "dst": ["tag:server"], "ip": ["tcp:8443"]},
    // A collaborator reaches one web terminal and nothing else.
    {"src": ["group:collab"], "dst": ["tag:dev"], "ip": ["tcp:7681"]},
  ],

  // Tailscale SSH rules, for machines started with `tailscale up --ssh`. Separate from the
  // grants: a network grant on port 22 does not let Tailscale SSH in, and an ssh rule does not
  // open the port.
  "ssh": [
    // Your own untagged devices, with a periodic browser check.
    {"action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"],
     "users": ["autogroup:nonroot", "root"]},
    // You to tagged machines, no prompt.
    {"action": "accept", "src": ["group:admins"], "dst": ["tag:server", "tag:dev"],
     "users": ["autogroup:nonroot", "deploy"]},
    // A tagged machine that deploys to another needs its own tag-to-tag rule.
    {"action": "accept", "src": ["tag:ci"], "dst": ["tag:server"], "users": ["deploy"]},
  ],

  // Run on every save; a failing test rejects the change.
  "tests": [
    {"src": "you@example.com", "accept": ["tag:server:22", "tag:dev:7681"]},
    {"src": "tag:ci", "accept": ["tag:server:22"], "deny": ["tag:server:8443"]},
    {"src": "friend@example.com", "accept": ["tag:dev:7681"], "deny": ["tag:server:22"]},
  ],
  "sshTests": [
    {"src": "you@example.com", "dst": ["tag:server"], "accept": ["deploy"]},
    {"src": "tag:ci", "dst": ["tag:server"], "accept": ["deploy"], "deny": ["root"]},
  ],
}
```

Rules that kept this tailnet working:

- **Don't tag the machines you type on.** Once a machine carries a tag, traffic from it matches
  tag rules only, not your user or group. Tag a laptop you administer from and its ssh to every
  server stops at "tailnet policy does not permit you to SSH to this node".
- **`tests` checks network rules; `sshTests` checks ssh rules.** Write both, and still run one real
  `ssh <alias> true` from each kind of machine after changing tags or ssh rules.
- **Grant by tag, never by address.** An address changes when a machine is re-created; a tag
  follows the machine you meant.
- **Name collaborators' access narrowly.** One group, one tag, one port, and a deny test that
  proves the rest stays closed.

## Tailscale SSH or plain OpenSSH

| | Tailscale SSH (`tailscale up --ssh`) | OpenSSH over the tailnet |
|---|---|---|
| Who may log in | the policy's `ssh` rules, by tailnet identity | `authorized_keys` on the machine |
| Keys to manage | none | yours, on every machine |
| Scripts (`BatchMode=yes`) | only with `accept` rules; `check` waits for a browser | yes |
| When the tailnet is down | unavailable | reachable through a public jump host, if you keep one |
| Session recording, central revocation | yes | no |

**Pick one per port.** `tailscale up --ssh` makes tailscaled answer every tailnet connection to
port 22 itself, so an sshd behind `tailscale0` never sees them: keys, `IdentityFile` and
`authorized_keys` stop mattering there, and only the policy's `ssh` rules let anyone in (a caller
with a port-22 grant but no `ssh` rule is refused). This setup uses **OpenSSH with keys for
everything a script drives** (handoffs, deploys, syncs), with sshd reachable only on `tailscale0`
([vps.md](vps.md), SSH and the firewall), and leaves Tailscale SSH off on those machines. To keep
Tailscale SSH as a fallback on one of them, give sshd a port of its own first (`Port 2222` in
sshd_config, `tcp:2222` in the grants and `Port 2222` in the key alias). For collaborators,
Tailscale SSH is the better default: there is no key to hand out or take back.

## `~/.ssh/config`

One alias per machine, named for what scripts call it, pointing at a MagicDNS name rather than an
address. This file lists your fleet, so keep it private: in your identity's dotfiles or in
`~/.ssh/config.local`, never in a public fork.

```sshconfig
# macOS-only options, skipped elsewhere instead of failing.
IgnoreUnknown UseKeychain,AddKeysToAgent

# Per-machine overrides that are never committed. ssh keeps the FIRST value it finds for each
# option, so a file included first wins over everything below.
Include ~/.ssh/config.local

# When box-a's tailnet name does not answer (Tailscale down, a network that blocks it), go
# through the public jump host instead. Auth is still your key against box-a itself.
Match originalhost box-a !exec "nc -z -w 2 %h 22"
  ProxyJump jump-public

Host box-a
  HostName box-a                      # MagicDNS short name (or the full name)
  User deploy
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new    # a new host is added silently; a changed key still fails

# The same machine through Tailscale SSH, if it runs `tailscale up --ssh` (its OpenSSH then
# needs a port of its own: see above). No key, so no IdentitiesOnly here (with it, a key file
# this machine lacks makes ssh give up before Tailscale SSH can answer).
Host box-a-ts
  HostName box-a
  User deploy

# A key-only public listener on one always-on machine that is also on the tailnet (it
# resolves box-a for you). Port 443 gets through most networks that block 22.
Host jump-public
  HostName 203.0.113.10
  Port 443
  User jump
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes

# An alias for a deploy key, not a machine: Match keeps it out of editors that list Host blocks.
Match host github-deploy
  HostName github.com
  User git
  IdentityFile ~/.ssh/id_deploy
  IdentitiesOnly yes
```

Gotchas:

- **First value wins, for every option.** A hand-written `Host box-a` block above a block a tool
  generates (between `# BEGIN managed` / `# END managed` markers, say) silently masks the
  generated `HostName`. Keep one owner per host: the generator or you.
- **Several `IdentityFile` lines are tried in order, and a missing file is skipped.** That lets
  one alias work from a laptop (a fleet key) and from a server (its own key).
- **Use names, not addresses.** An address in a config outlives the machine it belonged to; a
  name follows the machine.
- **A tagged node that also runs your interactive shell** loses your user's ssh rights (see the
  policy rules above); the error names the policy, not the key.

## Exposing a service

- **To the tailnet only:** bind the service to `127.0.0.1` and run `tailscale serve --bg 3100`,
  which proxies `https://box-a.<tailnet-dns-name>/` to it with a certificate Tailscale issues (turn
  HTTPS certificates on in the admin console first). No firewall change, nothing public.
- **To a service another tailnet machine calls directly:** bind the tailnet address (or
  `0.0.0.0` with the firewall allowing only `tailscale0`), and grant the caller's tag that one
  port in the policy.
- **To the internet:** a Cloudflare Tunnel, not a port opened on the box ([cloudflare.md](cloudflare.md)).

Before rebinding anything, find who calls it: a service you move to `127.0.0.1` because "only the
tunnel uses it" breaks the other machine that called it over the tailnet.

## See also

- [vps.md](vps.md): a production box, with sshd and UFW limited to the tailnet.
- [cloudflare.md](cloudflare.md): public names for services that stay closed to the internet.
- [aws.md](aws.md): Claude Code on Amazon Bedrock.
