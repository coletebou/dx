#!/usr/bin/env bash
# shellcheck disable=SC2088  # test labels name paths with a literal ~
# install.test.sh: install.sh into a throwaway HOME. A dry run changes nothing; a real run links
# every component, moves what it replaces into the backup with a change log, generates valid
# Claude Code settings, carries an existing git identity over, and a second run changes nothing.
# The opt-in manager component names the identity's OpenClaw manager overlay in Drover's settings.
# It refuses a foreign ~/.dotfiles and never writes into the checkout. Fake claude, launchctl and
# systemctl only log, so nothing real is registered or scheduled.
#
#   bash scripts/tests/install.test.sh            (INSTALL_BASH=/bin/bash to test another bash)
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
run_bash="${INSTALL_BASH:-bash}"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

mkdir -p "$tmp/bin"
for t in launchctl systemctl; do
  printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "%s"\nexit 0\n' "$t" "$tmp/calls" > "$tmp/bin/$t"
  chmod +x "$tmp/bin/$t"
done
# A fake claude whose `mcp get` knows what `mcp add-json` registered, per HOME, like the real one.
cat > "$tmp/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "claude \$*" >> "$tmp/calls"
reg="\$HOME/.fake-claude-mcp"
case "\$1 \$2" in
  "mcp get") grep -qx "\$3" "\$reg" 2>/dev/null ;;
  "mcp add-json") eval "n=\\\${\$((\$# - 1))}"; printf '%s\n' "\$n" >> "\$reg" ;;  # the name precedes the JSON
esac
EOF
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH" GIT_CONFIG_NOSYSTEM=1
unset XDG_CONFIG_HOME
newhome() { export HOME="$tmp/home$1"; mkdir -p "$HOME"; }
inst() { "$run_bash" "$root/install.sh" "$@" 2>&1; }
before_status="$(git -C "$root" status --porcelain)"

echo "usage"
newhome 0
out="$(inst)"; rc=$?
equal "no components is a usage error" 2 "$rc"
check "...that lists the components" "worktrees  wt-helper, pw" "$out"
out="$(inst --with bogus)"; rc=$?
equal "an unknown component is refused" 1 "$rc"
out="$(inst --all --identity nobody)"; rc=$?
equal "an unknown identity is refused" 1 "$rc"
check "...saying how to make one" "copy identities/example" "$out"

echo "dry run"
newhome 1
out="$(inst --all --dry-run)"; rc=$?
equal "a dry run succeeds" 0 "$rc"
check "...and says what it would do" "would link ~/.zshrc" "$out"
equal "...without touching HOME" "" "$(cd "$HOME" && find . -mindepth 1 | head -3)"

echo "a real install"
newhome 2
printf 'mine\n' > "$HOME/.zshrc"
printf '[user]\n\tname = Sam Example\n\temail = sam@example.com\n' > "$HOME/.gitconfig"
out="$(inst --all)"; rc=$?
equal "the install succeeds" 0 "$rc"
equal "~/.dotfiles points at the checkout" "$root" "$(readlink "$HOME/.dotfiles")"
equal "~/.zshrc is linked" "$root/zshrc" "$(readlink "$HOME/.zshrc")"
backup="$(ls -d "$HOME"/.dotfiles-backup/*/ 2>/dev/null | head -n 1)"
equal "the replaced ~/.zshrc is in the backup" "mine" "$(cat "${backup}.zshrc" 2>&1)"
check "...with a change log" '"action":"backup"' "$(cat "${backup}changes.jsonl" 2>&1)"
check "~/.df-profile names the identity and role" "export DF_IDENTITY=example" "$(cat "$HOME/.df-profile")"
check "...and the role" "export DF_ROLE=local" "$(cat "$HOME/.df-profile")"
equal "the generated settings are valid JSON with the statusline" "true" \
  "$(jq '.statusLine.command | test("statusline.sh")' "$HOME/.claude/settings.json" 2>&1)"
