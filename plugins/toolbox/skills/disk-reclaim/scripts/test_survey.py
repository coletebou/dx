"""Run with: python3 -B -m unittest discover -s plugins/toolbox/skills/disk-reclaim/scripts -v
(or bash scripts/tests/run-all.sh disk-reclaim, through scripts/tests/disk-reclaim.test.py)."""

import argparse
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import survey


class SurveyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="disk-survey-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def target(self, name="cache"):
        path = self.root / name
        path.mkdir()
        return survey.Target(path, name)

    def test_real_scan_keeps_files_and_treats_paths_as_literal_arguments(self):
        target = self.target("cache with 'quotes' $(touch SENTINEL)\nand newline")
        payload = target.path / "important.txt"
        payload.write_bytes(b"must remain intact" * 1024)
        before = payload.stat()
        report = survey.survey([target], self.root, budget=5)
        row = report["candidates"][0]
        self.assertEqual(row["status"], "ok")
        self.assertGreater(row["size_kib"], 0)
        self.assertTrue(report["read_only"])
        self.assertEqual(payload.read_bytes(), b"must remain intact" * 1024)
        self.assertEqual(payload.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual(list(self.root.iterdir()), [target.path])
        self.assertNotIn("reclaimed", report)

    def test_symlink_is_not_scanned_and_duplicate_paths_are_measured_once(self):
        target = self.target()
        link = self.root / "linked-store"
        link.symlink_to(target.path, target_is_directory=True)
        rows = survey.prepare([target, target, survey.Target(link, "link")])
        self.assertEqual([r["status"] for r in rows], ["pending", "duplicate", "symlink"])
        self.assertIsNone(rows[2]["size_kib"])

    def test_missing_and_permission_denied_are_distinct(self):
        missing = survey.prepare([survey.Target(self.root / "absent", "missing")])[0]
        self.assertEqual(missing["status"], "missing")
        target = self.target()
        with patch.object(Path, "lstat", side_effect=PermissionError("access denied")):
            denied = survey.prepare([target])[0]
        self.assertEqual(denied["status"], "error")
        self.assertIsNone(denied["size_kib"])

    def test_partial_du_is_not_reported_as_a_complete_measurement(self):
        row = survey.prepare([self.target()])[0]
        with patch.object(survey, "command", return_value={
            "status": "error", "stdout": "42\t/some/cache\n", "detail": "Permission denied",
        }):
            result = survey.measure(row, "du", time.monotonic() + 1, 1)
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["size_kib"], 42)

    def test_empty_or_bad_du_output_is_unknown_not_zero(self):
        row = survey.prepare([self.target()])[0]
        with patch.object(survey, "command", return_value={
            "status": "ok", "stdout": "", "detail": "",
        }):
            result = survey.measure(row, "du", time.monotonic() + 1, 1)
        self.assertEqual(result["status"], "error")
        self.assertIsNone(result["size_kib"])

    def test_native_command_timeout_is_bounded_and_process_reaped(self):
        real_run = subprocess.run
        with patch.object(survey.subprocess, "run", wraps=real_run) as run:
            started = time.monotonic()
            result = survey.command([sys.executable, "-c", "import time; time.sleep(10)"], 0.05)
        self.assertEqual(result["status"], "timeout")
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(run.call_args.kwargs["stdin"], subprocess.DEVNULL)

    def test_budget_exhaustion_does_not_start_another_process(self):
        with patch.object(survey.subprocess, "run") as run:
            result = survey.command(["du", "/unused"], 0)
        run.assert_not_called()
        self.assertEqual(result["status"], "budget")

    def test_scan_has_bounded_concurrency_and_shared_deadline(self):
        targets = [self.target(f"cache-{i}") for i in range(12)]
        lock = threading.Lock()
        active, peak = 0, 0

        def slow_command(argv, timeout):
            nonlocal active, peak
            if timeout <= 0:
                return {"status": "budget", "stdout": "", "detail": "budget exhausted"}
            with lock:
                active += 1
                peak = max(peak, active)
            time.sleep(min(timeout, 0.5))
            with lock:
                active -= 1
            return {"status": "timeout", "stdout": "", "detail": "timeout"}

        # Long enough per path that the two workers overlap even on a heavily loaded host; the
        # budget still runs out after two rounds, so later targets never start.
        with patch.object(survey, "capacity", return_value={"status": "ok"}), \
                patch.object(survey, "command", side_effect=slow_command):
            report = survey.survey(targets, self.root, budget=1.0, per_path=0.5, workers=2)
        self.assertEqual(peak, 2)
        self.assertLess(report["elapsed_seconds"], 4)
        self.assertGreater(report["status_counts"].get("budget", 0), 0)
        self.assertFalse(report["measurement_complete"])
        self.assertTrue(all(r["size_kib"] is None for r in report["candidates"]))

    def test_df_preserves_apfs_capacity_and_mount_with_spaces(self):
        with patch.object(survey, "command", return_value={
            "status": "ok", "detail": "",
            "stdout": "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
                      "/dev/disk3s5 239362496 199993140 5233712 98% /Volumes/External Data\n",
        }):
            result = survey.capacity(self.root, "df", 1)
        self.assertEqual(result["available_kib"], 5233712)
        self.assertEqual(result["used_percent"], 98)
        self.assertEqual(result["mount"], "/Volumes/External Data")

    def test_overlap_uses_path_components_not_string_prefixes(self):
        parent = self.target("cache")
        child = parent.path / "nested"
        child.mkdir()
        sibling = self.target("cache-old")
        pairs = survey.overlaps(survey.prepare([parent, survey.Target(child, "child"), sibling]))
        self.assertEqual(pairs, [[str(parent.path.resolve()), str(child.resolve())]])

    def test_nested_scan_measures_only_specific_target(self):
        parent = self.target()
        child = parent.path / "child"
        child.mkdir()
        report = survey.survey([parent, survey.Target(child, "child")], self.root, budget=5)
        self.assertEqual([r["status"] for r in report["candidates"]], ["overlap", "ok"])
        self.assertFalse(report["measurement_complete"])
        self.assertIsNone(report["candidates"][0]["size_kib"])

    def test_parent_symlink_destination_is_visible_in_text_report(self):
        target = self.target()
        child = target.path / "child"
        child.mkdir()
        link = self.root / "parent-link"
        link.symlink_to(target.path, target_is_directory=True)
        report = survey.survey([survey.Target(link / "child", "linked child")], self.root, budget=5)
        with patch.object(sys, "stdout", new_callable=io.StringIO) as output:
            survey.display(report)
        self.assertIn(str(child.resolve()), output.getvalue())

    def test_defaults_are_targeted_and_os_specific(self):
        mac = survey.default_targets(self.root, "Darwin", {"TMPDIR": str(self.root / "tmp")})
        linux = survey.default_targets(self.root, "Linux", {})
        for target in mac:
            self.assertNotIn(target.path, (self.root, self.root / "code", Path("/"), Path("/Users")))
        self.assertTrue(any("Xcode" in str(t.path) for t in mac))
        self.assertFalse(any("Xcode" in str(t.path) for t in linux))
        self.assertEqual(next(t for t in mac if t.path == self.root / ".npm/_npx").kind, "runtime")
        self.assertEqual(next(t for t in mac if t.path == self.root / ".Trash").kind, "data")

    def test_cli_selected_paths_replace_default_scan_and_json_is_valid(self):
        target = self.target()
        result = subprocess.run(
            [sys.executable, "-B", str(Path(survey.__file__)), "--path", str(target.path),
             "--filesystem", str(self.root), "--format", "json"],
            capture_output=True, text=True, timeout=10, check=True,
        )
        report = json.loads(result.stdout)
        self.assertEqual(len(report["candidates"]), 1)
        self.assertEqual(report["candidates"][0]["path"], str(target.path))

    def test_machine_id_comes_from_the_environment_not_the_hostname(self):
        with patch.object(survey, "capacity", return_value={"status": "ok"}):
            with patch.dict(survey.os.environ, {"CLAUDE_MACHINE": "", "DF_MACHINE": "box-a"}):
                named = survey.survey([], self.root, budget=1)
            with patch.dict(survey.os.environ, {"CLAUDE_MACHINE": "", "DF_MACHINE": ""}):
                unnamed = survey.survey([], self.root, budget=1)
        self.assertEqual(named["machine"], "box-a")
        self.assertEqual(unnamed["machine"], "unidentified-local")

    def test_time_limits_reject_nan_infinity_and_nonpositive_values(self):
        for value in ("nan", "inf", "-1", "0"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                survey.positive(value)


if __name__ == "__main__":
    unittest.main()
