#!/usr/bin/env python3
"""Hermetic tests for scripts/dream (the light -> REM -> deep sweep).

SCRIPT_DIR points at a temp dir holding the real lib/memory-homes.sh and
dream-held-nights next to a fake claude-consolidate, which records each phase it
is asked for and writes a canned report (the deep one comes from a file a test
controls), so no model is called and nothing under the real HOME is touched.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DREAM = ROOT / "scripts/dream"

FAKE_CONSOLIDATE = r"""#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
prompt = open(a[a.index("--prompt") + 1]).read()
phase = next(p for p in ("LIGHT", "REM", "DEEP") if prompt.startswith(p))
inputs = [a[i + 1] for i, x in enumerate(a) if x == "--input"]
with open(os.environ["FAKE_CALLS"], "a") as f:
    f.write(json.dumps({"phase": phase, "model": a[a.index("--model") + 1], "inputs": inputs}) + "\n")
if os.environ.get("FAKE_FAIL") == phase:
    sys.exit(3)
out = a[a.index("--output") + 1]
if phase == "DEEP":
    text = open(os.environ["FAKE_DEEP"]).read()
else:
    text = f"# {phase.title()}\n\n## Themes\n- x\n\n## Dream fragment ({phase.title()})\nYou drift through {phase.lower()} light.\n"
open(out, "w").write(text)
"""

PROMOTION = """# Deep — today

## Promoted (1)
=== FILE: feedback_use_pnpm.md ===
---
name: Use pnpm
description: installs go through pnpm
type: feedback
---
Use pnpm for every install.

=== MEMORY.md append ===
- [Use pnpm](feedback_use_pnpm.md) installs go through pnpm

## Rejected (reasons)
- **Branch tip is abc123**: work-state

## Dream fragment (Deep)
You set one stone and leave the rest in the river.
"""


@unittest.skipUnless(shutil.which("python3"), "python3 is required")
class DreamTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dream-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        sd = root / "scripts"
        (sd / "lib").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/lib/memory-homes.sh", sd / "lib/memory-homes.sh")
        shutil.copy(ROOT / "scripts/dream-held-nights", sd / "dream-held-nights")
        (sd / "claude-consolidate").write_text(FAKE_CONSOLIDATE)
        (sd / "claude-consolidate").chmod(0o755)
        self.mem = root / "memory/webapp"
        (self.mem / ".analysis/laptop").mkdir(parents=True)
        (self.mem / "MEMORY.md").write_text("- [Existing](reference_existing.md) already known\n")
        (self.mem / "reference_existing.md").write_text("---\nname: Existing\n---\nkept\n")
        for name in ("unfinished.md", "memory-candidates.raw.md", "workflow-tips.md", "memory-candidates.md"):
            (self.mem / ".analysis/laptop" / name).write_text(f"# {name}\n- something\n")
        (root / "homes.conf").write_text(f"webapp {self.mem}\n")
        self.conf = root / "dreaming.conf"
        self.write_conf()
        self.deep = root / "deep.md"
        self.deep.write_text(PROMOTION)
        self.calls = root / "calls.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("MEMORY_", "DREAM", "FAKE_"))}
        self.env.update(SCRIPT_DIR=str(sd), DREAMCONF=str(self.conf), MEMORY_HOMES_CONF=str(root / "homes.conf"),
                        FAKE_CALLS=str(self.calls), FAKE_DEEP=str(self.deep))

    def write_conf(self, extra=""):
        self.conf.write_text('enabled_repos=(\n  "webapp"\n)\ndream_machines=""\nlight_model="haiku"\n'
                             'rem_model="sonnet"\ndeep_model="opus"\ndreaming_model="sonnet"\n' + extra)

    def dream(self, *args, **env):
        return subprocess.run(["bash", str(DREAM), *args], env={**self.env, **env}, capture_output=True,
                              text=True, timeout=120)

    def calls_made(self):
        return [json.loads(x) for x in self.calls.read_text().splitlines()] if self.calls.exists() else []

    def test_sweep_runs_three_phases_promotes_and_keeps_a_diary(self):
        r = self.dream("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = self.calls_made()
        self.assertEqual([(c["phase"], c["model"]) for c in calls], [("LIGHT", "haiku"), ("REM", "sonnet"), ("DEEP", "opus")])
        self.assertTrue(any(p.endswith("laptop/unfinished.md") for p in calls[0]["inputs"]), "per-host .analysis is read")
        self.assertEqual((self.mem / "feedback_use_pnpm.md").read_text().splitlines()[1], "name: Use pnpm")
        self.assertIn("- [Use pnpm](feedback_use_pnpm.md)", (self.mem / "MEMORY.md").read_text())
        diary = (self.mem / "DREAMS.md").read_text()
        for phase in ("LIGHT", "REM", "DEEP"):
            self.assertIn(f" · {phase}\n", diary)
        self.assertIn("You set one stone", diary)
        reports = sorted(p.parent.name for p in (self.mem / "dreaming").glob("*/*.md"))
        self.assertEqual(reports, ["deep", "light", "rem"])

    def test_the_writer_refuses_bad_slugs_reserved_names_and_clobbering(self):
        self.deep.write_text("""# Deep

