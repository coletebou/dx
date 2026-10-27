#!/usr/bin/env bash
# install-node-tools.sh: install the pinned Node CLIs that node-tools/ lists (package.json, with
# every version pinned, and the committed package-lock.json) into one prefix, and publish their
# commands in its bin/.
#
#   scripts/install-node-tools.sh            install from the lock (or reuse a matching install), publish
#   scripts/install-node-tools.sh --check    verify only: exit 1 unless the published tools match the lock
#   scripts/install-node-tools.sh --prune    the same as a plain run, then remove older installs (below)
#
# NODE_TOOLS_PREFIX (default ~/.npm-global) holds node-tools-installs/<lock-sha256>-node-v<x.y.z>-<platform>/,
# node-tools-current (a link to the install in use), node-tools-previous (the one before it) and
# bin/<command> (links into the current one); put its bin/ on PATH. A changed lock or a different Node
# version gets a fresh install directory, published with an atomic rename. Installs run `npm ci`:
# exactly the locked versions, nothing newer, with npm's usual install scripts.
#
# Older installs are never deleted on their own: a tool that is still running may need its files,
# and whether one is can only be guessed. A plain run says how many there are and how much space
# they hold. --prune keeps the current and the previous install, and deletes an older one only
# when a best-effort look at the running processes finds nothing that may use it.
#
# Needs Node NODE_TOOLS_NODE_MAJOR (default 24) and npm. To change the tools, edit
# node-tools/package.json, run `npm install --package-lock-only --ignore-scripts` in node-tools/,
# and commit both files. NODE_TOOLS_SOURCE names another directory holding the two files.
set -euo pipefail

DOTFILES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE_DIR="${NODE_TOOLS_SOURCE:-$DOTFILES_DIR/node-tools}"
PREFIX="${NODE_TOOLS_PREFIX:-$HOME/.npm-global}"
INSTALL_ROOT="$PREFIX/node-tools-installs"
TARGET="$PREFIX/node-tools-current"
PREVIOUS="$PREFIX/node-tools-previous"
BIN_DIR="$PREFIX/bin"
NODE_MAJOR="${NODE_TOOLS_NODE_MAJOR:-24}"
CHECK_ONLY=0
PRUNE=0

