#!/usr/bin/env bash
# github-kit.test.sh: the GitHub repo kit (github-kit/). sync-labels.sh runs against a fake gh on
# PATH that records every call and keeps the label list it answers with, as GitHub would: a dry
# run writes nothing, a sync creates the missing labels and edits only the drifted ones, a second
# sync changes nothing, and only --prune deletes. Then the label file parser, the kit's own files
# (pinned actions, the labels its workflows and forms name, pr-labels.mjs's rules and label
# definitions), and the copies this repository's .github/ takes from the kit.
#
#   bash scripts/tests/github-kit.test.sh
#   SYNC_LABELS=/path/to/sync-labels.sh PR_LABELS_MJS=/path/to/pr-labels.mjs \
#     bash scripts/tests/github-kit.test.sh          (test other copies of the two scripts)
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
kit="$root/github-kit"
sync="${SYNC_LABELS:-$kit/sync-labels.sh}"
pr_labels="${PR_LABELS_MJS:-$kit/scripts/pr-labels.mjs}"
tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fail=$((fail + 1)); }
check() { if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "*$2*" "$3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "no '$2'" "$3"; fi; }
equal() { if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

# ── the fake gh ──────────────────────────────────────────────────────────
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'PY'
#!/usr/bin/env python3
"""A fake gh. Each call's argv goes to $FAKE_GH_LOG as a JSON line. It holds the labels of one
repository ($FAKE_GH_REPO) in $FAKE_GH_STATE: `label list` answers with them, and `api` writes
change them the way GitHub does (names compared case-insensitively, one URL-encoded name per
path). $FAKE_GH_FAIL_ON names a label whose write fails; $FAKE_GH_LIST_FAILS fails the list."""
import json
import os
import sys
from urllib.parse import unquote

argv = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps(argv, ensure_ascii=False) + "\n")
repo, state = os.environ["FAKE_GH_REPO"], os.environ["FAKE_GH_STATE"]
with open(state, encoding="utf-8") as f:
    labels = json.load(f)


def die(msg, code=1):
    sys.stderr.write(msg + "\n")
    sys.exit(code)


def save():
    with open(state, "w", encoding="utf-8") as f:
        json.dump(labels, f, ensure_ascii=False)
    sys.exit(0)


def opt(name):
    return argv[argv.index(name) + 1] if name in argv else None


def find(name):
    return next((lab for lab in labels if lab["name"].lower() == name.lower()), None)


if argv[:2] == ["label", "list"]:
    if os.environ.get("FAKE_GH_LIST_FAILS"):
        die("HTTP 401: Bad credentials")
    if opt("--repo") != repo:
        die("GraphQL: Could not resolve to a Repository with the name '%s'." % opt("--repo"))
    fields = (opt("--json") or "").split(",")
    if fields == [""]:
        die("fake gh: label list without --json")
    limit = int(opt("--limit") or 30)
    print(json.dumps([{k: lab[k] for k in fields} for lab in labels[:limit]], ensure_ascii=False))
    sys.exit(0)

if argv[:1] == ["api"]:
    method = opt("--method") or "GET"
    paths = [a for a in argv[1:] if a.startswith("repos/")]
    if len(paths) != 1:
        die("fake gh: api without exactly one repos/ path")
    path, fields = paths[0], {}
    for i, a in enumerate(argv):
        if a == "-f":
            key, _, value = argv[i + 1].partition("=")
            fields[key] = value
        elif a in ("-F", "--field", "--input"):
            die("fake gh: unexpected " + a)
    base = "repos/%s/labels" % repo
    fail_on = os.environ.get("FAKE_GH_FAIL_ON")
    if method == "POST" and path == base:
        if fail_on and fields.get("name") == fail_on:
            die("HTTP 422: Validation Failed")
        if find(fields["name"]):
            die("HTTP 422: Validation Failed (already_exists)")
        labels.append({"name": fields["name"], "color": fields.get("color", ""),
                       "description": fields.get("description", "")})
        save()
    if path.startswith(base + "/"):
        encoded = path[len(base) + 1:]
        if "/" in encoded:
            die("HTTP 404: Not Found (an unencoded / in the label name)")
        cur = find(unquote(encoded))
        if cur is None:
            die("HTTP 404: Not Found")
        if fail_on and cur["name"] == fail_on:
            die("HTTP 422: Validation Failed")
        if method == "PATCH":
            other = find(fields.get("new_name", cur["name"]))
            if other is not None and other is not cur:
                die("HTTP 422: Validation Failed (already_exists)")
            cur["name"] = fields.get("new_name", cur["name"])
            for key in ("color", "description"):
                if key in fields:
                    cur[key] = fields[key]
            save()
        if method == "DELETE":
            labels.remove(cur)
            save()
    die("fake gh: unexpected api call: %s %s" % (method, path))

die("fake gh: unexpected call: " + " ".join(argv), 64)
PY
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FAKE_GH_REPO=example/widgets FAKE_GH_STATE="$tmp/state.json" FAKE_GH_LOG="$tmp/gh.log"
unset FAKE_GH_FAIL_ON FAKE_GH_LIST_FAILS

# The label file the sync tests use, and the repository it meets: bug differs only in the color's
# case (in sync), Documentation in its name's case, enhancement in its description, size/XS (a
# slash to encode) in its color, cleared in a description the file drops; question and the emoji
# label are in sync; needs-triage and "priority: low" are missing; stale-thing is not in the file.
cat > "$tmp/labels.yml" <<'EOF'
- name: "bug"
  color: "d73a4a"
  description: "Something isn't working"
- name: "documentation"
  color: "0075ca"
  description: "Improvements or additions to documentation"
- name: "enhancement"
  color: "a2eeef"
  description: "New feature or request"
- name: "size/XS"
  color: "ededed"
  description: "Under 20 lines changed"
- name: "question"
  color: "d876e3"
  description: "Further information is requested"
- name: "proof: 🙋 override"
  color: "8250df"
  description: "Set by hand"
- name: "needs-triage"
  color: "d93f0b"
  description: "Needs priority and owner"
- name: "priority: low"
  color: "c2e0c6"
- name: "cleared"
  color: "ededed"
EOF
cat > "$tmp/initial.json" <<'EOF'
[
  {"name": "bug", "color": "D73A4A", "description": "Something isn't working"},
  {"name": "Documentation", "color": "0075ca", "description": "Improvements or additions to documentation"},
  {"name": "enhancement", "color": "a2eeef", "description": "Old words"},
  {"name": "size/XS", "color": "000000", "description": "Under 20 lines changed"},
  {"name": "question", "color": "d876e3", "description": "Further information is requested"},
  {"name": "proof: 🙋 override", "color": "8250DF", "description": "Set by hand"},
  {"name": "cleared", "color": "ededed", "description": "old"},
  {"name": "stale-thing", "color": "ededed", "description": ""}
]
EOF
reset_repo() { cp "$tmp/initial.json" "$tmp/state.json"; : > "$tmp/gh.log"; }
run_sync() { bash "$sync" --repo example/widgets --file "$tmp/labels.yml" "$@" 2>&1; }
calls()  { wc -l < "$tmp/gh.log" | tr -d ' '; }
writes() { grep -c '^\["api"' "$tmp/gh.log"; }
# The writes the log holds, one per line: METHOD PATH [name=...] (sorted).
write_list() {
  python3 -c '
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    a = json.loads(line)
    if a[:1] != ["api"]:
        continue
    method = a[a.index("--method") + 1]
    path = next(x for x in a if x.startswith("repos/"))
    names = [a[i + 1] for i, x in enumerate(a) if x == "-f" and a[i + 1].startswith(("name=", "new_name="))]
    print(" ".join([method, path] + names))' "$tmp/gh.log" | LC_ALL=C sort
}
# The repository's labels now, as NAME|color|description lines (sorted, color lowercased).
repo_labels() {
  python3 -c '
import json, sys
for lab in sorted(json.load(open(sys.argv[1], encoding="utf-8")), key=lambda x: x["name"].lower()):
    print("%s|%s|%s" % (lab["name"], lab["color"].lower(), lab["description"]))' "$tmp/state.json"
}

echo "usage"
reset_repo
out="$(bash "$sync" 2>&1)"; rc=$?
equal "no --repo is a usage error" 2 "$rc"
check "...saying what it needs" "--repo OWNER/NAME is required" "$out"
for bad_repo in foo a/b/c /x x/ 'a/b c'; do
  out="$(bash "$sync" --repo "$bad_repo" 2>&1)"; rc=$?
  [[ "$rc" == 2 ]] || bad "--repo '$bad_repo' is refused" "exit 2" "exit $rc: $out"
done
ok "a --repo that is not OWNER/NAME is refused"
out="$(bash "$sync" --repo example/widgets --bogus 2>&1)"; rc=$?
equal "an unknown option is a usage error" 2 "$rc"
out="$(bash "$sync" --help 2>&1)"; rc=$?
equal "--help succeeds" 0 "$rc"
check "...and documents the exit status" "Exit status: 0 in sync" "$out"
check "...and --prune" "--prune" "$out"
equal "usage errors call gh not once" 0 "$(calls)"

echo "dry run"
reset_repo
out="$(run_sync --dry-run)"; rc=$?
equal "a dry run succeeds" 0 "$rc"
check "...planning to create a missing label" 'create  "needs-triage"  color d93f0b, description "Needs priority and owner"' "$out"
check "...and one without a description" 'create  "priority: low"  color c2e0c6, description ""' "$out"
check "...to fix a name's case" 'edit    "Documentation"  name "Documentation" -> "documentation"' "$out"
check "...a description" 'edit    "enhancement"  description "Old words" -> "New feature or request"' "$out"
check "...a color" 'edit    "size/XS"  color 000000 -> ededed' "$out"
check "...to clear a description the file drops" 'edit    "cleared"  description "old" -> ""' "$out"
lacks "...not to touch a label whose color differs only in case" '"bug"' "$out"
lacks "...nor the label with an emoji, in sync" 'override' "$out"
check "...listing the extra label as kept" 'keep    "stale-thing"  (not in the label file; --prune deletes it)' "$out"
check "...with the counts" "example/widgets: 2 to create, 4 to edit, 0 to delete, 1 not in the file kept" "$out"
check "...and says nothing was made" "Dry run: 6 change(s) planned, none made." "$out"
equal "...after one gh call, the label list" '["label", "list", "--repo", "example/widgets", "--json", "name,color,description", "--limit", "1000"]' "$(cat "$tmp/gh.log")"
equal "...and no write" 0 "$(writes)"
equal "...so the repository is unchanged" "$(cat "$tmp/initial.json")" "$(cat "$tmp/state.json")"
out="$(run_sync --dry-run --prune)"; rc=$?
equal "a dry run with --prune succeeds" 0 "$rc"
check "...planning the delete" 'delete  "stale-thing"  (not in the label file)' "$out"
check "...counted" "2 to create, 4 to edit, 1 to delete" "$out"
equal "...without deleting it" 0 "$(writes)"
equal "...or changing anything" "$(cat "$tmp/initial.json")" "$(cat "$tmp/state.json")"

echo "sync"
reset_repo
out="$(run_sync)"; rc=$?
equal "the sync succeeds" 0 "$rc"
check "...and counts its changes" "Done: 6 change(s)." "$out"
equal "...creating the missing labels and editing only the drifted ones (names URL-encoded)" \
"PATCH repos/example/widgets/labels/Documentation new_name=documentation
PATCH repos/example/widgets/labels/cleared new_name=cleared
PATCH repos/example/widgets/labels/enhancement new_name=enhancement
PATCH repos/example/widgets/labels/size%2FXS new_name=size/XS
POST repos/example/widgets/labels name=needs-triage
POST repos/example/widgets/labels name=priority: low" "$(write_list)"
check "...sending the color and the description with each" \
  '["api", "--method", "POST", "repos/example/widgets/labels", "-f", "name=needs-triage", "-f", "color=d93f0b", "-f", "description=Needs priority and owner"]' "$(cat "$tmp/gh.log")"
check "...an empty description to clear one" \
  '"-f", "new_name=cleared", "-f", "color=ededed", "-f", "description="]' "$(cat "$tmp/gh.log")"
equal "the repository then has the file's labels, and keeps the extra one" \
"bug|d73a4a|Something isn't working
cleared|ededed|
documentation|0075ca|Improvements or additions to documentation
enhancement|a2eeef|New feature or request
needs-triage|d93f0b|Needs priority and owner
priority: low|c2e0c6|
proof: 🙋 override|8250df|Set by hand
question|d876e3|Further information is requested
size/XS|ededed|Under 20 lines changed
stale-thing|ededed|" "$(repo_labels)"

echo "idempotent"
: > "$tmp/gh.log"
out="$(run_sync)"; rc=$?
equal "a second sync succeeds" 0 "$rc"
check "...and changes nothing" "In sync: nothing to change." "$out"
equal "...making no write" 0 "$(writes)"
check "...still naming the extra label it keeps" 'keep    "stale-thing"' "$out"

echo "prune"
: > "$tmp/gh.log"
out="$(run_sync --prune)"; rc=$?
equal "--prune succeeds" 0 "$rc"
check "...with one change" "Done: 1 change(s)." "$out"
equal "...one delete, of the label the file lacks" "DELETE repos/example/widgets/labels/stale-thing" "$(write_list)"
lacks "...which is gone" "stale-thing" "$(repo_labels)"
equal "...and nothing else went" 9 "$(repo_labels | wc -l | tr -d ' ')"
: > "$tmp/gh.log"
out="$(run_sync --prune)"; rc=$?
check "a second --prune changes nothing" "In sync: nothing to change." "$out"
equal "...making no write" 0 "$(writes)"

echo "failures"
reset_repo
out="$(FAKE_GH_FAIL_ON=needs-triage run_sync)"; rc=$?
equal "a failed write fails the sync" 1 "$rc"
check "...naming it, with gh's error" 'failed: create  "needs-triage"' "$out"
check "...gh's error" "HTTP 422: Validation Failed" "$out"
check "...and says the rest were made" "Made 5 of 6 change(s); 1 failed (rerun to retry them)." "$out"
check "...which they were" "priority: low|c2e0c6|" "$(repo_labels)"
out="$(run_sync)"; rc=$?
equal "a rerun makes the one that failed" "0 Done: 1 change(s)." "$rc $(printf '%s\n' "$out" | tail -n 1)"
reset_repo
out="$(FAKE_GH_LIST_FAILS=1 run_sync)"; rc=$?
equal "a label list that fails stops the sync" 1 "$rc"
check "...saying why" "could not list the labels of example/widgets" "$out"
check "...with gh's error" "HTTP 401: Bad credentials" "$out"
equal "...before any write" 0 "$(writes)"
out="$(bash "$sync" --repo example/other --file "$tmp/labels.yml" 2>&1)"; rc=$?
equal "a repository gh cannot find stops the sync" 1 "$rc"

echo "the label file"
out="$(bash "$sync" --print --file "$kit/labels.yml" 2>&1)"; rc=$?
equal "the kit's labels.yml parses" 0 "$rc"
printf '%s\n' "$out" > "$tmp/kit-labels.json"
equal "...into a list of name, color and description" "ok" "$(python3 -c '
import json, re, sys
labels = json.load(open(sys.argv[1], encoding="utf-8"))
bad = [x for x in labels if sorted(x) != ["color", "description", "name"] or not re.fullmatch("[0-9a-f]{6}", x["color"])]
print("ok" if len(labels) >= 30 and not bad else "%d labels, malformed: %r" % (len(labels), bad))' "$tmp/kit-labels.json" 2>&1)"
for family in 'size/XS' 'size/XL' 'proof: ✅ sufficient' 'proof: 🙋 override' 'merge-risk: 🚨 security' 'ci:full' 'needs-triage' 'bug'; do
  [[ "$out" == *"\"name\": \"$family\""* ]] || bad "labels.yml has $family" "$family" "missing"
done
ok "...with the size, proof, merge-risk and triage labels"
# Generic labels only: a label outside these is a project's own, which belongs in that project.
equal "...and only generic ones: GitHub's defaults, kind and triage, and the label families" "" "$(python3 -c '
import json, sys
generic = {"accessibility", "bug", "documentation", "duplicate", "enhancement", "good first issue",
           "help wanted", "invalid", "question", "wontfix", "dependencies", "security", "performance",
           "ci", "chore", "needs-triage", "ci:full"}
families = ("size/", "proof: ", "merge-risk: ", "priority: ", "area: ")
labels = json.load(open(sys.argv[1], encoding="utf-8"))
print(" ".join(x["name"] for x in labels if x["name"] not in generic and not x["name"].startswith(families)))' "$tmp/kit-labels.json" 2>&1)"
if python3 -c 'import yaml' 2>/dev/null; then
  equal "...the same list a YAML library reads" "same" "$(python3 -c '
import json, sys, yaml
mine = json.load(open(sys.argv[1], encoding="utf-8"))
theirs = yaml.safe_load(open(sys.argv[2], encoding="utf-8"))
print("same" if mine == theirs else "differs")' "$tmp/kit-labels.json" "$kit/labels.yml" 2>&1)"
else
  ok "# SKIP PyYAML not installed: no cross-check against a YAML library"
fi
printf '\357\273\277---\r\n# a comment\r\n- name: "it\\"s \\u00e9"\r\n  color: "ABCDEF"   # trailing comment\r\n-   name: '"'it''s'"'\r\n    color: "123abc"\r\n    description: plain words # a comment\r\n- name: empty\r\n  color: "ededed"\r\n  description:\r\n' > "$tmp/quoting.yml"
equal "quoting, comments, CRLF, a BOM, wider indents and an empty description parse" \
  '[{"name": "it\"s é", "color": "ABCDEF", "description": ""}, {"name": "it'"'"'s", "color": "123abc", "description": "plain words"}, {"name": "empty", "color": "ededed", "description": ""}]' \
  "$(bash "$sync" --print --file "$tmp/quoting.yml" 2>&1 | python3 -c 'import json, sys; print(json.dumps(json.load(sys.stdin), ensure_ascii=False))' 2>&1)"
bad_file() {  # bad_file LABEL WANT CONTENT: the file is refused with WANT, and a sync calls no gh
  printf '%s' "$3" > "$tmp/bad.yml"
  : > "$tmp/gh.log"
  out="$(bash "$sync" --print --file "$tmp/bad.yml" 2>&1)"; rc=$?
  if [[ "$rc" == 1 && "$out" == *"$2"* ]]; then ok "$1"; else bad "$1" "exit 1, *$2*" "exit $rc: $out"; fi
  out="$(bash "$sync" --repo example/widgets --file "$tmp/bad.yml" 2>&1)"; rc=$?
  [[ "$rc" == 1 && "$(calls)" == 0 ]] || bad "...and a sync with it calls no gh" "exit 1, no call" "exit $rc, $(calls) call(s): $out"
}
bad_file "a color with a leading # is refused, with its line" 'bad.yml:2: color '"'"'#d73a4a'"'"': drop the leading #' \
  $'- name: "bug"\n  color: "#d73a4a"\n'
bad_file "a color that is not six hex digits" 'bad.yml:2: color '"'"'d73a4'"'"' is not six hex digits' $'- name: "bug"\n  color: "d73a4"\n'
bad_file "an unquoted color YAML reads as a number" 'bad.yml:2: quote this value: YAML reads 000000' $'- name: "black"\n  color: 000000\n'
bad_file "...or 1e3456, a float" 'quote this value: YAML reads 1e3456' $'- name: "x"\n  color: 1e3456\n'
bad_file "an unquoted yes, a boolean" 'quote this value: YAML reads yes' $'- name: yes\n  color: "ededed"\n'
bad_file "a duplicate name, in any case" 'bad.yml:3: label '"'"'Bug'"'"' is already defined on line 1' \
  $'- name: "bug"\n  color: "d73a4a"\n- name: "Bug"\n  color: "d73a4a"\n'
bad_file "an unknown key" "bad.yml:2: unknown key 'colour'" $'- name: "bug"\n  colour: "d73a4a"\n'
bad_file "a key given twice" 'bad.yml:3: color given twice' $'- name: "bug"\n  color: "d73a4a"\n  color: "d73a4a"\n'
bad_file "a label without a color" "bad.yml:1: label 'bug' needs a color" $'- name: "bug"\n  description: "x"\n'
bad_file "a label without a name" 'bad.yml:1: a label needs a name' $'- color: "d73a4a"\n'
bad_file "a flow mapping" 'write each label as a block mapping' $'- {name: bug, color: "d73a4a"}\n'
bad_file "a mapping instead of a list" 'bad.yml:1: the file must be a list' $'name: "bug"\ncolor: "d73a4a"\n'
bad_file "a tab indent" 'bad.yml:2: indent with spaces, not tabs' $'- name: "bug"\n\tcolor: "d73a4a"\n'
bad_file "a key out of line" 'bad.yml:2: indent this key to column 3' $'- name: "bug"\n    color: "d73a4a"\n'
bad_file "an unterminated string" 'unterminated double-quoted string' $'- name: "bug\n  color: "d73a4a"\n'
bad_file "a description over 100 characters" 'longer than 100 characters' \
  "$(printf -- '- name: "long"\n  color: "ededed"\n  description: "%0101d"\n' 0)"
bad_file "an empty file" 'defines no labels' $'# nothing\n'

echo "under /bin/bash"
if [[ -x /bin/bash ]]; then
  reset_repo
  want="$(run_sync --dry-run)"
  : > "$tmp/gh.log"
  got="$(/bin/bash "$sync" --repo example/widgets --file "$tmp/labels.yml" --dry-run 2>&1)"
  equal "a dry run under /bin/bash ($(/bin/bash -c 'echo "$BASH_VERSION"')) plans the same" "$want" "$got"
  got="$(/bin/bash "$sync" --repo example/widgets --file "$tmp/labels.yml" 2>&1)"
  check "...and syncs" "Done: 6 change(s)." "$got"
  check "...to the same labels" "documentation|0075ca|Improvements or additions to documentation" "$(repo_labels)"
else
  ok "# SKIP no /bin/bash"
fi

echo "the kit's files"
uses="$(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:' "$kit"/workflows/*.yml)"
check "the kit's workflows use actions" "uses: actions/checkout@" "$uses"
equal "...each pinned to a full commit SHA, its version in a comment" "" \
  "$(printf '%s\n' "$uses" | grep -vE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$')"
for w in "$kit"/workflows/*.yml; do
  grep -q '^permissions:' "$w" || bad "$(basename "$w") sets its token permissions" "a top-level permissions:" "none"
  grep -q '^  pull_request_target:' "$w" && grep -qE 'ref: .*head' "$w" \
    && bad "$(basename "$w") never checks out a PR head under pull_request_target" "no head ref" "found"
done
ok "...and each sets its token permissions"
for w in ci-full-label stacked-pr-retarget ci-full-on-approval; do
  grep -q "vars.CI_FULL_WORKFLOW != ''" "$kit/workflows/$w.yml" \
    || bad "$w.yml is off until CI_FULL_WORKFLOW is set" "the guard" "none"
done
ok "the full-lane workflows are off until CI_FULL_WORKFLOW is set"
for w in claude claude-code-review; do
  grep -q 'echo "ready=false"' "$kit/workflows/$w.yml" \
    || bad "$w.yml does nothing without a credential" "the guard" "none"
done
ok "the Claude workflows do nothing without a credential"
used="$(sed -n 's/^labels: \[\(.*\)\]$/\1/p' "$kit"/ISSUE_TEMPLATE/*_*.yml | tr ',' '\n' | sed 's/^ *//; s/ *$//' | sort -u)"
check "the issue forms apply labels" "needs-triage" "$used"
missing="$(printf '%s\n' "$used" "ci:full" | python3 -c '
import json, sys
have = set(x["name"] for x in json.load(open(sys.argv[1], encoding="utf-8")))
print(" ".join(n for n in sys.stdin.read().split("\n") if n and n not in have))' "$tmp/kit-labels.json")"
equal "...and they, and ci:full, are in labels.yml" "" "$missing"
cfg="$(cat "$kit/ISSUE_TEMPLATE/config.yml")"
check "the kit turns blank issues off" "blank_issues_enabled: false" "$cfg"
check "...and sends security reports to the security policy" "url: https://github.com/OWNER/REPO/security/policy" "$cfg"

echo "pr-labels.mjs"
if command -v node >/dev/null 2>&1 && node -e 'process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)'; then
  cat > "$tmp/pr-labels-check.mjs" <<'JS'
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const [, , modulePath, labelsPath] = process.argv;
const m = await import(pathToFileURL(modulePath).href);
const labels = JSON.parse(readFileSync(labelsPath, 'utf8'));
const eq = (name, want, got) => {
  const w = JSON.stringify(want);
  const g = JSON.stringify(got);
  console.log(w === g ? `ok\t${name}` : `FAIL\t${name}\t${w}\t${g}`);
};
const byName = new Map(labels.map((l) => [l.name, l]));
eq('every label it creates is in labels.yml, with the same color and description', [],
  m.LABEL_DEFINITIONS.filter((d) => {
    const l = byName.get(d.name);
    return !l || l.color.toLowerCase() !== d.color.toLowerCase() || l.description !== d.description;
  }).map((d) => d.name));
eq('...and it defines every size and proof label', [...m.SIZES.map((s) => s.name), ...Object.values(m.PROOF)].sort(),
  m.LABEL_DEFINITIONS.map((d) => d.name).sort());
eq('size thresholds', ['size/XS', 'size/XS', 'size/S', 'size/S', 'size/M', 'size/L', 'size/XL'],
  [0, 19, 20, 99, 100, 999, 1000].map(m.sizeLabel));
const f = (filename, additions = 10, deletions = 0, patch) => ({ filename, additions, deletions, patch });
const anywhere = m.uiRules({});
eq('lockfiles, generated output and assets do not count toward size', 42, m.classifyFiles([
  f('package-lock.json', 2000, 300), f('web/dist/app.js', 500), f('web/public/logo.svg', 400), f('src/server.ts', 30, 12),
], anywhere).lines);
eq('with no UI paths set, UI files anywhere are UI, but tests and backend code are not',
  ['web/src/Settings.tsx', 'ios/ChatView.swift'],
  m.classifyFiles([f('web/src/Settings.tsx'), f('ios/ChatView.swift'), f('web/src/Settings.test.tsx'), f('src/server.ts')], anywhere).ui);
eq('PR_LABELS_UI_PATHS and PR_LABELS_NOT_UI narrow what is UI', ['web/src/App.tsx'],
  m.classifyFiles([f('web/src/App.tsx'), f('web/src/api/client.tsx'), f('tools/report.html')],
    m.uiRules({ PR_LABELS_UI_PATHS: '^web/', PR_LABELS_NOT_UI: '^web/src/api/' })).ui);
eq('an invalid PR_LABELS_UI_PATHS is an error that names it', true, (() => {
  try { m.uiRules({ PR_LABELS_UI_PATHS: '(' }); return false; } catch (e) { return /PR_LABELS_UI_PATHS/.test(e.message); }
})());
eq('docs-only and tests-only changes are not behavior', [false, false], [
  m.classifyFiles([f('docs/guide.md'), f('README.md')], anywhere).behavior,
  m.classifyFiles([f('tests/api.test.ts'), f('pkg/store_test.go')], anywhere).behavior,
]);
eq('a workflow or Dockerfile change is behavior', [true, true], [
  m.classifyFiles([f('.github/workflows/ci.yml')], anywhere).behavior,
  m.classifyFiles([f('docker/Dockerfile', 1, 1)], anywhere).behavior,
]);
eq('an @types-only bump with its lockfile is not behavior', false, m.classifyFiles([
  f('package.json', 1, 1, '-    "@types/node": "^24.0.0",\n+    "@types/node": "^24.1.0",\n'), f('package-lock.json', 3, 3),
], anywhere).behavior);
const pr = (body) => ({ user: { login: 'author', type: 'User' }, body });
eq('a Testing section is not run evidence; a code block under Evidence is', [false, true], [
  m.collectEvidence({ pr: pr('## Testing\n```\nnpm test\n```\n## Evidence\n') }).run,
  m.collectEvidence({ pr: pr('## Evidence\n```\n$ curl -s localhost/health\nok\n```\n') }).run,
]);
eq("a bot's comment is never evidence, even a collaborator bot's; the author's Evidence comment is", [false, true], [
  m.collectEvidence({ pr: pr(''), comments: [{ user: { login: 'deploy-bot', type: 'Bot' }, author_association: 'COLLABORATOR', body: 'Evidence: https://example.com/run/1' }] }).run,
  m.collectEvidence({ pr: pr(''), comments: [{ user: { login: 'author', type: 'User' }, body: 'Evidence: https://example.com/run/1' }] }).run,
]);
const decide = (ui, behavior, media, run, current = []) =>
  m.decideProof({ classification: { ui, behavior }, evidence: { media, run }, labels: current });
eq('proof for docs only, UI without screenshots, behavior without a run, both covered, an override',
  [[m.PROOF.notNeeded], [m.PROOF.screenshots], [m.PROOF.e2e], [m.PROOF.sufficient], null],
  [decide([], false, 0, false), decide(['a.tsx'], false, 0, false), decide([], true, 0, false),
    decide(['a.tsx'], true, 1, true), decide(['a.tsx'], true, 0, false, [m.PROOF.override])]);
eq('planLabels swaps size and proof labels and leaves every other label alone',
  { add: [m.PROOF.sufficient, 'size/M'], remove: [m.PROOF.e2e, 'size/S'] },
  m.planLabels(['size/S', m.PROOF.e2e, 'merge-risk: 🚨 data', 'bug'], { size: 'size/M', proof: [m.PROOF.sufficient] }));
// GitHub resolves label names case-insensitively, so size/s on a PR is the size/S label.
eq('planLabels: a label already on the PR in another case is that label, neither added nor removed',
  { add: [], remove: [] }, m.planLabels(['size/s', 'PROOF: ✅ SUFFICIENT'], { size: 'size/S', proof: [m.PROOF.sufficient] }));
eq('...and one it replaces is removed under the name the PR has', { add: [m.PROOF.sufficient], remove: ['Proof: 🧪 Needs E2E'] },
  m.planLabels(['SIZE/S', 'Proof: 🧪 Needs E2E'], { size: 'size/S', proof: [m.PROOF.sufficient] }));
eq('...and an override in another case still freezes the proof labels', null,
  decide(['a.tsx'], true, 0, false, ['PROOF: 🙋 OVERRIDE']));
JS
  n=0
  while IFS=$'\t' read -r verdict name want got; do
    n=$((n + 1))
    case "$verdict" in
      ok) ok "$name" ;;
      FAIL) bad "$name" "$want" "$got" ;;
      *) bad "the pr-labels.mjs checks run" "ok or FAIL lines" "$verdict $name $want $got" ;;
    esac
  done < <(node "$tmp/pr-labels-check.mjs" "$pr_labels" "$tmp/kit-labels.json" 2>&1)
  [[ "$n" -ge 17 ]] || bad "every pr-labels.mjs check ran" "17 or more" "$n"
