# A production box on a VPS (optional)

Nothing in this repo needs a server. This page is how this setup runs one: a single VPS (Hetzner
or any provider) that serves several small apps, reachable for administration only over the
tailnet and for the public only through a Cloudflare Tunnel. Every name, address, port and path
below is a placeholder; the shape is what carries over.

| Layer | The rule here |
|---|---|
| Accounts | no root login; an `admin` user with full sudo, a `deploy` user with one sudo rule, one system account per app |
| SSH and the firewall | keys only, sshd reachable on the tailnet only, everything else denied |
| Services | systemd system units with a restart policy, a start limit and a failure alert |
| Ports | one table says which local port is which service; services bind `127.0.0.1` |
| nginx | one server block per public name, on loopback, behind the tunnel |
| Backups | daily, consistent dumps, one verified archive offsite, a restore drill on a schedule |
| The inventory | a private doc with all of the above, updated in the same change as the box |

This repo's own scheduled jobs are systemd *user* units (`systemd/user/`, installed by
`install.sh --with schedules`); the production patterns below are *system* units.

## Bootstrap

From the provider's console or the first root login:

```bash
apt-get update && apt-get -y upgrade
apt-get -y install unattended-upgrades ufw nginx jq sqlite3 restic
dpkg-reconfigure -f noninteractive unattended-upgrades
timedatectl set-timezone UTC

adduser --disabled-password --gecos "" admin
usermod -aG sudo admin && passwd admin       # sudo asks for this password; ssh never does
adduser --disabled-password --gecos "" deploy
usermod -aG systemd-journal deploy           # read logs without sudo
for u in admin deploy; do
  h="$(getent passwd "$u" | cut -d: -f6)"
  install -d -m 700 -o "$u" -g "$u" "$h/.ssh"
  install -m 600 -o "$u" -g "$u" ~root/.ssh/authorized_keys "$h/.ssh/authorized_keys"
done
visudo -f /etc/sudoers.d/deploy              # the one rule below, nothing broader
```

```text
deploy ALL=(root) NOPASSWD: /usr/bin/systemctl restart app.service
```

Grant exact commands with exact arguments, and nothing that can open a pager, an editor or a
script (`less`, `vi`, an interpreter): each of those can start a root shell, which turns a narrow
rule into full root. The journal group covers reading logs.

Then join the tailnet ([tailscale.md](tailscale.md), Joining a machine) and confirm
`ssh box-a true` works over it from another machine before you touch sshd or the firewall.

## SSH and the firewall

```text
# /etc/ssh/sshd_config.d/00-hardening.conf
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
AllowUsers deploy admin
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
```

```bash
sudo sshd -t                                          # syntax
sudo sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|allowusers'   # what sshd will use
sudo systemctl reload ssh
```

- **sshd keeps the first value it reads.** Ubuntu's `sshd_config` includes `sshd_config.d/*.conf`
  at the top, in name order, and cloud images ship a `50-cloud-init.conf` that can turn password
  login back on. A `00-` file is read first and wins; check `sshd -T`, not the file.
- **Keep a second session open** while you change sshd or the firewall, and test a fresh login
  before closing it. The provider's console is the last way back in.
- **Limit sshd with the firewall, not `ListenAddress`.** A tailnet address in `ListenAddress` is
  not there yet when sshd starts at boot, and sshd then listens nowhere.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow in on tailscale0       # your tailnet; the tailnet policy narrows it per machine