usage() { printf 'usage: %s [--check | --prune]\n' "${0##*/}" >&2; exit 2; }
case "${1:-}" in
    "") [[ $# -eq 0 ]] || usage ;;
    --check) [[ $# -eq 1 ]] || usage; CHECK_ONLY=1 ;;
    --prune) [[ $# -eq 1 ]] || usage; PRUNE=1 ;;
    *) usage ;;
esac

[[ -f "$SOURCE_DIR/package.json" && -f "$SOURCE_DIR/package-lock.json" ]] || {
    printf 'node tool manifests are missing under %s\n' "$SOURCE_DIR" >&2
    exit 1
}
command -v node >/dev/null 2>&1 || {
    printf 'Node.js %s is required to install the pinned Node tools\n' "$NODE_MAJOR" >&2
    exit 1
}
NODE_VERSION=$(node -p 'process.versions.node')
[[ "${NODE_VERSION%%.*}" == "$NODE_MAJOR" ]] || {
    printf 'Node.js %s is required to install the pinned Node tools (found %s)\n' "$NODE_MAJOR" "$NODE_VERSION" >&2
    exit 1
}
command -v npm >/dev/null 2>&1 || {
    printf 'npm is required to install the pinned Node tools\n' >&2
    exit 1
}

PLATFORM_ID=$(node -p '`${process.platform}-${process.arch}`')
case "$PLATFORM_ID" in
    linux-x64|linux-arm64|darwin-x64|darwin-arm64) ;;
    *)
        printf 'unsupported Node tool platform: %s\n' "$PLATFORM_ID" >&2
        exit 1
        ;;
esac
RUNTIME_ID="node-v${NODE_VERSION}-${PLATFORM_ID}"

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# The manifest, from the lock: every top-level dependency pinned to exactly the version the lock
# holds (a package.json edited without regenerating the lock is refused), and the commands
# ("bin") they publish, one per line.
bins_text=$(node - "$SOURCE_DIR" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const dir = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
const lock = JSON.parse(fs.readFileSync(path.join(dir, "package-lock.json"), "utf8"));
const deps = pkg.dependencies || {};
const bins = new Set();
for (const [name, want] of Object.entries(deps)) {
  const entry = (lock.packages || {})[`node_modules/${name}`];
  if (!entry || entry.version !== want) {
    console.error(`${name}: package.json pins ${want}, the lock has ${entry ? entry.version : "nothing"}; ` +
      "regenerate it with npm install --package-lock-only --ignore-scripts");
    process.exit(1);
  }
  const bin = entry.bin || {};
  for (const cmd of typeof bin === "string" ? [name.split("/").pop()] : Object.keys(bin)) bins.add(cmd);
}
if (bins.size === 0) { console.error("the pinned packages publish no commands"); process.exit(1); }
process.stdout.write([...bins].sort().join("\n") + "\n");
NODE
)
bins=()
while IFS= read -r b; do
    case "$b" in ""|*/*|.*) printf 'refusing odd command name from the lock: %s\n' "$b" >&2; exit 1 ;; esac
    bins+=("$b")
done <<<"$bins_text"

source_hash=$(hash_file "$SOURCE_DIR/package-lock.json")
install_name="${source_hash}-${RUNTIME_ID}"
install_dir="$INSTALL_ROOT/$install_name"
install_link="node-tools-installs/$install_name"

# An install is good when it holds this exact lock and runtime, every command, every locked
# package at its locked version, and every platform package the lock lists for this machine.
# npm skips other platforms' packages and everything below them, and may leave out an optional
# package that failed to install: those may be absent, but a platform package for this machine
# (an optional entry with os/cpu, such as a native binary) may not.
verify_node_tools() {
    local root="$1" bin
    [[ -d "$root" ]] || return 1
    [[ -f "$root/package-lock.json" && ! -L "$root/package-lock.json" ]] || return 1
    [[ "$(hash_file "$root/package-lock.json")" == "$source_hash" ]] || return 1
    [[ -f "$root/.node-tools-runtime" && ! -L "$root/.node-tools-runtime" ]] || return 1
    [[ "$(< "$root/.node-tools-runtime")" == "$RUNTIME_ID" ]] || return 1
    for bin in "${bins[@]}"; do
        [[ -x "$root/node_modules/.bin/$bin" ]] || return 1
    done
    node - "$root" <<'NODE' || return 1
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const lock = JSON.parse(fs.readFileSync(path.join(root, "package-lock.json"), "utf8"));
const libc = process.platform !== "linux" ? null
  : (process.report && process.report.getReport().header.glibcVersionRuntime ? "glibc" : "musl");
const absent = new Set();  // entries npm may leave out, and so everything nested below them
const entries = Object.entries(lock.packages || {})
  .filter(([rel, entry]) => rel.startsWith("node_modules/") && !entry.dev && !entry.link)
  .sort(([a], [b]) => a.split("/node_modules/").length - b.split("/node_modules/").length);
for (const [rel, entry] of entries) {
  const parts = rel.split("/node_modules/");
  if (parts.slice(1).some((_, i) => absent.has(parts.slice(0, i + 1).join("/node_modules/")))) {
    absent.add(rel);
    continue;
  }
  const forHere = (!entry.os || entry.os.includes(process.platform))
    && (!entry.cpu || entry.cpu.includes(process.arch))
    && (!entry.libc || !libc || entry.libc.includes(libc));
  if (!forHere) { absent.add(rel); continue; }  // another platform's package
  const targeted = Boolean(entry.os || entry.cpu || entry.libc);
  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(path.join(root, rel, "package.json"), "utf8"));
  } catch {
    if ((entry.optional || entry.devOptional) && !targeted) { absent.add(rel); continue; }
    throw new Error(`${rel}: missing (the lock pins ${entry.version})`);
  }
  if (manifest.version !== entry.version) {
    throw new Error(`${rel}: expected ${entry.version}, found ${manifest.version}`);
  }
}
NODE
}

target_link_is_safe() {
    local link
    [[ -L "$TARGET" ]] || return 1
    link=$(readlink "$TARGET") || return 1
    [[ "$link" == "$install_link" ]]
}

current_payload_ready() {
    target_link_is_safe && verify_node_tools "$TARGET"
}

published_links_ready() {
    local bin expected
    for bin in "${bins[@]}"; do
        expected="../node-tools-current/node_modules/.bin/$bin"
        [[ -L "$BIN_DIR/$bin" ]] \
            && [[ "$(readlink "$BIN_DIR/$bin")" == "$expected" ]] \
            && [[ -x "$BIN_DIR/$bin" ]] \
            || return 1
    done
}

installation_ready() {
    current_payload_ready && published_links_ready
}

# Replace DESTINATION with a symlink in one rename, so no reader ever sees it missing.
atomic_symlink() {
    local link_value="$1" destination="$2" staged_link
    if [[ -e "$destination" && ! -L "$destination" ]]; then
        printf 'refusing non-symlink Node tool publication target: %s\n' "$destination" >&2
        return 1
    fi
    staged_link="${destination}.stage.$$"
    [[ ! -e "$staged_link" && ! -L "$staged_link" ]] || return 1
    ln -s "$link_value" "$staged_link"
    if ! node -e 'require("node:fs").renameSync(process.argv[1], process.argv[2])' "$staged_link" "$destination"; then
        rm -f "$staged_link"
        return 1
    fi
}

delete_owned_path() {
    local path="$1"
    if [[ -d "$path" && ! -L "$path" ]]; then
        find "$path" -depth -delete
    elif [[ -e "$path" || -L "$path" ]]; then
        rm -f -- "$path"
    fi
}

# The installs a running process may still use, one per line, or "*" for all of them. A process
# uses an install when an argument names a path inside it (directly, or through another symlink:
# realpath), or its working directory or executable is inside it (a running Codex, for instance,
# starts helpers from its own bundle). A process started through the published commands or
# node-tools-current may use ANY older install: node resolves bin/<cmd> when the process starts,
# and the links have pointed elsewhere since, so the link path in its argv no longer tells which.
# Fails when the processes cannot be listed.
installs_in_use() {
    # The paths go in the environment: in argv, this helper would count as a process using them.
    NT_ROOT="$INSTALL_ROOT" NT_BIN="$BIN_DIR" NT_TARGET="$TARGET" node - <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");
const { NT_ROOT: root, NT_BIN: binDir, NT_TARGET: target } = process.env;
const real = (p) => { try { return fs.realpathSync(p); } catch { return null; } };
const installs = fs.readdirSync(root).filter((n) => !n.startsWith(".")).map((n) => path.join(root, n));
const homes = installs.map((i) => [i, real(i) || i]);
const argvs = [], places = [];
if (fs.existsSync("/proc/self/cmdline")) {  // Linux: exact argv, cwd and executable per process
  for (const pid of fs.readdirSync("/proc").filter((n) => /^\d+$/.test(n))) {
    try { argvs.push(fs.readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0")); } catch {}
    for (const link of ["cwd", "exe"]) { try { places.push(fs.readlinkSync(`/proc/${pid}/${link}`)); } catch {} }
  }
} else {  // macOS: ps for argv (split on spaces), lsof for working directories and executables
  for (const line of execFileSync("ps", ["-A", "-ww", "-o", "command="], { encoding: "utf8" }).split("\n")) {
    argvs.push(line.trim().split(/\s+/));
  }
  let out;
  try {
    out = execFileSync("lsof", ["-nP", "-F", "n", "-d", "cwd,txt"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch (e) {
    if (!e.stdout) throw e;  // lsof exits 1 when some processes are unreadable, but still lists the rest
    out = String(e.stdout);
  }
  for (const line of out.split("\n")) if (line.startsWith("n")) places.push(line.slice(1));
}
const inside = (p, dir) => p === dir || p.startsWith(dir + "/");
const binReal = real(binDir) || binDir, targetReal = real(target) || target;
const published = (p) => inside(p, binDir) || inside(p, target) || inside(p, binReal) || inside(p, targetReal);
const used = new Set();
let all = false;
// Follow a path's symlinks one link at a time: an alias such as ~/.local/bin/tool -> PREFIX/bin/tool
// passes through a published link on the way, though its realpath now ends in the new install.
function walk(start) {
  let p = start;
  for (let hop = 0; hop < 40 && p; hop++) {
    const dir = real(path.dirname(p));
    const here = dir ? path.join(dir, path.basename(p)) : p;  // the link's own physical place
    if (published(p) || published(here)) all = true;
    for (const [i, ir] of homes) if (inside(p, i) || inside(here, ir)) used.add(i);
    let next;
    try { next = fs.readlinkSync(p); } catch { break; }  // not a symlink (or gone): the chain ends
    p = path.resolve(dir || path.dirname(p), next);
  }
  const r = real(start);
  for (const [i, ir] of homes) if (r && inside(r, ir)) used.add(i);
}
for (const argv of argvs) {
  for (const arg of argv) {
    for (const tok of arg.split("=")) {  // --require=/path and the like
      if (tok.startsWith("/")) walk(tok);
    }
  }
}
for (const p of places) for (const [i, ir] of homes) if (inside(p, i) || inside(p, ir)) used.add(i);
process.stdout.write(all ? "*\n" : [...used].map((i) => i + "\n").join(""));
NODE
}

# The install directories other than the current one, one per line.
older_installs() {
    local candidate
    for candidate in "$INSTALL_ROOT"/*; do
        [[ -d "$candidate" && ! -L "$candidate" && "$candidate" != "$install_dir" ]] || continue
        [[ "${candidate##*/}" =~ ^[0-9a-f]{64}-node-v[0-9]+\.[0-9]+\.[0-9]+-(linux|darwin)-(x64|arm64)$ ]] || continue
        printf '%s\n' "$candidate"
    done
}

