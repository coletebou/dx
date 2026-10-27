#!/usr/bin/env bash
# aliases.test.sh: the shell functions in base/aliases.sh that touch git, Claude Code and
# processes. `ignore` untracks exactly what a new rule ignores (gitignore semantics, not
# pathspecs), finds info/exclude in a linked worktree and a `~/` core.excludesFile; `yuc` keeps
# its arguments apart; the resume picker reads a choice in zsh; the orphan commands work with
# GNU and BSD ps, and the force-kill pass only touches the orphans it sent TERM to.
# Hermetic: zsh with a temp HOME, and fake claude, ps and pkill on PATH that only log.
#
#   bash scripts/tests/aliases.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
aliases="$root/base/aliases.sh"
if ! command -v zsh >/dev/null 2>&1; then
  echo "# SKIP zsh not installed"
  exit 0
fi
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset ANTHROPIC_MODEL CLAUDE_MAX_EFFORT_MODELS XDG_CONFIG_HOME
mkdir -p "$HOME" "$tmp/bin"

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# A fake claude that writes one argument per line, so joined arguments show.
printf '#!/bin/sh\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done > "%s"\n' "$tmp/claude.argv" > "$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH"
# zsh_in DIR CODE: run CODE in a non-interactive zsh with the aliases loaded.
zsh_in() { (cd "$1" && zsh -fc "source '$aliases'; $2" 2>&1); }
argv() { tr '\n' ' ' < "$tmp/claude.argv" 2>/dev/null; }

echo "ignore -r: a new rule untracks what it ignores, nothing else"
repo="$tmp/repo"
mkdir -p "$repo/src"
git -C "$repo" init -q -b master
touch "$repo/a.json" "$repo/src/b.json" "$repo/src/deep.md" "$repo/.gitignore"
git -C "$repo" add -A && git -C "$repo" commit -qm init
zsh_in "$repo" "ignore -r '/*.json'" >/dev/null
tracked="$(git -C "$repo" ls-files | tr '\n' ' ')"
lacks "an anchored /*.json untracks the root file" "a.json " " $tracked"
check "...but not src/b.json" "src/b.json" "$tracked"
zsh_in "$repo" "ignore -r deep.md" >/dev/null
lacks "a bare name untracks it at any depth" "src/deep.md" "$(git -C "$repo" ls-files)"

echo "ignore -l in a linked worktree"
git -C "$repo" worktree add -q "$tmp/wt" -b wt
out="$(zsh_in "$tmp/wt" "ignore -l scratch.log" </dev/null)"; rc=$?
equal "succeeds" 0 "$rc"
check "...writing the shared info/exclude" "scratch.log" "$(cat "$repo/.git/info/exclude" 2>&1)"
check "...so git ignores it in the worktree" "scratch.log" \
  "$(cd "$tmp/wt" && touch scratch.log && git check-ignore scratch.log 2>&1)"

echo "ignore -g with a ~/ core.excludesFile"
# shellcheck disable=SC2088  # the literal ~ is the point: git expands it, not the shell
git config --global core.excludesFile '~/.gitignore_global'
touch "$HOME/.gitignore_global"
mkdir -p "$tmp/cwd"
out="$(zsh_in "$tmp/cwd" "ignore -g '*.swp'" </dev/null)"; rc=$?
equal "succeeds" 0 "$rc"
check "...writing the file git reads" "*.swp" "$(cat "$HOME/.gitignore_global" 2>&1)"
equal "...and no literal ~ directory" "" "$(ls -A "$tmp/cwd")"

echo "yuc keeps its arguments apart"
zsh_in "$tmp" "yuc --model sonnet" >/dev/null
equal "flags reach claude as separate words" \
  "[--dangerously-skip-permissions] [--continue] [--model] [sonnet] " "$(argv)"