sudo ufw allow 22/tcp                 # TEMPORARY, until ssh over the tailnet is proven
sudo ufw enable
# from another machine, over the tailnet: ssh box-a true
sudo ufw delete allow 22/tcp
sudo ufw status verbose
```

Behind a tunnel the box needs no inbound port at all: no 80, no 443. If the provider has a network
firewall (a cloud firewall, a security group), deny all inbound there too; it acts before the box.

**Docker ignores UFW.** A published container port (`ports: ["3100:3100"]`) is opened by Docker's
own firewall rules, ahead of UFW's, on every address. Publish on loopback only:
`ports: ["127.0.0.1:3100:3100"]`, and check from outside that it is closed.

## Services

| | System unit (`/etc/systemd/system/`) | User unit (`~/.config/systemd/user/`) |
|---|---|---|
| Runs under | PID 1, as the `User=` you name | that user's own service manager |
| Survives logout and reboot | yes | only with `sudo loginctl enable-linger <user>` |
| Manage with | `sudo systemctl ...` | `systemctl --user ...`; from root, `systemctl --user -M deploy@ ...` |
| Use for | production services, the tunnel, backups | per-user tools and schedules |

A user unit on a server without lingering "flaps": it starts with each ssh login and stops when
the last session ends. Production services are system units.

```ini
# /etc/systemd/system/app.service
[Unit]
Description=app: HTTP API on 127.0.0.1:3100 (api.example.com)
After=network-online.target
Wants=network-online.target
# Give up after 5 failed starts in 60 s instead of restarting forever and flooding the journal.
StartLimitIntervalSec=60
StartLimitBurst=5
OnFailure=alert@%n.service

[Service]
Type=simple
User=app
Group=app
WorkingDirectory=/srv/app/current
# KEY=value lines only, mode 0600 root (systemd reads it before dropping to User=).
EnvironmentFile=/etc/app/app.env
ExecStart=/srv/app/current/bin/server --listen 127.0.0.1:3100
Restart=on-failure
RestartSec=5
StateDirectory=app
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
```

The failure alert is a template unit plus a script that never fails itself:

```ini
# /etc/systemd/system/alert@.service
[Unit]
Description=Failure alert for %i
# No OnFailure= here: an alert that fails must not start another alert.

[Service]
Type=oneshot
EnvironmentFile=-/etc/alert/alert.env
ExecStart=/usr/local/bin/alert %i
```

```bash
#!/usr/bin/env bash
# /usr/local/bin/alert UNIT: tell a human that UNIT failed. Always exits 0.
unit="${1:?unit}"
if [[ -z "${ALERT_WEBHOOK_URL:-}" ]]; then echo "alert: no ALERT_WEBHOOK_URL; $unit failed" >&2; exit 0; fi
text="$(hostname -s): $unit failed
$(journalctl -u "$unit" -n 20 --no-pager -o cat 2>&1 | tail -c 1500)"
curl -fsS -m 10 -H 'Content-Type: application/json' -d "$(jq -n --arg text "$text" '{text: $text}')" \
  "$ALERT_WEBHOOK_URL" >/dev/null || echo "alert: could not post for $unit" >&2