check "...and the base hooks" "load-memory-hook.sh" "$(jq -r '.hooks.SessionStart[].hooks[].command' "$HOME/.claude/settings.json" 2>&1)"
check "CLAUDE.md imports the base rules" "@~/.dotfiles/base/claude/CLAUDE.base.md" "$(cat "$HOME/.claude/CLAUDE.md")"
check "...and the identity's" "@~/.dotfiles/identities/example/claude/common.CLAUDE.md" "$(cat "$HOME/.claude/CLAUDE.md")"
equal "the merged MCP config is valid JSON" "object" "$(jq -r '.mcpServers | type' "$HOME/.claude/mcp.json" 2>&1)"
equal "git resolves the hooks path under ~/.dotfiles" "$HOME/.dotfiles/base/git/hooks" \
  "$(git config --global --path --get core.hooksPath 2>&1)"
# The way git reads it for a commit: all config files, includes followed (--global alone skips them).
equal "the old git identity was kept" "sam@example.com" "$(cd "$tmp" && git config --get user.email 2>&1)"
for b in pw pw-append stack-branches stack-claude wt-helper cc-park cc-handoff reflections dream tmux-archive autoreview-pair; do
  [[ -L "$HOME/.local/bin/$b" && -x "$HOME/.local/bin/$b" ]] || bad "~/.local/bin/$b is a working link" "a link" "$(ls -l "$HOME/.local/bin/$b" 2>&1)"
done
ok "the CLIs are linked into ~/.local/bin"
for s in cc-park fresh-session-handoff parallel-worktrees tmux-archive reflect codex-subagents mcp-agent-safety; do
  [[ -f "$HOME/.claude/skills/$s/SKILL.md" ]] || bad "skill $s is linked" "SKILL.md" "$(ls -l "$HOME/.claude/skills/$s" 2>&1)"
done
ok "the skills are linked into ~/.claude/skills"
lacks "schedules are not part of --all" "systemctl" "$(cat "$tmp/calls" 2>/dev/null)"
equal "the manager overlay setting is not part of --all" "absent" \
  "$([[ -e "$HOME/.config/drover/dx-openclaw-manager.env" ]] && echo present || echo absent)"

echo "idempotent"
out="$(inst --all)"; rc=$?
equal "a second run succeeds" 0 "$rc"
check "...and changes nothing" "Everything was already in place." "$out"
equal "...nor makes another backup" "1" "$(ls -d "$HOME"/.dotfiles-backup/*/ | wc -l | tr -d ' ')"

echo "the shell it sets up"
if command -v zsh >/dev/null 2>&1; then
  equal "a zsh reads the profile" "example local" "$(env -i HOME="$HOME" PATH="$PATH" zsh -c 'echo "$DF_IDENTITY $DF_ROLE"' 2>&1)"
else
  ok "# SKIP zsh not installed"
fi

echo "a foreign ~/.dotfiles"
newhome 3
mkdir -p "$HOME/.dotfiles"
out="$(inst --with shell)"; rc=$?
equal "is refused" 1 "$rc"
check "...with the way out" "--replace-dotfiles" "$out"
out="$(inst --with shell --replace-dotfiles)"; rc=$?
equal "--replace-dotfiles moves it into the backup" 0 "$rc"
equal "...and links the checkout" "$root" "$(readlink "$HOME/.dotfiles")"

echo "schedules"
newhome 4
out="$(inst --with schedules --dry-run)"; rc=$?
equal "a schedules dry run succeeds" 0 "$rc"
case "$(uname -s)" in
  Linux)  check "...naming the timers" "would enable the timers" "$out" ;;
  Darwin) check "...naming the agents" "would load com.cc-park-auto" "$out" ;;
  *)      ok "# SKIP no launchd or systemd" ;;
esac
equal "...writing nothing" "" "$(cd "$HOME" && find . -mindepth 1 | head -3)"

echo "the manager overlay"
newhome 10
out="$(inst --with manager --dry-run)"; rc=$?
equal "a manager dry run succeeds" 0 "$rc"
check "...naming the setting it would write" "would create ~/.config/drover/dx-openclaw-manager.env" "$out"
equal "...writing nothing" "" "$(cd "$HOME" && find . -mindepth 1 | head -3)"
out="$(inst --with manager)"; rc=$?
equal "the manager install succeeds" 0 "$rc"
equal "...naming the identity's overlay through ~/.dotfiles" \
  "DROVER_OPENCLAW_OVERLAY=~/.dotfiles/identities/example/openclaw-manager" \
  "$(grep -v '^#' "$HOME/.config/drover/dx-openclaw-manager.env" 2>&1)"