# The install that was current before this one: node-tools-previous, else (installs from before
# that link existed) the most recently modified older install.
previous_install() {
    local link newest="" candidate
    if link=$(readlink "$PREVIOUS" 2>/dev/null) && [[ "$PREFIX/$link" != "$install_dir" && -d "$PREFIX/$link" ]]; then
        printf '%s\n' "$PREFIX/$link"
        return 0
    fi
    while IFS= read -r candidate; do
        [[ -z "$newest" || "$candidate" -nt "$newest" ]] && newest="$candidate"
    done < <(older_installs)
    [[ -z "$newest" ]] || printf '%s\n' "$newest"
}

# --prune: delete the older installs that are neither the previous one nor possibly in use. When
# the processes cannot be listed completely, nothing is deleted.
prune_obsolete_node_tools() {
    local candidate previous in_use kept=0 removed=0
    previous=$(previous_install)
    if ! in_use=$(installs_in_use 2>/dev/null); then
        printf 'not pruning Node tool installs: could not list every running process\n' >&2
        return 0
    fi
    while IFS= read -r candidate; do
        [[ -n "$candidate" && "$candidate" != "$previous" ]] || continue
        if [[ "$in_use" == "*" ]] || grep -qxF -- "$candidate" <<<"$in_use"; then
            kept=$((kept + 1))
            continue
        fi
        delete_owned_path "$candidate"
        removed=$((removed + 1))
    done < <(older_installs)
    printf 'pruned %d older Node tool install(s)' "$removed"
    [[ -z "$previous" ]] || printf '; kept the previous one'
    (( kept == 0 )) || printf '; kept %d a running process may still use' "$kept"
    printf '\n'
}

