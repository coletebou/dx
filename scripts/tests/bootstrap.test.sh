#!/usr/bin/env bash
# bootstrap.test.sh: bootstrap.sh and the provisioner (scripts/bootstrap/), with nothing real
# touched. The step harness (rows, skips, a failing step that stops the run, the timing table,
# readiness markers); flag parsing; the clobber refusal and the fast-forward-only update; the
# default dry run writing nothing but the checkout; a download cut short doing nothing; the NVMe
# instance-store detection against a fake /sys, /dev, lsblk and nvme (EBS, none, several, already
# mounted), and apply with fake mkfs and mount; and the overlay's hook order and contract.
# The end-to-end runs in fresh Ubuntu containers are scripts/tests/bootstrap-e2e.sh.
#
#   bash scripts/tests/bootstrap.test.sh [SECTION...]
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
lib="$root/scripts/bootstrap/lib"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# With arguments, only those sections run: harness pins os system flags provision checkout cut nvme
# overlay.
only="$*"
section() {  # section NAME TITLE: whether to run this section; says its title when it does
    if [ -n "$only" ] && [[ " $only " != *" $1 "* ]]; then return 1; fi
    echo "$2"
}

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

before_status="$(git -C "$root" status --porcelain)"
# The test repositories' commits run no hooks of the machine's own (a global core.hooksPath).
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null

# harness CODE: run CODE in a fresh bash, in a scratch directory, with the harness loaded and
# strict mode on.
mkdir -p "$tmp/harness"
harness() {
    (cd "$tmp/harness" && bash -c 'set -Eeuo pipefail; . "$1/harness.sh"; eval "$2"' bash "$lib" "$1" 2>&1)
}

if section harness "the step harness"; then
out="$(harness 'BOOTSTRAP_TIMINGS="$PWD/t.tsv"
    a() { :; }; b() { step_skip off "not asked for"; }; c() { sub_begin part; sub_end; }
    run_step one a; run_step two b; run_step three c
    printf "%s\n" "${STEP_ROWS[@]}" | cut -f1,2; timing_table; echo "tsv $(wc -l < "$PWD/t.tsv")"' )"
check "a step gets an ok row" "one	ok" "$out"
check "a skipped step still gets its row" "two	skip-off" "$out"
check "...and says why" "skipped: not asked for" "$out"
check "a sub-step is named under its step, and listed after it" "three	ok
three > part	ok" "$out"
check "the timing table lists the steps" "one                                ok" "$out"
check "...and the total" "total" "$out"
check "each row is appended to the TSV" "tsv 4" "$out"

out="$(harness 'trap "rc=\$?; harness_on_exit \$rc; printf \"%s\n\" \"\${STEP_ROWS[@]}\" | cut -f1,2" EXIT
    good() { :; }; broken() { false; touch "$PWD/after"; }
    run_step good good; run_step broken broken; echo unreachable')"; rc=$?
equal "a failing command in a step stops the run" 1 "$rc"
check "...and the open step is recorded as failed" "broken	err-1" "$out"
lacks "...nothing after it runs" "unreachable" "$out"
if [[ -e "$tmp/harness/after" ]]; then bad "errexit holds inside a step" "no file" "the step went on"; else ok "...not even the rest of the failing step"; fi
out="$(harness 'die "it broke"; echo after')"; rc=$?
equal "die exits 1" 1 "$rc"
check "...saying why" "error: it broke" "$out"
equal "seconds have one decimal" "12.3 0.0" "$(harness 'echo "$(fmt_secs 12345) $(fmt_secs 0)"')"

echo "readiness markers"
printf 'v1 binary\n' > "$tmp/harness/tool.bin"
out="$(harness 'BOOTSTRAP_STATE_DIR="$PWD/state"
    ready_mark tool "1.0:abc" "$PWD/tool.bin"
    ready_ok tool "1.0:abc" "$PWD/tool.bin" && echo same-pin-ok
    ready_ok tool "2.0:def" "$PWD/tool.bin" || echo new-pin-no
    BOOTSTRAP_FULL=1 ready_ok tool "1.0:abc" "$PWD/tool.bin" || echo full-no
    printf "changed\n" > "$PWD/tool.bin"; ready_ok tool "1.0:abc" "$PWD/tool.bin" || echo changed-no
    rm -f "$PWD/tool.bin"; ready_ok tool "1.0:abc" "$PWD/tool.bin" || echo missing-no')"
check "a marker counts while the pin and the file's hash hold" "same-pin-ok" "$out"
check "...not after a version bump" "new-pin-no" "$out"
check "...not under --full" "full-no" "$out"
check "...not once the file changed" "changed-no" "$out"
check "...not once the file is gone" "missing-no" "$out"

fi

if section pins "pins"; then
out="$(bash -c '. "$1/harness.sh"; . "$1/../versions.sh"
    for a in x86_64 aarch64; do for t in $PINNED_TOOLS; do
        s="$(BOOTSTRAP_ARCH=$a pin_sha "$t")"; u="$(BOOTSTRAP_ARCH=$a pin_url "$t")"
        [[ "$s" =~ ^[0-9a-f]{64}$ ]] || echo "badsum $a $t"
        case "$u" in https://*) ;; *) echo "badurl $a $t $u" ;; esac
    done; done; echo checked' bash "$lib" 2>&1)"
equal "every pinned tool has an https URL and a sha256 for both architectures" "checked" "$out"
equal "...distinct per architecture" "aarch64" \
    "$(bash -c '. "$1/harness.sh"; . "$1/../versions.sh"; BOOTSTRAP_ARCH=aarch64 pin_url zoxide' bash "$lib" | grep -o aarch64)"

fi