## Promoted (5)
=== FILE: ../escape.md ===
evil
=== FILE: Memory.md ===
evil
=== FILE: MEMORY.md ===
evil
=== FILE: reference_existing.md ===
overwrite attempt
=== FILE: gotcha_fresh.md ===
---
name: Fresh
---
fresh body

=== MEMORY.md append ===
- [Escape](../escape.md) no
- [Existing](reference_existing.md) dup
- [Fresh](gotcha_fresh.md) and [Never written](gotcha_never.md)
- [Fresh alone](gotcha_fresh.md) the good one

## Rejected (reasons)
None

## Dream fragment (Deep)
Quiet.
""")
        r = self.dream("deep")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.mem.parent / "escape.md").exists())
        self.assertEqual((self.mem / "reference_existing.md").read_text(), "---\nname: Existing\n---\nkept\n")
        self.assertEqual(sorted(p.name for p in self.mem.glob("*.md")),
                         ["DREAMS.md", "MEMORY.md", "gotcha_fresh.md", "reference_existing.md"])
        index = (self.mem / "MEMORY.md").read_text()
        self.assertIn("- [Fresh alone](gotcha_fresh.md) the good one", index)
        self.assertNotIn("Never written", index, "a line with any unresolved link is dropped")
        self.assertNotIn("escape", index)
        self.assertEqual(index.count("reference_existing.md"), 1, "the existing line is not re-appended")

    def test_a_full_index_refuses_the_append_and_rolls_the_file_back(self):
        lines = "".join(f"- [M{n}](reference_existing.md) x\n" for n in range(188))
        (self.mem / "MEMORY.md").write_text(lines)
        self.write_conf("deep_memory_md_max_lines=188\n")
        r = self.dream("deep")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("exceeds 188L", r.stderr)
        self.assertFalse((self.mem / "feedback_use_pnpm.md").exists(), "no unindexed orphan is left behind")
        self.assertEqual((self.mem / "MEMORY.md").read_text(), lines)

    def test_an_absent_index_is_never_created_by_a_promotion(self):
        (self.mem / "MEMORY.md").unlink()
        r = self.dream("deep")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("MEMORY.md ABSENT", r.stderr)
        self.assertFalse((self.mem / "MEMORY.md").exists())
        self.assertFalse((self.mem / "feedback_use_pnpm.md").exists())

    def test_a_host_outside_the_gate_promotes_nothing(self):
        self.write_conf('dream_machines="some-other-host"\n')
        r = self.dream("sweep")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("is not a dreamer", r.stderr)
        self.assertEqual(self.calls_made(), [])
        me = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip().lower()
        self.write_conf(f'dream_machines="some-other-host"\ndream_machines_webapp="{me}"\n')
        self.assertEqual(self.dream("sweep").returncode, 0)
        self.assertEqual(len(self.calls_made()), 3, "a per-repo gate naming this host lets it dream")

    def test_a_failed_phase_fails_the_sweep(self):
        r = self.dream("sweep", FAKE_FAIL="REM")
        self.assertEqual(r.returncode, 1)
        self.assertIn("rem FAILED for webapp", r.stderr)

    def test_per_repo_model_override(self):
        self.write_conf('model_webapp="claude-opus-5-5"\n')
        self.dream("sweep")
        self.assertEqual({c["model"] for c in self.calls_made()}, {"claude-opus-5-5"})

    def test_enable_and_disable_edit_the_conf(self):
        self.assertEqual(self.dream("enable", "shop").returncode, 0)
        self.assertIn('  "shop"\n)', self.conf.read_text())
        self.assertIn("already enabled", self.dream("enable", "shop").stderr)
        self.assertEqual(self.dream("disable", "webapp").returncode, 0)
        self.assertNotIn('"webapp"', self.conf.read_text())
        out = self.dream("status").stdout
        self.assertIn("shop (UNRESOLVED", out)

    def test_the_diary_rotates_whole_entries_into_an_archive(self):
        head = "# Dream Diary\n\nintro\n"
        entries = "".join(f"\n## 2026-01-{d:02d} · DEEP\n\n" + "line\n" * 5 for d in range(1, 21))
        (self.mem / "DREAMS.md").write_text(head + entries)
        self.write_conf("dreams_md_keep_lines=40\n")
        r = self.dream("light")
        self.assertEqual(r.returncode, 0, r.stderr)
        kept = (self.mem / "DREAMS.md").read_text()
        self.assertLessEqual(len(kept.strip().split("\n")), 40)
        self.assertTrue(kept.startswith("# Dream Diary"))
        self.assertIn(" · LIGHT", kept, "the newest entry stays")
        archives = list(self.mem.glob("DREAMS-archive-*.md"))
        self.assertEqual(len(archives), 1)
        self.assertIn("## 2026-01-01 · DEEP", archives[0].read_text())
        self.assertNotIn("## 2026-01-01 · DEEP", kept)


if __name__ == "__main__":
    unittest.main(verbosity=2)
