#!/usr/bin/env bash
# autoreview.test.sh: the autoreview skill's own suites (plugins/review/skills/autoreview), hermetic.
# Its Python sources compile and its shell harness parses; then its unittest groups run in parallel,
# each with an empty HOME and TMPDIR and nothing of the caller's environment but PATH, so no
# AUTOREVIEW_* setting, credential, ~/.codex or ~/.claude reaches them. The engines are fakes and
# nothing needs the network.
#
#   bash scripts/tests/autoreview.test.sh [GROUP...]
#
# Groups: core (scripts/autoreview_test.py), boundaries (every other tests/test_*.py), hardening-1
# and hardening-2 (tests/test_autoreview_hardening.py, split in two). Default: all four.
# AUTOREVIEW_TEST_PYTHON is the interpreter (default: python3 when it is 3.10 or newer, else the
# newest python3.1x on PATH). AUTOREVIEW_TEST_JOBS caps the groups run at once (default 4).
# Pillow is optional (pip install -r plugins/review/skills/autoreview/requirements-dev.txt):
# without it the tests that decode images are skipped, and the summary counts them.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
skill="$root/plugins/review/skills/autoreview"
groups=(core boundaries hardening-1 hardening-2)
[[ $# -eq 0 ]] || groups=("$@")
for g in "${groups[@]}"; do
  case "$g" in core|boundaries|hardening-1|hardening-2) ;; *) echo "autoreview.test.sh: unknown group $g" >&2; exit 64 ;; esac
done

new_enough() { "$1" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; }
py="${AUTOREVIEW_TEST_PYTHON:-}"
if [[ -z "$py" ]]; then
  for c in python3 python3.14 python3.13 python3.12 python3.11 python3.10; do
    p="$(command -v "$c" 2>/dev/null)" || continue
    if new_enough "$p"; then py="$p"; break; fi
  done
fi
if [[ -z "$py" ]] || ! new_enough "$py"; then
  echo "autoreview.test.sh: needs Python 3.10 or newer (set AUTOREVIEW_TEST_PYTHON)" >&2; exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/autoreview-test.XXXXXX")"
work="$(cd "$work" && pwd -P)"
trap 'rm -rf "$work"' EXIT

# One group of the unittest suites, bound to this checkout under a private package name, so the test
# modules' relative imports resolve here and never in an installed package of the same name.
cat > "$work/driver.py" <<'PY'
import importlib.machinery
import importlib.util
import inspect
import sys
import unittest
from pathlib import Path

skill, group = Path(sys.argv[1]), sys.argv[2]
spec = importlib.machinery.ModuleSpec("autoreview_skill", None, is_package=True)
spec.submodule_search_locations = [str(skill)]
sys.modules["autoreview_skill"] = importlib.util.module_from_spec(spec)

if group == "core":
    names = ["autoreview_skill.scripts.autoreview_test"]
elif group == "boundaries":
    names = sorted(f"autoreview_skill.tests.{p.stem}" for p in (skill / "tests").glob("test_*.py")
                   if p.stem != "test_autoreview_hardening")
else:
    names = ["autoreview_skill.tests.test_autoreview_hardening"]
loader = unittest.TestLoader()
suite = loader.loadTestsFromNames(names)
if loader.errors:
    print("\n".join(loader.errors))
    sys.exit(1)


def flat(s):
    for t in s:
        if isinstance(t, unittest.TestSuite):
            yield from flat(t)
        else:
            yield t


tests = list(flat(suite))
if group.startswith("hardening-"):
    tests = sorted(tests, key=lambda t: t.id())[int(group[-1]) - 1::2]
if not tests:
    print(f"{group}: no tests found")
    sys.exit(1)

image_skips = 0
if importlib.util.find_spec("PIL") is None:
    for t in tests:
        method = getattr(t, t._testMethodName, None)
        try:
            source = inspect.getsource(method)
        except (OSError, TypeError):
            source = ""
        # The image suites need Pillow throughout (the helper refuses image review without it);
        # elsewhere only a test that imports it itself does, so the rest still runs.
        if "Image" in type(t).__name__ or "from PIL import" in source:
            setattr(t, t._testMethodName, unittest.skip("Pillow is not installed")(method))
            image_skips += 1

result = unittest.TextTestRunner(stream=sys.stdout, verbosity=1).run(unittest.TestSuite(tests))
print(f"summary: ran={result.testsRun} failures={len(result.failures)} errors={len(result.errors)}"
      f" skipped={len(result.skipped)} image_skips={image_skips}")
sys.exit(0 if result.wasSuccessful() else 1)
PY

echo "python: $("$py" -c 'import sys; print(sys.version.split()[0])') ($py)"
# The caller's per-user site-packages (pip install --user) stay importable with HOME emptied.
userbase="$("$py" -c 'import site; print(site.getuserbase())' 2>/dev/null)"
status=0
if ! "$py" -B - "$skill" <<'PY'
import sys
from pathlib import Path

skill = Path(sys.argv[1])
bad = 0
for p in sorted(skill.rglob("*")):
    if not p.is_file() or "__pycache__" in p.parts:
        continue
    text = p.read_bytes()
    if p.suffix == ".py" or (p.suffix == "" and text.startswith(b"#!") and b"python" in text.split(b"\n", 1)[0]):
        try:
            compile(text, str(p), "exec")
        except SyntaxError as exc:
            print(f"compile: {p.relative_to(skill)}: {exc}")
            bad = 1
sys.exit(bad)
PY
then status=1; echo "compile: FAILED"; else echo "compile: ok"; fi
if bash -n "$skill/scripts/test-review-harness"; then echo "bash -n: ok"; else status=1; echo "bash -n: FAILED"; fi

run_group() {  # run_group GROUP: its log is $work/GROUP.log, its exit status $work/GROUP.rc
  local g="$1" start=$SECONDS
  mkdir -p "$work/$g/home" "$work/$g/tmp"
  (cd "$root" && env -i HOME="$work/$g/home" TMPDIR="$work/$g/tmp" PATH="$PATH" PYTHONUTF8=1 TERM=dumb \
    ${userbase:+PYTHONUSERBASE="$userbase"} \
    "$py" -B "$work/driver.py" "$skill" "$g") > "$work/$g.log" 2>&1
  echo "$? $((SECONDS - start))" > "$work/$g.rc"
}
jobs_max="${AUTOREVIEW_TEST_JOBS:-4}"
[[ "$jobs_max" =~ ^[1-9][0-9]*$ ]] || jobs_max=4
i=0
while (( i < ${#groups[@]} )); do
  pids=()
  for g in "${groups[@]:i:jobs_max}"; do run_group "$g" & pids+=("$!"); done
  wait "${pids[@]}"
  i=$((i + jobs_max))
done

for g in "${groups[@]}"; do
  rc=1 secs=0   # a group whose shell died before recording its status counts as failed
  [[ -f "$work/$g.rc" ]] && read -r rc secs < "$work/$g.rc"
  line="$(grep '^summary: ' "$work/$g.log" | tail -n 1)"
  if [[ "$rc" -eq 0 ]]; then
    printf '%-12s ok    %4ss  %s\n' "$g" "$secs" "${line#summary: }"
  else
    status=1
    printf '%-12s FAIL  %4ss  %s\n' "$g" "$secs" "${line#summary: }"
    sed 's/^/  | /' "$work/$g.log"
  fi
done
exit "$status"
