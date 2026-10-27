#!/usr/bin/env python3
"""dotsync's configuration surfaces: the config file, the peers file and the opt-in tailnet
source, hooks, the activity guard, heartbeats, and the background fan-out's bookkeeping. All
in temporary directories; nothing contacts a network.

    python3 scripts/tests/dotsync-config.test.py
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

spec = importlib.util.spec_from_file_location("runtime_fixture", Path(__file__).with_name("dotsync-runtime.test.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
ACTIVITY = fixture.SCRIPTS / "lib" / "dotsync-activity.py"


class ConfigTest(fixture.RuntimeTest):
    """Runs only the tests below; RuntimeTest's own run in their suite."""

    # ── the config file ──
    def load(self, text, mode=0o600, env=None):
        config = self.home / "config"
        config.write_text(text)
        config.chmod(mode)
        return self.bash('dotsync_load_config "$1"; env | grep "^DOTSYNC_" | sort || true', config, env=env)

    def test_the_config_file_is_literal_and_the_environment_wins(self):
        sentinel = self.root / "must-not-exist"
        result = self.load('# a comment\nDOTSYNC_PEER_TIMEOUT=45\nexport DOTSYNC_QUIET_MINUTES="20"\n'
                           "DOTSYNC_COMMIT_MESSAGE_CMD='claude -p --model haiku'\n"
                           "DOTSYNC_HOOK_TIMEOUT=$(touch %s)\nPATH=/evil\nOTHER=1\n"
                           "DOTSYNC_LOCK_HELD=/tmp/x\nDOTSYNC_EXPECTED_HEAD=abc\n  DOTSYNC_WAIT=1\n" % sentinel,
                           env=dict(self.env, DOTSYNC_QUIET_MINUTES="5"))
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertIn("DOTSYNC_PEER_TIMEOUT=45", lines)
        self.assertIn("DOTSYNC_QUIET_MINUTES=5", lines, "the environment wins")
        self.assertIn("DOTSYNC_COMMIT_MESSAGE_CMD=claude -p --model haiku", lines)
        self.assertIn("DOTSYNC_HOOK_TIMEOUT=$(touch %s)" % sentinel, lines, "kept as text, never run")
        self.assertIn("DOTSYNC_WAIT=1", lines)
        self.assertFalse(any(line.startswith(("DOTSYNC_LOCK_HELD", "DOTSYNC_EXPECTED_HEAD")) for line in lines))
        self.assertFalse(sentinel.exists())

    def test_a_config_file_others_can_write_is_ignored(self):
        result = self.load("DOTSYNC_PEER_TIMEOUT=45\n", mode=0o622)
        self.assertNotIn("DOTSYNC_PEER_TIMEOUT", result.stdout)
        self.assertIn("must be owned by you", result.stderr)

    # ── peers ──
    def test_the_peers_file_and_the_repository_list(self):
        peers = self.home / "peers"
        peers.write_text("# machines\nbox-b\nbox-c   example   server  # the build box\n"
                         "laptop - local\n-bad\nuser@host\nbox-d bad/identity\n\nBOX-B other\n")
        listed = self.repo / "identities" / "example" / "dotsync-peers"
        listed.parent.mkdir(parents=True)
        listed.write_text("box-e example\nbox-c\n")
        result = self.bash('DOTFILES_DIR="$1"; DOTSYNC_PEERS_FILE="$2"; dotsync_peers_list example', self.repo, peers)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([line.split("\t") for line in result.stdout.splitlines()], [
            ["box-b", "-", "-", "peers-file"],
            ["box-c", "example", "server", "peers-file"],
            ["laptop", "-", "local", "peers-file"],
            ["box-e", "example", "-", "identities/example/dotsync-peers"],
        ])
        for bad in ("-bad", "user@host", "bad/identity"):
            self.assertIn(bad, result.stderr)
        result = self.bash('DOTFILES_DIR="$1"; DOTSYNC_PEERS_FILE="$2"; dotsync_peers_list ""', self.repo, self.home / "absent")
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_the_tailnet_source_is_opt_in_and_filtered_by_tag(self):
        payload = {"Peer": {
            "a": {"HostName": "tagged", "Online": True, "OS": "linux", "Tags": ["tag:dotfiles"]},
            "b": {"HostName": "untagged", "Online": True, "OS": "linux"},
            "c": {"HostName": "other-tag", "Online": True, "OS": "linux", "Tags": ["tag:server"]},
            "d": {"HostName": "offline", "Online": False, "OS": "linux", "Tags": ["tag:dotfiles"]},
            "e": {"HostName": "phone", "Online": True, "OS": "iOS", "Tags": ["tag:dotfiles"]},
            "f": {"HostName": "pc", "Online": True, "OS": "windows", "Tags": ["tag:dotfiles"]},
            "g": {"HostName": "shared", "Online": True, "ShareeNode": True, "Tags": ["tag:dotfiles"]},
            "h": {"HostName": "bad;rm -rf", "Online": True, "OS": "linux", "Tags": ["tag:dotfiles"]},
            "i": {"HostName": "a-mac", "Online": True, "OS": "macOS", "Tags": ["tag:x", "tag:dotfiles"]},
        }}
        directory = self.root / "ts-bin"
        directory.mkdir()
        calls = self.root / "tailscale-calls"
        (directory / "tailscale").write_text("#!/bin/sh\necho called >> %s\ncat %s\n" % (calls, self.root / "status.json"))
        (directory / "tailscale").chmod(0o755)
        (self.root / "status.json").write_text(json.dumps(payload))
        env = dict(self.env, PATH=str(directory) + os.pathsep + self.env["PATH"])
        if not fixture.shutil.which("jq"):
            self.skipTest("jq is not installed")
        result = self.bash('dotsync_tailnet_peers ""', env=env)
        self.assertEqual((result.returncode, result.stdout), (0, ""))
        self.assertFalse(calls.exists(), "no tag: tailscale is never asked")
        result = self.bash('dotsync_tailnet_peers tag:dotfiles', env=env)
        self.assertEqual(sorted(result.stdout.split()), ["a-mac", "tagged"])
        self.assertIn("unsafe name", result.stderr)

    # ── hooks ──
    def hooks(self, stage, scripts, mode=0o700):
        base = self.home / "hooks"
        directory = base / (stage + ".d")
        directory.mkdir(parents=True, exist_ok=True)
        base.chmod(0o700)
        for name, body in scripts.items():
            path = directory / name
            path.write_text("#!/bin/sh\n" + body)
            path.chmod(mode)
        return base

    def run_hooks(self, stage, base, extra=""):
        code = ('DOTFILES_DIR="$1"; DOTSYNC_HOOKS_DIR="$2"; EXIT_CODE=0; DOTSYNC_FAILED_PHASE=""\n' + extra +
                'rc=0; dotsync_run_hooks "$3" || rc=$?\nprintf "rc=%s exit=%s phase=%s\\n" "$rc" "$EXIT_CODE" "$DOTSYNC_FAILED_PHASE"\n')
        return self.bash(code, self.repo, base, stage)

    def test_hooks_run_in_name_order_from_the_repository(self):
        log = self.root / "hook-log"
        base = self.hooks("post-pull", {
            "20-second": 'echo "second $DOTSYNC_HOOK $(pwd)" >> %s\n' % log,
            "10-first": 'echo "first" >> %s; echo "said something"\n' % log,
            "30-skipped.disabled": "echo disabled >> %s\n" % log,
            "README": "echo readme >> %s\n" % log})
        (base / "post-pull.d" / "README").chmod(0o600)
        result = self.run_hooks("post-pull", base)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().splitlines(), ["first", "second post-pull %s" % self.repo])
        self.assertIn("hook post-pull/10-first: said something", result.stdout)
        self.assertIn("rc=0 exit=0 phase=", result.stdout)

    def test_a_failing_hook_fails_the_run_and_a_pre_commit_one_stops_there(self):
        log = self.root / "hook-log"
        for stage, expected in (("pre-commit", ["one"]), ("post-sync", ["one", "three"])):
            with self.subTest(stage=stage):
                log.unlink(missing_ok=True)
                base = self.hooks(stage, {"1": "echo one >> %s\n" % log, "2": "exit 7\n", "3": "echo three >> %s\n" % log})
                result = self.run_hooks(stage, base)
                self.assertIn("rc=1 exit=1 phase=hook-%s" % stage, result.stdout)
                self.assertIn("hook %s/2 failed (exit 7)" % stage, result.stderr)
                self.assertEqual(log.read_text().splitlines(), expected)

    def test_hooks_others_can_write_are_refused(self):
        log = self.root / "hook-log"
        base = self.hooks("post-sync", {"1": "echo ran >> %s\n" % log})
        (base / "post-sync.d").chmod(0o777)
        result = self.run_hooks("post-sync", base)
        self.assertIn("rc=1 exit=1 phase=hook-post-sync", result.stdout)
        self.assertFalse(log.exists())
        (base / "post-sync.d").chmod(0o700)
        (base / "post-sync.d" / "1").chmod(0o777)
        result = self.run_hooks("post-sync", base)
        self.assertIn("rc=1", result.stdout)
        self.assertFalse(log.exists())

    def test_a_hook_holds_neither_the_lock_nor_the_callers_stdout_and_is_bounded(self):
        base = self.hooks("post-sync", {"1": 'for fd in 3 9; do if { true >&$fd; } 2>/dev/null; then echo "fd $fd open"; fi; done\n',
                                        "2": "sleep 30\n"})
        started = time.monotonic()
        result = self.bash('DOTFILES_DIR="$1"; DOTSYNC_HOOKS_DIR="$2"; EXIT_CODE=0; DOTSYNC_FAILED_PHASE=""; DOTSYNC_HOOK_TIMEOUT=1\n'
                           'exec 9>"$1/lockfile"; exec 3>&1\ndotsync_run_hooks post-sync || true\n', self.repo, base, timeout=30)
        self.assertLess(time.monotonic() - started, 15)
        self.assertNotIn("fd 3 open", result.stdout)
        self.assertNotIn("fd 9 open", result.stdout)
        self.assertIn("hook post-sync/2 failed (exit 124)", result.stderr)

    # ── the activity guard ──
    def activity(self, quiet=10, session=30, env=None):
        result = subprocess.run([sys.executable, str(ACTIVITY), "--repo", str(self.repo), "--quiet-minutes", str(quiet),
                                 "--session-minutes", str(session)], env=env or self.env, capture_output=True, text=True,
                                timeout=30)
        return result.returncode, result.stdout.strip()

    def test_a_recent_uncommitted_edit_is_activity_an_old_one_is_not(self):
        self.assertEqual(self.activity(), (1, ""))
        (self.repo / "payload").write_text("mid-edit\n")
        self.assertEqual(self.activity(), (0, "1 uncommitted file edited in the last 10 minutes"))
        self.assertEqual(self.activity(quiet=0), (1, ""), "zero minutes turns the check off")
        old = time.time() - 3600
        os.utime(self.repo / "payload", (old, old))
        self.assertEqual(self.activity(), (1, ""))
        (self.repo / "new dir").mkdir()
        (self.repo / "new dir" / "untracked").write_text("x\n")
        self.assertEqual(self.activity()[0], 0)

    def test_an_agent_session_in_the_checkout_is_activity(self):
        repo = os.path.realpath(self.repo)
        slug = "".join(c if c.isalnum() else "-" for c in repo)
        projects = self.home / ".claude" / "projects"
        inside = projects / (slug + "-sub") / "session.jsonl"
        inside.parent.mkdir(parents=True)
        inside.write_text(json.dumps({"cwd": repo + "/sub", "type": "user"}) + "\n")
        self.assertEqual(self.activity(), (0, "a Claude Code session is working in the checkout"))
        self.assertEqual(self.activity(session=0), (1, ""))
        old = time.time() - 3600
        os.utime(inside, (old, old))
        self.assertEqual(self.activity(), (1, ""), "a quiet session is not working")
        neighbour = projects / (slug + "-old") / "s.jsonl"
        neighbour.parent.mkdir(parents=True)
        neighbour.write_text(json.dumps({"cwd": repo + "-old"}) + "\n")
        self.assertEqual(self.activity(), (1, ""), "a sibling directory whose name extends the slug")
        day = time.localtime()
        rollouts = self.home / ".codex" / "sessions" / ("%04d" % day.tm_year) / ("%02d" % day.tm_mon) / ("%02d" % day.tm_mday)
        rollouts.mkdir(parents=True)
        (rollouts / "rollout-1.jsonl").write_text(json.dumps({"type": "session_meta", "payload": {"cwd": repo}}) + "\n")
        self.assertEqual(self.activity(), (0, "a Codex session is working in the checkout"))

    def test_the_activity_check_fails_as_an_error_outside_a_repository(self):
        code, _ = self.activity(env=dict(self.env, GIT_DIR=str(self.root / "nowhere")))
        self.assertEqual(code, 2)

    # ── heartbeats ──
    def test_a_heartbeat_is_one_force_pushed_commit_per_machine(self):
        origin = self.root / "origin.git"
        self.git("init", "-q", "--bare", str(origin), repo=self.root)
        heartbeat = self.state / "heartbeat.json"
        for ts in (100, 200):
            heartbeat.write_text('{"host":"box-a","ts":%d,"exit":0,"result":"ok"}\n' % ts)
            result = self.bash('cd "$1"; dotsync_heartbeat_publish "$2" box-a "$3"', self.repo, heartbeat, origin)
            self.assertEqual(result.returncode, 0, result.stderr)
        ref = "refs/dotsync/heartbeats/box-a"
        self.assertIn('"ts":200', self.git("cat-file", "-p", ref + ":heartbeat.json", repo=origin))
        self.assertEqual(self.git("rev-list", "--count", ref, repo=origin), "1", "no history accumulates")
        self.assertEqual(self.git("for-each-ref", "refs/heads", repo=origin), "", "no branch is touched")
        result = self.bash('cd "$1"; dotsync_heartbeat_publish "$2" box-a "$3"', self.repo, heartbeat, self.root / "missing.git")
        self.assertEqual(result.returncode, 1)
        self.assertIn("could not publish the heartbeat", result.stderr)
        self.assertEqual(self.bash('cd "$1"; dotsync_heartbeat_publish "$2" box-a "$3"', self.repo, heartbeat, origin,
                                   env=dict(self.env, DOTSYNC_HEARTBEAT_PUSH="0")).returncode, 0)

    def test_heartbeat_fields_and_ages_read_without_jq(self):
        json_text = '{"version":1,"host":"box-a","ts":1700000000,"exit":3,"result":"stale-config","branch":"main"}'
        for key, expected in (("ts", "1700000000"), ("exit", "3"), ("result", "stale-config"), ("missing", "")):
            self.assert_bash_output('dotsync_json_field "$1" "$2"', expected, json_text, key)
        for age, expected in ((30, "0m ago"), (7200, "2h ago"), (3 * 86400, "3d ago"), (-5, "in the future")):
            self.assert_bash_output('dotsync_age_label "$1"', expected, str(age))

    # ── the background fan-out ──
    def dispatch_block(self):
        text = fixture.MAIN.read_text()
        start = text.index("# Record a background fan-out")
        end = text.index("else\n  dotsync_fanout\n", start)
        end = text.index("\nfi\n", end) + len("\nfi\n")
        return text[start:end]

    PRELUDE = r'''
ts_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
fmt_dur() { printf '%sms' "$1"; }
dotsync_result() { if [[ "$1" -ne 0 ]]; then echo failed; elif [[ "${peers_failed_count:-0}" -gt 0 ]]; then echo partial; else echo ok; fi; }
write_heartbeat() { printf 'heartbeat exit=%s result=%s phase=%s\n' "$1" "$DOTSYNC_RESULT" "$DOTSYNC_PHASE" >> "$TIMING_LOG_DIR/heartbeat"; }
publish_heartbeat() { echo published >> "$TIMING_LOG_DIR/heartbeat"; }
run_post_sync() { echo post-sync >> "$TIMING_LOG_DIR/heartbeat"; }
dotsync_notify() { printf '%s | %s\n' "$1" "$2" >> "$TIMING_LOG_DIR/notified"; }
dotsync_fanout() {
  sleep "${FANOUT_SLEEP:-0}"
  peers_dispatched=2
  peers_failed_count="${FANOUT_INCOMPLETE:-0}"
  [[ "${FANOUT_EXIT:-}" == "" ]] || exit "$FANOUT_EXIT"
  echo "fanout body ran"
}
'''

    def run_dispatch(self, state, extra="", env_extra=None):
        code = (self.PRELUDE + 'TIMING_LOG_DIR="$1"; TIMING_LOG="$1/timing.log"; DOTFILES_DIR="$1"; _DOTSYNC_HOST=fixture\n'
                'EXIT_CODE=0; scheduled=0; one_line=0; wait_peers=0; strict_peers=0; selected_hosts=(); fanout_background=0\n'
                + extra + "\n" + self.dispatch_block() + '\necho "dispatch returned"; exit "$EXIT_CODE"\n')
        return subprocess.run([fixture.BASH, "--noprofile", "--norc", "-c", "set -euo pipefail\n" + code, "x", str(state)],
                              env=dict(self.env, **(env_extra or {})), capture_output=True, text=True, timeout=60)

    def wait_for(self, path, seconds=30):
        deadline = time.time() + seconds
        while time.time() < deadline:
            if path.exists() and path.stat().st_size:
                return path.read_text()
            time.sleep(0.1)
        self.fail("%s never appeared" % path)

    def test_a_manual_run_returns_before_its_peers_and_frees_the_callers_pipe(self):
        state = self.root / "bg"
        state.mkdir()
        started = time.time()
        result = self.run_dispatch(state, extra="exec 3>&1", env_extra={"FANOUT_SLEEP": "4", "FANOUT_INCOMPLETE": "1"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("peers updating in the background", result.stdout)
        self.assertNotIn("fanout body ran", result.stdout)
        self.assertLess(time.time() - started, 3.5, "the run waited for the fan-out or its pipe")
        record = self.wait_for(state / "fanout-result")
        self.assertIn("result=partial incomplete=1 dispatched=2", record)
        self.assertIn("fanout body ran", (state / "fanout.log").read_text())
        self.assertEqual((state / "heartbeat").read_text().splitlines(),
                         ["post-sync", "heartbeat exit=0 result=partial phase=peer-sync", "published"])
        self.assertIn("1 of 2 peer(s) incomplete", (state / "notified").read_text())

    def test_a_background_fan_out_that_aborts_still_reports_failure(self):
        state = self.root / "abort"
        state.mkdir()
        self.assertEqual(self.run_dispatch(state, env_extra={"FANOUT_EXIT": "7"}).returncode, 0)
        self.assertIn("result=failed", self.wait_for(state / "fanout-result"))
        self.assertIn("heartbeat exit=7 result=failed", (state / "heartbeat").read_text())

    def test_wait_scheduled_host_and_strict_runs_keep_the_fan_out_inline(self):
        for name, extra in (("wait", "wait_peers=1"), ("scheduled", "scheduled=1"),
                            ("host", "selected_hosts=(box-b)"), ("strict", "strict_peers=1"), ("peer", "one_line=1")):
            with self.subTest(mode=name):
                state = self.root / ("inline-" + name)
                state.mkdir()
                result = self.run_dispatch(state, extra=extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("fanout body ran", result.stdout)
                self.assertFalse((state / "fanout-pid").exists())
        state = self.root / "inline-exit"
        state.mkdir()
        self.assertEqual(self.run_dispatch(state, extra="wait_peers=1", env_extra={"FANOUT_EXIT": "5"}).returncode, 5)

    def test_status_reports_the_running_then_the_finished_fan_out(self):
        state = self.root / "status"
        state.mkdir()
        functions = "".join(fixture.actual_function(name) for name in ("dotsync_fanout_running", "dotsync_fanout_status"))
        holder = subprocess.Popen([fixture.BASH, "-c", "exec -a '/bin/bash /fixture/scripts/dotsync' sleep 30"])
        self.addCleanup(holder.kill)
        (state / "fanout-pid").write_text("pid=%d started=%d\n" % (holder.pid, int(time.time()) - 5))
        code = 'TIMING_LOG_DIR="$1"\n' + functions
        result = self.bash(code + "dotsync_fanout_status", state)
        self.assertIn("running in the background (pid %d" % holder.pid, result.stdout)
        (state / "fanout-pid").write_text("pid=%d started=%d\n" % (os.getpid(), int(time.time())))
        (state / "fanout-result").write_text("ts=%d result=partial incomplete=1 dispatched=3 seconds=41\n" % (int(time.time()) - 120))
        result = self.bash(code + "dotsync_fanout_status", state)
        self.assertIn("last finished 2m ago: partial, 1/3 peer(s) incomplete, 41s", result.stdout)
        self.assertNotEqual(self.bash(code + "dotsync_fanout_running", state).returncode, 0, "a recycled pid is not dotsync")


if __name__ == "__main__":
    suite = unittest.TestSuite(ConfigTest(name) for name in ConfigTest.__dict__ if name.startswith("test_"))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