overlay="$HOME/.dotfiles/identities/example/openclaw-manager"
for f in profiles/mine.json roles/manager/role.json roles/manager/AGENTS.md roles/manager/MEMORY.md \
  workspace/SOUL.md workspace/USER.md; do
  [[ -f "$overlay/$f" ]] || bad "the overlay has $f" "a file" "$(ls -l "$overlay/$f" 2>&1)"
done
ok "...which resolves to the overlay's files"
equal "...whose role defaults to the overlay's profile" "mine" "$(jq -r .profile "$overlay/roles/manager/role.json" 2>&1)"
out="$(inst --with manager)"; rc=$?
check "a second manager run changes nothing" "Everything was already in place." "$out"
newhome 11
out="$(DROVER_CONFIG_DIR="$HOME/drover-config" inst --with manager)"; rc=$?
equal "DROVER_CONFIG_DIR moves the setting" "moved" \
  "$([[ -f "$HOME/drover-config/dx-openclaw-manager.env" && ! -e "$HOME/.config/drover" ]] && echo moved || echo "rc $rc: $out")"

echo "a git identity split across files"
newhome 5
printf '[user]\n\tname = Sam Example\n\temail = sam@example.com\n' > "$HOME/.gitconfig"
printf '[user]\n\tname = Local Name\n' > "$HOME/.gitconfig.local"
out="$(inst --with git)"; rc=$?
equal "the install succeeds" 0 "$rc"
equal "...keeps the name ~/.gitconfig.local already had" "Local Name" \
  "$(git config --file "$HOME/.gitconfig.local" --get-all user.name 2>&1)"
equal "...and carries the email it lacked" "sam@example.com" \
  "$(git config --file "$HOME/.gitconfig.local" --get user.email 2>&1)"

echo "a ~/.local/bin that links into the checkout"
# From a copy of the checkout, so a regression cannot damage the real one.
copy="$tmp/copy"
mkdir -p "$copy"
(cd "$root" && git ls-files -co --exclude-standard -z | xargs -0 tar -cf - 2>/dev/null) | tar -xf - -C "$copy"
newhome 6
mkdir -p "$HOME/.local"
ln -s "$copy/scripts" "$HOME/.local/bin"
out="$("$run_bash" "$copy/install.sh" --with worktrees 2>&1)"; rc=$?
equal "the install succeeds" 0 "$rc"
check "...says why it skips those links" "inside this checkout" "$out"
equal "...leaves the checkout's own script a file" "file" \
  "$([[ -f "$copy/scripts/wt-helper" && ! -L "$copy/scripts/wt-helper" ]] && echo file || ls -l "$copy/scripts/wt-helper" 2>&1)"
equal "...and links nothing into it" "" "$(find "$copy/scripts" -maxdepth 1 -type l | head -3)"

echo "github-kit"
newhome 7
target="$tmp/widgets"
git init -q "$target"
git -C "$target" remote add origin git@github.com:example/widgets.git
kit_files="$(cd "$root/github-kit" && find . -type f ! -name README.md ! -name sync-labels.sh | sed 's|^\./||' | LC_ALL=C sort)"
out="$(inst --with github-kit)"; rc=$?
equal "github-kit without --target is refused" 1 "$rc"
check "...saying what it needs" "github-kit needs --target DIR" "$out"
mkdir -p "$tmp/not-a-repo"
out="$(inst --with github-kit --target "$tmp/not-a-repo")"; rc=$?
equal "a --target outside a git repository is refused" 1 "$rc"
out="$(inst --with github-kit --target "$target" --dry-run)"; rc=$?
equal "a github-kit dry run succeeds" 0 "$rc"
check "...naming the files it would create" "would create $target/.github/workflows/pr-labels.yml" "$out"
equal "...one per kit file" "$(printf '%s\n' "$kit_files" | wc -l | tr -d ' ')" "$(printf '%s\n' "$out" | grep -c 'would create')"
equal "...writing nothing into the target" "" "$(cd "$target" && find . -mindepth 1 -not -path './.git' -not -path './.git/*' | head -3)"
equal "...nor into HOME (no ~/.dotfiles link for github-kit alone)" "" "$(cd "$HOME" && find . -mindepth 1 | head -3)"
mkdir -p "$target/.github"
printf 'mine\n' > "$target/.github/pull_request_template.md"
out="$(inst --with github-kit --target "$target/.github")"; rc=$?
equal "the kit installs, from a --target inside the repository" 0 "$rc"
missing="" differ=""
for f in $kit_files; do
  [ -f "$target/.github/$f" ] || { missing="$missing $f"; continue; }
  [ "$f" = ISSUE_TEMPLATE/config.yml ] || cmp -s "$root/github-kit/$f" "$target/.github/$f" || differ="$differ $f"
