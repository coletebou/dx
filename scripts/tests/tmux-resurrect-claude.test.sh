#!/usr/bin/env bash
# tmux-resurrect-claude.test.sh: hermetic tests for scripts/tmux-resurrect-claude-save,
# scripts/tmux-resurrect-claude-restore and scripts/tmux-resurrect-autosave, on a private
# tmux server from lib/tmux-sandbox.sh. Fake `claude`, `yuma` and `codex` on PATH log their
# argv (`claude agents --json` prints a fixture), so no real agent or tmux server is touched.
#
#   bash scripts/tests/tmux-resurrect-claude.test.sh
set -uo pipefail

# shellcheck source=lib/tmux-sandbox.sh
. "$(cd "$(dirname "$0")" && pwd -P)/lib/tmux-sandbox.sh"
tsb_require_private_tmp || exit 1
for t in tmux jq; do
  command -v "$t" >/dev/null 2>&1 || { printf 'tmux-resurrect-claude.test.sh needs %s\n' "$t" >&2; exit 1; }
done
here="$(cd "$(dirname "$0")" && pwd -P)"
scripts="$(cd "$here/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/resurrect-test.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
tsb_init "$tmp" || { printf 'the tmux sandbox refused to start\n' >&2; rm -rf "$tmp"; exit 1; }
tsb_own resurrect
cleanup() { tsb_teardown; rm -rf "$tmp"; }
trap cleanup EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
until_true() { local d=$((SECONDS + $1)); shift; while (( SECONDS < d )); do "$@" && return 0; sleep 0.2; done; "$@"; }

export HOME="$tmp/home" LOG="$tmp/log" XDG_RUNTIME_DIR="$tmp/run"
mkdir -p "$HOME/.claude/projects" "$HOME/repo" "$HOME/other" "$HOME/.dotted" "$LOG" "$XDG_RUNTIME_DIR" "$tmp/bin"
unset CODEX_HOME

# A fake agent: `claude agents --json` prints $FAKE_AGENTS; anything else logs its argv
# (one file per run) and stays alive like a TUI until killed.
cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == agents ]]; then cat "${FAKE_AGENTS:-/dev/null}" 2>/dev/null || echo '[]'; exit 0; fi
printf '%s\n' "${0##*/} $*" >> "$LOG/launched"
sleep 600   # a child, not exec: the argv must stay a claude command line
EOF
chmod +x "$tmp/bin/claude"
ln -s claude "$tmp/bin/yuma"
ln -s claude "$tmp/bin/codex"
export PATH="$tmp/bin:$PATH"
U1=11111111-1111-4111-8111-111111111111 U2=22222222-2222-4222-8222-222222222222
U3=33333333-3333-4333-8333-333333333333 U4=44444444-4444-4444-8444-444444444444
U5=55555555-5555-4555-8555-555555555555 U6=66666666-6666-4666-8666-666666666666

tsb -f /dev/null new-session -d -s resurrect -n shell -x 200 -y 50 -c "$HOME/repo" 'sh'
tsb set -g default-shell /bin/sh

printf 'save: which conversation each pane holds, its launcher and its permission mode\n'
tsb new-window -d -t '=resurrect:' -n bypass -c "$HOME/repo" "exec claude --dangerously-skip-permissions --resume $U1"
tsb new-window -d -t '=resurrect:' -n plain -c "$HOME/repo" "exec claude --resume $U2"
tsb new-window -d -t '=resurrect:' -n mantle -c "$HOME/repo" "exec claude --settings $HOME/.dotfiles/base/claude/mantle.settings.json --resume $U3"
fresh_pane="$(tsb new-window -d -P -F '#{pane_pid}' -t '=resurrect:' -n fresh -c "$HOME/other" 'exec claude')"
# A plain shell in a repo with transcripts: it holds no agent, so it must not "restore" one.
enc="$(printf '%s' "$HOME/repo" | sed 's|[^A-Za-z0-9]|-|g')"
mkdir -p "$HOME/.claude/projects/$enc"
: > "$HOME/.claude/projects/$enc/$U5.jsonl"
# Neither --resume nor agents --json: the last-resort match by the newest transcript of its
# cwd. The cwd has a dot, which Claude Code encodes as "-" like every non-alphanumeric.
tsb new-window -d -t '=resurrect:' -n dotted -c "$HOME/.dotted" 'exec claude'
denc="$(printf '%s' "$HOME/.dotted" | sed 's|[^A-Za-z0-9]|-|g')"
mkdir -p "$HOME/.claude/projects/$denc"
: > "$HOME/.claude/projects/$denc/$U6.jsonl"
until_true 5 test "$(grep -c . "$LOG/launched" 2>/dev/null)" = 5
printf '[{"pid": %s, "sessionId": "%s", "cwd": "%s"}]\n' "$fresh_pane" "$U4" "$HOME/other" > "$tmp/agents.json"
FAKE_AGENTS="$tmp/agents.json" bash "$scripts/tmux-resurrect-claude-save"
tsv="$(cat "$HOME/.tmux/resurrect/claude-sessions.tsv")"
row() { awk -F'\t' -v u="$1" '$5 == u' <<<"$tsv"; }
equal "the --resume id, from argv, with bypass on" \
  "resurrect	1	0	$HOME/repo	$U1	argv	claude	1" "$(row "$U1")"
