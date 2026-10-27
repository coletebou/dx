#!/usr/bin/env bash
# scripts/autoreview-pair: both engines run in parallel with the same arguments, each with its own --engine
# and output paths, after $AUTOREVIEW_ENV_FILE (default ~/.env_secrets) is sourced; the summary and exit
# status follow the worst review.
# A fake helper stands in for autoreview. Sandbox HOME and checkout, EXAMPLE values only.
# shellcheck disable=SC2016  # check strings are eval'd later
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PAIR="$ROOT/scripts/autoreview-pair"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/autoreview-pair-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state"
unset AUTOREVIEW_ENV_FILE
mkdir -p "$HOME" "$TMP/repo"
printf 'export EXAMPLE_PAIR_SECRET=from-env-secrets\n' > "$HOME/.env_secrets"
git -C "$TMP/repo" init -q
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"; [[ -z "${2:-}" ]] || printf '#   %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else not_ok "$1" "${3:-}"; fi; }

# The fake helper: records what it was given, sleeps, and answers per engine from FAKE_<ENGINE>.
cat > "$TMP/fake-autoreview" <<'EOF'
import json, os, sys, time
a = sys.argv[1:]
def opt(name):
    return a[a.index(name) + 1] if name in a else None
engine = opt("--engine")
with open(os.path.join(os.environ["FAKE_LOG"], engine + ".seen"), "w") as f:
    json.dump({"argv": a, "start": time.time(), "secret": os.environ.get("EXAMPLE_PAIR_SECRET"), "tmpdir": os.environ.get("TMPDIR")}, f)
time.sleep(1)
outcome = os.environ.get("FAKE_" + engine.upper(), "clean")
if outcome == "crash":
    print("fake: could not authenticate"); sys.exit(3)
findings = [{"title": "[P2] a finding"}] if outcome == "findings" else []
status = "findings" if findings else "scoped-clean"
open(opt("--output"), "w").write("report\n")
json.dump({"findings": findings, "review_status": status}, open(opt("--json-output"), "w"))
json.dump({"status": status}, open(opt("--status-output"), "w"))
print("overall: patch is " + ("incorrect" if findings else "correct") + " (0.9)")
sys.exit(1 if findings else 0)
EOF
export AUTOREVIEW="$TMP/fake-autoreview" FAKE_LOG="$TMP/seen"
mkdir -p "$FAKE_LOG"
run() { (cd "$TMP/repo" && "$PAIR" "$@") > "$TMP/out" 2>&1; }

