#!/usr/bin/env bash
# shipped-but-open.test.sh: the toolbox plugin's sweep against a fake glab that records every
# call and serves canned GitLab JSON. A merged MR whose branch is "<issue>-..." or whose title or
# description closes the issue with a GitLab closing keyword is STRONG; a merged MR that only
# mentions it (or closes #1040 next to #104) is WEAK; open-only and MR-less issues are not listed.
# Paginated pages are merged, the project comes from `glab repo view` unless PROJECT names one,
# a username argument picks the assignee, a failed lookup is reported and fails the run, PARALLEL
# gives the same answer, and every call is a GET: nothing is closed, commented or labelled.
#
#   bash scripts/tests/shipped-but-open.test.sh
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
sweep="$root/plugins/toolbox/skills/shipped-but-open/scripts/sweep.sh"
command -v jq >/dev/null 2>&1 || { printf 'shipped-but-open.test.sh needs jq\n' >&2; exit 1; }
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# ── the fake glab ─────────────────────────────────────────────────────────────────────────────
fx="$tmp/fixtures"
mkdir -p "$tmp/bin" "$fx"
cat > "$tmp/bin/glab" <<'EOF'
#!/usr/bin/env bash
# Records argv (one call per line, arguments separated by " | "), then answers from $FAKE_FX.
{ printf '%s' "$1"; for a in "${@:2}"; do printf ' | %s' "$a"; done; printf '\n'; } >> "$FAKE_CALLS"
if [[ "$1 ${2:-}" == "repo view" ]]; then
  [[ -z "${FAKE_NO_REPO:-}" ]] || { echo "not a git repository" >&2; exit 1; }
  echo '{"id": 1, "path_with_namespace": "acme/widgets"}'; exit 0
