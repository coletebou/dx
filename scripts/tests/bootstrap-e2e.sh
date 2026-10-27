#!/usr/bin/env bash
# bootstrap-e2e.sh: bootstrap.sh and the provisioner end to end, each in a fresh Ubuntu container
# that starts with nothing installed (no git, no curl). Not part of run-all.sh: it needs Docker and
# the network, and takes minutes. The containers get this checkout read-only and clone from a
# local copy of it (DX_REPO_URL), so what runs is the code here, not what GitHub has.
#
#   bash scripts/tests/bootstrap-e2e.sh [dry|install|provision|modules|url]...   (default: all)
#
#   dry        the one-liner's default: git installed, dx cloned, a dry run that changes nothing
#   install    --with shell,git: the components linked into the container's HOME; a rerun is a no-op
#   provision  --provision --install as root for the image's ubuntu user, with the example overlay:
#              every phase, the pinned tools, Docker's packages, the done marker; then a second
#              run takes the fast path, and a third runs in cloud-init mode
#   modules    the opt-in modules (AWS CLI, Terraform, Tailscale's package), nothing else
#   url        the published one-liner against GitHub as it is now
# E2E_IMAGE picks the image (default ubuntu:24.04); E2E_DOCKER_ARGS adds docker run options (say
# --dns 9.9.9.9 where the host's resolver is flaky inside containers). Containers are removed.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
image="${E2E_IMAGE:-ubuntu:24.04}"
parts="${*:-dry install provision modules url}"
work="$(mktemp -d)"
# Containers are named dx-e2e-<part>-<pid>; any left go when this script does.
cleanup() {
    docker ps -aq --filter "name=dx-e2e-.*-$$" | xargs -r docker rm -f >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

docker info >/dev/null 2>&1 || { echo "bootstrap-e2e: docker is not usable here" >&2; exit 2; }

# The repository the containers clone: this checkout's files as they are now, committed.
mkdir -p "$work/src"
(cd "$root" && git ls-files -z -co --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$work/src"
git -C "$work/src" init -q -b master
git -C "$work/src" add -A
GIT_AUTHOR_NAME=e2e GIT_AUTHOR_EMAIL=e2e@example.invalid GIT_COMMITTER_NAME=e2e GIT_COMMITTER_EMAIL=e2e@example.invalid \
    git -C "$work/src" -c core.hooksPath=/dev/null commit -qm "e2e snapshot"
git clone -q --bare "$work/src" "$work/repo.git"

status=0
run() {  # run NAME SCRIPT: SCRIPT in a fresh container, with the checkout at /src
    local name="$1" start=$SECONDS rc
    echo "=== $name ($image)"
    # shellcheck disable=SC2086  # E2E_DOCKER_ARGS is a list of options
    docker run --rm --name "dx-e2e-$name-$$" ${E2E_DOCKER_ARGS:-} -v "$root:/src:ro" -v "$work/repo.git:/repo.git:ro" \
        -e DX_REPO_URL=file:///repo.git "$image" bash -c "$2"
    rc=$?
    echo "=== $name: exit $rc in $((SECONDS - start))s"
    [ "$rc" -eq 0 ] || status=1
}

# Shared by every container: a tiny check helper that counts failures. The mounted repository
# belongs to this host's user, which git (once installed) would refuse as "dubious ownership" for
# any other user; a system config file, written before git exists, marks it safe. It is the only
# thing a container gets before the run.
checks='
printf "[safe]\n\tdirectory = /repo.git\n" > /etc/gitconfig
fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
finish() { echo "  $fails failed"; [ "$fails" -eq 0 ]; }
'

for part in $parts; do
case "$part" in
dry) run dry "$checks"'
H="$HOME"
expect "no git before" "! command -v git >/dev/null"
touch /marker; sleep 1
out="$(cat /src/bootstrap.sh | bash 2>&1)"; rc=$?
printf "%s\n" "$out" | sed -n "1,6p;/would link ~\/.zshrc/p;/change(s) would be made/p;/that was a dry run/p" | sed "s/^/    | /"
[ $rc -eq 0 ] || printf "%s\n" "$out" | tail -15 | sed "s/^/    ! /"
expect "the one-liner succeeds" "[ $rc -eq 0 ]"
expect "git got installed" "command -v git >/dev/null"
expect "dx is cloned to ~/.dotfiles" "[ -f \"\$H/.dotfiles/install.sh\" ] && git -C \"\$H/.dotfiles\" rev-parse HEAD >/dev/null"
expect "the dry run printed its plan" "printf %s \"\$out\" | grep -q \"would link ~/.zshrc\""
expect "...and said it was a dry run" "printf %s \"\$out\" | grep -q \"that was a dry run\""
changed="$(find "$H" /home -newer /marker -not -path "$H/.dotfiles" -not -path "$H/.dotfiles/*" 2>/dev/null | grep -vx "$H")"
expect "nothing in HOME changed but the checkout" "[ -z \"\$changed\" ]"
[ -z "$changed" ] || printf "    changed: %s\n" $changed
other="$(find / -xdev -newer /marker -type f 2>/dev/null | grep -v "^$H/.dotfiles/" | grep -vE "^/(proc|sys|dev|run|tmp)/|^/var/(lib/(apt|dpkg)|cache/(apt|debconf|ldconfig)|log)/|^/usr/|^/etc/(ssl|ca-certificates|ld.so.cache|alternatives|perl)|^/var/lib/ucf/" | head -20)"
expect "outside HOME, only the packages apt installed for git changed" "[ -z \"\$other\" ]"
[ -z "$other" ] || printf "    also changed: %s\n" $other
finish' ;;

install) run install "$checks"'
H="$HOME"
out="$(cat /src/bootstrap.sh | bash -s -- --with shell,git 2>&1)"; rc=$?
printf "%s\n" "$out" | grep -E "linked|Done:|warning" | head -12 | sed "s/^/    | /"
[ $rc -eq 0 ] || printf "%s\n" "$out" | tail -15 | sed "s/^/    ! /"
expect "--with shell,git succeeds" "[ $rc -eq 0 ]"
expect "~/.zshrc is linked into the checkout" "[ \"\$(readlink \"\$H/.zshrc\")\" = \"\$H/.dotfiles/zshrc\" ]"
expect "~/.gitconfig is linked" "[ \"\$(readlink \"\$H/.gitconfig\")\" = \"\$H/.dotfiles/base/gitconfig.base\" ]"
expect "~/.df-profile names the identity" "grep -q DF_IDENTITY=example \"\$H/.df-profile\""
out="$(cat /src/bootstrap.sh | bash -s -- --with shell,git 2>&1)"
expect "a second run changes nothing" "printf %s \"\$out\" | grep -q \"Everything was already in place.\""
finish' ;;

provision) run provision "$checks"'
export DEBIAN_FRONTEND=noninteractive
U=ubuntu
H="$(getent passwd "$U" | cut -d: -f6)"
t0=$SECONDS
out="$(cat /src/bootstrap.sh | bash -s -- --user "$U" --provision --install -- \
    --hostname box-a --hosts-entry "203.0.113.10 git.example.com" \
    --overlay "$H/.dotfiles/identities/example/bootstrap-overlay" 2>&1)"; rc=$?
echo "    first run: $((SECONDS - t0))s"
printf "%s\n" "$out" | sed -n "/^step  /,\$p" | sed "s/^/    | /"
printf "%s\n" "$out" | grep -E "instance store|warning|error|fast path|hook " | sed "s/^/    > /"
[ $rc -eq 0 ] || printf "%s\n" "$out" | tail -40 | sed "s/^/    ! /"
expect "the provision run succeeds" "[ $rc -eq 0 ]"
expect "it wrote the done marker" "grep -q status=ok /var/lib/dx-bootstrap/done"
expect "the nvme detection reports none" "printf %s \"\$out\" | grep -q \"instance store: none\""
expect "the hostname file says box-a" "[ \"\$(cat /etc/hostname)\" = box-a ]"
expect "127.0.1.1 maps box-a" "grep -q \"^127.0.1.1 box-a\" /etc/hosts"
expect "the managed hosts block holds the entry" "grep -A1 \">>> dx-bootstrap hosts\" /etc/hosts | grep -q git.example.com"
expect "inotify limits are configured" "grep -q max_user_watches /etc/sysctl.d/60-dx-inotify.conf"
expect "the locale is UTF-8" "grep -q LANG=C.UTF-8 /etc/default/locale"
expect "apt fails fast" "grep -q Acquire::Retries /etc/apt/apt.conf.d/80-dx-timeouts"
expect "tmux is the pinned build" "[ \"\$(/usr/local/bin/tmux -V)\" = \"tmux 3.7b\" ]"
for t in gitleaks lazygit eza delta zoxide; do expect "$t is installed" "/usr/local/bin/$t --version >/dev/null 2>&1 || /usr/local/bin/$t version >/dev/null 2>&1"; done
expect "xterm-ghostty has a terminfo entry" "infocmp -x xterm-ghostty >/dev/null 2>&1"
u() { runuser -u "$U" -- env HOME="$H" PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"; }
expect "node is the pinned version, for the user" "[ \"\$(u node --version)\" = v24.22.1 ]"
expect "fnm knows it as the default" "u env FNM_DIR=\"\$H/.local/share/fnm\" \"\$H/.local/share/fnm/fnm\" list | grep -q \"v24.22.1 default\""
expect "Claude Code is the pinned version" "u claude --version | grep -q 2.1.220"
expect "starship runs" "u starship --version >/dev/null"
expect "tpm is at its pinned commit" "[ \"\$(u git -C \"\$H/.tmux/plugins/tpm\" rev-parse HEAD)\" = \"\$(sed -n \"s/^PIN_TPM_COMMIT=//p\" /src/scripts/bootstrap/versions.sh)\" ]"
expect "the user owns everything in their home" "[ -z \"\$(find \"\$H\" -user root 2>/dev/null | head -1)\" ]"
expect "Docker'"'"'s packages are installed" "docker --version >/dev/null && dpkg -s docker-compose-plugin >/dev/null"
expect "the user is in the docker group" "id -nG \"\$U\" | grep -qw docker"
expect "install.sh linked the user'"'"'s ~/.zshrc" "[ \"\$(readlink \"\$H/.zshrc\")\" = \"\$H/.dotfiles/zshrc\" ]"
expect "the login shell is zsh" "getent passwd \"\$U\" | grep -q \":/usr/bin/zsh\$\""
expect "the overlay hooks ran" "printf %s \"\$out\" | grep -q \"hook pre-system/10-hello.sh\" && printf %s \"\$out\" | grep -q \"hook post-install/90-next-steps.sh\""
expect "the timings were kept" "grep -q \"toolchains.tmux\" /var/lib/dx-bootstrap/timings.tsv"

t0=$SECONDS
out="$(bash "$H/.dotfiles/scripts/bootstrap/provision" --user "$U" --install --hostname box-a --hosts-entry "203.0.113.10 git.example.com" 2>&1)"; rc=$?
echo "    second run: $((SECONDS - t0))s"
printf "%s\n" "$out" | sed -n "/^step  /,\$p" | sed "s/^/    | /"
[ $rc -eq 0 ] || printf "%s\n" "$out" | tail -30 | sed "s/^/    ! /"
expect "a second run succeeds" "[ $rc -eq 0 ]"
expect "...on the fast path" "printf %s \"\$out\" | grep -q \"fast path: every pinned tool is in place\""
expect "...skipping the installs" "printf %s \"\$out\" | grep -qE \"toolchains.claude +skip-fast\""
expect "...and install.sh changes nothing" "printf %s \"\$out\" | grep -q \"Everything was already in place.\""

out="$(bash "$H/.dotfiles/scripts/bootstrap/provision" --user "$U" --no-install --cloud-init 2>&1)"; rc=$?
[ $rc -eq 0 ] || printf "%s\n" "$out" | tail -30 | sed "s/^/    ! /"
expect "cloud-init mode succeeds" "[ $rc -eq 0 ]"
expect "...logging to /var/log/dx-bootstrap.log" "grep -q \"mode cloud-init\" /var/log/dx-bootstrap.log"
expect "...and updating the done marker" "grep -q mode=cloud-init /var/lib/dx-bootstrap/done"
finish' ;;

modules) run modules "$checks"'
out="$(cat /src/bootstrap.sh | bash -s -- --provision -- --no-docker --no-toolchains --no-install --aws --terraform --tailscale 2>&1)"; rc=$?
printf "%s\n" "$out" | sed -n "/^step  /,\$p" | sed "s/^/    | /"
[ $rc -eq 0 ] || printf "%s\n" "$out" | tail -30 | sed "s/^/    ! /"
expect "the modules run succeeds" "[ $rc -eq 0 ]"
expect "the AWS CLI is the pinned version" "aws --version 2>&1 | grep -q aws-cli/2.36.12"
expect "Terraform is the pinned version" "terraform version | grep -q \"Terraform v1.17.0\""
expect "Tailscale is installed from its repository" "tailscale version >/dev/null 2>&1 && grep -q pkgs.tailscale.com /etc/apt/sources.list.d/tailscale.list"
expect "...and with no systemd here it does not try to join" "printf %s \"\$out\" | grep -q \"tailscaled is installed but not running\""
finish' ;;

url) run url "$checks"'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null
set -o pipefail
out="$( { curl -fsSL https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh | bash; } 2>&1 )"; rc=$?   # exactly the one-liner, under pipefail
printf "    | %s\n" "$out" | head -5
echo "    the one-liner exited $rc"
code="$(curl -s -o /dev/null -w "%{http_code}" https://raw.githubusercontent.com/coletebou/dx/master/bootstrap.sh)"
echo "    raw URL: HTTP $code"
readme="$(curl -s -o /dev/null -w "%{http_code}" https://raw.githubusercontent.com/coletebou/dx/master/README.md)"
echo "    control, README.md on the same branch: HTTP $readme"
expect "the URL shape answers (README.md is served from the same path)" "[ \"$readme\" = 200 ]"
if [ "$code" = 200 ]; then ok "bootstrap.sh is published"; else echo "  note bootstrap.sh is not on master yet (HTTP $code)"; fi
finish' ;;
*) echo "unknown part: $part" >&2; status=1 ;;
esac
done
exit "$status"