if section os "the operating system"; then
osr() { printf '%s\n' "$@" > "$tmp/os-release"; bash -c '. "$1/harness.sh"; . "$1/system.sh"; BOOTSTRAP_OS_RELEASE="$2" os_detect && echo "$OS_ID $OS_CODENAME"' bash "$lib" "$tmp/os-release" 2>&1; }
equal "Ubuntu" "ubuntu noble" "$(osr ID=ubuntu VERSION_CODENAME=noble)"
equal "Debian" "debian bookworm" "$(osr ID=debian VERSION_CODENAME=bookworm)"
equal "an Ubuntu derivative maps to its Ubuntu release" "ubuntu noble" "$(osr ID=mint 'ID_LIKE="ubuntu debian"' VERSION_CODENAME=wilma UBUNTU_CODENAME=noble)"
check "anything else is refused" "for Debian and Ubuntu" "$(osr ID=fedora)"
hn() { bash -c '. "$1/harness.sh"; . "$1/system.sh"; valid_hostname "$2" && echo yes || echo no' bash "$lib" "$1"; }
equal "a hostname: box-a" yes "$(hn box-a)"
equal "...a full name" yes "$(hn box-a.example.com)"
equal "...not one with a space" no "$(hn 'box a')"
equal "...not a leading dash" no "$(hn -box)"
equal "...not an empty label" no "$(hn box..example.com)"
mkdir -p "$tmp/dmi" && printf 'Amazon EC2\n' > "$tmp/dmi/sys_vendor"
equal "EC2 is told from the DMI vendor" yes "$(bash -c '. "$1/harness.sh"; . "$1/system.sh"; BOOTSTRAP_DMI_DIR="$2" is_ec2 && echo yes' bash "$lib" "$tmp/dmi")"
equal "...and anything else is not EC2" no "$(bash -c '. "$1/harness.sh"; . "$1/system.sh"; BOOTSTRAP_DMI_DIR="$2/none" is_ec2 || echo no' bash "$lib" "$tmp/dmi")"

fi

