#!/usr/bin/env bash
# install-node-tools.test.sh: scripts/install-node-tools.sh against a synthetic lock and a fake npm
# (a node script that "installs" what the lock lists, offline). An install publishes every command
# the lock's packages declare, skips other platforms' optional packages but requires this one's, and
# a second run reuses it without npm; --check verifies; a wrong Node major, a package.json that
# disagrees with its lock, a non-symlink command in the way and a missing platform package are
# refused without publishing anything; a changed lock gets a new install, and the old one stays:
# only --prune deletes, never the current or previous install, nor one a running tool may use.
#
#   bash scripts/tests/install-node-tools.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
script="$root/scripts/install-node-tools.sh"
if ! command -v node >/dev/null 2>&1; then
  printf '  ok   # SKIP node not installed\n\n1 passed, 0 failed\n'
  exit 0
fi
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
consumers=()   # background stand-ins for running tools, killed on exit
trap 'for c in "${consumers[@]}"; do kill "$c" 2>/dev/null; done; rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

major="$(node -p 'process.versions.node.split(".")[0]')"
here="$(node -p '`${process.platform}-${process.arch}`')"
native="alpha-$here"

# ── a synthetic tool set ──────────────────────────────────────────────────────────────────────
write_source() {  # write_source DIR BETA_VERSION [ALPHA_PIN]
  local dir="$1" beta="$2" alpha_pin="${3:-1.2.3}"
  mkdir -p "$dir"
  node - "$dir" "$beta" "$alpha_pin" "$native" <<'NODE'
const fs = require("node:fs");
const [dir, beta, alphaPin, native] = process.argv.slice(2);
const pkg = { name: "t-tools", private: true, version: "1.0.0",
  dependencies: { alpha: alphaPin, "@scope/beta": beta } };
const lock = { name: "t-tools", version: "1.0.0", lockfileVersion: 3, requires: true, packages: {
  "": { name: "t-tools", version: "1.0.0", dependencies: { alpha: "1.2.3", "@scope/beta": beta } },
  "node_modules/alpha": { version: "1.2.3", bin: { alpha: "bin/alpha.js" },
    optionalDependencies: { [native]: "1.2.3", "alpha-aix-ppc64": "1.2.3" } },
  [`node_modules/${native}`]: { version: "1.2.3", optional: true,
    os: [process.platform], cpu: [process.arch] },
  "node_modules/alpha-aix-ppc64": { version: "1.2.3", optional: true, os: ["aix"], cpu: ["ppc64"] },
  "node_modules/alpha-aix-ppc64/node_modules/aix-helper": { version: "0.0.1", optional: true },
  // A platform package for this machine, but below another platform's: npm never reaches it.
  "node_modules/alpha-aix-ppc64/node_modules/helper-here": { version: "0.0.1", optional: true,
    os: [process.platform] },
  "node_modules/maybe": { version: "2.0.0", optional: true },
  "node_modules/@scope/beta": { version: beta, bin: { beta: "cli.js", "beta-server": "server.js" } },
  "node_modules/@scope/beta/node_modules/dep": { version: "0.1.0" },
} };
fs.writeFileSync(`${dir}/package.json`, JSON.stringify(pkg, null, 2) + "\n");
fs.writeFileSync(`${dir}/package-lock.json`, JSON.stringify(lock, null, 2) + "\n");
NODE
}

