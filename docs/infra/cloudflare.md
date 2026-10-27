# Cloudflare in front of self-hosted services (optional)

Nothing in this repo needs Cloudflare. This page is how this setup puts public names on services
that run on its own machines without opening a port on any of them: the box dials out to
Cloudflare through a Tunnel, Access decides who may reach the private names, and the zone's DNS,
WAF and rate limits live as reviewed config in a private repo. Every name, id and number below is
a placeholder.

| Piece | Job | Source of truth |
|---|---|---|
| **Tunnel** (`cloudflared`) | carries traffic from Cloudflare's edge to `127.0.0.1` ports on the box; no inbound port | `/etc/cloudflared/config.yml` on the box |
| **Access** | a login (or a service token) in front of a hostname, before any request reaches the box | an Access application plus its policies |
| **DNS** | each public name, proxied (through Cloudflare) or DNS-only | a zone file exported to a private repo |
| **WAF custom rules, rate limits** | block probes and abuse at the edge | ruleset JSON in a private repo |
| **Zone settings** | TLS mode, HTTPS redirects, HSTS, bot features | a settings table in the same repo |

## `cf` or Wrangler

| Task | Tool |
|---|---|
| DNS records, zones, Tunnels, Access, D1, KV, R2, rulesets | Cloudflare's `cf` CLI ([cloudflare/cf](https://github.com/cloudflare/cf), beta, `npm install -g cf`) |
| A new Worker | `cf` (`cf dev`, `cf build`, `cf deploy`) |
| A project that has a `wrangler.jsonc`, `wrangler.json` or `wrangler.toml` and no `cloudflare.config.ts` | that project's own Wrangler scripts for dev, build and deploy: `cf dev` and `cf deploy` can ignore the Wrangler file. `cf` resource commands are still fine there |
| Live Worker logs, Worker secrets | `npx wrangler tail`, `npx wrangler secret put <NAME>`, until `cf` supports them |

`cf` finds its own commands: `cf cli search "<what you want to do>"` returns the matching
commands, `<command> --help` their flags, and `cf schema <command>` the API request behind each.
Most commands that change something take `--dry-run`, and ruleset updates take
`--validate-only`.

**Credentials.** Sign in once per machine with `cf auth login --no-browser` (check with
`cf auth whoami`); `cf auth activate <profile> <dir>` binds another account's profile to one
project directory. Scripts and Wrangler read a scoped API token (`CLOUDFLARE_API_TOKEN`) from
`~/.env_secrets`, never from a command line or a committed file. Give each token only the
permissions its job needs (DNS edit on one zone, Tunnel edit, Access edit); an account-wide global
key can do everything to every zone, so keep it out of scripts entirely.

## Tunnels

One tunnel per box, locally managed (the config file on the box is the source of truth), running
as a system service:

```bash
cloudflared tunnel login                           # once: authorizes this machine for a zone
cloudflared tunnel create box-a                    # writes ~/.cloudflared/<TUNNEL-UUID>.json
sudo install -d -m 700 /etc/cloudflared
sudo install -m 600 ~/.cloudflared/<TUNNEL-UUID>.json /etc/cloudflared/
sudoedit /etc/cloudflared/config.yml               # the template below
sudo cloudflared --config /etc/cloudflared/config.yml service install
cloudflared tunnel route dns box-a api.example.com # a proxied CNAME to <TUNNEL-UUID>.cfargotunnel.com
```

```yaml
# /etc/cloudflared/config.yml
tunnel: <TUNNEL-UUID>
credentials-file: /etc/cloudflared/<TUNNEL-UUID>.json

ingress:
  # One rule per public name, first match wins. Targets are loopback ports (vps.md, Port map).
  - hostname: api.example.com
    service: http://127.0.0.1:3100

  # A private name: the tunnel itself refuses a request without a valid Access token, so a
  # deleted Access app or a DNS slip cannot expose it.
  - hostname: staging.example.com
    service: http://127.0.0.1:3101
    originRequest:
      access:
        required: true
        teamName: <your-team>
        audTag:
          - <ACCESS-APP-AUD-TAG>

  # Everything else on the zone goes to nginx, which dispatches by Host (vps.md, nginx).
  - hostname: "*.example.com"
    service: http://127.0.0.1:80

  # Required last rule: anything that matched nothing.
  - service: http_status:404
```