rc=0; run --mode branch --base origin/master --prompt "look" || rc=$?
check "both clean: exit 0" '[[ "$rc" -eq 0 ]]' "rc=$rc; $(cat "$TMP/out")"
# Each fake review takes a second, so run one after the other their start times would be a second apart.
gap="$(python3 -c "import json; s = [json.load(open('$FAKE_LOG/' + e + '.seen'))['start'] for e in ('codex', 'claude')]; print(abs(s[0] - s[1]))" 2>/dev/null || echo 99)"
check "both engines ran, in parallel (their start times under 0.9 s apart)" 'python3 -c "import sys; sys.exit(0 if $gap < 0.9 else 1)"' "start gap $gap s"
check "each got the same scope plus its own --engine and outputs" 'python3 -c "
import json, sys
for e in (\"codex\", \"claude\"):
    a = json.load(open(\"$FAKE_LOG/\" + e + \".seen\"))[\"argv\"]
    assert a[:5] == [\"--mode\", \"branch\", \"--base\", \"origin/master\", \"--prompt\"] and a[5] == \"look\", a
    assert a[a.index(\"--engine\") + 1] == e and a[a.index(\"--output\") + 1].endswith(\"/\" + e + \".md\"), a
"'
check "the secrets file is sourced for the reviewers" 'grep -q "\"secret\": \"from-env-secrets\"" "$FAKE_LOG/codex.seen"'
printf 'export EXAMPLE_PAIR_SECRET=from-other-file\n' > "$TMP/other.env"
rc=0; AUTOREVIEW_ENV_FILE="$TMP/other.env" run --mode branch --base origin/master || rc=$?
check "AUTOREVIEW_ENV_FILE names another file to source" '[[ "$rc" -eq 0 ]] && grep -q "\"secret\": \"from-other-file\"" "$FAKE_LOG/codex.seen"' "rc=$rc"
rc=0; AUTOREVIEW_ENV_FILE='' run --mode branch --base origin/master || rc=$?
check "an empty AUTOREVIEW_ENV_FILE sources nothing" '[[ "$rc" -eq 0 ]] && grep -q "\"secret\": null" "$FAKE_LOG/codex.seen"' "rc=$rc"
if [[ "$(uname -s)" == Darwin ]]; then
    check "TMPDIR is the per-user temp directory on macOS" 'grep -q "\"tmpdir\": \"$(getconf DARWIN_USER_TEMP_DIR | sed "s:/$::")\"" "$FAKE_LOG/codex.seen"'
else
    ok "# SKIP TMPDIR: not macOS"
fi
check "the summary names each verdict and report" 'grep -q "^codex   scoped-clean  overall: patch is correct" "$TMP/out" && grep -q "^claude  scoped-clean" "$TMP/out" && grep -q "/codex.md$" "$TMP/out"' "$(cat "$TMP/out")"
check "the default output directory is under XDG_STATE_HOME" 'ls -d "$XDG_STATE_HOME"/autoreview-pair/repo-* >/dev/null 2>&1'

rc=0; FAKE_CODEX=findings run --mode commit --commit HEAD || rc=$?
check "one review with findings: exit 1, counted" '[[ "$rc" -eq 1 ]] && grep -q "^codex   findings (1)" "$TMP/out"' "rc=$rc; $(cat "$TMP/out")"
rc=0; FAKE_CODEX=findings FAKE_CLAUDE=crash run --mode commit --commit HEAD || rc=$?
check "a review that did not finish wins: exit 2, with its log tail" '[[ "$rc" -eq 2 ]] && grep -q "^claude  did not finish (no status, exit 3)  fake: could not authenticate" "$TMP/out"' "rc=$rc; $(cat "$TMP/out")"
rc=0; run --out "$TMP/reused" --mode commit --commit HEAD || rc=$?
rc2=0; FAKE_CLAUDE=crash run --out "$TMP/reused" --mode commit --commit HEAD || rc2=$?
check "a reused --out cannot pass off the last run's clean result as this one's" '[[ "$rc" -eq 0 && "$rc2" -eq 2 ]] && grep -q "^claude  did not finish" "$TMP/out"' "rc=$rc rc2=$rc2; $(cat "$TMP/out")"
# Without jq on PATH (the wrapper must not need it): only the tools it uses, linked into one directory.
mkdir -p "$TMP/nojq"
for t in bash env git python3 mkdir chmod date basename uname getconf cat grep tail tr rm awk sed dirname; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$TMP/nojq/$t"
done
rc=0; (cd "$TMP/repo" && PATH="$TMP/nojq" "$PAIR" --mode commit --commit HEAD) > "$TMP/out" 2>&1 || rc=$?
check "without jq a clean pair is still clean" '[[ "$rc" -eq 0 ]] && grep -q "^codex   scoped-clean" "$TMP/out"' "rc=$rc; $(cat "$TMP/out")"
rc=0; (cd "$TMP/repo" && FAKE_CLAUDE=findings PATH="$TMP/nojq" "$PAIR" --mode commit --commit HEAD) > "$TMP/out" 2>&1 || rc=$?
check "without jq findings are still counted" '[[ "$rc" -eq 1 ]] && grep -q "^claude  findings (1)" "$TMP/out"' "rc=$rc; $(cat "$TMP/out")"

# Code in the checkout under review never runs in the wrapper (it holds the sourced secrets): a json.py there
# would shadow the standard library for a python3 that puts the working directory on sys.path.
printf 'import sys\nopen(%s, "w").write("ran")\nsys.exit(9)\n' "'$TMP/json-ran'" > "$TMP/repo/json.py"
rc=0; run --mode commit --commit HEAD || rc=$?
check "a json.py in the reviewed checkout neither runs nor breaks the verdict" '[[ "$rc" -eq 0 && ! -e "$TMP/json-ran" ]] && grep -q "^codex   scoped-clean" "$TMP/out"' "rc=$rc; $(cat "$TMP/out")"
rm -f "$TMP/repo/json.py"

rm -f "$FAKE_LOG"/*.seen
rc=0; run --engines codex --out "$TMP/one" --mode commit --commit HEAD || rc=$?
check "--engines codex runs only Codex, into --out" '[[ "$rc" -eq 0 && -f "$FAKE_LOG/codex.seen" && ! -f "$FAKE_LOG/claude.seen" && -f "$TMP/one/codex.md" ]]'

rc=0; run --engine codex --mode local || rc=$?
check "--engine is refused (the wrapper sets it)" '[[ "$rc" -eq 64 ]] && grep -q "set per engine" "$TMP/out"'
rc=0; run || rc=$?
check "no scope is a usage error" '[[ "$rc" -eq 64 ]]'
rc=0; run --out "$TMP/repo/reviews" --mode local || rc=$?
check "an output directory inside the checkout is refused" '[[ "$rc" -eq 64 ]] && grep -q "outside the checkout" "$TMP/out"'
rc=0; run --engines codex,bogus --mode local || rc=$?
check "an unknown engine is refused" '[[ "$rc" -eq 64 ]]'
rc=0; (cd "$TMP" && "$PAIR" --mode local) > "$TMP/out" 2>&1 || rc=$?
check "outside a git checkout is a usage error" '[[ "$rc" -eq 64 ]]'
check "--help prints the header, usage included" '"$PAIR" --help | grep -q "^  autoreview-pair \[--out DIR\] \[--engines codex,claude\]"' "$("$PAIR" --help | head -5)"

printf '# %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
