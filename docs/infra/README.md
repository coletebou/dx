# Infrastructure playbooks

All optional: nothing in this repo needs any of them. Each page is how this setup does it, with
templates that use placeholder values only.

| Page | Covers |
|---|---|
| [tailscale.md](tailscale.md) | a personal fleet over a tailnet: joining machines, the policy file, Tailscale SSH or OpenSSH, `~/.ssh/config` |
| [cloudflare.md](cloudflare.md) | Tunnels, Access, DNS as config, WAF and rate-limit rules, when to use `cf` or Wrangler |
| [vps.md](vps.md) | a production box: bootstrap, SSH and UFW, systemd services and alerts, the port map, nginx, offsite backups |
| [aws.md](aws.md) | Claude Code on Amazon Bedrock |

The first three fit together: your machines reach each other over the tailnet, the public reaches
the server only through a tunnel, and the server binds every service to loopback.