# The fake npm: `npm ci --prefix DIR ...` lays out DIR/node_modules from DIR/package-lock.json
# the way npm does (this platform's packages, nothing below a skipped one), minus the packages
# FAKE_NPM_SKIP names (comma-separated), each command printing "<package> <version>".
mkdir -p "$tmp/bin"
cat > "$tmp/bin/npm" <<'EOF'
#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");
fs.appendFileSync(process.env.FAKE_NPM_LOG, process.argv.slice(2).join(" ") + "\n");
const args = process.argv.slice(2);
if (args[0] !== "ci") { console.error("fake npm: only ci"); process.exit(2); }
const dir = args[args.indexOf("--prefix") + 1];
const lock = JSON.parse(fs.readFileSync(path.join(dir, "package-lock.json"), "utf8"));
const skip = (process.env.FAKE_NPM_SKIP || "").split(",");
const skipped = [];
for (const [rel, e] of Object.entries(lock.packages)) {
  if (!rel) continue;
  const name = rel.split("node_modules/").pop();
  if (skipped.some((s) => rel.startsWith(s + "/node_modules/")) || skip.includes(name)
      || (e.os && !e.os.includes(process.platform)) || (e.cpu && !e.cpu.includes(process.arch))) {
    skipped.push(rel);
    continue;
  }
  fs.mkdirSync(path.join(dir, rel), { recursive: true });
  fs.writeFileSync(path.join(dir, rel, "package.json"), JSON.stringify({ name, version: e.version }));
  for (const [cmd, file] of Object.entries(e.bin || {})) {
    const target = path.join(dir, rel, file);
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.writeFileSync(target, `#!/bin/sh\necho "${name} ${e.version}"\n`, { mode: 0o755 });
    fs.mkdirSync(path.join(dir, "node_modules/.bin"), { recursive: true });
    fs.symlinkSync(path.relative(path.join(dir, "node_modules/.bin"), target), path.join(dir, "node_modules/.bin", cmd));
  }
}
EOF
chmod +x "$tmp/bin/npm"
export PATH="$tmp/bin:$PATH" FAKE_NPM_LOG="$tmp/npm.log" NODE_TOOLS_NODE_MAJOR="$major"
unset FAKE_NPM_SKIP
run() {  # run SOURCE PREFIX [ARGS...]: the script on one source and prefix
  local src="$1" prefix="$2"; shift 2
  : > "$FAKE_NPM_LOG"
  out="$(NODE_TOOLS_SOURCE="$src" NODE_TOOLS_PREFIX="$prefix" bash "$script" "$@" 2>&1)"; rc=$?
}

echo "install"
write_source "$tmp/src" 4.5.6
p="$tmp/prefix"
run "$tmp/src" "$p" --check
equal "--check before any install fails" 1 "$rc"
run "$tmp/src" "$p"
equal "an install succeeds" 0 "$rc"
check "...and says where" "Pinned Node tools ready under $p/node-tools-current" "$out"
check "...through npm ci in a staging directory" "ci --prefix $p/node-tools-installs/.stage." "$(cat "$FAKE_NPM_LOG")"
check "...omitting dev dependencies" "--omit=dev" "$(cat "$FAKE_NPM_LOG")"
for cmd in alpha beta beta-server; do
  equal "$cmd is published as a link into the current install" "../node-tools-current/node_modules/.bin/$cmd" \
    "$(readlink "$p/bin/$cmd" 2>&1)"
done
equal "...and runs" "alpha 1.2.3" "$("$p/bin/alpha" 2>&1)"
equal "a scoped package's commands run too" "@scope/beta 4.5.6" "$("$p/bin/beta-server" 2>&1)"
first="$(readlink "$p/node-tools-current")"
check "the install directory names the lock hash and the runtime" "-node-v$(node -p 'process.versions.node')-$here" "$first"
equal "this platform's optional package is installed" "yes" \
  "$([[ -f "$p/$first/node_modules/$native/package.json" ]] && echo yes || echo no)"
equal "...another platform's is not, and is not required" "no" \
  "$([[ -e "$p/$first/node_modules/alpha-aix-ppc64" ]] && echo yes || echo no)"
equal "...nor is what only it depends on" "no" \
  "$([[ -e "$p/$first/node_modules/alpha-aix-ppc64/node_modules/aix-helper" ]] && echo yes || echo no)"
