# Bootstrapping a fresh machine

Two tools, one for any machine and one for a server:

| Tool | Runs on | Does |
|---|---|---|
| [`bootstrap.sh`](../bootstrap.sh) | macOS, Debian, Ubuntu | installs git if it is missing, clones dx to `~/.dotfiles`, runs `install.sh` (a dry run unless you ask for more) |
| [`scripts/bootstrap/provision`](../scripts/bootstrap/provision) | Debian, Ubuntu | sets up a fresh box (packages, system settings, Docker, pinned tools, optional modules), then runs `install.sh` |

`bootstrap.sh --provision` chains them: clone, then provision.

## The one line

```bash
curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh | bash
```

That changes two things: git, if it was missing, and a new clone in `~/.dotfiles`. Then it prints
what `install.sh --all` would link, generate and back up, and changes nothing else. To apply it:

```bash
curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh | bash -s -- --install
curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh | bash -s -- --with shell,git,tmux
# or, with the checkout already there:
bash ~/.dotfiles/bootstrap.sh --install
```

| Option | Meaning |
|---|---|
| `--install` | `install.sh --all` for real (the default is `install.sh --all --dry-run`) |
| `--with LIST` | `install.sh --with LIST` for real (`./install.sh --list` names the components) |
| `--identity ID`, `--role ROLE` | passed to `install.sh` (the role defaults to `server` with `--provision`) |
| `--dir DIR` | where the checkout goes (default `~/.dotfiles`; `install.sh` then links `~/.dotfiles` to it) |
| `--ref REF` | a branch or tag for a new clone |
| `--user NAME` | as root: set up NAME instead (clone into their home and install as them) |
| `--provision` | run the provisioner first; its own options follow a second `--` |
| `--no-update` | use an existing checkout as it is |
| `--plan` | say what would happen, change nothing at all |

How it treats what is already there:

- **git.** Installed only when missing: with apt on Debian and Ubuntu (`git` and `ca-certificates`,
  through sudo, which it says before asking), on macOS with Homebrew when Homebrew is installed, and
  otherwise by opening the Command Line Tools installer and stopping until you rerun. It never
  installs Homebrew. Any other system: install git yourself.
- **`~/.dotfiles` (or `--dir`).** Missing or empty: cloned. A dx checkout (its own git top level,
  with `install.sh` and the dx plugin marketplace): fast-forwarded, never merged or reset; if it has
  diverged or has no upstream, it is used as it is, with a warning. Anything else (your files, a
  different repository, a file, a symlink elsewhere): the run stops with exit 3 and touches nothing.
- **Your home.** Only `install.sh` changes it, and it moves whatever it replaces into
  `~/.dotfiles-backup/<time>/` with a change log (see the README).

**Why piping it into bash is safe.** The whole script is one `{ ... }` block, and bash runs nothing
until it has read the closing brace: a download cut off anywhere is a syntax error and does
nothing. It runs under `set -euo pipefail`, gives every child process `/dev/null` as stdin (so
nothing can eat the rest of the script), and turns off git's credential prompts.

`DX_REPO_URL` clones from somewhere other than GitHub: a fork, or a local copy when testing a
branch (`DX_REPO_URL=file:///srv/dx.git`). It is said out loud when set.

## Provisioning a server

On a fresh Debian or Ubuntu box, as a user with sudo:

```bash
curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh \
  | bash -s -- --provision --install -- --hostname box-a
```

or, as root, for a login user that already exists:

```bash
curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh \
  | bash -s -- --user admin --provision --install -- --hostname box-a
```

Without `--install` (or `--with`) the last step is again a dry run of `install.sh`; everything
before it is real. `provision --plan` (or `bootstrap.sh --provision --plan`) prints every phase and
what it would do, changing nothing. Accounts, sshd and the firewall are not the provisioner's job:
[infra/vps.md](infra/vps.md) covers creating the user, SSH hardening and UFW, and
[infra/tailscale.md](infra/tailscale.md) the tailnet a box joins.

### The phases

