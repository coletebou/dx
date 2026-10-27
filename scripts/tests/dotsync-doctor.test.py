#!/usr/bin/env python3
"""dotsync doctor on temporary fixtures: what it reports, that it changes nothing, and that it
never prints file contents, remote credentials or secrets.

    python3 scripts/tests/dotsync-doctor.test.py
"""

import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

DOCTOR = Path(__file__).resolve().parents[1] / "dotsync-doctor"


@unittest.skipUnless(shutil.which("git"), "git is required")
class DoctorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dotsync-doctor-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.root.chmod(0o700)
        self.repo = self.root / "repo"
        self.state = self.root / "state"
        self.config = self.root / "config"
        self.installed = self.root / "bin" / "dotsync"
        self.lock = self.root / "lock"
        self.profile = self.root / "profile"
        for path in (self.repo, self.state, self.config, self.installed.parent):
            path.mkdir()
        self.profile.write_text("export DF_MACHINE=fixture\nexport DF_IDENTITY=example\n")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "DOTSYNC_", "XDG_", "ANTHROPIC_", "AWS_"))
                    and k not in {"DF_MACHINE", "DF_IDENTITY"}}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_ALLOW_PROTOCOL="file",
                        GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        self.git("init", "-q", "-b", "master")
        (self.repo / "scripts").mkdir()
        (self.repo / "scripts" / "dotsync").write_text("#!/bin/sh\nexit 0\n")
        (self.repo / "scripts" / "dotsync").chmod(0o755)
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.git("update-ref", "refs/remotes/origin/master", "HEAD")
        self.git("config", "branch.master.remote", "origin")
        self.git("config", "branch.master.merge", "refs/heads/master")
        # A credential-shaped remote URL, built at run time, that doctor must never print.
        userinfo = ":".join(("fixture", "NEVER_PRINT_REMOTE_SECRET"))
        self.git("config", "remote.origin.url", "https://" + "@".join((userinfo, "invalid.example")) + "/repo")
        self.git("config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")
        self.installed.symlink_to(self.repo / "scripts" / "dotsync")
        self.heartbeat = self.state / "heartbeat.json"
        self.write_heartbeat()
        self.log = self.state / "dotsync-timing.log"
        self.log.write_text("=== 2026-09-07 04:41:17 host=fixture pid=100 local=1 scheduled=0 peer=0 ===\n"
                            "  step git-fetch      503ms\n  step git-push       939ms\n  total           19.15s\n")
        (self.config / "peers").write_text("box-b\nbox-c example server\nbox-d other\n-bad\n")

    def git(self, *args, repo=None):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                                        "-C", str(repo or self.repo), *args], env=self.env,
                                       stderr=subprocess.DEVNULL, timeout=30).decode().strip()

    def write_heartbeat(self, **fields):
        data = dict(version=1, host="fixture", ts=int(time.time()), iso="2026-09-07T04:41:36Z", exit=0,
                    result="ok", phase="finished", branch="master", pushed=0, pulled=1, peers_failed=0,
                    scheduled=0, peer=0, deferred=0, pull_only=0)
        data.update(fields)
        self.heartbeat.write_text(json.dumps(data))

    def run_doctor(self, json_output=True, env=None, repo=None, host="fixture", extra=()):
        command = [sys.executable, str(DOCTOR), "--repo", str(repo or self.repo), "--state-dir", str(self.state),
                   "--config-dir", str(self.config), "--installed-path", str(self.installed),
                   "--lock-file", str(self.lock), "--profile-path", str(self.profile), *extra]
        if host:
            command += ["--host", host]
        if json_output:
            command.append("--json")
        done = subprocess.run(command, env=env or self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("NEVER_PRINT_REMOTE_SECRET", done.stdout + done.stderr)
        self.assertEqual(done.stderr, "")
        return json.loads(done.stdout) if json_output else done.stdout

    def codes(self, data):
        return [issue["code"] for issue in data["issues"]]

    def test_a_healthy_machine_and_no_side_effects(self):
        paths = [self.repo / ".git" / "index", self.repo / ".git" / "config", self.heartbeat, self.log]
        before = {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths}
        data = self.run_doctor()
        self.assertFalse(data["network_checked"])
        self.assertTrue(data["read_only"])
        self.assertEqual((data["host"], data["identity"]), ("fixture", "example"))
        self.assertEqual((data["repository"]["branch"], data["repository"]["upstream"]), ("master", "origin/master"))
        self.assertEqual((data["repository"]["ahead"], data["repository"]["behind"]), (0, 0))
        self.assertEqual(data["installation"]["status"], "linked")
        self.assertEqual(data["heartbeat"]["outcome"], "success")
        self.assertEqual((data["peers"]["peers"], data["peers"]["other_identity"], data["peers"]["invalid"]), (2, 1, 1))
        self.assertEqual(data["commit_messages"]["provider"], "off")
        self.assertEqual(before, {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in paths})
        self.assertFalse(self.lock.exists())
        self.assertIn("peers_invalid", self.codes(data))

    def test_missing_gitleaks_is_a_warning(self):
        bare = self.root / "no-gitleaks"
        bare.mkdir()
        (bare / "git").symlink_to(shutil.which("git"))
        data = self.run_doctor(env=dict(self.env, PATH=str(bare)))
        self.assertFalse(data["tools"]["gitleaks"])
        self.assertIn("gitleaks_missing", self.codes(data))
        self.assertEqual(data["health"], "attention")

    def test_no_peers_file_no_identity_and_no_upstream(self):
        (self.config / "peers").unlink()
        self.profile.write_text("export DF_MACHINE=fixture\n")
        self.git("config", "--unset", "branch.master.remote")
        data = self.run_doctor()
        for code in ("no_peers_file", "no_identity", "no_upstream"):
            self.assertIn(code, self.codes(data))

    def test_hooks_and_config_report_counts_and_unsafe_modes_without_contents(self):
        hooks = self.config / "hooks" / "post-pull.d"
        hooks.mkdir(parents=True)
        (self.config / "hooks").chmod(0o700)
        hooks.chmod(0o700)
        (hooks / "10-update").write_text("#!/bin/sh\necho PRIVATE_HOOK_BODY\n")
        (hooks / "10-update").chmod(0o700)
        (hooks / "notes.txt").write_text("PRIVATE_NOTE\n")
        (self.config / "config").write_text("DOTSYNC_PEER_TIMEOUT=45\nDOTSYNC_COMMIT_MESSAGE_PROVIDER=anthropic\n")
        (self.config / "config").chmod(0o600)
        data = self.run_doctor()
        self.assertEqual(data["hooks"]["stages"]["post-pull"], {"executable": 1, "ignored": 1, "unsafe": False})
        self.assertEqual(data["config"]["keys"], ["DOTSYNC_COMMIT_MESSAGE_PROVIDER", "DOTSYNC_PEER_TIMEOUT"])
        self.assertEqual(data["commit_messages"], {"provider": "anthropic", "credential": "ANTHROPIC_API_KEY", "credential_set": False})
        self.assertIn("provider_credential_missing", self.codes(data))
        self.assertIn("hooks_not_executable", self.codes(data))
        self.assertNotIn("PRIVATE_", json.dumps(data))
        data = self.run_doctor(env=dict(self.env, ANTHROPIC_API_KEY="PRIVATE_KEY_VALUE_0123456789"))
        self.assertTrue(data["commit_messages"]["credential_set"])
        self.assertNotIn("PRIVATE_KEY_VALUE", json.dumps(data))
        hooks.chmod(0o777)
        (self.config / "config").chmod(0o666)
        data = self.run_doctor()
        self.assertIn("hooks_unsafe", self.codes(data))
        self.assertEqual(data["config"]["status"], "unsafe")
        hooks.chmod(0o700)

    def test_dirty_and_operation_state_do_not_expose_filenames(self):
        (self.repo / "PRIVATE_FILENAME_NEVER_PRINT").write_text("PRIVATE_CONTENT_NEVER_PRINT")
        (self.repo / ".git" / "MERGE_HEAD").write_text(self.git("rev-parse", "HEAD") + "\n")
        data = self.run_doctor()
        self.assertEqual((data["repository"]["dirty"], data["repository"]["dirty_entries"]), (True, 1))
        self.assertIn("merge", data["repository"]["in_progress"])
        self.assertNotIn("PRIVATE_", json.dumps(data))

    def test_inherited_git_overrides_cannot_redirect_or_write_trace_files(self):
        trace = self.root / "trace-that-must-not-be-created"
        env = dict(self.env, GIT_DIR=str(self.root / "not-a-repo"), GIT_WORK_TREE=str(self.root / "elsewhere"),
                   GIT_INDEX_FILE=str(self.root / "wrong-index"), GIT_TRACE=str(trace))
        data = self.run_doctor(env=env)
        self.assertEqual((data["repository"]["status"], data["repository"]["branch"]), ("ok", "master"))
        self.assertFalse(trace.exists())

    def test_cached_ahead_and_behind_and_a_detached_head(self):
        base = self.git("rev-parse", "HEAD")
        (self.repo / "local").write_text("local")
        self.git("add", "local")
        self.git("commit", "-qm", "local")
        other = self.git("commit-tree", self.git("rev-parse", "HEAD^{tree}"), "-p", base, "-m", "upstream")
        self.git("update-ref", "refs/remotes/origin/master", other)
        data = self.run_doctor()
        self.assertEqual((data["repository"]["ahead"], data["repository"]["behind"]), (1, 1))
        self.git("switch", "--detach", "-q")
        self.assertIn("detached_head", self.codes(self.run_doctor()))

    def test_pause_and_the_kernel_lock_are_probed_not_changed(self):
        pause = self.state / "pause"
        pause.touch()
        old = time.time() - 7200
        os.utime(pause, (old, old))
        self.lock.write_text("PRIVATE_LOCK_CONTENT")
        self.lock.chmod(0o600)
        before = (self.lock.read_bytes(), self.lock.stat().st_mtime_ns, self.lock.stat().st_ino)
        with self.lock.open("rb") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            data = self.run_doctor()
            self.assertEqual(data["lock"]["status"], "active")
            fcntl.flock(stream, fcntl.LOCK_UN)
        self.assertEqual(data["pause"]["status"], "paused")
        self.assertGreaterEqual(data["pause"]["age_seconds"], 7200)
        self.assertEqual(self.run_doctor()["lock"]["status"], "unlocked")
        self.assertEqual(before, (self.lock.read_bytes(), self.lock.stat().st_mtime_ns, self.lock.stat().st_ino))
        self.assertTrue(pause.exists())
        self.assertNotIn("PRIVATE_LOCK_CONTENT", json.dumps(data))

    def test_a_lock_the_helper_would_refuse_is_unsafe(self):
        self.lock.write_text("")
        for mode in (0o640, 0o604):
            self.lock.chmod(mode)
            self.assertEqual(self.run_doctor()["lock"]["status"], "unsafe")
        self.lock.chmod(0o600)
        self.assertEqual(self.run_doctor()["lock"]["status"], "unlocked")
        self.lock.unlink()
        self.lock.symlink_to(self.root / "target")
        self.assertEqual(self.run_doctor()["lock"]["status"], "unavailable")

    def test_broken_and_different_installed_program(self):
        self.installed.unlink()
        self.installed.symlink_to(self.root / "missing-source")
        self.assertEqual(self.run_doctor()["installation"]["status"], "broken_symlink")
        self.installed.unlink()
        self.installed.write_text("#!/bin/sh\nexit 1\n")
        self.installed.chmod(0o755)
        data = self.run_doctor()
        self.assertEqual(data["installation"]["status"], "different")
        self.assertIn("installation_attention", self.codes(data))

    def test_heartbeat_outcomes_are_explicit_and_contents_never_leak(self):
        head = self.git("rev-parse", "HEAD")
        self.write_heartbeat(exit=1, result="failed", phase="git-push", head=head, private="PRIVATE_HEARTBEAT")
        data = self.run_doctor()
        self.assertEqual((data["heartbeat"]["outcome"], data["heartbeat"]["phase"], data["heartbeat"]["head"]),
                         ("failed", "git-push", head))
        self.assertNotIn("PRIVATE_HEARTBEAT", json.dumps(data))
        for result in ("deferred", "stale-config", "partial"):
            self.write_heartbeat(exit=0, result=result)
            self.assertEqual(self.run_doctor()["heartbeat"]["outcome"], result)
        self.write_heartbeat(exit=0, peers_failed=2)
        self.assertIn("peer_sync_failed", self.codes(self.run_doctor()))
        self.write_heartbeat(ts=int(time.time()) - 90000)
        self.assertTrue(self.run_doctor()["heartbeat"]["stale"])
        self.write_heartbeat(ts=int(time.time()) + 3600, exit="x")
        data = self.run_doctor()
        self.assertTrue(data["heartbeat"]["clock_skew"])
        self.assertEqual(data["heartbeat"]["outcome"], "unknown")
        self.heartbeat.write_text("PRIVATE_INVALID_JSON")
        self.assertEqual(self.run_doctor()["heartbeat"]["status"], "invalid_json")
        self.heartbeat.write_text("x" * 20000)
        self.assertEqual(self.run_doctor()["heartbeat"]["status"], "too_large")
        self.heartbeat.unlink()
        os.mkfifo(self.heartbeat)
        self.assertEqual(self.run_doctor()["heartbeat"]["status"], "not_regular")

    def test_host_order_matches_dotsync_and_the_profile_is_data(self):
        marker = self.root / "must-not-exist"
        self.profile.write_text("touch %s\nexport DF_MACHINE='Profile-Host'\n" % marker)
        self.assertEqual(self.run_doctor(host=None)["host"], "profile-host")
        self.assertEqual(self.run_doctor(host=None, env=dict(self.env, DF_MACHINE="env-host"))["host"], "env-host")
        self.profile.write_text('export DF_MACHINE="$(touch %s)"\n' % marker)
        hostname = os.uname().nodename.split(".")[0].lower()
        self.assertEqual(self.run_doctor(host=None)["host"], hostname)
        self.assertFalse(marker.exists())

    def test_timing_parses_only_the_latest_bounded_run(self):
        self.log.write_text("PRIVATE_OLD_LOG" * 10000 + "\n"
                            "=== 2026-09-07 04:41:17 host=fixture pid=100 local=0 ===\n  step git-push 3.12s\n  total 21s\n"
                            "=== 2026-09-07 05:41:17 host=fixture pid=200 local=1 ===\n  step git-fetch 19ms\nPRIVATE_LOG_CONTENT\n")
        data = self.run_doctor()
        self.assertEqual((data["timing"]["pid"], data["timing"]["last_phase"], data["timing"]["completed"]), (200, "git-fetch", False))
        self.assertNotIn("PRIVATE_", json.dumps(data))

    def test_missing_repo_and_state_still_produce_a_report(self):
        self.heartbeat.unlink()
        self.log.unlink()
        data = self.run_doctor(repo=self.root / "absent")
        self.assertEqual((data["repository"]["status"], data["heartbeat"]["status"], data["timing"]["status"]),
                         ("unavailable", "missing", "missing"))

    def test_git_timeouts_and_huge_output_are_bounded(self):
        stubs = self.root / "stubs"
        stubs.mkdir()
        stub = stubs / "git"
        stub.write_text("#!" + sys.executable + "\nimport time\ntime.sleep(60)\n")
        stub.chmod(0o755)
        env = dict(self.env, PATH=str(stubs) + os.pathsep + self.env.get("PATH", ""))
        started = time.monotonic()
        self.assertEqual(self.run_doctor(env=env)["repository"]["reason"], "timeout")
        self.assertLess(time.monotonic() - started, 15)
        stub.write_text("#!" + sys.executable + "\nimport sys\nsys.stdout.write('PRIVATE_GIT_OUTPUT' * 40000)\n")
        data = self.run_doctor(env=env)
        self.assertEqual(data["repository"]["reason"], "too_large")
        self.assertNotIn("PRIVATE_GIT_OUTPUT", json.dumps(data))

    def test_text_output_is_compact_and_explains_its_limits(self):
        output = self.run_doctor(json_output=False)
        self.assertIn("dotsync doctor:", output)
        self.assertIn("No network checks were run", output)
        self.assertIn("timing does not establish success", output)
        self.assertLess(len(output), 3000)


if __name__ == "__main__":
    unittest.main()
