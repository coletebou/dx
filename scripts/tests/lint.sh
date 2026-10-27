#!/usr/bin/env bash
# lint.sh: the static checks CI runs, on every tracked file of each kind.
#   - ShellCheck (-x -S warning) on bash and sh: a bash/sh shebang, or a `# shellcheck shell=`
#     directive in a sourced library;
#   - `zsh -n` on zsh: a zsh shebang, the entry points, and the *.sh files zsh sources
#     (ShellCheck does not parse zsh);
#   - ruff (F, E9) on Python: *.py, or a python shebang;
#   - jq on every *.json.
# A missing tool is a failure, not a skip: CI installs them all.
#
#   bash scripts/tests/lint.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$root" || exit 1

sh_files=() zsh_files=() py_files=() json_files=()
while IFS= read -r -d '' f; do
  [[ -f "$f" && ! -L "$f" ]] || continue
  first="$(head -n 1 "$f" 2>/dev/null)"
  case "$f" in
    *.json) json_files+=("$f"); continue ;;
    *.py) py_files+=("$f"); continue ;;
  esac
  case "$first" in
    '#!'*zsh*) zsh_files+=("$f") ;;
    '#!'*python*) py_files+=("$f") ;;
    '#!'*bash*|'#!'*/sh|'#!'*' sh') sh_files+=("$f") ;;
    *)
      case "$f" in
        zshrc|zshenv|aliases|profile.*|zprofile.*) zsh_files+=("$f") ;;
        *.sh) if grep -q '^# shellcheck shell=' "$f"; then sh_files+=("$f"); else zsh_files+=("$f"); fi ;;
      esac ;;
  esac
done < <(git ls-files -z)

status=0
run() {  # run LABEL COMMAND...: report and remember a failure
  local label="$1"; shift
  if "$@"; then printf 'ok    %s\n' "$label"; else printf 'FAIL  %s\n' "$label"; status=1; fi
}
zsh_check() { local f bad=0; for f in "$@"; do zsh -n "$f" || { echo "  zsh -n: $f"; bad=1; }; done; return "$bad"; }
json_check() { local f bad=0; for f in "$@"; do jq empty "$f" || { echo "  jq: $f"; bad=1; }; done; return "$bad"; }

run "shellcheck: ${#sh_files[@]} bash/sh files" shellcheck -x -S warning "${sh_files[@]}"
run "zsh -n: ${#zsh_files[@]} zsh files" zsh_check "${zsh_files[@]}"
run "ruff: ${#py_files[@]} Python files" ruff check --select F,E9 --quiet "${py_files[@]}"
run "jq: ${#json_files[@]} JSON files" json_check "${json_files[@]}"
exit "$status"