zsh_in "$tmp" "yuc" >/dev/null
equal "no arguments: no empty prompt" "[--dangerously-skip-permissions] [--continue] " "$(argv)"
zsh_in "$tmp" "yuc --model opus" >/dev/null
check "an Opus model still gets max effort" "[--effort=max]" "$(argv)"
zsh_in "$tmp" "yuc --model opus --effort high" >/dev/null
lacks "...unless the caller set an effort" "--effort=max" "$(argv)"
out="$(zsh_in "$tmp" 'yu; read -r x; print -r -- "left=[$x]"' <<<"keep")"
check "the effort probe never reads stdin (no settings files here)" "left=[keep]" "$out"

echo "the resume picker"
mkdir -p "$HOME/.claude/projects/-p1" "$HOME/.claude/projects/-p2"
touch "$HOME/.claude/projects/-p1/11111111-1111-4111-8111-1111111abcde.jsonl" \
      "$HOME/.claude/projects/-p2/22222222-2222-4222-8222-2222222abcde.jsonl"
out="$(zsh_in "$tmp" "cr abcde" <<<"2")"; rc=$?
equal "a numbered choice resumes" 0 "$rc"
check "...the session picked" "[--resume] [22222222-2222-4222-8222-2222222abcde]" "$(argv)"

echo "orphaned Claude processes"
# Fake ps: 101 is an orphan (no TTY, 10 min), 102 too young, 103 has a TTY, 104 is headless -p.
# FAKE_PS=bsd answers like macOS ps: no etimes field, "??" for no TTY.
cat > "$tmp/bin/ps" <<'EOF'
#!/bin/sh
if [ "${FAKE_PS:-}" = bsd ]; then
  case "$*" in
    *etimes*) echo "ps: etimes: keyword not found" >&2; exit 1 ;;
    "-eo pid,tty,args") printf '%s\n' "  PID TT ARGS" "101 ?? claude --dangerously-skip-permissions" ;;
  esac
fi
case "$*" in
  "-eo pid=,tty=,etimes=,args=")
    printf '%s\n' "101 ? 600 claude --dangerously-skip-permissions" "102 ? 60 claude --dangerously-skip-permissions" \
      "103 pts/1 900 claude --dangerously-skip-permissions" "104 ? 900 claude --dangerously-skip-permissions -p hi" ;;
  "-axo pid=,tty=,etime=,args=")
    printf '%s\n' "101 ?? 10:00 claude --dangerously-skip-permissions" "102 ?? 01:00 claude --dangerously-skip-permissions" \
      "103 ttys001 15:00 claude --dangerously-skip-permissions" "104 ?? 15:00 claude --dangerously-skip-permissions -p hi" ;;
  "-eo pid,tty,args")  # the shape older versions of these commands asked for
    printf '%s\n' "  PID TT ARGS" "101 ? claude --dangerously-skip-permissions" "102 ? claude --dangerously-skip-permissions" ;;
  "-o etimes= -p 101") echo 600 ;;
  "-o etimes= -p 102") echo 60 ;;
  "-o rss= -p "*) echo 204800 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/pkill"
chmod +x "$tmp/bin/ps" "$tmp/bin/pkill"
for os in linux-gnu darwin23; do
  [[ "$os" == darwin* ]] && export FAKE_PS=bsd || unset FAKE_PS
  out="$(zsh_in "$tmp" "OSTYPE=$os; claude-orphans")"
  check "$os: claude-orphans lists the orphan" "101 " "$out"
  lacks "$os: ...and only it" "102 " "$out"
done
unset FAKE_PS
# kill is a builtin; a function of the same name records the calls instead, and says 101
# and 102 are still alive, so the force-kill pass has something to consider.
out="$(zsh_in "$tmp" 'OSTYPE=linux-gnu; sleep() { :; }; kill() { print -r -- "kill $*"; [[ "$1" != -0 || "$2" == 10[12] ]]; }; claude-kill-orphans')"
check "claude-kill-orphans sends TERM to the orphan" "kill -TERM 101" "$out"
check "...force-kills it when it lingers" "kill -9 101" "$out"
lacks "...and never touches a session that was not an orphan" "102" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