equal "a plain session records bypass off" "argv	claude	0" "$(row "$U2" | cut -f6-8)"
equal "a mantle.settings.json launch records yuma" "argv	yuma	0" "$(row "$U3" | cut -f6-8)"
equal "a fresh session is matched through claude agents --json" "agents-json	claude	0" "$(row "$U4" | cut -f6-8)"
equal "an idle shell never borrows a transcript from its cwd" "" "$(row "$U5")"
equal "a dotted cwd finds its newest transcript (the cwd-mtime fallback)" "cwd-mtime	claude	0" "$(row "$U6" | cut -f6-8)"
equal "one row per agent pane" 5 "$(grep -c . <<<"$tsv")"

printf 'restore: each row resumes with exactly the launch it had\n'
mkdir -p "$tmp/restore"
for w in r-bypass r-plain r-legacy r-mantle r-live r-busy r-codex; do
  tsb new-window -d -t '=resurrect:' -n "$w" -c "$HOME/repo" 'sh'
done
tsb new-window -d -t '=resurrect:' -n r-busy2 -c "$HOME/repo" "exec claude --resume $U2"
idx() { tsb display-message -p -t "=resurrect:=$1" '#{window_index}'; }
mkdir -p "$HOME/.codex/sessions"
printf 'model_provider = "amazon-bedrock"\n' > "$HOME/.codex/bedrock.config.toml"
{
  printf 'resurrect\t%s\t0\t%s\t%s\targv\tclaude\t1\n' "$(idx r-bypass)" "$HOME/repo" "$U1"
  printf 'resurrect\t%s\t0\t%s\t%s\targv\tclaude\t0\n' "$(idx r-plain)" "$HOME/repo" "$U2"
  printf 'resurrect\t%s\t0\t%s\t%s\targv\tclaude\n' "$(idx r-legacy)" "$HOME/repo" "$U3"
  printf 'resurrect\t%s\t0\t%s\t%s\targv\tyuma\t1\n' "$(idx r-mantle)" "$HOME/repo" "$U4"
  printf 'resurrect\t%s\t0\t%s\t%s\targv\tclaude\t0\n' "$(idx r-live)" "$HOME/repo" "$U5"
  printf 'resurrect\t%s\t0\t%s\t%s\targv\tclaude\t1\n' "$(idx r-busy2)" "$HOME/repo" "$U1"
  printf 'resurrect\t99\t0\t%s\t%s\targv\tclaude\t1\n' "$HOME/repo" "$U1"
} > "$HOME/.tmux/resurrect/claude-sessions.tsv"
printf 'resurrect\t%s\t0\t%s\t%s\topen-file\tamazon-bedrock\tbedrock\n' "$(idx r-codex)" "$HOME/repo" "$U2" \
  > "$HOME/.tmux/resurrect/codex-sessions.tsv"
printf '[{"pid": 1, "sessionId": "%s"}]\n' "$U5" > "$tmp/agents-live.json"
: > "$LOG/launched"
FAKE_AGENTS="$tmp/agents-live.json" bash "$scripts/tmux-resurrect-claude-restore"
until_true 10 test "$(grep -c . "$LOG/launched")" -ge 6
launched="$(cat "$LOG/launched")"
check "bypass=1 resumes with permission checks off" "claude --dangerously-skip-permissions --resume $U1" "$launched"
check "bypass=0 resumes plain" "claude --resume $U2" "$launched"
check "a legacy row (no bypass column) resumes plain" "claude --resume $U3" "$launched"
check "yuma rows go through yuma" "yuma --resume $U4" "$launched"
check "a codex row keeps its provider profile" "codex -p bedrock resume $U2" "$launched"
lacks "a session live elsewhere is not resumed twice" "--resume $U5" "$launched"
screen="$(tsb capture-pane -p -J -t "=resurrect:=r-live")"
check "it says where to pick it up instead" "previous claude session $U5 is still live elsewhere" "$screen"
equal "the busy pane and the missing pane got nothing" 1 "$(grep -c -- "--dangerously-skip-permissions --resume $U1" <<<"$launched")"

printf 'autosave: a backstop that stands down while a snapshot is fresh\n'
mkdir -p "$HOME/.tmux/plugins/tmux-resurrect/scripts"
cat > "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh" <<EOF
#!/usr/bin/env bash
mkdir -p "$HOME/.tmux/resurrect" && date > "$HOME/.tmux/resurrect/snap.txt" && ln -sf snap.txt "$HOME/.tmux/resurrect/last"
EOF
chmod +x "$HOME/.tmux/plugins/tmux-resurrect/scripts/save.sh"
rm -f "$HOME/.tmux/resurrect/last"
out="$(bash "$scripts/tmux-resurrect-autosave" 2>&1)"; code=$?
equal "the first run saves" 0 "$code"
check "says it saved" "save complete" "$out"
if [[ -e "$HOME/.tmux/resurrect/last" ]]; then ok "the snapshot exists"; else bad "snapshot" "present" "absent"; fi
out="$(bash "$scripts/tmux-resurrect-autosave" 2>&1)"
check "a fresh snapshot stands it down" "standing down" "$out"
out="$(TMUX_AUTOSAVE_FRESH_SECS=0 bash "$scripts/tmux-resurrect-autosave" 2>&1)"
check "an old snapshot saves again" "save complete" "$out"

printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
