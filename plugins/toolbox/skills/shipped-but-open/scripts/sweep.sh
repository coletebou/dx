#!/usr/bin/env bash
# sweep.sh: find OPEN GitLab issues that already have a MERGED merge request. Read-only: every
# call is a GET through `glab api`; nothing is closed, commented or labelled.
#
# Why: work often merges when someone other than the issue's author merges it, so nobody closes
# the issue and it rots in the backlog. This lists those issues.
#
# The nuance: GitLab's related_merge_requests endpoint returns MRs that merely MENTION the issue,
# not only MRs that fixed it, so a merged sibling MR that refers to several issues shows up under
# each of them. Hits are split by a STRONG signal:
#   - the merged MR's source branch starts with "<issue>-" (the name GitLab gives a branch or MR
#     created from the issue), or
#   - the merged MR's title or description closes the issue with one of GitLab's default closing
#     keywords ("Closes #12", "Fixes #12, #13 and #14", "Resolves: #12", "Implements #12").
# STRONG hits were built for the issue; WEAK hits (mention only) need a human read.
#
# Usage: sweep.sh [USERNAME]     open issues assigned to USERNAME (default: you, the glab user)
# Env:   PROJECT    group/project (default: the project of the checkout you run it in)
#        GITLAB_HOST  the GitLab host, when PROJECT names one outside the current checkout's
#        PARALLEL   concurrent glab calls (default 1; some self-hosted instances behind slow
#                   links or VPNs stall under parallel API load)
#        SWEEP_TIMEOUT  seconds per related-MR request when timeout/gtimeout exists (default 20)
set -uo pipefail

die() { printf 'sweep.sh: %s\n' "$*" >&2; exit 1; }
for t in glab jq; do command -v "$t" >/dev/null 2>&1 || die "$t is required"; done

PARALLEL="${PARALLEL:-1}"
case "$PARALLEL" in ''|*[!0-9]*|0) die "PARALLEL must be a positive integer, not: $PARALLEL" ;; esac
SWEEP_TIMEOUT="${SWEEP_TIMEOUT:-20}"
case "$SWEEP_TIMEOUT" in ''|*[!0-9]*|0) die "SWEEP_TIMEOUT must be a positive integer, not: $SWEEP_TIMEOUT" ;; esac

if [ -z "${PROJECT:-}" ]; then
  PROJECT="$(glab repo view -F json 2>/dev/null | jq -r '.path_with_namespace // empty' 2>/dev/null)"
  [ -n "$PROJECT" ] || die "no project: run this inside a GitLab checkout, or set PROJECT=group/project"
fi
PROJ_ENC="$(jq -rn --arg p "$PROJECT" '$p | @uri')"

# GET only, always: a fixed method, so no future edit can turn a sweep into a write by adding a
# field (glab api switches to POST when a parameter is given).
api() { glab api --method GET "$@"; }

if [ -n "${1:-}" ]; then
  uid="$(api "users?username=$(jq -rn --arg u "$1" '$u | @uri')" 2>/dev/null | jq -r '.[0].id // empty')"
  [ -n "$uid" ] || die "no GitLab user named $1"
  who="$1"
else
  uid="$(api user 2>/dev/null | jq -r '.id // empty')"
  [ -n "$uid" ] || die "could not resolve the current glab user (is glab authenticated? glab auth status)"
  who="you"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/shipped-but-open.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

printf 'Fetching open issues assigned to %s in %s ...\n' "$who" "$PROJECT" >&2
api --paginate "projects/$PROJ_ENC/issues?state=opened&assignee_id=$uid&per_page=100" > "$tmp/issues.json" \
  || die "could not list the issues of $PROJECT"
jq -s -c 'add // [] | .[] | {iid, title}' "$tmp/issues.json" > "$tmp/issues.jsonl" \
  || die "the issue list of $PROJECT is not JSON"