Each phase is a list of steps, each step idempotent and timed. Overlay hooks can run before and
after each phase ([Overlays](#overlays)).

| Phase | Steps |
|---|---|
| **system** | `hostname`: with `--hostname`, the hostname, Debian's `127.0.1.1` line, and cloud-init's `preserve_hostname` so a reboot keeps it. `hosts`: `--hosts-entry` lines, in one marked block rewritten each run. `inotify`: raised watch, instance and queue limits in `/etc/sysctl.d/60-dx-inotify.conf` (many file watchers otherwise fail with ENOSPC far from the cause). `locale`: `LANG=C.UTF-8` in `/etc/default/locale` unless a UTF-8 locale is already set. `apt-config`: 30-second network timeouts and 3 retries, so a stalled mirror cannot hold the apt lock forever. `packages`: the base packages (git, curl, gnupg, unzip, zsh, jq, python3, tmux, fzf, ripgrep, fd, bat, tree, htop, the zsh plugins) plus `BOOTSTRAP_APT_EXTRA`, with `fd` and `bat` shims. `ec2-swap`: with `--ec2`, see below. |
| **nvme** | `detect`: always, read-only: which local instance-store disks there are. `apply`: with `--nvme`, see [Instance-store NVMe](#instance-store-nvme). |
| **docker** | `engine`: Docker Engine, buildx and compose from Docker's apt repository, its signing key checked against the fingerprint Docker publishes (a download holding any other key is refused, and only the pinned key is installed for apt to trust); the user joins the `docker` group. `binfmt`: `qemu-user-static`, so Docker runs and builds images of the other architecture. `--no-docker` skips both. |
| **toolchains** | Pinned and sha256-checked (see [Pins](#pins)): tmux built from source into `/usr/local`; gitleaks (the git hooks need it), lazygit, eza, delta and zoxide into `/usr/local/bin`; Ghostty's terminfo. For the user, as the user: fnm and Node (also linked into `~/.local/bin` for non-interactive shells), starship, Claude Code (its native binary, laid out as its own installer does), and the four tmux plugins `tmux.conf` names, each at a pinned commit. `--no-toolchains` skips them. |
| **modules** | Opt-in: `--aws`, `--terraform`, `--tailscale` ([Modules](#modules)). |
| **install** | `install.sh` as the user (`--all --dry-run` by default; `--install`, `--with LIST`, or `--no-install`), then the login shell becomes zsh when the shell component is really installed. |

At the end it prints a timing table (every step, its status and seconds) and writes
`/var/lib/dx-bootstrap/done` (or `failed`, naming the step). A failing command anywhere stops the
run: the steps run under `set -Eeuo pipefail`, deliberately never inside a conditional, where bash
would ignore errexit.

### Options

| Option | Meaning |
|---|---|
| `--install`, `--with LIST`, `--no-install` | how `install.sh` runs |
| `--identity ID`, `--role ROLE` | `install.sh`'s identity, and its role (default `server`) |
| `--user NAME` | the login user to set up (default: you; as root, `$SUDO_USER`, else root) |
| `--hostname NAME` | set the hostname |
| `--hosts-entry "ADDRESS NAME..."` | an `/etc/hosts` line (repeatable) |
| `--upgrade` | `apt-get upgrade` as well |
| `--nvme` | use the local instance-store NVMe |
| `--ec2` | EC2 extras: `--nvme`, plus the hibernation-agent swap fix |
| `--no-docker`, `--no-toolchains` | leave those phases out |
| `--aws`, `--terraform`, `--tailscale` | the modules |
| `--tailscale-authkey-file PATH`, `--tailscale-tags LIST`, `--tailscale-hostname NAME`, `--tailscale-ssh`, `--tailscale-rejoin` | Tailscale's join |
| `--overlay DIR` | an overlay of private hooks and defaults |
| `--full` | ignore the readiness markers and reinstall every pinned tool |
| `--cloud-init` | cloud-init mode (detected on its own under cloud-init) |
| `--trace` | a bash trace, mode 0600, in `/var/log/dx-bootstrap-trace.log` |
| `--plan` | the plan, changing nothing |
| `--verify-pins` | download every pinned asset for both architectures and check its sum |

Every option has an environment twin, which an overlay's `overlay.env` can set as a default:
`BOOTSTRAP_INSTALL` (`dry-run`, `all`, `with`, `none`), `BOOTSTRAP_WITH`, `BOOTSTRAP_IDENTITY`,
`BOOTSTRAP_ROLE`, `BOOTSTRAP_USER`, `BOOTSTRAP_HOSTNAME`, `BOOTSTRAP_HOSTS_ENTRIES` (one per
line), `BOOTSTRAP_UPGRADE`, `BOOTSTRAP_NVME`, `BOOTSTRAP_EC2`, `BOOTSTRAP_DOCKER`,
`BOOTSTRAP_TOOLCHAINS`, `BOOTSTRAP_AWS`, `BOOTSTRAP_TERRAFORM`, `BOOTSTRAP_TAILSCALE`,
`BOOTSTRAP_TAILSCALE_TAGS`, `BOOTSTRAP_TAILSCALE_HOSTNAME`, `BOOTSTRAP_TAILSCALE_SSH`,
`BOOTSTRAP_TAILSCALE_REJOIN`, `BOOTSTRAP_TAILSCALE_AUTHKEY_FILE`, `BOOTSTRAP_FULL`,
`BOOTSTRAP_CLOUD_INIT`, `BOOTSTRAP_TRACE` (all `1` to turn on). Tuning without a flag:
`BOOTSTRAP_APT_EXTRA`, `BOOTSTRAP_APT_PACKAGES` (replaces the base set), `BOOTSTRAP_APT_LOCK_TIMEOUT`
(seconds to wait for the dpkg lock, default 900), `BOOTSTRAP_INOTIFY_WATCHES`, `_INSTANCES`,
`_EVENTS`, `BOOTSTRAP_SWAP_GB`, `BOOTSTRAP_NVME_CACHE=0` (no per-user cache directory on the
instance store),
`BOOTSTRAP_STATE_DIR` (default `/var/lib/dx-bootstrap`).

## Instance-store NVMe

Some cloud instances come with local NVMe disks (on EC2, the instance types with a `d`): fast, and
wiped every time the instance stops. The `nvme` phase always looks for them and reports what it
finds; with `--nvme` (or `--ec2`) it uses one.

- **What counts.** A disk is an instance store when its controller's model string is exactly one of
  `NVME_MODELS` (default: EC2's `Amazon EC2 NVMe Instance Storage`). EC2's EBS volumes, the root
  disk among them, report `Amazon Elastic Block Store` and are never touched. Device numbers
  (`nvme0n1`, `nvme1n1`) are never trusted: the kernel hands them out in probe order. The model
  comes from sysfs, or from `nvme id-ctrl` when sysfs has none.
- **Which one.** Usable means blank, or already carrying this tool's ext4 label (`dx-nvme`), or
  already mounted at `/srv/nvme`. A disk with partitions, any other filesystem or signature, or a
  mount anywhere else is left alone. With several usable disks it takes the one with the lowest
  serial and leaves the rest. Right before formatting, it probes the disk directly (`blkid -p`,
  `wipefs`) and refuses if either finds anything.
- **What goes there.** `/srv/nvme` holds bind mounts for root-owned system directories only
  (`NVME_BINDS`, default `/var/lib/docker /var/lib/containerd`) and an 8 GB swap file
  (`NVME_SWAP_GB`, 0 for none). The phase runs before Docker is installed, so Docker's data starts
  out there. A target that already holds data is left on the root disk, with a warning.
- **Never a bind onto a path a user controls.** Root resolving or mounting onto a path inside a
  user's home would follow whatever symlink is there at the time: a user could point `~/.cache` at
  `/etc` (or anything else) and have root plant a user-writable directory over a system one, or,
  worse, swap the symlink in between root's checks and the `mount` call and have root bind over
  a path like `/etc` directly. So `NVME_BINDS` holds only paths root already owns outright, never
  one under a user's home, and the bind's landing place is still checked against the resolved
  mountinfo path afterwards (undone, failing the run, if it landed anywhere else).
- **A user's cache, without ever touching their home as root.** With `--nvme` (unless
  `BOOTSTRAP_NVME_CACHE=0`), the target user gets a cache directory *on the instance store*, at
  `/srv/nvme/users/<user>/cache` (`0700`, owned by them) — created entirely under `/srv/nvme`,
  a tree only root can write to, so creating it never resolves anything under the user's own home.
  The user is pointed at it non-invasively: `~/.config/dx-nvme-cache.sh` (`export
  XDG_CACHE_HOME=...`) is written *as the user*, through `as_user`, so writing it follows only
  symlinks the user already chose for their own home — the same as anything else they could do
  there themselves. Source it (from `~/.zshenv.local`, say) to use it.
- **Where it is mounted** is read from `/proc/self/mountinfo`, which tells the disk's own mount from
  the bind mounts made from it (lsblk names only one of the places a disk is mounted), so a second
  run, or the boot unit run again, finds its disk in place.
- **At every boot.** `dx-nvme-setup.service` runs `/usr/local/sbin/dx-nvme-setup apply` before
  Docker, containerd and logins: after a stop and start the disk is blank again, so it formats,
  mounts and binds it anew. Docker and containerd require that unit, so a box whose instance store
  is present but unusable does not quietly start Docker on the root disk. With no instance store at
  all (the instance type changed) the unit does nothing and Docker uses the root disk.
- **The data is disposable.** Everything on the instance store is gone after a stop: images,
  containers, volumes, caches. Keep anything you need on the root volume or elsewhere.

`dx-nvme-setup detect` and `dx-nvme-setup report` show what it sees, at any time.

**`--ec2`** also handles EC2's hibernation agent, which creates a swap file as large as RAM on the
root disk at every boot: it is stopped, and a root `/swapfile` over 16 GB is cut to
`BOOTSTRAP_SWAP_GB` (8). Whether the box is on EC2 is read from its DMI vendor, never guessed from
the network.

## Modules

| Module | How |
|---|---|
| `--aws` | AWS CLI v2 through AWS's own installer (`/usr/local/aws-cli`, `/usr/local/bin/aws`), from the versioned zip, its sha256 pinned. It installs the CLI only: credentials and profiles stay yours ([infra/aws.md](infra/aws.md)). |
| `--terraform` | Terraform from HashiCorp's versioned release zip, sha256 pinned, into `/usr/local/bin`. |
| `--tailscale` | Tailscale from its apt repository (the signing key's fingerprint pinned, and only that key installed), then a join. |

The Tailscale join:

- **The auth key** comes from a file (`--tailscale-authkey-file PATH`) or from the environment
  (`BOOTSTRAP_TAILSCALE_AUTHKEY`), never from an argument. The variable is moved into a 0600 file
  under `/run` and unset before any hook or per-user step starts, and tailscale reads it with
  `--auth-key=file:`, so it never shows in `ps`, a trace or a child's environment. The temporary
  file is removed after the join; a file you passed is yours to delete.
- **Tags** come from `--tailscale-tags` (or `BOOTSTRAP_TAILSCALE_TAGS`, e.g. from an overlay). Right
  after joining it checks the node really carries them: an interrupted join can leave a node
  authorized but untagged, which a tag-based policy then cuts off.
- **Tailscale SSH is off** unless `--tailscale-ssh`.
- **Rejoin.** A node already on the tailnet is left alone, unless `--tailscale-rejoin`, or unless
  its machine-id differs from the one recorded when it joined. A box started from an image of
  another carries that box's tailscaled state, and with it the machine key that is its identity on
  the tailnet; a logout and a new login keep that key, so the clone would come back as the same
  device. Either way it stops tailscaled, deletes its state (`/var/lib/tailscale/tailscaled.state`,
  or `BOOTSTRAP_TAILSCALE_STATE`), starts it again and joins as a new device. It refuses to do that
  without a key to join with, which would leave the box off the tailnet. The old device stays in the
  admin console until you remove it.
- With no key, Tailscale is installed and the command to join is printed.

## The fast path and baked images

Every pinned tool writes a readiness marker in `/var/lib/dx-bootstrap/ready/`: the pin (version
and sha256 of the release asset), the installed file, and that file's sha256. A marker counts only
while the pin is unchanged and the file still hashes the same, so a version bump in `versions.sh`,
a deleted binary or a modified one all mean "install again".

When every marker holds, the base packages are installed and Docker is there, the run takes the
**fast path**: no apt update, every install step reports `skip-fast`, and only the per-box steps
(hostname, hosts, sysctl, the instance store, Tailscale, `install.sh`) do anything. That is what
makes a baked image fast: provision a box fully, clean what is per-box, snapshot it, and every box
started from the image provisions in seconds. Before the snapshot, remove the per-box state:

```bash
sudo systemctl stop tailscaled                   # if it joined: a logout keeps the machine key
sudo rm -f /var/lib/tailscale/tailscaled.state   # so delete the state that holds it
sudo rm -f /var/lib/dx-bootstrap/done
```

and whatever your image tooling resets (machine-id, ssh host keys, cloud-init's instance state).
Keep `/var/lib/dx-bootstrap/ready/`, and keep `tailscale-machine-id`: a box started from the image
has a new machine-id, which is how it knows to join as a new device even if the state was left in.

Outside a baked image the markers still pay off: a second run skips each tool that is in place
(`skip-ready`). `--full` ignores every marker, and `--upgrade` turns the fast path off (an upgrade
always runs); `BOOTSTRAP_FAST=0` turns it off while still letting each step check its own marker. Timings of every run are appended to
`/var/lib/dx-bootstrap/timings.tsv` (start, milliseconds, step, status) to compare the two.

## cloud-init

From user-data the provisioner runs as root, with no terminal and often no `HOME`. It notices it is
running under cloud-init (or takes `--cloud-init`): everything is also logged to
`/var/log/dx-bootstrap.log`, nothing prompts, and the done or failed marker says how it ended. It
never calls `cloud-init status --wait`: from user-data that waits for itself.

```yaml
#cloud-config
# Every value is a placeholder.
write_files:
  - path: /run/dx/tailscale-authkey
    permissions: "0600"
    content: <your-tailscale-auth-key>
runcmd:
  - - bash
    - -c
    - >-
      curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh
      | bash -s -- --user ubuntu --provision --install --
      --hostname box-a --tailscale --tailscale-tags tag:server
      --tailscale-authkey-file /run/dx/tailscale-authkey
  - rm -f /run/dx/tailscale-authkey
```

`--user` names a login user that exists by then (the image's default user, or one `users:` in the
same cloud-config creates). Check on it later with `sudo cat /var/lib/dx-bootstrap/done` and
`sudo tail /var/log/dx-bootstrap.log`. Instance metadata keeps user-data readable on the machine,
so prefer an ephemeral, pre-approved, tagged auth key there ([infra/tailscale.md](infra/tailscale.md)).

## Overlays

An overlay adds your private parts (an internal mirror, a CA bundle, a registry login, an agent you
run) to the generic flow without forking it. It is a directory, kept where only you can write (your
identity in a private repo, say), named with `--overlay DIR` or `BOOTSTRAP_OVERLAY=DIR`:

```text
overlay.env              BOOTSTRAP_* defaults, sourced before the flags (a flag wins)
pre-system.d/            hooks run before the system phase
post-system.d/           ... and after it
pre-nvme.d/ post-nvme.d/ pre-docker.d/ post-docker.d/ pre-toolchains.d/ post-toolchains.d/
pre-modules.d/ post-modules.d/ pre-install.d/ post-install.d/
terminfo/*.terminfo      terminfo sources, compiled after the toolchains' own
```

The contract:

- **What is a hook.** A file whose name starts with a letter or digit and does not end in `~` or
  `.disabled`. An executable one is run as its own process. A non-executable `*.sh` is sourced in a
  subshell under `set -Eeuo pipefail`, with the provisioner's helpers at hand: `log`, `warn`,
  `die`, `as_root CMD`, `as_user CMD` (as the user being set up), `root_write FILE CONTENT` (writes
  as root, only when the content differs) and `apt_ensure PKG...`. Anything else (a README) is
  ignored. An executable bash hook gets the same helpers with `. "$BOOTSTRAP_LIB/hook-env.sh"`.
- **Order.** By name (`LC_ALL=C`), so number them: `10-mirror.sh`, `20-ca.sh`.
- **Who.** The provisioner's own user: root under cloud-init, else you (with sudo through
  `as_root`). `as_user` runs a command as the user being set up.
- **Failure.** A hook that exits non-zero (or whose sourced commands fail) stops the run, and the
  failure names it. Each hook is a step of its own in the timing table.
- **Trust.** Hooks run as root. The provisioner refuses an overlay directory, hook directory, hook or
  `overlay.env` that anyone can write to.
- **The environment.** `BOOTSTRAP_HOOK` (e.g. `post-toolchains`), `BOOTSTRAP_PHASE`,
  `BOOTSTRAP_OVERLAY`, `BOOTSTRAP_DX_DIR`, `BOOTSTRAP_LIB`, `BOOTSTRAP_TARGET_USER`,
  `BOOTSTRAP_TARGET_HOME`, `BOOTSTRAP_STATE_DIR`, `BOOTSTRAP_MODE` (`interactive` or `cloud-init`),
  `BOOTSTRAP_FAST`, `BOOTSTRAP_INSTALL_MODE` (`dry-run` or `install`), `BOOTSTRAP_ARCH`,
  `BOOTSTRAP_OS_ID`, `BOOTSTRAP_OS_CODENAME`. No auth key is in it.

[`identities/example/bootstrap-overlay/`](../identities/example/bootstrap-overlay) is a harmless
example: an `overlay.env` of commented defaults, a sourced hook that reports the contract, an
executable one that prints the tools' versions, and a closing reminder. Try it with
`provision --plan --overlay identities/example/bootstrap-overlay`, then a real run.

## Pins

[`scripts/bootstrap/versions.sh`](../scripts/bootstrap/versions.sh) pins each downloaded tool to a
version and the sha256 of each architecture's release asset (x86_64 and aarch64), all from the
project's own release URLs: GitHub releases, nodejs.org, the Claude Code release bucket, AWS's and
HashiCorp's download sites, and ncurses' terminfo database for Ghostty (ncurses names the entry
`ghostty`; an `xterm-ghostty` alias is added because that is the TERM Ghostty sets; an overlay's
`terminfo/` can supply Ghostty's own). A download whose hash differs stops the run before anything
is unpacked. Node is unpacked from its checked tarball into fnm's own directory, so fnm's
unchecked download is never used.

To bump a tool, change its version and both sums, then `scripts/bootstrap/provision --verify-pins`
downloads every asset for both architectures and compares (it changes nothing else).

## What it never does

- Run anything from a download it has not checked, or `curl | sh` an installer.
- Install Homebrew, or anything else on macOS beyond git.
- Overwrite, merge into or reset an existing checkout, or clobber a directory that is not dx.
- Format a disk that is not a blank instance store, or touch an EBS volume.
- Bind-mount, as root, onto any path under a user's home, or otherwise have root resolve or
  create a path there — a cache for the user lives on the instance store instead, and the one file
  pointing at it is written by the user, not root.
- Put an auth key in an argument, a trace or a child's environment, or turn Tailscale SSH on
  unasked.
- Change sshd, the firewall, users or passwords ([infra/vps.md](infra/vps.md) does that by hand).
- Upgrade every package unasked (`--upgrade`), or reboot.
- Write outside the user's home, the paths above under `/etc`, `/usr/local`, `/srv/nvme`, `/run`,
  `/var/lib/dx-bootstrap` and `/var/log/dx-bootstrap*`, and what apt installs.

## What is and is not verified

`scripts/tests/bootstrap.test.sh` covers the harness and markers, the flags, the system steps
against a scratch root, the clobber refusal, the dry run, truncated downloads, the instance-store
detection and apply against fake disks and tools, and the overlay contract.
`scripts/tests/bootstrap-e2e.sh` runs, each in a fresh Ubuntu 24.04 container with nothing
installed: the one-liner's dry run, an install, a full `--provision --install` for a non-root user
(every pinned tool downloaded, checked and run; Docker's packages; the overlay's hooks), a second
run on the fast path and one in cloud-init mode, and the AWS CLI, Terraform and Tailscale modules.

Not verified, because a container cannot show it: Docker's daemon and binfmt under systemd, real
instance-store hardware and its boot unit across a stop and start, a real EC2 boot from user-data,
and a real tailnet join. The macOS path is deliberately small (git through the Command Line Tools
or an existing Homebrew, then `install.sh`) and has not been run on a Mac.