Changing the ingress, every time:

1. Copy the file first: `sudo cp -p config.yml config.yml.bak-$(date -u +%Y%m%dT%H%M%SZ)-<reason>`.
2. Add the rule above the catch-all, and keep every other rule as it was.
3. Validate the file and the rule a URL will hit:
   `cloudflared tunnel --config /etc/cloudflared/config.yml ingress validate`, then
   `cloudflared tunnel --config /etc/cloudflared/config.yml ingress rule https://new.example.com/`.
4. Create the DNS record (`cloudflared tunnel route dns`, or `cf dns records create`).
5. `sudo systemctl restart cloudflared`, once: a locally managed tunnel does not reload ingress.
6. Verify from outside: `curl -sSI https://new.example.com/`, plus one old name, to prove
   nothing else moved.
7. Record the change (date, name, target, backup file) in the private repo's change log.

Updates: install `cloudflared` from Cloudflare's package repository so normal upgrades cover it.
A binary install needs its own update timer; `cloudflared update` exits 11 when it replaced
itself, which is the signal to restart the service:

```ini
# /etc/systemd/system/cloudflared-update.service (run daily by a matching .timer)
[Service]
Type=oneshot
ExecStart=/bin/bash -c '/usr/bin/cloudflared update; rc=$?; if [ "$rc" -eq 11 ]; then systemctl restart cloudflared; exit 0; fi; exit "$rc"'
```

## Access in front of self-hosted services

Put every name that is not meant for the public (staging, admin panels, web terminals, dashboards)
behind an Access application. A reusable policy, then the application that uses it:

```bash
cf zero-trust access policies create --body '{
  "name": "owners",
  "decision": "allow",
  "include": [{"email": {"email": "you@example.com"}}],
  "session_duration": "24h"
}'
cf zero-trust access applications create --body '{
  "name": "staging",
  "type": "self_hosted",
  "domain": "staging.example.com",
  "session_duration": "24h",
  "policies": [{"id": "<POLICY-ID>", "precedence": 1}]
}'
```

- **One application per hostname**, one policy per audience: `owners`, a named collaborator, a
  service token. Name people one by one (`email`), or a whole domain you control (`email_domain`).
