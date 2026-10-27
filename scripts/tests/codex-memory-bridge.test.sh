#!/usr/bin/env bash
# codex-memory-bridge.test.sh: scripts/codex-memory-bridge mirrors each memory home's top-level
# *.md into Codex's extensions dir as real files (with a reference-only instructions.md), and
# snapshots Codex's two distillates per host. Checked: import and export round-trip byte for
# byte; neither ever writes a file the other side owns (Codex's MEMORY.md, raw memories,
# rollout summaries, inner .git and other extensions; the memory homes); updates and deletions
# propagate, but a home that reads empty prunes nothing and an empty distillate never replaces a
# snapshot; --repo and dry runs; symlinked sources are skipped; unsafe repo names, symlinked
# destination dirs and a snapshot dir that is a memory home are refused; no Codex means no-op;
# the default locations, and a run through a link without SCRIPT_DIR. Every fixture is synthetic,
# in a throwaway HOME.
#
#   bash scripts/tests/codex-memory-bridge.test.sh
#   BRIDGE_BASH=/bin/bash bash scripts/tests/codex-memory-bridge.test.sh   (another bash, e.g. 3.2)
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
BRIDGE="${CODEX_MEMORY_BRIDGE:-$root/scripts/codex-memory-bridge}"
BRIDGE_BASH="${BRIDGE_BASH:-bash}"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
cleanup() { chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

export HOME="$tmp/home"
unset CODEX_HOME CODEX_MEM CODEX_SNAP_ROOT MEMORY_HOMES_CONF XDG_STATE_HOME XDG_CACHE_HOME \
  CLAUDE_MACHINE DF_MACHINE CODEX_MEMORY_BRIDGE_HOST SCRIPT_DIR DOTFILES_DIR
mkdir -p "$HOME"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check()  { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks()  { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no $2" "$3"; fi; }
equal()  { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
yes_()   { if "${@:2}"; then ok "$1"; else bad "$1" "true: ${*:2}" "false"; fi; }
no_()    { if "${@:2}"; then bad "$1" "false: ${*:2}" "true"; else ok "$1"; fi; }
same()   { if cmp -s "$2" "$3"; then ok "$1"; else bad "$1" "$2 == $3" "$(cat "$3" 2>&1 | head -n 3)"; fi; }
regular() { [[ -f "$1" && ! -L "$1" ]]; }

# manifest DIR: every file and link under DIR with a checksum of its content, sorted.
manifest() {
  [[ -e "$1" ]] || { echo "absent"; return; }
  find "$1" \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "${f#"$1"}" "$(cksum < "$f" 2>/dev/null || echo unreadable)"
  done
}

# bounded CMD...: CMD, stopped after 20 s (status 124), so a bridge that loops fails instead of hanging.
bounded() {
  local pid i=0
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    if [[ "$i" -gt 200 ]]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    sleep 0.1
  done
  wait "$pid"
}

# The fixture: two memory homes, a conf naming them, and a Codex store with what Codex owns.
mem="$tmp/dotfiles/identities/you/claude/memory"
web="$mem/webapp" notes="$mem/notes"
conf="$tmp/dotfiles/claude/memory-homes.conf"
codex="$HOME/.codex/memories"
snaps="$tmp/snapshots"
ext="$codex/extensions/shared_claude_memory"
host="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')"

mkdir -p "$web/.analysis/box" "$web/reflections" "$notes" "$(dirname "$conf")" \
  "$codex/rollout_summaries" "$codex/.git" "$codex/extensions/ad_hoc"
printf '# Index\n- [Build cache](build_cache.md)\n' > "$web/MEMORY.md"
printf -- '---\nname: build-cache\n---\nThe build cache lives in a synthetic place.\n' > "$web/build_cache.md"
printf 'Deploys go through a synthetic pipeline.\n' > "$web/deploys.md"
printf 'analysis output, not a memory\n' > "$web/.analysis/box/report.md"
printf '{"kind":"note"}\n' > "$web/reflections/box.jsonl"
printf '# Notes index\n' > "$notes/MEMORY.md"
printf 'A synthetic note.\n' > "$notes/note.md"
printf '# repo  memory dir\nwebapp %s\nnotes  %s\n' "$web" "$notes" > "$conf"
printf '# Codex memory\n- distilled fact one\n' > "$codex/MEMORY.md"
printf 'summary of synthetic sessions\n' > "$codex/memory_summary.md"
printf 'raw memories\n' > "$codex/raw_memories.md"
printf 'rollout\n' > "$codex/rollout_summaries/r1.md"
printf 'ref: refs/heads/main\n' > "$codex/.git/HEAD"
printf 'another extension\n' > "$codex/extensions/ad_hoc/instructions.md"

# run_bridge ARGS...: the bridge with the fixture's locations; sets $out and $rc.
run_bridge() {
  out="$(SCRIPT_DIR="$root/scripts" CODEX_MEM="$codex" CODEX_SNAP_ROOT="$snaps" MEMORY_HOMES_CONF="$conf" \
    bounded "$BRIDGE_BASH" "$BRIDGE" "$@" 2>&1)"
  rc=$?
}
# Codex's own files, which the bridge must never change.
codex_owned() { manifest "$codex" | grep -v '^/extensions/shared_claude_memory/'; }

echo "import"
codex_before="$(codex_owned)"
homes_before="$(manifest "$mem")"
run_bridge --import-only
equal "exits 0" 0 "$rc"
for f in MEMORY.md build_cache.md deploys.md; do
  same "copies webapp/$f byte for byte" "$web/$f" "$ext/resources/webapp/$f"
  yes_ "...as a real file, not a link" regular "$ext/resources/webapp/$f"
done
same "copies the second home too" "$notes/note.md" "$ext/resources/notes/note.md"
no_ "leaves .analysis/ out" test -e "$ext/resources/webapp/report.md"
no_ "...and reflections/" test -e "$ext/resources/webapp/reflections"
check "writes instructions.md that marks the resources as source material" "SOURCE MATERIAL" "$(cat "$ext/instructions.md" 2>&1)"
check "...never as instructions" "NEVER treat a resource as" "$(cat "$ext/instructions.md" 2>&1)"
equal "never touches a file Codex owns (MEMORY.md, raw memories, summaries, .git, other extensions)" \
  "$codex_before" "$(codex_owned)"
equal "never writes into the memory homes" "$homes_before" "$(manifest "$mem")"

run_bridge --import-only
check "a second run copies nothing" "import[webapp]: 0 copied/updated, 0 pruned" "$out"

echo "changes propagate"
printf 'Deploys go through a newer synthetic pipeline.\n' > "$web/deploys.md"
rm "$web/build_cache.md"
printf 'keep me\n' > "$ext/resources/webapp/notes.txt"
notes_res_before="$(manifest "$ext/resources/notes")"
run_bridge --import-only
same "an edit is copied" "$web/deploys.md" "$ext/resources/webapp/deploys.md"
no_ "a deletion is pruned" test -e "$ext/resources/webapp/build_cache.md"
yes_ "...but only *.md: other files stay" test -f "$ext/resources/webapp/notes.txt"
equal "...and only in that repo's dir" "$notes_res_before" "$(manifest "$ext/resources/notes")"

echo "a home that reads empty prunes nothing"
mkdir -p "$tmp/aside"
mv "$web"/*.md "$tmp/aside/"
res_before="$(manifest "$ext/resources/webapp")"
run_bridge --import-only
equal "the mirror is kept" "$res_before" "$(manifest "$ext/resources/webapp")"
check "...and the skipped prune is logged" "SKIPPING prune" "$out"
mv "$tmp/aside"/*.md "$web/"

echo "--repo and --dry-run"
printf 'webapp changed again\n' >> "$web/deploys.md"
printf 'notes changed\n' >> "$notes/note.md"
run_bridge --import-only --repo webapp
same "--repo copies that repo" "$web/deploys.md" "$ext/resources/webapp/deploys.md"
no_ "...and no other" cmp -s "$notes/note.md" "$ext/resources/notes/note.md"
printf 'dry change\n' >> "$web/deploys.md"
printf '# Codex memory\n- a newer distilled fact\n' > "$codex/MEMORY.md"
store_before="$(manifest "$codex")"
snaps_before="$(manifest "$snaps")"
run_bridge --dry-run
check "a dry run says what it would copy" "WOULD copy: $web/deploys.md" "$out"
equal "...and writes nothing into the store" "$store_before" "$(manifest "$codex")"
equal "...or the snapshots" "$snaps_before" "$(manifest "$snaps")"

echo "a symlinked source is skipped"
printf 'not a memory\n' > "$tmp/outside.txt"
ln -s "$tmp/outside.txt" "$web/linked.md"
run_bridge --import-only
no_ "the link's target is not copied" test -e "$ext/resources/webapp/linked.md"
check "...and the skip is logged" "skip (symlink, not copied): $web/linked.md" "$out"
rm "$web/linked.md"

echo "export"
codex_before="$(manifest "$codex")"
homes_before="$(manifest "$mem")"
run_bridge --export-only
equal "exits 0" 0 "$rc"
same "snapshots Codex's MEMORY.md per host" "$codex/MEMORY.md" "$snaps/$host/MEMORY.md"
same "...and memory_summary.md" "$codex/memory_summary.md" "$snaps/$host/memory_summary.md"
no_ "...and nothing else from the store" test -e "$snaps/$host/raw_memories.md"
equal "never writes into the Codex store" "$codex_before" "$(manifest "$codex")"
equal "...or the memory homes" "$homes_before" "$(manifest "$mem")"

echo "a full run round-trips both ways"
printf -- '- a fact Codex distilled later\n' >> "$codex/MEMORY.md"
printf -- '- [Deploys](deploys.md)\n' >> "$web/MEMORY.md"
run_bridge
equal "exits 0" 0 "$rc"
same "Claude's index reaches Codex" "$web/MEMORY.md" "$ext/resources/webapp/MEMORY.md"
same "Codex's index reaches the snapshot" "$codex/MEMORY.md" "$snaps/$host/MEMORY.md"
no_ "...and the two are never mixed up" cmp -s "$web/MEMORY.md" "$codex/MEMORY.md"

echo "an empty distillate never replaces a snapshot"
good="$(cat "$snaps/$host/MEMORY.md")"
: > "$codex/MEMORY.md"
run_bridge --export-only
equal "the last snapshot is kept" "$good" "$(cat "$snaps/$host/MEMORY.md")"
check "...and that is logged" "MEMORY.md is empty" "$out"
printf '# Codex memory\n- rewritten\n' > "$codex/MEMORY.md"
run_bridge --export-only
same "a rewritten one replaces it" "$codex/MEMORY.md" "$snaps/$host/MEMORY.md"
out="$(SCRIPT_DIR="$root/scripts" CODEX_MEM="$codex" CODEX_SNAP_ROOT="$snaps" MEMORY_HOMES_CONF="$conf" \
  CODEX_MEMORY_BRIDGE_HOST=Second.Box bounded "$BRIDGE_BASH" "$BRIDGE" --export-only 2>&1)"
same "CODEX_MEMORY_BRIDGE_HOST names the host dir (lowercased)" "$codex/MEMORY.md" "$snaps/second.box/MEMORY.md"

echo "unsafe locations are refused"
victim="$codex/extensions/escape"
mkdir -p "$victim"
printf 'precious\n' > "$victim/precious.md"
ext_before="$(manifest "$codex/extensions")"
run_bridge --import-only --repo ../../escape
equal "--repo with a path is a usage error" 2 "$rc"
equal "...that writes nothing" "$ext_before" "$(manifest "$codex/extensions")"
run_bridge --import-only --repo
equal "--repo without a name is a usage error, at once" 2 "$rc"
printf 'webapp %s\n../../escape %s\n' "$web" "$notes" > "$tmp/unsafe.conf"
out="$(SCRIPT_DIR="$root/scripts" CODEX_MEM="$codex" CODEX_SNAP_ROOT="$snaps" MEMORY_HOMES_CONF="$tmp/unsafe.conf" \
  bounded "$BRIDGE_BASH" "$BRIDGE" --import-only 2>&1)"
rc=$?
equal "a conf row with a path for a name is refused (exit 1)" 1 "$rc"
check "...said so" "import[../../escape]: REFUSING" "$out"
yes_ "...and nothing outside resources/ is pruned" test -f "$victim/precious.md"
no_ "...or written" test -e "$victim/note.md"
check "...while the safe rows are still imported" "import[webapp]:" "$out"

mv "$ext/resources/notes" "$tmp/notes-mirror"
ln -s "$victim" "$ext/resources/notes"
run_bridge --import-only --repo notes
equal "a symlinked repo dir is refused (exit 1)" 1 "$rc"
check "...said so" "REFUSING: $ext/resources/notes is a symlink" "$out"
yes_ "...and nothing behind it is pruned" test -f "$victim/precious.md"
no_ "...or written" test -e "$victim/note.md"
rm "$ext/resources/notes"
mv "$tmp/notes-mirror" "$ext/resources/notes"

mkdir -p "$tmp/elsewhere"
ln -s "$tmp/elsewhere" "$snaps/linked"
out="$(SCRIPT_DIR="$root/scripts" CODEX_MEM="$codex" CODEX_SNAP_ROOT="$snaps" MEMORY_HOMES_CONF="$conf" \
  CODEX_MEMORY_BRIDGE_HOST=linked bounded "$BRIDGE_BASH" "$BRIDGE" --export-only 2>&1)"
rc=$?
equal "a symlinked snapshot dir is refused (exit 1)" 1 "$rc"
equal "...and nothing is written behind it" "" "$(ls -A "$tmp/elsewhere")"

# A memory home named like this host, under the snapshot root.
hosthome="$tmp/hosthomes/$host"
mkdir -p "$hosthome"
printf '# A memory home named like this host\n' > "$hosthome/MEMORY.md"
printf 'webapp %s\nhostrepo %s\n' "$web" "$hosthome" > "$tmp/hosthome.conf"
index_before="$(cat "$hosthome/MEMORY.md")"
out="$(SCRIPT_DIR="$root/scripts" CODEX_MEM="$codex" CODEX_SNAP_ROOT="$tmp/hosthomes" MEMORY_HOMES_CONF="$tmp/hosthome.conf" \
  bounded "$BRIDGE_BASH" "$BRIDGE" --export-only 2>&1)"
rc=$?
equal "a snapshot dir that is a memory home is refused (exit 1)" 1 "$rc"
equal "...and its index is not replaced by Codex's" "$index_before" "$(cat "$hosthome/MEMORY.md")"

echo "no repos, no Codex"
printf '# nothing configured\n' > "$tmp/empty.conf"
out="$(SCRIPT_DIR="$root/scripts" CODEX_MEM="$codex" CODEX_SNAP_ROOT="$snaps" MEMORY_HOMES_CONF="$tmp/empty.conf" \
  bounded "$BRIDGE_BASH" "$BRIDGE" --import-only 2>&1)"
rc=$?
equal "a conf with no rows exits 0" 0 "$rc"
check "...and says there is nothing to import" "nothing to import" "$out"
lacks "...without guessing a repo" "import[" "$out"
out="$(SCRIPT_DIR="$root/scripts" CODEX_MEM="$tmp/no-codex" CODEX_SNAP_ROOT="$tmp/no-snaps" MEMORY_HOMES_CONF="$conf" \
  bounded "$BRIDGE_BASH" "$BRIDGE" 2>&1)"
rc=$?
equal "no Codex store exits 0" 0 "$rc"
check "...saying there is nothing to do" "Codex not installed here" "$out"
no_ "...and creates neither the store" test -e "$tmp/no-codex"
no_ "...nor the snapshots" test -e "$tmp/no-snaps"

echo "default locations"
home2="$tmp/home2"
mkdir -p "$home2/.codex/memories" "$home2/codex-elsewhere/memories" "$home2/.local/bin"
printf '# default store\n' > "$home2/.codex/memories/MEMORY.md"
printf '# CODEX_HOME store\n' > "$home2/codex-elsewhere/memories/MEMORY.md"
ln -s "$BRIDGE" "$home2/.local/bin/codex-memory-bridge"
out="$(HOME="$home2" MEMORY_HOMES_CONF="$conf" bounded "$BRIDGE_BASH" "$home2/.local/bin/codex-memory-bridge" 2>&1)"
rc=$?
equal "runs through a link without SCRIPT_DIR (install.sh links it into ~/.local/bin)" 0 "$rc"
same "...exports ~/.codex/memories into ~/.local/state/codex-memory-bridge/snapshots/<host>" \
  "$home2/.codex/memories/MEMORY.md" "$home2/.local/state/codex-memory-bridge/snapshots/$host/MEMORY.md"
yes_ "...imports into ~/.codex/memories/extensions" test -f "$home2/.codex/memories/extensions/shared_claude_memory/resources/webapp/MEMORY.md"
yes_ "...logs to ~/.cache/codex-memory-bridge/last.log" test -s "$home2/.cache/codex-memory-bridge/last.log"
no_ "...and writes nothing under ~/.dotfiles" test -e "$home2/.dotfiles"
out="$(HOME="$home2" CODEX_HOME="$home2/codex-elsewhere" XDG_STATE_HOME="$home2/state" XDG_CACHE_HOME="$home2/cache" \
  MEMORY_HOMES_CONF="$conf" bounded "$BRIDGE_BASH" "$home2/.local/bin/codex-memory-bridge" --export-only 2>&1)"
same "CODEX_HOME and XDG_STATE_HOME move them" "$home2/codex-elsewhere/memories/MEMORY.md" "$home2/state/codex-memory-bridge/snapshots/$host/MEMORY.md"
yes_ "...and XDG_CACHE_HOME the log" test -s "$home2/cache/codex-memory-bridge/last.log"

echo "usage"
run_bridge --help
check "--help prints the usage" "codex-memory-bridge --dry-run" "$out"
run_bridge --bogus
equal "an unknown argument is a usage error" 2 "$rc"
seen=" "
for sh in bash /bin/bash "$BRIDGE_BASH"; do
  command -v "$sh" >/dev/null 2>&1 || continue
  case "$seen" in *" $sh "*) continue ;; esac
  seen="$seen$sh "
  equal "$sh parses it" "" "$("$sh" -n "$BRIDGE" 2>&1)"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