if section system "the system steps, against a scratch root"; then
sr="$tmp/sysroot"
mkdir -p "$sr/etc/cloud/cloud.cfg.d"
printf '127.0.0.1 localhost\n127.0.1.1 old-name\n' > "$sr/etc/hosts"
# sysrun CODE: CODE with the system steps loaded, root's writes done directly under the scratch root.
sysrun() {
    (cd "$tmp/harness" && bash -c 'set -Eeuo pipefail; . "$1/harness.sh"; . "$1/system.sh"
        as_root() { "$@"; }; hostname() { echo "${HN:-old-name}"; }; BOOTSTRAP_SYSROOT="$2"; eval "$3"' \
        bash "$lib" "$sr" "$1" 2>&1)
}
steps='for s in hostname hosts inotify locale apt_config; do run_step "system.$s" "step_$s"; done
    printf "%s\n" "${STEP_ROWS[@]}" | cut -f1,2'
out="$(sysrun 'BOOTSTRAP_HOSTNAME=box-a.example.com BOOTSTRAP_HOSTS_ENTRIES="203.0.113.10 git.example.com
203.0.113.11 ci.example.com"; '"$steps")"; rc=$?
equal "the system steps run" 0 "$rc"
equal "...each one making its change" "system.hostname	ok system.hosts	ok system.inotify	ok system.locale	ok system.apt_config	ok" \
    "$(printf '%s\n' "$out" | grep '^system\.' | tr '\n' ' ' | sed 's/ $//')"
equal "...setting /etc/hostname" box-a.example.com "$(cat "$sr/etc/hostname" 2>&1)"
check "...the machine's name on 127.0.1.1, full and short" "127.0.1.1 box-a.example.com box-a" "$(cat "$sr/etc/hosts")"
lacks "...in place of the old one" "old-name" "$(cat "$sr/etc/hosts")"
check "...keeping the rest of /etc/hosts" "127.0.0.1 localhost" "$(cat "$sr/etc/hosts")"
equal "...the entries in the managed block" "203.0.113.10 git.example.com
203.0.113.11 ci.example.com" "$(sed -n '/>>> dx-bootstrap hosts/,/<<< dx-bootstrap hosts/p' "$sr/etc/hosts" | sed '1d;$d')"
check "...telling cloud-init to keep the hostname" "preserve_hostname: true" "$(cat "$sr/etc/cloud/cloud.cfg.d/99-dx-hostname.cfg" 2>&1)"
check "...the inotify limits" "fs.inotify.max_user_watches = 1048576" "$(cat "$sr/etc/sysctl.d/60-dx-inotify.conf" 2>&1)"
equal "...the locale" "LANG=C.UTF-8" "$(cat "$sr/etc/default/locale" 2>&1)"
check "...apt's timeouts" 'Acquire::Retries "3";' "$(cat "$sr/etc/apt/apt.conf.d/80-dx-timeouts" 2>&1)"
before="$(cd "$sr" && find . -type f -exec cat {} + | cksum)"
out="$(HN=box-a.example.com sysrun 'BOOTSTRAP_HOSTNAME=box-a.example.com BOOTSTRAP_HOSTS_ENTRIES="203.0.113.10 git.example.com
203.0.113.11 ci.example.com"; '"$steps")"
check "a second run finds the hostname set" "system.hostname	skip-ready" "$out"
check "...the hosts in place" "system.hosts	skip-ready" "$out"
check "...the inotify limits" "system.inotify	skip-ready" "$out"
check "...the locale" "system.locale	skip-ready" "$out"
check "...and apt's timeouts" "system.apt_config	skip-ready" "$out"
equal "...and changes no file" "$before" "$(cd "$sr" && find . -type f -exec cat {} + | cksum)"
out="$(sysrun 'BOOTSTRAP_HOSTS_ENTRIES="203.0.113.10 git.example.com"; run_step system.hosts step_hosts')"
lacks "an entry dropped from the configuration leaves the file" "ci.example.com" "$(cat "$sr/etc/hosts")"
check "...and the one kept stays" "203.0.113.10 git.example.com" "$(cat "$sr/etc/hosts")"
out="$(sysrun 'BOOTSTRAP_HOSTS_ENTRIES="not an entry!"; run_step system.hosts step_hosts')"; rc=$?
equal "a malformed hosts entry is refused" 1 "$rc"
check "...by what it is" "not an /etc/hosts entry" "$out"
out="$(sysrun 'BOOTSTRAP_HOSTNAME="bad name"; run_step system.hostname step_hostname')"; rc=$?
equal "so is a malformed hostname" 1 "$rc"
printf '127.0.0.1 localhost\n::1 ip6-localhost\n' > "$sr/etc/hosts"
out="$(sysrun 'BOOTSTRAP_HOSTNAME=box-b; run_step system.hostname step_hostname')"
equal "with no 127.0.1.1 line, one goes right after 127.0.0.1" "127.0.0.1 localhost
127.0.1.1 box-b
::1 ip6-localhost" "$(cat "$sr/etc/hosts")"
fi

if section flags "bootstrap.sh flags"; then
bs() { HOME="$tmp/h-flags" bash "$root/bootstrap.sh" "$@" 2>&1; }
mkdir -p "$tmp/h-flags"
out="$(bs --help)"; rc=$?
equal "--help exits 0" 0 "$rc"
check "...and lists --provision" "--provision" "$out"
out="$(bs --bogus)"; rc=$?
equal "an unknown flag is a usage error (2)" 2 "$rc"
out="$(bs --with)"; rc=$?
equal "--with without a list is a usage error" 2 "$rc"
out="$(bs -- --hostname box-a)"; rc=$?
equal "arguments after -- without --provision are refused" 2 "$rc"
out="$(bs --plan)"
check "--plan clones into ~/.dotfiles" "would clone https://github.com/coletebou/dx.git into $tmp/h-flags/.dotfiles" "$out"
check "...and runs a dry run of every component" "install.sh --all --dry-run" "$out"
check "--install runs it for real" "install.sh --all --identity sam --role server" "$(bs --plan --install --identity sam --role server)"
check "--with names the components" "install.sh --with shell,git" "$(bs --plan --with shell,git)"
# shellcheck disable=SC2088  # a literal ~ is what is being tested
check "--dir takes ~" "into $tmp/h-flags/dx" "$(bs --plan --dir '~/dx')"
check "--ref names the branch" "dx.git (v0.2.0) into" "$(bs --plan --ref v0.2.0)"
check "--provision hands the rest to provision, as a server" "provision --user $(id -un) --role server --hostname box-a --nvme" \
    "$(bs --plan --provision -- --hostname box-a --nvme)"
check "--provision --install passes --install on" "provision --user $(id -un) --install --role server" "$(bs --plan --provision --install)"
check "DX_REPO_URL is said out loud" "DX_REPO_URL is set" "$(DX_REPO_URL=file:///nowhere bs --plan)"
if [[ "$(id -u)" -ne 0 ]]; then
    out="$(bs --plan --user nobody)"; rc=$?
    equal "--user someone else needs root" 2 "$rc"
else
    ok "# SKIP running as root"
fi
equal "--plan changes nothing" "" "$(ls -A "$tmp/h-flags")"

fi

if section provision "provision flags"; then
pv() { BOOTSTRAP_STATE_DIR="$tmp/state-pv" bash "$root/scripts/bootstrap/provision" "$@" 2>&1; }
out="$(pv --help)"; rc=$?
equal "--help exits 0" 0 "$rc"
check "...and lists the phases" "toolchains  pinned, sha256-checked" "$out"
out="$(pv --frobnicate)"; rc=$?
equal "an unknown flag is refused" 1 "$rc"
check "...by name" "unknown argument: --frobnicate" "$out"
check "a bad role is refused" "--role must be local or server" "$(pv --role desk)"
check "a flag without its value is refused" "--hostname needs a value" "$(pv --hostname)"
if [[ "$(uname -s)" == Linux && -r /etc/os-release ]] && grep -qE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release; then
    out="$(pv --plan --hostname box-a --aws)"
    check "--plan lists every phase" "system" "$out"
    check "...the nvme detection" "instance store:" "$out"
    check "...the opt-in modules, as asked" "AWS CLI $(sed -n 's/^PIN_AWSCLI_VERSION=//p' "$root/scripts/bootstrap/versions.sh")" "$out"
    check "...and install.sh as a server dry run" "--all --dry-run --role server" "$out"
    check "--install --with: install.sh for real" "install.sh --with shell,git --role server" "$(pv --plan --with shell,git)"
else
    out="$(pv --plan)"
    check "anywhere but Debian or Ubuntu it stops" "Debian and Ubuntu" "$out"
fi

fi

if section checkout "the checkout: the default dry run, an existing one, what is refused"; then
# A dx repository to clone from: the files of this checkout as they are now, committed.
src="$tmp/src"
mkdir -p "$src"
(cd "$root" && git ls-files -z -co --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$src"
git -C "$src" init -q -b master 2>/dev/null || git -C "$src" init -q
git -C "$src" add -A && git -C "$src" -c core.hooksPath=/dev/null commit -qm snapshot
export DX_REPO_URL="$src"

echo "the default run: a dry run that writes only the checkout"
h="$tmp/home-dry" && mkdir -p "$h" "$tmp/tmpdir-dry"
touch "$tmp/marker" && sleep 1
out="$(HOME="$h" TMPDIR="$tmp/tmpdir-dry" bash "$root/bootstrap.sh" 2>&1)"; rc=$?
equal "the one-liner's default succeeds" 0 "$rc"
check "...clones" "cloning $src into $h/.dotfiles" "$out"
check "...and prints install.sh's plan" "would link ~/.zshrc" "$out"
check "...and says it was a dry run" "that was a dry run" "$out"
equal "...leaving nothing in HOME but the checkout" ".dotfiles" "$(ls -A "$h")"
equal "...and nothing in TMPDIR" "" "$(ls -A "$tmp/tmpdir-dry")"
equal "...and nothing newer anywhere under HOME outside it" "" \
    "$(cd "$h" && find . -mindepth 1 -newer "$tmp/marker" -not -path './.dotfiles' -not -path './.dotfiles/*' | head -3)"
equal "...nor in the source repository" "" "$(git -C "$src" status --porcelain)"
check "read from stdin (curl | bash) it works the same" "would fast-forward the dx checkout" \
    "$(HOME="$h" bash -s -- --plan < "$root/bootstrap.sh" 2>&1)"

echo "an existing checkout"
git -C "$src" commit -q --allow-empty -m upstream-change
want="$(git -C "$src" rev-parse HEAD)"
out="$(HOME="$h" bash "$root/bootstrap.sh" 2>&1)"; rc=$?
equal "a dx checkout is updated" 0 "$rc"
equal "...by fast-forward to upstream" "$want" "$(git -C "$h/.dotfiles" rev-parse HEAD)"
git -C "$src" commit -q --allow-empty -m upstream-again
git -C "$h/.dotfiles" commit -q --allow-empty -m local-work
mine="$(git -C "$h/.dotfiles" rev-parse HEAD)"
out="$(HOME="$h" bash "$root/bootstrap.sh" 2>&1)"; rc=$?
equal "a diverged checkout still runs" 0 "$rc"
check "...with a warning" "could not fast-forward" "$out"
equal "...and keeps its own commit (no merge, no reset)" "$mine" "$(git -C "$h/.dotfiles" rev-parse HEAD)"
out="$(HOME="$h" bash "$root/bootstrap.sh" --no-update 2>&1)"
check "--no-update leaves it alone" "as it is (--no-update)" "$out"

echo "what bootstrap.sh refuses to clobber"
refuse() {  # refuse LABEL SETUP: SETUP builds ~/.dotfiles in a fresh HOME; the run must refuse
    local hh="$tmp/home-$RANDOM" before after
    mkdir -p "$hh"
    (cd "$hh" && eval "$2")
    before="$(cd "$hh" && find . | sort)"
    out="$(HOME="$hh" bash "$root/bootstrap.sh" --install 2>&1)"; rc=$?
    after="$(cd "$hh" && find . | sort)"
    equal "$1 is refused (exit 3)" 3 "$rc"
    if [[ "$before" == "$after" ]]; then ok "...and left exactly as it was"; else bad "...and left as it was" "$before" "$after"; fi
}
refuse "a directory with someone's files" 'mkdir .dotfiles && echo mine > .dotfiles/notes'
check "...saying what to do" "is not a dx checkout; nothing was changed" "$out"
refuse "a file" 'echo mine > .dotfiles'
refuse "a git repository that is not dx" 'mkdir .dotfiles && git -C .dotfiles init -q && echo x > .dotfiles/install.sh'
refuse "a symlink to someone else's directory" 'mkdir other && echo x > other/f && ln -s other .dotfiles'
refuse "a dangling symlink" 'ln -s nowhere .dotfiles'
refuse "dx's files outside a checkout of their own" 'mkdir .dotfiles && cp -R "$root/.claude-plugin" "$root/install.sh" .dotfiles/'
hh="$tmp/home-empty" && mkdir -p "$hh/.dotfiles"
out="$(HOME="$hh" bash "$root/bootstrap.sh" 2>&1)"; rc=$?
equal "an empty directory is cloned into" 0 "$rc"
check "...and holds dx" "dx" "$(sed -n 's/.*"name": *"\(dx\)".*/\1/p' "$hh/.dotfiles/.claude-plugin/marketplace.json" | head -1)"

fi

if section cut "a download cut short does nothing"; then
stub="$tmp/stub-bin" && mkdir -p "$stub"
for t in git sudo apt-get curl brew xcode-select runuser getent; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$tmp/stub-calls" > "$stub/$t"
    chmod +x "$stub/$t"
done
script="$root/bootstrap.sh"
size="$(wc -c < "$script" | tr -d ' ')"
cuts="" n=1
while [ "$n" -lt $((size - 1)) ]; do cuts="$cuts $n"; n=$((n + 97)); done
n=$((size - 80)); while [ "$n" -lt $((size - 1)) ]; do cuts="$cuts $n"; n=$((n + 1)); done
hc="$tmp/home-cut" && mkdir -p "$hc"
ran=0 tried=0
for n in $cuts; do
    tried=$((tried + 1))
    o="$(head -c "$n" "$script" | HOME="$hc" PATH="$stub:/usr/bin:/bin" bash 2>&1)"
    if [ -s "$tmp/stub-calls" ] || [ -n "$(ls -A "$hc")" ] || [[ "$o" == *"bootstrap: "* ]]; then
        ran=$((ran + 1)); echo "    ran at a cut of $n bytes: $(head -c 200 "$tmp/stub-calls" 2>/dev/null)"
        rm -f "$tmp/stub-calls"
    fi
done
equal "no cut of $tried tried (every 97th byte, and each of the last 80) runs anything" 0 "$ran"
o="$(HOME="$hc" PATH="$stub:/usr/bin:/bin" bash < "$script" 2>&1)"
check "control: the whole script does run (and reaches git)" "git --version" "$(cat "$tmp/stub-calls" 2>/dev/null)"
rm -f "$tmp/stub-calls"

fi

if section nvme "nvme: instance-store detection against a fake /sys, /dev, mountinfo, lsblk and nvme"; then
fake_nvme_tools() {  # fake lsblk, nvme, blkid, wipefs, mkfs.ext4, mount, chown, swapon in $1/bin
    local d="$1"
    mkdir -p "$d/bin" "$d/lsblk" "$d/idctrl"
    : > "$d/mountinfo"
    cat > "$d/bin/lsblk" <<EOF
#!/bin/sh
for a in "\$@"; do last="\$a"; done
f="$d/lsblk/\$(basename "\$last").json"
[ -f "\$f" ] && cat "\$f" || { echo "lsblk: \$last: not a block device" >&2; exit 32; }
EOF
    cat > "$d/bin/nvme" <<EOF
#!/bin/sh
f="$d/idctrl/\$(basename "\$2").json"
[ "\$1" = id-ctrl ] && [ -f "\$f" ] && cat "\$f" || exit 1
EOF
    for t in mkfs.ext4 swapon fallocate mkswap chown; do
        printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$t" "$d" > "$d/bin/$t"
    done
    printf '#!/bin/sh\necho "blkid $*" >> "%s/calls"\nexit "${FAKE_BLKID_RC:-2}"\n' "$d" > "$d/bin/blkid"
    printf '#!/bin/sh\necho "wipefs $*" >> "%s/calls"\nprintf "%%s" "${FAKE_WIPEFS_OUT:-}"\n' "$d" > "$d/bin/wipefs"
    # mount records what the kernel would: a line of mountinfo, the disk's own mount with root "/",
    # a bind mount with the directory it came from as its root.
    cat > "$d/bin/mount" <<EOF
#!/bin/sh
echo "mount \$*" >> "$d/calls"
for a in "\$@"; do last="\$a"; done
if [ "\$1" = --bind ]; then
    base="$d/root/srv/nvme"
    devno="\$(awk -v m="\$base" '\$5 == m { print \$3; exit }' "$d/mountinfo")"
    echo "90 1 \${devno:-0:0} \${2#\$base} \$last rw - ext4 bind rw" >> "$d/mountinfo"
else
    devno="\$(cat "$d/sys/block/\$(basename "\$3")/dev")"
    echo "80 1 \$devno / \$last rw,noatime - ext4 \$3 rw" >> "$d/mountinfo"
fi
EOF
    chmod +x "$d"/bin/*
}
dn=0
disk() {  # disk ROOT NAME MODEL SERIAL [LSBLK-JSON]: a fake NVMe disk (MODEL - for no sysfs model)
    local json="${5:-}"
    [ -n "$json" ] || json='{"blockdevices":[{"name":"/dev/'"$2"'","type":"disk","fstype":null,"label":null,"mountpoint":null}]}'
    mkdir -p "$1/sys/block/$2/device" "$1/dev"
    : > "$1/dev/$2"
    dn=$((dn + 1))
    printf '259:%s\n' "$dn" > "$1/sys/block/$2/dev"
    if [ "$3" != - ]; then printf '%-40s\n' "$3" > "$1/sys/block/$2/device/model"; fi
    printf '%-20s\n' "$4" > "$1/sys/block/$2/device/serial"
    printf '%s\n' "$json" > "$1/lsblk/$2.json"
}
mounted_at() {  # mounted_at ROOT NAME FSROOT WHERE: a mountinfo line for disk NAME
    printf '70 1 %s %s %s rw - ext4 /dev/%s rw\n' "$(cat "$1/sys/block/$2/dev")" "$3" "$4" "$2" >> "$1/mountinfo"
}
IS="Amazon EC2 NVMe Instance Storage" EBS="Amazon Elastic Block Store"
ebs_root='{"blockdevices":[{"name":"/dev/nvme0n1","type":"disk","fstype":null,"label":null,"mountpoint":null,"children":[{"name":"/dev/nvme0n1p1","type":"part","fstype":"ext4","label":"root","mountpoint":"/"}]}]}'
nv() {  # nv ROOT CMD: dx-nvme-setup CMD against the fakes under ROOT
    PATH="$1/bin:$PATH" NVME_SYSFS="$1/sys" NVME_DEV="$1/dev" NVME_ROOT="$1/root" NVME_TEST_MODE=1 \
        NVME_MOUNTINFO="$1/mountinfo" NVME_SWAP_GB="${SWAP:-0}" bash "$lib/nvme.sh" "${@:2}" 2>&1
}
sel() { bash -c '. "$1/nvme.sh"; nvme_select' bash "$lib"; }
newroot() { r="$tmp/nv-$1"; mkdir -p "$r/root"; fake_nvme_tools "$r"; }

newroot none
mkdir -p "$r/sys/block/sda" "$r/sys/block/loop0"
equal "no NVMe at all: nothing detected" "" "$(nv "$r" detect)"
check "...and the report says none" "instance store: none" "$(nv "$r" report)"

newroot ebs
disk "$r" nvme0n1 "$EBS" vol0aaa "$ebs_root"
equal "an EBS volume (the root disk) is never an instance store" "" "$(nv "$r" detect)"

newroot one
disk "$r" nvme0n1 "$EBS" vol0aaa "$ebs_root"
disk "$r" nvme1n1 "$IS" AWSB1
equal "EBS root plus a blank instance store: the instance store, by its padded model" \
    "$r/dev/nvme1n1	AWSB1	blank" "$(nv "$r" detect)"
check "...which apply would format" "nvme1n1 serial=AWSB1 state=blank (would format)" "$(nv "$r" report)"
out="$(nv "$r" apply --provisioning)"; rc=$?
calls="$(cat "$r/calls" 2>/dev/null)"
equal "apply succeeds" 0 "$rc"
check "...formats the blank instance store with the label" "mkfs.ext4 -q -F -L dx-nvme -E nodiscard $r/dev/nvme1n1" "$calls"
lacks "...and never touches the EBS volume" "nvme0n1" "$calls"
check "...probes it directly first" "blkid -p $r/dev/nvme1n1" "$calls"
check "...mounts it" "mount -o defaults,noatime $r/dev/nvme1n1 $r/root/srv/nvme" "$calls"
check "...binds Docker's and containerd's data onto it" "mount --bind $r/root/srv/nvme/binds/var_lib_docker $r/root/var/lib/docker" "$calls"
check "...and reports what it bound" "binds: /var/lib/docker /var/lib/containerd" "$out"
check "afterwards it is the disk mounted where it belongs, its bind mounts and all" \
    "$r/dev/nvme1n1	AWSB1	mounted:/srv/nvme" "$(nv "$r" detect)"
rm -f "$r/calls"
out="$(nv "$r" apply --provisioning)"; rc=$?
equal "so a second apply (another provision run, a restarted unit) succeeds" 0 "$rc"
lacks "...formatting nothing" "mkfs" "$(cat "$r/calls" 2>/dev/null)"
check "...and finding the binds in place" "/var/lib/docker is already a mount point" "$out"

newroot several
disk "$r" nvme0n1 "$EBS" vol0aaa "$ebs_root"
disk "$r" nvme1n1 "$IS" AWSB
disk "$r" nvme2n1 "$IS" AWSA
disk "$r" nvme3n1 "$IS" AWSC '{"blockdevices":[{"name":"/dev/nvme3n1","type":"disk","fstype":"xfs","label":null,"mountpoint":null}]}'
disk "$r" nvme4n1 - AWSD
printf '{"mn":"%s","sn":"AWSD"}\n' "$IS" > "$r/idctrl/nvme4n1.json"
disk "$r" nvme5n1 "$IS" AWSE '{"blockdevices":[{"name":"/dev/nvme5n1","type":"disk","fstype":null,"label":null,"mountpoint":null,"children":[{"name":"/dev/nvme5n1p1","type":"part","fstype":"ext4","label":null,"mountpoint":null}]}]}'
disk "$r" nvme1c1n1 "$IS" AWS0    # a hidden multipath path to nvme1n1, with a node of its own
out="$(nv "$r" detect)"
equal "several: listed by serial, not by device number" "AWSA AWSB AWSC AWSD AWSE" "$(printf '%s\n' "$out" | cut -f2 | tr '\n' ' ' | sed 's/ $//')"
check "...the model read from nvme id-ctrl when sysfs has none" "$r/dev/nvme4n1	AWSD	blank" "$out"
check "...another filesystem is in use" "$r/dev/nvme3n1	AWSC	in-use:xfs" "$out"
check "...a partitioned disk is too" "$r/dev/nvme5n1	AWSE	partitioned" "$out"
lacks "...and a hidden multipath path is not a disk" "nvme1c1n1" "$out"
equal "...the lowest serial of the blank ones is chosen" "$r/dev/nvme2n1 format" "$(printf '%s\n' "$out" | sel)"
check "...and the rest are left alone" "nvme1n1 serial=AWSB state=blank (left alone)" "$(nv "$r" report)"

newroot mounted
disk "$r" nvme1n1 "$IS" AWSA
disk "$r" nvme2n1 "$IS" AWSB
disk "$r" nvme3n1 "$IS" AWSC '{"blockdevices":[{"name":"/dev/nvme3n1","type":"disk","fstype":"ext4","label":"dx-nvme","mountpoint":null}]}'
disk "$r" nvme4n1 "$IS" AWSD
mounted_at "$r" nvme1n1 / /data
# nvme2n1 is this tool's disk after a provision: mounted at /srv/nvme, with bind mounts made from
# it after that. lsblk's one MOUNTPOINT names a bind target there, as the real lsblk does.
mounted_at "$r" nvme2n1 / "$r/root/srv/nvme"
mounted_at "$r" nvme2n1 /binds/var_lib_docker "$r/root/var/lib/docker"
mounted_at "$r" nvme2n1 /binds/var_lib_containerd "$r/root/var/lib/containerd"
printf '%s\n' '{"blockdevices":[{"name":"/dev/nvme2n1","type":"disk","fstype":"ext4","label":"dx-nvme","mountpoint":"'"$r"'/root/var/lib/containerd"}]}' > "$r/lsblk/nvme2n1.json"
out="$(nv "$r" detect)"
check "already mounted elsewhere: in use there" "$r/dev/nvme1n1	AWSA	mounted:/data" "$out"
check "mounted where it belongs, with bind mounts made from it" "$r/dev/nvme2n1	AWSB	mounted:/srv/nvme" "$out"
equal "...is the one used, as it is (no format)" "$r/dev/nvme2n1 use" "$(printf '%s\n' "$out" | sel)"
equal "without it, this tool's own filesystem comes before a blank disk" "$r/dev/nvme3n1 mount" \
    "$(printf '%s\n' "$out" | grep -v nvme2n1 | sel)"
equal "a disk mounted elsewhere is never chosen" "" "$(printf '%s\n' "$out" | grep nvme1n1 | sel)"
out="$(nv "$r" apply --provisioning)"; rc=$?
equal "apply on the provisioned disk succeeds" 0 "$rc"
lacks "...and formats nothing" "mkfs" "$(cat "$r/calls" 2>/dev/null)"
: > "$r/mountinfo"; mounted_at "$r" nvme1n1 /binds/x "$r/root/var/lib/docker"
check "a disk only bind-mounted somewhere is in use there" "$r/dev/nvme1n1	AWSA	mounted:$r/root/var/lib/docker" "$(nv "$r" detect)"

newroot signature
disk "$r" nvme1n1 "$IS" AWSA
out="$(FAKE_BLKID_RC=0 nv "$r" apply --provisioning)"; rc=$?
equal "a disk that lsblk calls blank but blkid finds a signature on is refused" 1 "$rc"
lacks "...and not formatted" "mkfs" "$(cat "$r/calls" 2>/dev/null)"
rm -f "$r/calls"
out="$(FAKE_WIPEFS_OUT="0x438 ext4" nv "$r" apply --provisioning)"; rc=$?
equal "so is one wipefs finds a signature on" 1 "$rc"

newroot busy
disk "$r" nvme1n1 "$IS" AWSA
mkdir -p "$r/root/var/lib/docker" && echo old > "$r/root/var/lib/docker/state"
out="$(nv "$r" apply --provisioning)"
check "while provisioning, a target that holds data is left where it is" "binds: /var/lib/containerd" "$out"
check "...saying so" "already has data on the root disk" "$out"
rm -f "$r/calls" && : > "$r/mountinfo"            # a reboot: nothing mounted
out="$(nv "$r" apply)"
check "at boot it is bound anyway (hidden, not deleted)" "binds: /var/lib/docker /var/lib/containerd" "$out"
equal "...and its data is still on the root disk" old "$(cat "$r/root/var/lib/docker/state")"

newroot cache
disk "$r" nvme1n1 "$IS" AWSA
mkdir -p "$r/root/home/sam"
out="$(NVME_BINDS="/var/lib/docker /home/sam/.cache:sam" nv "$r" apply --provisioning)"; rc=$?
calls="$(cat "$r/calls" 2>/dev/null)"
equal "a per-user cache binds" 0 "$rc"
check "...a missing cache is created as the user's" "chown sam: $r/root/home/sam/.cache" "$calls"
check "...and so is its place on the disk, which the bind shows in their home" \
    "chown sam: $r/root/srv/nvme/binds/home_sam_.cache" "$calls"
check "...and the owner stays on record for the boot unit" "binds: /var/lib/docker /home/sam/.cache:sam" "$out"
rm -rf "$r/calls" "$r/root/srv/nvme/binds/home_sam_.cache" && : > "$r/mountinfo"   # a stop and start
out="$(NVME_BINDS="/var/lib/docker /home/sam/.cache:sam" nv "$r" apply)"
check "after a stop and start the new place on the disk is the user's again" \
    "chown sam: $r/root/srv/nvme/binds/home_sam_.cache" "$(cat "$r/calls" 2>/dev/null)"
lacks "...and a system directory's place is never given to a user" "chown sam: $r/root/srv/nvme/binds/var_lib_docker" "$(cat "$r/calls" 2>/dev/null)"

# step_nvme_apply as provision runs it, as a root that writes under a scratch root.
newroot provision
disk "$r" nvme1n1 "$IS" AWSA
mkdir -p "$r/root/home/sam" "$r/sys-root"
out="$(cd "$tmp/harness" && PATH="$r/bin:$PATH" NVME_SYSFS="$r/sys" NVME_DEV="$r/dev" NVME_ROOT="$r/root" \
    NVME_TEST_MODE=1 NVME_MOUNTINFO="$r/mountinfo" NVME_SWAP_GB=0 bash -c '
    set -Eeuo pipefail; . "$1/harness.sh"; . "$1/system.sh"; . "$1/nvme.sh"; . "$1/docker.sh"
    as_root() { "$@"; }; has_systemd() { return 1; }
    BOOTSTRAP_SYSROOT="$2" BOOTSTRAP_LIB="$1" BOOTSTRAP_NVME=1 NVME_PRESENT=1 TARGET_USER=sam TARGET_HOME=/home/sam
    run_step nvme.apply step_nvme_apply' bash "$lib" "$r/sys-root" 2>&1)"; rc=$?
equal "--nvme as provision runs it succeeds" 0 "$rc"
check "...giving the user's cache to the user" "chown sam: $r/root/home/sam/.cache" "$(cat "$r/calls" 2>/dev/null)"
check "...and recording it, with its owner, for the boot unit" '/home/sam/.cache:sam' "$(cat "$r/sys-root/etc/default/dx-nvme" 2>&1)"
equal "...which it installs" yes "$( [ -x "$r/sys-root/usr/local/sbin/dx-nvme-setup" ] && echo yes)"

newroot unusable
disk "$r" nvme1n1 "$IS" AWSA '{"blockdevices":[{"name":"/dev/nvme1n1","type":"disk","fstype":"xfs","label":null,"mountpoint":null}]}'
out="$(nv "$r" apply)"; rc=$?
equal "instance stores that are all in use fail apply (so Docker does not start on the root disk)" 1 "$rc"
newroot noneapply
out="$(nv "$r" apply)"; rc=$?
equal "no instance store at all: apply succeeds" 0 "$rc"
check "...doing nothing" "nothing to do" "$out"
equal "...and binds nothing" "binds:" "$(printf '%s\n' "$out" | grep '^binds:')"

newroot models
disk "$r" nvme1n1 "Local NVMe SSD" S1
equal "another cloud's model string counts only when NVME_MODELS names it" "" "$(nv "$r" detect)"
check "...and then it does" "$r/dev/nvme1n1	S1	blank" "$(NVME_MODELS="Other|Local NVMe SSD" nv "$r" detect)"

fi

if section aptkey "apt signing keys: only the pinned key, and nothing but it, is installed"; then
if command -v gpg >/dev/null 2>&1; then
    g="$tmp/gpg"
    mkdir -p "$g/home" "$g/served" "$g/bin"
    chmod 700 "$g/home"
    genkey() {  # genkey UID: a throwaway signing key; prints its fingerprint
        GNUPGHOME="$g/home" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
            --quick-gen-key "$1" ed25519 sign never 2>/dev/null
        GNUPGHOME="$g/home" gpg --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
    }
    A="$(genkey 'dx test signer <signer@example.invalid>')"
    B="$(genkey 'dx test intruder <intruder@example.invalid>')"
    GNUPGHOME="$g/home" gpg --batch --armor --export "$A" > "$g/served/genuine.asc"
    GNUPGHOME="$g/home" gpg --batch --export "$A" > "$g/served/genuine.gpg"
    GNUPGHOME="$g/home" gpg --batch --armor --export "$A" "$B" > "$g/served/bundle.asc"
    GNUPGHOME="$g/home" gpg --batch --export "$B" "$A" > "$g/served/bundle.gpg"
    GNUPGHOME="$g/home" gpg --batch --armor --export "$B" > "$g/served/other.asc"
    gpgconf --homedir "$g/home" --kill all 2>/dev/null || true
    # curl, faked: serves $g/served/<the URL's file name> to -o.
    cat > "$g/bin/curl" <<EOF
#!/bin/sh
out="" last=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) last="\$1"; shift ;; esac; done
cp "$g/served/\$(basename "\$last")" "\$out"
EOF
    chmod +x "$g/bin/curl"
    keyrun() {  # keyrun FILE FPR: apt_repo_key for a served FILE, root writing under a scratch root
        (cd "$tmp/harness" && PATH="$g/bin:$PATH" bash -c 'set -Eeuo pipefail; . "$1/harness.sh"; . "$1/system.sh"
            as_root() { "$@"; }; BOOTSTRAP_SYSROOT="$2"; trap cleanup_run EXIT
            apt_repo_key test "https://example.invalid/keys/$3" "$4"' bash "$lib" "$g/root-$1" "$1" "$2" 2>&1)
    }
    fprs_in() {  # the primary fingerprints in a key file, space-separated
        local h
        h="$(mktemp -d)"
        GNUPGHOME="$h" gpg --batch --with-colons --show-keys "$1" 2>/dev/null \
            | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }' | tr '\n' ' ' | sed 's/ $//'
        rm -rf "$h"
    }
    equal "two different throwaway keys were made" yes "$( [ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ] && echo yes)"
    out="$(keyrun genuine.asc "$A")"; rc=$?
    equal "the pinned key alone is accepted" 0 "$rc"
    equal "...and its keyring path printed for signed-by" /etc/apt/keyrings/test.gpg "$(printf '%s\n' "$out" | tail -n 1)"
    equal "...holding exactly the pinned key" "$A" "$(fprs_in "$g/root-genuine.asc/etc/apt/keyrings/test.gpg")"
    out="$(keyrun genuine.gpg "$A")"; rc=$?
    equal "...armored or binary" "0 $A" "$rc $(fprs_in "$g/root-genuine.gpg/etc/apt/keyrings/test.gpg")"
    for bundle in bundle.asc bundle.gpg; do
        out="$(keyrun "$bundle" "$A")"; rc=$?
        equal "a download holding the pinned key and another one ($bundle) is refused" 1 "$rc"
        check "...as not exactly the pinned key" "is not exactly the pinned key $A" "$out"
        equal "...and no keyring is installed" "" "$(ls "$g/root-$bundle/etc/apt/keyrings" 2>/dev/null)"
    done
    out="$(keyrun other.asc "$A")"; rc=$?
    equal "a different key alone is refused" 1 "$rc"
    equal "...and installs nothing" "" "$(ls "$g/root-other.asc/etc/apt/keyrings" 2>/dev/null)"
else
    ok "# SKIP no gpg here"
fi
fi

if section aptkey "apt signing keys: only the pinned key, and nothing but it, is installed"; then
if command -v gpg >/dev/null 2>&1; then
    g="$tmp/gpg"
    mkdir -p "$g/home" "$g/served" "$g/bin"
    chmod 700 "$g/home"
    genkey() {  # genkey UID: a throwaway signing key; prints its fingerprint
        GNUPGHOME="$g/home" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
            --quick-gen-key "$1" ed25519 sign never 2>/dev/null
        GNUPGHOME="$g/home" gpg --batch --with-colons --list-keys "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10; exit }'
    }
    A="$(genkey 'dx test signer <signer@example.invalid>')"
    B="$(genkey 'dx test intruder <intruder@example.invalid>')"
    GNUPGHOME="$g/home" gpg --batch --armor --export "$A" > "$g/served/genuine.asc"
    GNUPGHOME="$g/home" gpg --batch --export "$A" > "$g/served/genuine.gpg"
    GNUPGHOME="$g/home" gpg --batch --armor --export "$A" "$B" > "$g/served/bundle.asc"
    GNUPGHOME="$g/home" gpg --batch --export "$B" "$A" > "$g/served/bundle.gpg"
    GNUPGHOME="$g/home" gpg --batch --armor --export "$B" > "$g/served/other.asc"
    gpgconf --homedir "$g/home" --kill all 2>/dev/null || true
    # curl, faked: serves $g/served/<the URL's file name> to -o.
    cat > "$g/bin/curl" <<EOF
#!/bin/sh
out="" last=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) last="\$1"; shift ;; esac; done
cp "$g/served/\$(basename "\$last")" "\$out"
EOF
    chmod +x "$g/bin/curl"
    keyrun() {  # keyrun FILE FPR: apt_repo_key for a served FILE, root writing under a scratch root
        (cd "$tmp/harness" && PATH="$g/bin:$PATH" bash -c 'set -Eeuo pipefail; . "$1/harness.sh"; . "$1/system.sh"
            as_root() { "$@"; }; BOOTSTRAP_SYSROOT="$2"; trap cleanup_run EXIT
            apt_repo_key test "https://example.invalid/keys/$3" "$4"' bash "$lib" "$g/root-$1" "$1" "$2" 2>&1)
    }
    fprs_in() {  # the primary fingerprints in a key file, space-separated
        local h
        h="$(mktemp -d)"
        GNUPGHOME="$h" gpg --batch --with-colons --show-keys "$1" 2>/dev/null \
            | awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 }' | tr '\n' ' ' | sed 's/ $//'
        rm -rf "$h"
    }
    equal "two different throwaway keys were made" yes "$( [ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ] && echo yes)"
    out="$(keyrun genuine.asc "$A")"; rc=$?
    equal "the pinned key alone is accepted" 0 "$rc"
    equal "...and its keyring path printed for signed-by" /etc/apt/keyrings/test.gpg "$(printf '%s\n' "$out" | tail -n 1)"
    equal "...holding exactly the pinned key" "$A" "$(fprs_in "$g/root-genuine.asc/etc/apt/keyrings/test.gpg")"
    out="$(keyrun genuine.gpg "$A")"; rc=$?
    equal "...armored or binary" "0 $A" "$rc $(fprs_in "$g/root-genuine.gpg/etc/apt/keyrings/test.gpg")"
    for bundle in bundle.asc bundle.gpg; do
        out="$(keyrun "$bundle" "$A")"; rc=$?
        equal "a download holding the pinned key and another one ($bundle) is refused" 1 "$rc"
        check "...as not exactly the pinned key" "is not exactly the pinned key $A" "$out"
        equal "...and no keyring is installed" "" "$(ls "$g/root-$bundle/etc/apt/keyrings" 2>/dev/null)"
    done
    out="$(keyrun other.asc "$A")"; rc=$?
    equal "a different key alone is refused" 1 "$rc"
    equal "...and installs nothing" "" "$(ls "$g/root-other.asc/etc/apt/keyrings" 2>/dev/null)"
else
    ok "# SKIP no gpg here"
fi
fi

if section overlay "the overlay: hook order and contract"; then
ov="$tmp/overlay" && mkdir -p "$ov/pre-system.d" "$ov/post-install.d"
chmod 755 "$ov" "$ov"/*.d
log="$tmp/hook-log"
printf 'echo "b sourced:$(type -t log)" >> "%s"\n' "$log" > "$ov/pre-system.d/20-b.sh"
printf '#!/bin/sh\necho "a run:$BOOTSTRAP_HOOK:$BOOTSTRAP_PHASE:$BOOTSTRAP_TARGET_USER" >> "%s"\n' "$log" > "$ov/pre-system.d/10-a"
chmod +x "$ov/pre-system.d/10-a"
printf 'echo f >> "%s"\n' "$log" > "$ov/pre-system.d/50-f.sh"
for skipped in 05-c.disabled README 30-d.sh~ .hidden.sh 40-e.txt; do printf 'echo %s >> "%s"\n' "$skipped" "$log" > "$ov/pre-system.d/$skipped"; done
printf 'echo post-install >> "%s"\n' "$log" > "$ov/post-install.d/10-x.sh"
run_overlay() {  # run_overlay OVERLAY POINT...: overlay_run each point, as provision does
    bash -c 'set -Eeuo pipefail; . "$1/harness.sh"; . "$1/system.sh"; . "$1/overlay.sh"
        BOOTSTRAP_OVERLAY="$2" TARGET_USER="${RO_USER:-sam}" TARGET_HOME="${RO_HOME:-/home/sam}"
        BOOTSTRAP_DX_DIR=/x BOOTSTRAP_LIB="$1"
        overlay_check "$2"; shift 2; for p in "$@"; do overlay_run "$p"; done
        printf "%s\n" "${STEP_ROWS[@]}" | cut -f1,2' bash "$lib" "$@" 2>&1
}
out="$(run_overlay "$ov" pre-system post-install)"; rc=$?
equal "the hooks run" 0 "$rc"
equal "...in name order, skipping what is not a hook" "a run:pre-system:system:sam
b sourced:function
f
post-install" "$(cat "$log")"
check "...each as its own step" "hook pre-system/20-b.sh	ok" "$out"
: > "$log"
printf 'echo before >> "%s"\nfalse\necho after >> "%s"\n' "$log" "$log" > "$ov/pre-system.d/30-fails.sh"
out="$(run_overlay "$ov" pre-system)"; rc=$?
equal "a failing hook stops the run" 1 "$rc"
check "...naming it" "the overlay hook pre-system/30-fails.sh failed" "$out"
equal "...a sourced hook stops at its failing command, and later hooks never run" "a run:pre-system:system:sam
b sourced:function
before" "$(cat "$log")"
rm -f "$ov/pre-system.d/30-fails.sh"
chmod o+w "$ov/pre-system.d/50-f.sh"
out="$(run_overlay "$ov" pre-system)"; rc=$?
equal "a world-writable hook is refused" 1 "$rc"
chmod o-w "$ov/pre-system.d/50-f.sh"
chmod o+w "$ov/pre-system.d"
out="$(run_overlay "$ov" pre-system)"; rc=$?
check "...and so is a world-writable hook directory" "is world-writable" "$out"
chmod o-w "$ov/pre-system.d"
printf 'BOOTSTRAP_ROLE=local\nBOOTSTRAP_TAILSCALE_TAGS=tag:server\n' > "$ov/overlay.env"
out="$(BOOTSTRAP_STATE_DIR="$tmp/state-ov" bash "$root/scripts/bootstrap/provision" --overlay "$ov" --role server --plan 2>&1)"
if [[ "$(uname -s)" == Linux ]] && grep -qE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release 2>/dev/null; then
    check "overlay.env sets defaults, and a flag still wins over them" "--role server" "$out"
    out="$(BOOTSTRAP_STATE_DIR="$tmp/state-ov" bash "$root/scripts/bootstrap/provision" --overlay "$ov" --plan --tailscale 2>&1)"
    check "...an overlay default shows in the plan" "join with tags tag:server" "$out"
    check "...as does its role" "--role local" "$out"
else
    ok "# SKIP the provision plan needs Debian or Ubuntu"
fi
ex="$root/identities/example/bootstrap-overlay"
out="$(run_overlay "$ex" pre-system post-install)"; rc=$?
equal "the example overlay's hooks run" 0 "$rc"
check "...and report the contract" "setting up sam (/home/sam)" "$out"
out="$(RO_USER="$(id -un)" RO_HOME="$HOME" run_overlay "$ex" post-toolchains)"; rc=$?
equal "...its executable hook too" 0 "$rc"
check "...which gets hook-env.sh's log from the helpers" "[post-toolchains] tmux" "$out"

fi

equal "the checkout is untouched by all of it" "$before_status" "$(git -C "$root" status --porcelain)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