- **Machines get service tokens**, not shared logins: a policy with `"decision": "non_identity"`
  and `{"service_token": {"token_id": "<TOKEN-ID>"}}`, and the client sends the
  `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers.
- **Enforce it at the tunnel too** (`originRequest.access` above): Access at the edge plus the
  tunnel's check means a mistake in one layer still leaves the other.
- **A web terminal is a shell.** Gate it with its own application and a short session, never with
  the policy of a dashboard next to it.
- **Webhooks from a provider** cannot log in. Give them their own public path, check the provider's
  signature in the app, and if the managed WAF flags their payloads, skip it for that path and
  user agent only (WAF rules below).

## DNS as config

The zone's records are configuration: export them into the private repo, review changes as diffs,
and reconcile the file with the live zone whenever you touch it.

```bash
cf dns records export -z example.com > dns/example.com.zone       # the reviewed copy
cf dns records create -z example.com --dry-run --body '{
  "type": "CNAME", "name": "new.example.com",
  "content": "<TUNNEL-UUID>.cfargotunnel.com", "proxied": true, "ttl": 1
}'
```

```dns
;; example.com, reconciled YYYY-MM-DD against the live zone. TTL 1 = automatic.
;; Tunnel names (proxied).
api.example.com.        1  IN  CNAME  <TUNNEL-UUID>.cfargotunnel.com. ; proxied
staging.example.com.    1  IN  CNAME  <TUNNEL-UUID>.cfargotunnel.com. ; proxied, Access
*.example.com.          1  IN  CNAME  <TUNNEL-UUID>.cfargotunnel.com. ; proxied, nginx by Host
;; A frontend host that issues its own certificates (DNS-only).
www.example.com.      300  IN  CNAME  frontend-host.example.net.
;; Mail.
example.com.            1  IN  MX     10 mail-provider.example.net.
example.com.            1  IN  TXT    "v=spf1 include:mail-provider.example.net -all"
_dmarc.example.com.     1  IN  TXT    "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com"
```

A domain that sends no mail at all should say so, or anyone can send as it:

```dns
example.org.         1  IN  MX   0 .
example.org.         1  IN  TXT  "v=spf1 -all"
_dmarc.example.org.  1  IN  TXT  "v=DMARC1; p=reject; sp=reject"
```

| Proxied (through Cloudflare) | DNS-only |
|---|---|
| everything behind a tunnel; anything that should get the WAF, rate limits and HTTPS redirects | hosts that issue their own certificates or run their own CDN; mail records; records a provider requires DNS-only |

DNS gotchas:

- **An explicit record beats the wildcard.** With `*.example.com` pointed at the tunnel, a new name
  needs only an nginx `server_name`. An A record added for it "to be safe" sends it around the
  tunnel to an origin that is not listening publicly, and it fails.
- **A record pointing at a deleted tunnel** answers HTTP 530 (error 1033), and a wildcard pointing
  at one breaks every name under it. Delete the records when you delete a tunnel.
- **A redirect rule only runs for a proxied name.** Keep a proxied record for an old name you
  redirect, even though nothing serves it.
- **Retiring a domain:** remove its hostnames from the tunnel ingress and delete its records in
  the same change. Nothing you no longer control should still route into your services.
- **Native apps may not follow redirects.** When you move an API to a new canonical name, keep the
  old API path serving directly until the shipped clients are gone.

## WAF custom rules

Up to five custom rules on the Free plan, more on paid plans. A starting set (rules run in order,
so skips go first):

| # | Rule | Action | Expression |
|---|---|---|---|
| 1 | A provider's webhook skips the managed rules | skip (phase `http_request_firewall_managed`) | `starts_with(http.request.uri.path, "/webhooks/provider") and http.user_agent contains "ProviderHookshot"` |
| 2 | Probes for secrets and admin kits | block | `(http.request.uri.path contains "/.env") or (http.request.uri.path contains "/.git/") or starts_with(http.request.uri.path, "/wp-") or (http.request.uri.path contains "/xmlrpc.php") or (http.request.uri.path contains "/phpmyadmin")` |
| 3 | Scanners by user agent | block | `(lower(http.user_agent) contains "sqlmap") or (lower(http.user_agent) contains "nikto") or (lower(http.user_agent) contains "masscan") or (lower(http.user_agent) contains "nmap")` |
| 4 | An empty user agent on the API | block | `starts_with(http.request.uri.path, "/api/") and http.user_agent eq ""` |
| 5 | Signups from hosting networks | managed_challenge | `http.request.method eq "POST" and starts_with(http.request.uri.path, "/api/signup") and ip.src.asnum in {64496 64497 64498}` |

Others worth a slot: a block on search crawlers for non-production names
(`cf.verified_bot_category eq "Search Engine Crawler" and http.host in {"staging.example.com"}`),
or a challenge for one expensive endpoint from countries you do not serve
(`ip.src.country in {"XA" "XB"}`). The ASNs and country codes above are documentation values:
fill in your own.

As config, the whole phase is one JSON file:

```json
{
  "rules": [
    {
      "description": "Webhook from the provider skips managed rules",
      "expression": "starts_with(http.request.uri.path, \"/webhooks/provider\") and http.user_agent contains \"ProviderHookshot\"",
      "action": "skip",
      "action_parameters": {"phases": ["http_request_firewall_managed"]}
    },
    {
      "description": "Block probes for secrets and admin kits",
      "expression": "(http.request.uri.path contains \"/.env\") or (http.request.uri.path contains \"/.git/\") or starts_with(http.request.uri.path, \"/wp-\")",
      "action": "block"
    }
  ]
}
```

```bash
cf rulesets entrypoint get http_request_firewall_custom -z example.com > waf/live.json   # what is there now
cf rulesets entrypoint update http_request_firewall_custom -z example.com \
  --body "$(cat waf/custom.json)" --validate-only                                       # then without --validate-only