total="$(wc -l < "$tmp/issues.jsonl" | tr -d ' ')"
printf 'Open issues assigned to %s: %s\nChecking each for merged MRs ...\n' "$who" "$total" >&2

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$SWEEP_TIMEOUT" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout "$SWEEP_TIMEOUT" "$@"
  else "$@"; fi
}

# check_one IID: one tab-separated row for an issue with at least one merged MR:
#   iid  strong-MRs  merged-MRs  open-MR-count  title
check_one() {
  local iid="$1" mrs title
  if ! mrs="$(with_timeout glab api --method GET --paginate \
      "projects/$PROJ_ENC/issues/$iid/related_merge_requests?per_page=100" 2>/dev/null)"; then
    printf '%s\n' "$iid" >> "$tmp/failed"
    return 0
  fi
  title="$(jq -r --argjson n "$iid" 'select(.iid == $n) | .title' "$tmp/issues.jsonl" | head -n 1)"
  printf '%s' "$mrs" | jq -r -s --arg n "$iid" --arg title "$title" '
    def closes($n):
      [ (.title // ""), (.description // "")
        | scan("(?i)\\b(?:clos(?:e[sd]?|ing)|fix(?:e[sd]|ing)?|resolv(?:e[sd]?|ing)|implement(?:s|ed|ing)?):? +(?:issues? +)?((?:#\\d+(?: *,? +and +| *,? *)?)+)")
        | .[0] ]
      | any(test("#" + $n + "(?!\\d)"));
    (add // []) as $all
    | [ $all[] | select(.state == "merged") ] as $merged
    | select($merged | length > 0)
    | [ $merged[] | select(((.source_branch // "") | startswith($n + "-")) or closes($n)) | "!\(.iid)" ] as $strong
    | [ $all[] | select(.state == "opened") ] as $open
    | [$n, ($strong | join(",")), ([$merged[] | "!\(.iid)"] | join(",")), ($open | length | tostring), $title]
    | @tsv
  ' 2>/dev/null || printf '%s\n' "$iid" >> "$tmp/failed"
}

: > "$tmp/hits.tsv"
if [ "$PARALLEL" -gt 1 ]; then
  export -f check_one with_timeout
  export PROJ_ENC SWEEP_TIMEOUT tmp
  # A check that could not even run (xargs exits nonzero) must not read as "nothing shipped".
  jq -r '.iid' "$tmp/issues.jsonl" | xargs -n 1 -P "$PARALLEL" bash -c 'check_one "$1"' _ >> "$tmp/hits.tsv" \
    || printf '(a parallel worker)\n' >> "$tmp/failed"
else
  while IFS= read -r i; do check_one "$i"; done < <(jq -r '.iid' "$tmp/issues.jsonl") >> "$tmp/hits.tsv"
fi

sort -t "$(printf '\t')" -k1,1 -rn "$tmp/hits.tsv" > "$tmp/hits.sorted"

echo ""
echo "================ STRONG (branch or closing-keyword match: very likely done) ================"
awk -F'\t' '$2 != "" { printf "#%s\t[merged %s]\topen_mrs=%s\t%s\n", $1, $2, $4, $5 }' "$tmp/hits.sorted"
echo ""
echo "================ WEAK (mention-only merged MR: NEEDS A HUMAN READ) ========================="
awk -F'\t' '$2 == "" { printf "#%s\t[merged %s]\topen_mrs=%s\t%s\n", $1, $3, $4, $5 }' "$tmp/hits.sorted"
echo ""
strong_n="$(awk -F'\t' '$2 != ""' "$tmp/hits.sorted" | wc -l | tr -d ' ')"
weak_n="$(awk -F'\t' '$2 == ""' "$tmp/hits.sorted" | wc -l | tr -d ' ')"
printf 'Summary: %s strong, %s weak, out of %s open issues.\n' "$strong_n" "$weak_n" "$total" >&2
if [ -s "$tmp/failed" ]; then
  printf 'UNCHECKED (the related-MR request failed or timed out): %s\n' \
    "$(sort -rn "$tmp/failed" | sed 's/^/#/' | paste -sd ' ' -)" >&2
  exit 1
fi
exit 0