done
equal "...every kit file at its path under the repository's .github/" "" "$missing"
equal "...as an exact copy" "" "$differ"
equal "...but not the README or the label sync" "no no" \
  "$([ -e "$target/.github/README.md" ] && echo yes || echo no) $([ -e "$target/.github/sync-labels.sh" ] && echo yes || echo no)"
check "...with the security link filled from the origin" "url: https://github.com/example/widgets/security/policy" \
  "$(cat "$target/.github/ISSUE_TEMPLATE/config.yml" 2>&1)"
lacks "...and no placeholder left" "github.com/OWNER/REPO" "$(cat "$target/.github/ISSUE_TEMPLATE/config.yml" 2>&1)"
check "...saying how to sync the labels" "sync-labels.sh --repo example/widgets --dry-run" "$out"
backup="$(ls -d "$HOME"/.dotfiles-backup/*/ 2>/dev/null | head -n 1)"
equal "the replaced PR template is in the backup" "mine" "$(cat "${backup}abs$target/.github/pull_request_template.md" 2>&1)"
equal "~/.dotfiles is not linked for github-kit alone" "no" "$([ -e "$HOME/.dotfiles" ] || [ -L "$HOME/.dotfiles" ] && echo yes || echo no)"
out="$(inst --with github-kit --target "$target")"; rc=$?
equal "a second github-kit run succeeds" 0 "$rc"
check "...and changes nothing" "Everything was already in place." "$out"
plain="$tmp/plain"
git init -q "$plain"
out="$(inst --with github-kit --target "$plain")"; rc=$?
equal "a repository with no github.com origin gets the kit" 0 "$rc"
check "...told to fill the security link by hand" "replace OWNER/REPO in .github/ISSUE_TEMPLATE/config.yml" "$out"
out="$(inst --with shell --target "$target" --dry-run)"; rc=$?
check "--target without github-kit is ignored, said so" "--target is for github-kit" "$out"

echo "github-kit into this checkout"
# From a copy that is a git repository of its own, so a regression cannot write into the real one.
git init -q "$copy"
before="$(cd "$copy" && find .github -type f | LC_ALL=C sort | xargs cksum 2>&1)"
out="$("$run_bash" "$copy/install.sh" --with github-kit --target "$copy" 2>&1)"; rc=$?
equal "a --target that is the checkout itself succeeds" 0 "$rc"
check "...leaving it alone, said so" "is this checkout (or inside it); leaving it alone" "$out"
equal "...its .github/ unchanged" "$before" "$(cd "$copy" && find .github -type f | LC_ALL=C sort | xargs cksum 2>&1)"
echo "an identity without a manager overlay"
cp -R "$copy/identities/example" "$copy/identities/bare"
rm -rf "$copy/identities/bare/openclaw-manager"
newhome 9
out="$("$run_bash" "$copy/install.sh" --with manager --identity bare 2>&1)"; rc=$?
equal "the install succeeds" 0 "$rc"
check "...saying how to add one" "copy identities/example/openclaw-manager" "$out"
equal "...and writes no setting" "absent" "$([[ -e "$HOME/.config/drover" ]] && echo present || echo absent)"

echo "the checkout"
equal "nothing was written into the repo" "$before_status" "$(git -C "$root" status --porcelain)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
