#!/usr/bin/env bash
# shellcheck disable=SC2088  # test labels name paths with a literal ~
# claude-backup.test.sh: claude-backup in a throwaway HOME. A backup lands in BACKUP_DIR (or the
# default) without debug/; --prune-days deletes exactly what --help says, after the backup; and
# nothing outside BACKUP_DIR and ~/.claude is touched. The real HOME is never used.
#
#   bash scripts/tests/claude-backup.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
backup_bin="$root/scripts/claude-backup"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
unset BACKUP_DIR
mkdir -p "$HOME" "$tmp/t"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

if ! command -v jq >/dev/null 2>&1; then echo "jq is required for this suite" >&2; exit 1; fi

# run [VAR=value...] ARGS...: claude-backup in the throwaway HOME, with nothing else of ours.
run() {
  local envs=()
  while [[ $# -gt 0 && "$1" == [A-Z]*=* ]]; do envs+=("$1"); shift; done
  out="$(cd "$tmp" && env -i HOME="$HOME" PATH="$PATH" TMPDIR="$tmp/t" LC_ALL=C ${envs[@]+"${envs[@]}"} \
    bash "$backup_bin" "$@" 2>&1)"
  rc=$?
}
# snap DIR: every path under DIR, with a checksum for each file.
snap() {
  (cd "$1" && find . -print | LC_ALL=C sort | while IFS= read -r p; do
    if [[ -f "$p" ]]; then printf '%s %s\n' "$p" "$(cksum < "$p")"; else printf '%s\n' "$p"; fi
  done)
}
# outside: everything in the scratch tree but ~/.claude and the backup directories.
outside() {
  (cd "$tmp" && find . \( -path ./home/.claude -o -path ./backups -o -path ./home/Archives -o -path ./t \) -prune -o -print \
    | LC_ALL=C sort | while IFS= read -r p; do
      if [[ -f "$p" ]]; then printf '%s %s\n' "$p" "$(cksum < "$p")"; else printf '%s\n' "$p"; fi
    done)
}
tars() { find "$1" -name 'claude-backup-*.tar.gz' 2>/dev/null | LC_ALL=C sort; }

# A ~/.claude with three sessions: OLD (an entry 40 days old), NEW (1 day), MIX (one of each).
OLD=aaaaaaaa-0000-4000-8000-000000000001
NEW=bbbbbbbb-0000-4000-8000-000000000002
MIX=cccccccc-0000-4000-8000-000000000003
now_ms="$(date +%s)000"
old_ms=$(( $(date +%s) - 40 * 86400 ))000
new_ms=$(( $(date +%s) - 86400 ))000
c="$HOME/.claude"
p="$c/projects/-home-someone-proj"
mkdir -p "$p/$OLD/subagents" "$p/$NEW" "$p/$MIX" "$c/file-history/$OLD" "$c/file-history/$NEW" \
  "$c/todos" "$c/plans" "$c/debug" "$HOME/notes/$OLD"
{
  printf '{"display":"old","timestamp":%s,"project":"/p","sessionId":"%s"}\n' "$old_ms" "$OLD"
  printf '{"display":"mix old","timestamp":%s,"project":"/p","sessionId":"%s"}\n' "$old_ms" "$MIX"
  printf '{"display":"new","timestamp":%s,"project":"/p","sessionId":"%s"}\n' "$new_ms" "$NEW"
  printf '{"display":"mix new","timestamp":%s,"project":"/p","sessionId":"%s"}\n' "$now_ms" "$MIX"
} > "$c/history.jsonl"
for s in "$OLD" "$NEW" "$MIX"; do printf '{"type":"user"}\n' > "$p/$s.jsonl"; done
printf 'sub\n' > "$p/$OLD/subagents/agent-1.jsonl"
printf 'n\n' > "$p/$NEW/tool.txt"
printf 'm\n' > "$p/$MIX/tool.txt"
printf 'v1\n' > "$c/file-history/$OLD/f@v1"
printf 'v1\n' > "$c/file-history/$NEW/f@v1"
printf '[]\n' > "$c/todos/$OLD-agent-$OLD.json"
printf '[]\n' > "$c/todos/$NEW-agent-$NEW.json"
printf '# plan\n' > "$c/plans/plan-$OLD.md"
printf '# plan\n' > "$c/plans/a-named-plan.md"
printf '{}\n' > "$c/settings.json"
printf 'log\n' > "$c/debug/latest.txt"
printf 'mine\n' > "$HOME/notes/$OLD.txt"
printf 'mine\n' > "$HOME/notes/$OLD/inside"

echo "usage"
run --help
equal "--help succeeds" 0 "$rc"
check "...names BACKUP_DIR" "BACKUP_DIR" "$out"
check "...says what --prune-days deletes from history.jsonl" "its entries older than N days, from ~/.claude/history.jsonl" "$out"
check "...from projects/ and file-history/" "directories named by its session id, under ~/.claude/projects/ and" "$out"
check "...from todos/ and plans/" "files whose names contain its session id, under ~/.claude/todos/ and" "$out"
check "...and what it keeps" "transcript files (projects/*/<id>.jsonl)" "$out"
run --bogus
equal "an unknown option fails" 1 "$rc"
equal "...creating nothing" "" "$(tars "$tmp")"

echo "a backup"
claude_before="$(snap "$c")" outside_before="$(outside)"
run BACKUP_DIR="$tmp/backups"
equal "a backup into BACKUP_DIR succeeds" 0 "$rc"
equal "...one archive there" 1 "$(tars "$tmp/backups" | wc -l | tr -d ' ')"
listing="$(tar -tzf "$(tars "$tmp/backups")" 2>&1)"
check "...holding history.jsonl" ".claude/history.jsonl" "$listing"
check "...and the sessions" ".claude/projects/-home-someone-proj/$OLD/subagents/agent-1.jsonl" "$listing"
lacks "...but not debug/" ".claude/debug" "$listing"
equal "~/.claude is unchanged" "$claude_before" "$(snap "$c")"
equal "nothing outside ~/.claude and BACKUP_DIR changed" "$outside_before" "$(outside)"
run
equal "without BACKUP_DIR it backs up to ~/Archives/claude-history" 1 "$(tars "$HOME/Archives/claude-history" | wc -l | tr -d ' ')"
run BACKUP_DIR="$c/backups"
equal "a BACKUP_DIR inside ~/.claude is refused" 1 "$rc"
equal "...before creating it" "$claude_before" "$(snap "$c")"
mkdir -p "$tmp/real-backups"
ln -s "$c" "$tmp/via-link"
run BACKUP_DIR="$tmp/via-link/sub"
equal "...also through a symlink" 1 "$rc"
rm -rf "$tmp/via-link" "$c/sub"

echo "a prune"
outside_before="$(outside)"
run BACKUP_DIR="$tmp/backups" --prune-days 30
equal "a prune succeeds" 0 "$rc"
check "...counting the two sessions with an old entry" "Found 2 old sessions to prune" "$out"
newest="$(tars "$tmp/backups" | tail -n 1)"
equal "...after a new backup" 2 "$(tars "$tmp/backups" | wc -l | tr -d ' ')"
check "...that holds what it then deleted" ".claude/file-history/$OLD/f@v1" "$(tar -tzf "$newest" 2>&1)"
# Exactly these went, nothing else in ~/.claude changed but history.jsonl.
expected="$(printf '%s\n' "$claude_before" | grep -v -e "^./projects/-home-someone-proj/$OLD\(/\| \|$\)" \
  -e "^./projects/-home-someone-proj/$MIX\(/\|$\)" -e "^./file-history/$OLD" -e "^./todos/$OLD-agent" \
  -e "^./plans/plan-$OLD" -e '^./history.jsonl ')"
actual="$(snap "$c" | grep -v '^./history.jsonl ')"
equal "...deleting exactly the old sessions' directories and files" "$expected" "$actual"
equal "...keeping every transcript file" 3 "$(find "$p" -maxdepth 1 -name '*.jsonl' | wc -l | tr -d ' ')"
equal "history.jsonl keeps only the entries newer than 30 days" $'new\nmix new' "$(jq -r .display "$c/history.jsonl")"
equal "nothing outside ~/.claude and BACKUP_DIR changed" "$outside_before" "$(outside)"
claude_before="$(snap "$c")"
run BACKUP_DIR="$tmp/backups" --prune-days 30
equal "a prune with nothing old succeeds" 0 "$rc"
check "...saying so" "No sessions older than 30 days" "$out"
lacks "...without an error" "syntax error" "$out"
equal "...changing nothing" "$claude_before" "$(snap "$c")"
mv "$c/history.jsonl" "$tmp/history.saved"
run BACKUP_DIR="$tmp/backups" --prune-days 0
check "without history.jsonl it skips the prune" "No history.jsonl found, skipping prune" "$out"
mv "$tmp/history.saved" "$c/history.jsonl"
equal "...deleting nothing" "$claude_before" "$(snap "$c")"

echo "--clear-debug"
run BACKUP_DIR="$tmp/backups" --clear-debug
equal "it succeeds" 0 "$rc"
equal "...debug/ is gone" "no" "$(if [[ -e "$c/debug" ]]; then echo yes; else echo no; fi)"
equal "...and nothing else changed" "$(printf '%s\n' "$claude_before" | grep -v '^./debug')" "$(snap "$c")"
equal "nothing outside ~/.claude and BACKUP_DIR changed" "$outside_before" "$(outside)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