fi
[[ "$1" == api ]] || { echo "fake glab: unexpected command $1" >&2; exit 2; }
endpoint="${@: -1}"
case "$endpoint" in
  user) echo '{"id": 7, "username": "me"}' ;;
  users\?username=sam) echo '[{"id": 9, "username": "sam"}]' ;;
  users\?username=*) echo '[]' ;;
  projects/*/issues\?state=opened*) cat "$FAKE_FX/issues.json" ;;
  projects/*/issues/*/related_merge_requests*)
    iid="${endpoint#*/issues/}"; iid="${iid%%/*}"
    [[ "$iid" != "${FAKE_FAIL_IID:-none}" ]] || { echo "504 Gateway Timeout" >&2; exit 1; }
    if [[ -f "$FAKE_FX/related-$iid.json" ]]; then cat "$FAKE_FX/related-$iid.json"; else echo '[]'; fi ;;
  *) echo "fake glab: unexpected endpoint $endpoint" >&2; exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/glab"

mr() {  # mr IID STATE BRANCH TITLE DESCRIPTION: one MR object
  jq -cn --argjson iid "$1" --arg s "$2" --arg b "$3" --arg t "$4" --arg d "$5" \
    '{iid: $iid, state: $s, source_branch: $b, title: $t, description: $d}'
}
{
  echo '['
  for i in 101 102 103 104 105 106 107; do
    printf '{"iid": %s, "title": "issue %s"}' "$i" "$i"; [[ $i == 107 ]] || printf ','; echo
  done
  echo ']'
} > "$fx/issues.json"
echo "[$(mr 11 merged 101-fix-the-thing 'Fix the thing' '')]" > "$fx/related-101.json"
echo "[$(mr 12 merged feature-x 'Feature X' 'Fixes #100, #102 and #104')]" > "$fx/related-102.json"
# Two pages, as --paginate may print them: one array per page.
{ echo "[$(mr 13 merged other-work 'Other work' 'Refs #103 #104')]"
  echo "[$(mr 15 opened draft-103 'Draft' 'Refs #103')]"; } > "$fx/related-103.json"
echo "[$(mr 14 merged 1040-neighbour 'Neighbour' 'Closes #1040')]" > "$fx/related-104.json"
echo "[$(mr 16 opened 105-wip 'WIP' 'Closes #105')]" > "$fx/related-105.json"
echo "[$(mr 17 merged tidy 'RESOLVES: #107 tidy up' ''),$(mr 18 opened follow-up 'Follow-up' '')]" > "$fx/related-107.json"

export PATH="$tmp/bin:$PATH" FAKE_FX="$fx" FAKE_CALLS="$tmp/calls"
unset PROJECT GITLAB_HOST PARALLEL FAKE_NO_REPO FAKE_FAIL_IID
sweep_run() { : > "$FAKE_CALLS"; out="$(bash "$sweep" "$@" 2>"$tmp/err")"; rc=$?; err="$(cat "$tmp/err")"; }
section() {  # section STRONG|WEAK: the rows under that heading
  awk -v h="$1" 'index($0, "=== " h " ") { on = 1; next } /^=+ / { on = 0 } on && NF' <<<"$out"
}

echo "classification"
sweep_run
equal "a clean sweep exits 0" 0 "$rc"
strong="$(section STRONG)"
weak="$(section WEAK)"
check "an MR from the issue's own branch is STRONG" $'#101\t[merged !11]' "$strong"
check "a closing keyword in a list of issues is STRONG" $'#102\t[merged !12]' "$strong"
check "a closing keyword in the title, any case, with a colon, is STRONG" $'#107\t[merged !17]\topen_mrs=1' "$strong"
check "a mention-only merged MR is WEAK" $'#103\t[merged !13]' "$weak"
check "...with the open MR from the second page counted" $'#103\t[merged !13]\topen_mrs=1' "$weak"
check "closing #1040 and a 1040- branch do not make #104 STRONG" $'#104\t[merged !14]' "$weak"
lacks "...so #104 is not STRONG" "#104" "$strong"
lacks "...and #103 is not STRONG" "#103" "$strong"
lacks "an issue with only an open MR is not listed" "#105" "$out"
lacks "an issue with no MR is not listed" "#106" "$out"
check "the summary counts them" "Summary: 3 strong, 2 weak, out of 7 open issues." "$err"
check "...and rows keep the issue title" $'\tissue 101' "$strong"
equal "STRONG rows are newest first" "#107 #102 #101" "$(cut -f1 <<<"$strong" | paste -sd ' ' -)"

echo "project and assignee"
calls="$(cat "$FAKE_CALLS")"
check "the project comes from glab repo view" "repo | view | -F | json" "$calls"
check "...and is URL-encoded in the API path" "projects/acme%2Fwidgets/issues?state=opened&assignee_id=7&per_page=100" "$calls"
check "related MRs are read with pagination" "--paginate | projects/acme%2Fwidgets/issues/101/related_merge_requests?per_page=100" "$calls"
PROJECT=group/sub/repo sweep_run
calls="$(cat "$FAKE_CALLS")"
lacks "PROJECT skips glab repo view" "repo | view" "$calls"
check "...and is used as given" "projects/group%2Fsub%2Frepo/issues?" "$calls"
sweep_run sam
check "a username picks that assignee" "assignee_id=9&" "$(cat "$FAKE_CALLS")"
check "...and the messages name them" "assigned to sam" "$err"
sweep_run nobody
equal "an unknown username fails" 1 "$rc"
check "...saying so" "no GitLab user named nobody" "$err"
FAKE_NO_REPO=1 sweep_run
equal "outside a checkout without PROJECT it fails" 1 "$rc"
check "...with the way out" "set PROJECT=group/project" "$err"

echo "failures are reported"
FAKE_FAIL_IID=103 sweep_run
equal "a failed related-MR lookup fails the run" 1 "$rc"
check "...naming the unchecked issue" "UNCHECKED (the related-MR request failed or timed out): #103" "$err"
check "...and still reports the rest" $'#101\t[merged !11]' "$(section STRONG)"
lacks "...without guessing about the failed one" "#103" "$out"

echo "parallel"
PARALLEL=3 sweep_run
equal "PARALLEL=3 succeeds" 0 "$rc"
equal "...with the same STRONG rows" "$strong" "$(section STRONG)"
equal "...and the same WEAK rows" "$weak" "$(section WEAK | sort -t $'\t' -k1,1 -rn)"
PARALLEL=0 sweep_run
equal "PARALLEL=0 is refused" 1 "$rc"

echo "read-only"
: > "$tmp/all-calls"
for args in "" "sam"; do
  sweep_run $args; cat "$FAKE_CALLS" >> "$tmp/all-calls"
  PARALLEL=2 sweep_run $args; cat "$FAKE_CALLS" >> "$tmp/all-calls"
done
writes="$(grep -v -E '^(repo \| view \| -F \| json|api \| --method \| GET \| .*)$' "$tmp/all-calls")"
equal "every call is glab repo view or a GET through glab api" "" "$writes"
lacks "...never a write method" "POST" "$(grep -E 'POST|PUT|PATCH|DELETE' "$tmp/all-calls")"
lacks "...never a field, form or body" "|" "$(grep -E '\| (-f|-F|--field|--raw-field|--form|--input)\b' "$tmp/all-calls" | grep -v 'repo | view' | head -n 1)"
lacks "...never an issue or MR command" "issue" "$(grep -E '^(issue|mr|note)\b' "$tmp/all-calls")"
equal "...and it made calls at all" "yes" "$([[ -s "$tmp/all-calls" ]] && echo yes || echo no)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