else
  ok "# SKIP no Node 18 or newer: pr-labels.mjs not checked"
fi

echo "this repository's .github"
for f in workflows/pr-labels.yml scripts/pr-labels.mjs docs/pull-requests.md; do
  if cmp -s "$kit/$f" "$root/.github/$f"; then ok ".github/$f is the kit's"; else bad ".github/$f is the kit's" "identical" "differs"; fi
done
cfg="$(cat "$root/.github/ISSUE_TEMPLATE/config.yml" 2>&1)"
check "blank issues are off" "blank_issues_enabled: false" "$cfg"
check "...and security reports go to SECURITY.md" "url: https://github.com/coletebou/dx/blob/master/SECURITY.md" "$cfg"
[[ -f "$root/SECURITY.md" ]] && ok "...which exists" || bad "...which exists" "SECURITY.md" "missing"
for f in bug_report feature_request; do
  grep -q '^body:' "$root/.github/ISSUE_TEMPLATE/$f.yml" 2>/dev/null \
    && ok "the $f issue form is there" || bad "the $f issue form is there" "a form" "missing"
done
check "the pull request template has Summary, Testing and Evidence" "## Summary ## Testing ## Evidence" \
  "$(grep -E '^## (Summary|Testing|Evidence)$' "$root/.github/pull_request_template.md" 2>&1 | tr '\n' ' ')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