exit 0
```

Whether `OnFailure=` fires on every crash of a `Restart=` service or only once systemd gives up
depends on the systemd version and `RestartMode=` (on systemd 254 and newer, `RestartMode=direct`
skips it during automatic restarts). Find out on your box: `sudo systemctl kill -s KILL app`, then
read the alert's journal (`journalctl -u 'alert@*'`).

Timers for scheduled work, and a slice for anything that must never starve production (CI runners,
agents, batch jobs):

```ini
# /etc/systemd/system/backup.timer
[Timer]
OnCalendar=*-*-* 05:15:00 UTC
# A run missed while the box was down happens at the next boot.
Persistent=true
RandomizedDelaySec=10m

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/side.slice: put Slice=side.slice in each side workload's unit.
[Slice]
MemoryHigh=1536M
MemoryMax=2G
CPUQuota=200%
CPUWeight=20
IOWeight=10
```

Unit lessons:

- **`ExecCondition=`** skips a unit cleanly on a host that lacks its binary
  (`ExecCondition=/usr/bin/env sh -c 'command -v ttyd'`); a failed condition does not trigger
  `Restart=`, so there is no loop.
- **`StandardOutput=append:<file>` needs the directory first.** Use `LogsDirectory=` (system
  units) or `ExecStartPre=/usr/bin/env mkdir -p <dir>`; otherwise the start fails before exec.
- **A user manager's `PATH` is minimal.** Name the directories in `Environment=PATH=...` instead of
  trusting a login profile.
- **`EnvironmentFile=` is not a shell script.** A line like `export KEY=value` is rejected, and the
  warning that says so goes to the journal with the value in it.
- **`systemctl show -p Environment` lists inline `Environment=` lines only**, never the file's
  contents. To see what a process really got, read the names (never the values):
  `sudo tr '\0' '\n' < /proc/"$(systemctl show -p MainPID --value app)"/environ | cut -d= -f1`.
- **Containers keep the environment they were created with.** `docker restart` after editing an
  `env_file` changes nothing; `docker compose up -d --force-recreate <service>` does.
- **An `ExecStartPre=` that takes a lock the deploy script already holds** waits for itself until
  its timeout and fails the start. Do that work in the deploy, before the locked restart.
- **Restart heavy services in small batches** with a pause between them; a small box that boots
  ten at once can stop answering ssh.

## Port map

One table, in the private inventory, changed in the same commit as the service:

| Port | Bind | Service | Unit | Public name | Notes |
|---|---|---|---|---|---|
| 22 | all, UFW: `tailscale0` only | sshd | `ssh.service` | none | |
| 80 | 127.0.0.1 | nginx | `nginx.service` | `*.example.com` via the tunnel | dispatches by Host |
| 3100 | 127.0.0.1 | app API | `app.service` | `api.example.com` | |
| 3101 | 127.0.0.1 | app staging | `app-staging.service` | `staging.example.com` | Access only |
| 3200 | tailnet address | metrics, called by box-b | `metrics.service` | none | box-b's tag granted 3200 |
| 5432 | 127.0.0.1 | PostgreSQL | `postgresql.service` | none | |
| 4000 | none | **kept free** | | | a retired service's port; a deploy check refuses listeners |

Free for new services: 3102 to 3199, 3201 to 3299.

- **Bind `127.0.0.1` unless another machine calls the service.** Then bind the tailnet address
  (or all addresses, with UFW allowing only `tailscale0`) and grant the caller's tag that port.
  Before rebinding, search every repo that calls the box for the port and the service's name.
- **Give each project a range** (3100s, 3200s), so a new service never lands on a neighbour's port.
- **Prove who owns a port** before you call it free or yours: `sudo ss -ltnp 'sport = :3100'`
  names the process; compare its PID with `systemctl show -p MainPID --value app`.

## nginx

One file per public name in `sites-available/`, enabled by a symlink. Behind the tunnel nginx
listens on loopback only, and a default server catches names nobody configured:

```nginx
# /etc/nginx/conf.d/00-common.conf
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
real_ip_header CF-Connecting-IP;
set_real_ip_from 127.0.0.1;            # only cloudflared connects, from loopback

