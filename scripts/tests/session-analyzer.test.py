#!/usr/bin/env python3
"""Hermetic tests for scripts/session-analyzer.

Synthetic transcripts in a temp projects dir, temp memory-homes and canonicals
confs, and a fake claude-consolidate (CLAUDE_CONSOLIDATE_BIN) that records each
call and writes a canned reply, so no model is called and nothing under the real
HOME is read or written.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/session-analyzer"

FAKE_CONSOLIDATE = r"""#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
prompt = open(a[a.index("--prompt") + 1]).read()
inputs = [a[i + 1] for i, x in enumerate(a) if x == "--input"]
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write(json.dumps({"prompt": prompt[:200], "inputs": [open(p).read() for p in inputs]}) + "\n")
out = a[a.index("--output") + 1]
if "workflow patterns" in prompt:
    open(out, "w").write("# Workflow tips (1 actionable)\n\n## Do not push early\n")
else:
    open(out, "w").write("Sure, here you go.\n\n# Memory candidates (1 new)\n\n- [type: feedback] Use pnpm\n")
"""


def bash_ok():
    """session-analyzer needs bash 4.4+ (macOS ships 3.2; CI runners have a newer one first)."""
    try:
        out = subprocess.run(["bash", "-c", "echo ${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"],
                             capture_output=True, text=True).stdout.split()
        return (int(out[0]), int(out[1])) >= (4, 4)
    except (OSError, ValueError, IndexError):
        return False


def user(text, uuid):
    return {"type": "user", "uuid": uuid, "message": {"role": "user", "content": text}}


def assistant(*blocks):
    return {"type": "assistant", "message": {"role": "assistant", "content": list(blocks)}}


@unittest.skipUnless(shutil.which("jq") and bash_ok(), "needs jq and bash 4.4+")
class SessionAnalyzerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="analyzer-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.projects = root / "projects"
        self.tdir = self.projects / "-home-u-code-webapp"
        self.tdir.mkdir(parents=True)
        self.home = root / "memory/webapp"
        self.home.mkdir(parents=True)
        (self.home / "MEMORY.md").write_text("- [Existing](existing.md) — already known\n")
        (root / "homes.conf").write_text(f"# repo home\nwebapp {self.home}\n")
        (root / "canonicals.conf").write_text("# repo machine:dir\nwebapp testbox:-home-u-code-webapp\n"
                                              "other otherbox:-home-u-code-other\n")
        fake = root / "consolidate"
        fake.write_text(FAKE_CONSOLIDATE)
        fake.chmod(0o755)
        self.calls = root / "calls.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("MEMORY_", "CLAUDE_"))}
        self.env.update(MEMORY_HOMES_CONF=str(root / "homes.conf"), MEMORY_CANONICALS_CONF=str(root / "canonicals.conf"),
                        CLAUDE_CONSOLIDATE_BIN=str(fake), FAKE_CALLS=str(self.calls))
        self.write("a1", [
            user("please ship the widget", "u-a1-1"),
            assistant({"type": "tool_use", "name": "TaskCreate", "id": "t1", "input": {"subject": "Ship the widget"}}),
            user("don't push to main yet", "u-a1-2"),
            user("from now on we use pnpm for every install", "u-a1-3"),
            assistant({"type": "text", "text": "Understood."}),
        ])
        self.write("b1", [
            user("acme-confidential: don't share the quarterly numbers", "u-b1-1"),
            assistant({"type": "tool_use", "name": "TaskCreate", "id": "t2", "input": {"subject": "Client report"}}),
        ])
        old = self.write("c1", [assistant({"type": "tool_use", "name": "TaskCreate", "id": "t3",
                                           "input": {"subject": "Ancient task"}})])
        past = time.time() - 90 * 86400
        os.utime(old, (past, past))

    def write(self, name, entries):
        path = self.tdir / f"{name}.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        return path

    def run_it(self, *extra, **env):
        return subprocess.run(["bash", str(SCRIPT), "--transcripts-root", str(self.projects), "--machine", "testbox",
                               *extra], env={**self.env, **env}, capture_output=True, text=True, timeout=120)

    def calls_made(self):
        return [json.loads(x) for x in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_reports_open_work_tips_and_candidates_for_this_machines_rows(self):
        r = self.run_it(MEMORY_BOUNDARY_CMD='grep -q acme-confidential "$MEMORY_BOUNDARY_PATH"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("1 sessions in window", r.stderr)
        self.assertIn("1 restricted skipped", r.stderr)
        analysis = self.home / ".analysis"
        unfinished = (analysis / "unfinished.md").read_text()
        self.assertIn("open=1 · session=a1", unfinished)
        self.assertIn("    - Ship the widget", unfinished)
        for absent in ("Client report", "Ancient task"):
            self.assertNotIn(absent, unfinished, "restricted and out-of-window sessions are not read")
        raw_tips = (analysis / "workflow-tips.raw.md").read_text()
        self.assertIn("[u-a1-2] don't push to main yet", raw_tips)
        self.assertNotIn("quarterly", raw_tips)
        self.assertIn("from now on we use pnpm", (analysis / "memory-candidates.raw.md").read_text())
        self.assertTrue((analysis / "workflow-tips.md").read_text().startswith("# Workflow tips (1 actionable)"))
        candidates = (analysis / "memory-candidates.md").read_text()
        self.assertTrue(candidates.startswith("# Memory candidates (1 new)"), "a preamble before the heading is cut")
        calls = self.calls_made()
        self.assertEqual(len(calls), 2)
        self.assertIn("already known", calls[0]["inputs"][0], "MEMORY.md is offered so known facts are skipped")
        self.assertFalse(any("quarterly" in i for c in calls for i in c["inputs"]))

    def test_without_a_boundary_every_recent_session_is_read(self):
        r = self.run_it()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("2 sessions in window", r.stderr)
        self.assertIn("Client report", (self.home / ".analysis/unfinished.md").read_text())

    def test_a_broken_boundary_check_reads_nothing(self):
        r = self.run_it(MEMORY_BOUNDARY_CMD="/nonexistent/boundary-check")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("0 sessions in window", r.stderr)
        self.assertNotIn("Ship the widget", (self.home / ".analysis/unfinished.md").read_text())

    def test_dry_run_makes_no_model_calls_and_keeps_existing_tips(self):
        tips = self.home / ".analysis/workflow-tips.md"
        tips.parent.mkdir(parents=True)
        tips.write_text("# Workflow tips (3 actionable)\n")
        r = self.run_it("--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.calls_made(), [])
        self.assertEqual(tips.read_text(), "# Workflow tips (3 actionable)\n")

    def test_host_label_namespaces_the_output_and_other_machines_rows_are_ignored(self):
        r = self.run_it("--host-label", "laptop")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.home / ".analysis/laptop/unfinished.md").is_file())
        r = self.run_it("--machine", "nobody")
        self.assertIn("no canonicals found", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