equal "no staging directory is left behind" "" "$(find "$p/node-tools-installs" -mindepth 1 -maxdepth 1 -name '.stage*')"

echo "idempotent"
run "$tmp/src" "$p"
equal "a second run succeeds" 0 "$rc"
equal "...without running npm" "" "$(cat "$FAKE_NPM_LOG")"
run "$tmp/src" "$p" --check
equal "--check passes" 0 "$rc"
check "...saying so" "Pinned Node tools verified" "$out"

echo "tampering"
pkgjson="$p/$first/node_modules/@scope/beta/node_modules/dep/package.json"
cp "$pkgjson" "$tmp/dep.json"
printf '{"name":"dep","version":"9.9.9"}' > "$pkgjson"
run "$tmp/src" "$p" --check
equal "--check fails when an installed package drifts from the lock" 1 "$rc"
cp "$tmp/dep.json" "$pkgjson"
rm "$p/bin/beta"
run "$tmp/src" "$p" --check
equal "...or a command link is missing" 1 "$rc"
run "$tmp/src" "$p"
equal "a rerun republishes it" "../node-tools-current/node_modules/.bin/beta" "$(readlink "$p/bin/beta" 2>&1)"
equal "...without reinstalling" "" "$(cat "$FAKE_NPM_LOG")"

echo "refusals"
NODE_TOOLS_NODE_MAJOR=1 run "$tmp/src" "$tmp/p-node"
equal "a different Node major is refused" 1 "$rc"
check "...naming the one needed and the one found" "Node.js 1 is required to install the pinned Node tools (found" "$out"
equal "...creating nothing" "no" "$([[ -e "$tmp/p-node" ]] && echo yes || echo no)"
write_source "$tmp/src-pin" 4.5.6 1.2.4
run "$tmp/src-pin" "$tmp/p-pin"
equal "a package.json that disagrees with its lock is refused" 1 "$rc"
check "...with the way to fix it" "alpha: package.json pins 1.2.4, the lock has 1.2.3; regenerate it" "$out"
mkdir -p "$tmp/p-file/bin"
printf 'mine\n' > "$tmp/p-file/bin/alpha"
run "$tmp/src" "$tmp/p-file"
equal "a regular file where a command goes is refused" 1 "$rc"
check "...by name" "refusing non-symlink Node tool command: $tmp/p-file/bin/alpha" "$out"
equal "...and left as it was" "mine" "$(cat "$tmp/p-file/bin/alpha")"
equal "...before npm runs" "" "$(cat "$FAKE_NPM_LOG")"
FAKE_NPM_SKIP=maybe run "$tmp/src" "$tmp/p-maybe"
equal "an optional package npm left out (a failed optional install) is allowed" 0 "$rc"
FAKE_NPM_SKIP="$native" run "$tmp/src" "$tmp/p-native"
equal "an install missing this platform's package fails" 1 "$rc"
check "...naming it" "node_modules/$native: missing" "$out"
equal "...publishes nothing" "no" "$([[ -e "$tmp/p-native/node-tools-current" || -e "$tmp/p-native/bin/alpha" ]] && echo yes || echo no)"
equal "...and cleans up its staging directory" "" "$(cd "$tmp/p-native/node-tools-installs" && ls -A)"

echo "a new lock"
write_source "$tmp/src" 4.5.7
run "$tmp/src" "$p"
equal "a changed lock installs again" 0 "$rc"
check "...through npm" "ci --prefix" "$(cat "$FAKE_NPM_LOG")"
second="$(readlink "$p/node-tools-current")"
lacks "...into a new directory" "$first" "$second"
equal "...that the commands now run from" "@scope/beta 4.5.7" "$("$p/bin/beta" 2>&1)"
equal "...recording the one it replaced as the previous install" "$first" "$(readlink "$p/node-tools-previous")"
equal "the old install is kept: nothing is deleted without --prune" "yes" "$([[ -e "$p/$first" ]] && echo yes || echo no)"
check "...and the run counts it, with the space it holds" "1 older Node tool install(s) (" "$out"
check "...and says how to remove it" "install-node-tools.sh --prune removes those no running process uses" "$out"