# One line about the older installs left, when there are any.
report_older_installs() {
    local n kib
    n=$(older_installs | grep -c . || true)
    (( n > 0 )) || return 0
    kib=$(older_installs | tr '\n' '\0' | xargs -0 du -sk 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')
    printf '%d older Node tool install(s) (%d MB) under %s; %s --prune removes those no running process uses\n' \
        "$n" "$(( (kib + 1023) / 1024 ))" "$INSTALL_ROOT" "${0##*/}"
}

if (( CHECK_ONLY == 1 )); then
    installation_ready || {
        printf 'published Node tools do not match the lock and platform %s\n' "$PLATFORM_ID" >&2
        exit 1
    }
    printf 'Pinned Node tools verified under %s\n' "$TARGET"
    exit 0
fi

mkdir -p "$PREFIX" "$INSTALL_ROOT" "$BIN_DIR"
if [[ -e "$TARGET" && ! -L "$TARGET" ]]; then
    printf 'refusing non-symlink Node tool current target: %s\n' "$TARGET" >&2
    exit 1
fi
for bin in "${bins[@]}"; do
    if [[ -e "$BIN_DIR/$bin" && ! -L "$BIN_DIR/$bin" ]]; then
        printf 'refusing non-symlink Node tool command: %s\n' "$BIN_DIR/$bin" >&2
        exit 1
    fi
done

if ! current_payload_ready >/dev/null 2>&1; then
    if ! verify_node_tools "$install_dir" >/dev/null 2>&1; then
        if [[ -e "$install_dir" || -L "$install_dir" ]]; then
            printf 'refusing invalid deterministic Node tool install: %s\n' "$install_dir" >&2
            exit 1
        fi

        stage=$(mktemp -d "$INSTALL_ROOT/.stage.XXXXXX")
        cleanup() {
            [[ -z "${stage:-}" || ! -d "$stage" ]] || find "$stage" -depth -delete
        }
        trap cleanup EXIT

        cp "$SOURCE_DIR/package.json" "$SOURCE_DIR/package-lock.json" "$stage/"
        npm ci --prefix "$stage" --omit=dev --no-audit --no-fund
        printf '%s\n' "$RUNTIME_ID" > "$stage/.node-tools-runtime"
        verify_node_tools "$stage" || {
            printf 'the fresh Node tool install does not match the lock\n' >&2
            exit 1
        }

        if node -e 'require("node:fs").renameSync(process.argv[1], process.argv[2])' "$stage" "$install_dir"; then
            stage=""
        elif verify_node_tools "$install_dir" >/dev/null 2>&1; then
            find "$stage" -depth -delete  # a concurrent run published the same install first
            stage=""
        else
            printf 'could not publish deterministic Node tool install: %s\n' "$install_dir" >&2
            exit 1
        fi
    fi
    # The install being replaced becomes the previous one, which --prune always keeps.
    if current_link=$(readlink "$TARGET" 2>/dev/null) && [[ "$current_link" != "$install_link" ]]; then
        atomic_symlink "$current_link" "$PREVIOUS"
    fi
    atomic_symlink "$install_link" "$TARGET"
    trap - EXIT
fi

for bin in "${bins[@]}"; do
    atomic_symlink "../node-tools-current/node_modules/.bin/$bin" "$BIN_DIR/$bin"
done

installation_ready || {
    printf 'Node tool publication failed validation\n' >&2
    exit 1
}
(( PRUNE == 0 )) || prune_obsolete_node_tools
report_older_installs
printf 'Pinned Node tools ready under %s\n' "$TARGET"