```

An update replaces the phase's whole rule list, so diff your file against the live export first:
a rule someone added in the dashboard and not in the repo is gone after the update.

A skip rule skips what its `action_parameters` names. `"ruleset": "current"` skips only the
custom rules after it, not the managed rules; to keep the managed WAF off a webhook's payloads,
name the managed phase as in rule 1.

## Rate limits

The lower plans allow one or two rate-limit rules, and the Free plan fixes the period and the
block at 10 seconds; check your plan before designing around more. Spend them on what an attacker
would hammer, and put finer limits in the app.

```json
{
  "rules": [
    {
      "description": "Auth endpoints, except the OAuth callbacks providers post to",
      "expression": "starts_with(http.request.uri.path, \"/api/auth/\") and not (http.request.uri.path in {\"/api/auth/google/callback\" \"/api/auth/apple/callback\"})",
      "action": "block",
      "ratelimit": {
        "characteristics": ["ip.src", "cf.colo.id"],
        "period": 60,
        "requests_per_period": 30,
        "mitigation_timeout": 300
      }
    },
    {
      "description": "Login attempts that use a known leaked password",
      "expression": "cf.waf.credential_check.password_leaked",
      "action": "block",
      "ratelimit": {
        "characteristics": ["ip.src", "cf.colo.id"],
        "period": 10,
        "requests_per_period": 5,
        "mitigation_timeout": 3600
      }
    }
  ]
}
```

Apply it to the `http_ratelimit` phase the same way as the WAF file. Exempt every callback a
provider posts to; a limit that blocks the sign-in provider's callback looks like a broken login.

## Zone settings baseline

| Setting | Value | Why |
|---|---|---|
| SSL/TLS mode | Full (strict) | the edge checks the origin's certificate; a tunnel needs no origin certificate |
| Minimum TLS version | 1.2 | |
| TLS 1.3 | on | |
| Always Use HTTPS | on | |
| HSTS | on, with subdomains, after every name serves HTTPS | turn on preload only if that will stay true: leaving a browser preload list takes months |
| Bot Fight Mode | off on a zone whose API serves scripts or agents | it challenges every automated client zone-wide on Free |
| Browser Integrity Check | on, then test your own clients | it rejects some scripting user agents (error 1010) |
| Noindex for non-production names | a response header transform: `X-Robots-Tag: noindex, nofollow` | staging and preview names stay out of search |
| `security.txt` | served by the app at `/.well-known/security.txt` | a contact for whoever finds a hole |

After turning on any bot or security feature, run the clients you own through the edge (`curl`,
your mobile app, an agent's HTTP client) before calling it done.

## Gotchas

- **A published container port bypasses the edge.** Docker writes its own firewall rules ahead of
  UFW's, so `ports: ["3100:3100"]` answers on the public address no matter what UFW says. Publish
  as `127.0.0.1:3100:3100` ([vps.md](vps.md), SSH and the firewall).
- **The docs drift from the dashboard.** Reconcile the private repo against the live zone (DNS
  export, ruleset exports, settings) whenever you change something, and write the date at the top.
  A rule the docs list but the zone lacks protects nothing.
- **Plan limits move.** Rule counts, rate-limit periods and bot features differ by plan and change
  over time; read the current numbers before building around them.

## See also

- [vps.md](vps.md): the box behind the tunnel (loopback ports, nginx, the port map).
- [tailscale.md](tailscale.md): private access between your own machines.
- [aws.md](aws.md): Claude Code on Amazon Bedrock.