echo "--prune"
run "$tmp/src" "$p" --prune
equal "--prune succeeds" 0 "$rc"
equal "...and keeps the previous install" "yes" "$([[ -e "$p/$first" ]] && echo yes || echo no)"
check "...saying so" "pruned 0 older Node tool install(s); kept the previous one" "$out"
write_source "$tmp/src" 4.5.8
run "$tmp/src" "$p"
third="$(readlink "$p/node-tools-current")"
equal "a plain run after another lock change still deletes nothing" "yes" "$([[ -e "$p/$first" ]] && echo yes || echo no)"
check "...counting both older installs" "2 older Node tool install(s) (" "$out"
run "$tmp/src" "$p" --prune
equal "--prune deletes an install older than the previous one" "no" "$([[ -e "$p/$first" ]] && echo yes || echo no)"
equal "...keeps the previous one" "yes" "$([[ -e "$p/$second" ]] && echo yes || echo no)"
equal "...and the current one" "yes" "$([[ -e "$p/$third" ]] && echo yes || echo no)"
check "...and says what it did" "pruned 1 older Node tool install(s); kept the previous one" "$out"
equal "...leaving two installs" "2" "$(find "$p/node-tools-installs" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"

echo "a running consumer"
# A stand-in for a tool still running: its argv holds PATH, as node's does for a CLI started
# through the published link (node resolves the link itself; ps shows the link). The `; :` keeps
# the shell from exec'ing sleep in its place (bash does, and so macOS's /bin/sh and newer dash),
# which would take PATH out of the process list a moment after it appeared.
consume() {  # consume PATH: start it, and wait until the process list shows it (a FAIL if never)
  bash -c 'sleep 120; :' "$1" & consumers+=("$!")
  local tries=0
  while (( tries++ < 25 )); do
    ps -A -ww -o command= | grep -qF -- "$1" && return 0
    sleep 0.2
  done
  bad "the consumer stand-in shows $1 in the process list" "a process whose argv holds it" \
    "$(ps -o command= -p "${consumers[${#consumers[@]}-1]}" 2>&1)"
}
stop_consumers() { local c; for c in "${consumers[@]}"; do kill "$c" 2>/dev/null; wait "$c" 2>/dev/null; done; consumers=(); }
step() {  # step PREFIX VERSION: install the tool set with beta at VERSION into PREFIX
  write_source "$tmp/s-$2" "$2"
  run "$tmp/s-$2" "$1"
}
# Three installs per case, so the oldest is neither current nor previous: only a consumer saves it.
q="$tmp/pq-link"
step "$q" 1.0.1
oldest="$(readlink "$q/node-tools-current")"
consume "$q/bin/beta"
step "$q" 1.0.2
step "$q" 1.0.3
run "$tmp/s-1.0.3" "$q" --prune
equal "--prune keeps an install a tool started through its published link may run" "yes" \
  "$([[ -e "$q/$oldest" ]] && echo yes || echo no)"
check "...saying so" "kept 1 a running process may still use" "$out"
stop_consumers
run "$tmp/s-1.0.3" "$q" --prune
equal "once that tool exits, --prune removes it" "no" "$([[ -e "$q/$oldest" ]] && echo yes || echo no)"

q="$tmp/pq-elsewhere"
step "$q" 2.0.1
oldest="$(readlink "$q/node-tools-current")"
ln -s "$q/$oldest/node_modules/@scope/beta/cli.js" "$tmp/beta-elsewhere"
consume "$tmp/beta-elsewhere"
step "$q" 2.0.2
step "$q" 2.0.3
run "$tmp/s-2.0.3" "$q" --prune
equal "--prune keeps an install a tool reached through another symlink runs" "yes" \
  "$([[ -e "$q/$oldest" ]] && echo yes || echo no)"
stop_consumers

# An alias of a published command (~/.local/bin/tool -> PREFIX/bin/tool): after the upgrade the
# alias resolves to the NEW install, so only the link it passes through can tell.
q="$tmp/pq-alias"
step "$q" 3.0.1
oldest="$(readlink "$q/node-tools-current")"
mkdir -p "$tmp/alias-bin"
ln -s "$q/bin/beta" "$tmp/alias-bin/beta"
consume "$tmp/alias-bin/beta"
step "$q" 3.0.2
step "$q" 3.0.3
run "$tmp/s-3.0.3" "$q" --prune
equal "--prune keeps an install a tool started through an alias of a published command may run" "yes" \
  "$([[ -e "$q/$oldest" ]] && echo yes || echo no)"
stop_consumers

# macOS lists processes with ps, whose command lines arrive as single strings: a prefix with a
# space in it (~/Library/Application Support/...) must still match. NODE_TOOLS_PROC_SOURCE=ps
# makes Linux read processes the macOS way.
if command -v lsof >/dev/null 2>&1; then
  q="$tmp/with space/pq"
  step "$q" 4.0.1
  oldest="$(readlink "$q/node-tools-current")"
  consume "$q/$oldest/node_modules/@scope/beta/cli.js"
  step "$q" 4.0.2
  step "$q" 4.0.3
  NODE_TOOLS_PROC_SOURCE="ps" run "$tmp/s-4.0.3" "$q" --prune
  equal "with ps, --prune keeps an install under a prefix with a space that a tool runs from" "yes" \
    "$([[ -e "$q/$oldest" ]] && echo yes || echo no)"
  stop_consumers
else
  ok "# SKIP lsof not installed (the ps listing pairs with it)"
fi

# A process list the check cannot read whole must stop --prune, not shrink what it sees. Fake
# lsofs: one prints more than node's default 1 MiB exec buffer before the line that matters (a
# working directory inside the oldest install), one fails (exit 2, not lsof's partial-list 1).
mkdir -p "$tmp/lsof-long" "$tmp/lsof-broken"
cat > "$tmp/lsof-long/lsof" <<'EOF'
#!/bin/sh
awk 'BEGIN { for (i = 0; i < 40000; i++) printf "p%d\nn/elsewhere/a/path/long/enough/to/fill/a/buffer/%d\n", i, i }'
printf 'p1\nn%s\n' "$FAKE_LSOF_CWD"
EOF
printf '#!/bin/sh\nprintf "p1\\nn/elsewhere\\n"\nexit 2\n' > "$tmp/lsof-broken/lsof"
chmod +x "$tmp/lsof-long/lsof" "$tmp/lsof-broken/lsof"
q="$tmp/pq-lsof"
step "$q" 5.0.1
oldest="$(readlink "$q/node-tools-current")"
step "$q" 5.0.2
step "$q" 5.0.3
FAKE_LSOF_CWD="$q/$oldest" PATH="$tmp/lsof-long:$PATH" NODE_TOOLS_PROC_SOURCE="ps" run "$tmp/s-5.0.3" "$q" --prune
equal "--prune reads a process list longer than 1 MiB to the end (a cwd there keeps the install)" "yes" \
  "$([[ -e "$q/$oldest" ]] && echo yes || echo no)"
PATH="$tmp/lsof-broken:$PATH" NODE_TOOLS_PROC_SOURCE="ps" run "$tmp/s-5.0.3" "$q" --prune
equal "--prune deletes nothing when lsof fails" "yes" "$([[ -e "$q/$oldest" ]] && echo yes || echo no)"
check "...saying why" "not pruning Node tool installs: could not list every running process" "$out"

echo "usage"
run "$tmp/src" "$p" --bogus
equal "an unknown flag is a usage error" 2 "$rc"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