server {                                # unknown Host: close the connection
    listen 127.0.0.1:80 default_server;
    return 444;
}
```

```nginx
# /etc/nginx/sites-available/api.example.com
server {
    listen 127.0.0.1:80;
    server_name api.example.com;
    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:3100;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;      # the edge terminated TLS
        proxy_set_header Upgrade $http_upgrade;         # WebSockets
        proxy_set_header Connection $connection_upgrade;
        proxy_read_timeout 300s;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/api.example.com /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
curl -sSI -H 'Host: api.example.com' http://127.0.0.1/      # locally, then through the edge
```

A box that serves the public directly (no tunnel) listens on 443 with a certificate
(`sudo certbot --nginx -d api.example.com`, which also installs its renewal timer), redirects 80 to
443, and opens only those two ports. Retire a site by removing its symlink, not its file, and say
where it went in the inventory.

## Releases and state

| Path | Holds |
|---|---|
| `/srv/app/releases/<commit>/` | one reviewed build per release, its runtime included (pinned and checksum-verified) |
| `/srv/app/current` | a symlink to the live release; switching it is the deploy |
| `/etc/app/app.env` | configuration and secrets, `0600 root` |
| `/var/lib/app/` | state (`StateDirectory=app`), owned by the app's account |
| `/var/backups/app/<time>/` | a copy of state, env and unit taken by each deploy before it migrates anything; keep the newest few |

- **Ship the runtime with the release.** A shared runtime on the host (the system Node or Bun) gets
  upgraded by some other job one day, and your service breaks without a deploy.
- **Expose the deployed commit** on a health endpoint, and check it after every deploy: a green CI
  run says the files arrived, not that the process restarted onto them.
- **Put bulky data on the provider's volume**, mounted by UUID with `nofail` in `/etc/fstab`, and
  bind it into place (`/var/lib/app`) with `RequiresMountsFor=` on the units that need it.

## Offsite backups

Dump every datastore consistently, archive the dumps with the configuration, and send one
snapshot offsite every day:

```bash
#!/usr/bin/env bash
# /usr/local/sbin/backup: consistent dumps, one offsite snapshot, a receipt.
set -euo pipefail
umask 077
set -a; . /etc/backup/backup.env; set +a      # exports RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE
stage=/data/backup-stage          # on the data volume, never a small root disk
rm -rf "$stage" && mkdir -p "$stage"

sqlite3 /var/lib/app/app.sqlite ".backup '$stage/app.sqlite'"     # safe while the app writes
sudo -u postgres pg_dump -Fc appdb > "$stage/appdb.dump"
# mongodump --archive="$stage/mongo.archive" --oplog              # a replica set

restic backup --tag daily "$stage" /etc /srv /var/lib --exclude /var/lib/docker
restic forget --tag daily --keep-daily 7 --keep-weekly 5 --keep-monthly 12 --prune
restic check --read-data-subset=5%
rm -rf "$stage"
date -u +%FT%TZ > /var/lib/backup/last-success
```

```ini
# /etc/systemd/system/backup.service (run by backup.timer above)
[Unit]
Description=Daily offsite backup
OnFailure=alert@%n.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup
Nice=10
IOSchedulingClass=idle
```

`/etc/backup/backup.env` (`0600 root`) holds `RESTIC_REPOSITORY` (an sftp, S3 or REST server
target, e.g. `sftp:backup@backup.example.com:/backups/box-a`) and `RESTIC_PASSWORD_FILE`.

- **Keep the repository password somewhere off the box too** (your password manager). Without it
  the backup cannot be read, and the box that held it is the one you lost.
- **Make the target refuse deletes from the box** (an append-only server such as restic's
  `rest-server --append-only`, or object lock on a bucket), and prune from another machine, so a
  compromised box cannot destroy its own history.
- **Alert on silence, not only on failure.** A daily check that `last-success` is less than 26
  hours old catches the timer that stopped running, which `OnFailure=` never sees.

A backup nobody restored is a hope. Once a month, and after every change to the script:

```bash
restic snapshots --tag daily | tail -n 3
restic restore latest --target /var/tmp/restore-drill --include /data/backup-stage
sqlite3 /var/tmp/restore-drill/data/backup-stage/app.sqlite 'PRAGMA integrity_check'   # ok
pg_restore --list /var/tmp/restore-drill/data/backup-stage/appdb.dump | head            # a table of contents
# compare a few row counts with the live databases, then:
rm -rf /var/tmp/restore-drill
```

Write the date, the snapshot id and the result in the inventory's change log.

## The inventory

A private doc per box (in a private repo, never this one), changed in the same commit as the box,
with these sections:

| Section | Contents |
|---|---|
| Machine | provider, size, OS, volumes, role (no addresses in anything public) |
| System services | port, bind, process, unit |
| Each app | its port, unit, account, paths, public name, health endpoint |
| Port map | the table above, with free ranges |
| nginx sites | file, `server_name`, upstream |
| Tunnel ingress | hostname, target |
| File locations | where code, configuration, state and backups live |
| Change log | date, change, why, the backup file each change left, how it was verified |

Back up a config file before editing it (`<file>.bak-<UTC time>-<reason>`), validate it, restart
once, verify from outside, and record all four in the change log. The next person to touch the
box (often an agent with none of your context) reads the inventory first.

## See also

- [tailscale.md](tailscale.md): the private network the box is administered over.
- [cloudflare.md](cloudflare.md): the tunnel, Access, DNS and WAF in front of it.
- [aws.md](aws.md): Claude Code on Amazon Bedrock.
