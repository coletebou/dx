#!/usr/bin/env python3
"""Hermetic tests for base/claude/api_error_recovery.py (the StopFailure/Stop hook).

Every path the hook writes is redirected into a temp dir; the notifier and the
diagnostic agent are stand-ins that only record what they were given. No tmux,
no network, no real agents, sub-second backoffs.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "base/claude/api_error_recovery.py"
WRAPPER = ROOT / "base/claude/api-error-recovery-hook.sh"

spec = importlib.util.spec_from_file_location("api_error_recovery", SCRIPT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class ClassifyTest(unittest.TestCase):
    # Real StopFailure messages seen in session transcripts.
    CASES = [
        ("server_error", "API Error: 500 The server had an error while processing your request.", "transient"),
        ("server_error", "API Error: Server error mid-response. The response above may be incomplete.", "transient"),
        ("overloaded", "API Error: 529 Overloaded.", "transient"),
        ("rate_limit", "429 Too Many Requests", "transient"),
        ("rate_limit", "You've hit your monthly spend limit · raise it at claude.ai/settings/usage", "quota"),
        ("model_not_found", "The model claude-fable-5-1[1m] is not available on your mantle deployment.", "config"),
        ("invalid_request", "Prompt is too long", "context"),
        ("invalid_request", "API Error: Opus 5's safeguards flagged this message (https://www.anthropic.com/legal/aup).", "safeguard"),
        ("invalid_request", "API Error: 400 unexpected field", "config"),
        ("unknown", "API Error: 400 data retention mode 'default' is not available for this model", "config"),
        ("unknown", "API Error: The response stopped arriving.", "transient"),
        ("unknown", "", "transient"),
        ("authentication_failed", "Login expired · Please run /login", "auth"),
        ("cloud_credential_error", "AWS credentials expired or invalid", "auth"),
        ("billing_error", "", "billing"),
        ("max_output_tokens", "", "output"),
        (None, "API Error: 503 Service Unavailable", "transient"),
    ]

    def test_real_messages(self):
        for error, text, want in self.CASES:
            with self.subTest(error=error, text=text):
                self.assertEqual(mod.classify(error, text), want)


class BackoffTest(unittest.TestCase):
    def test_doubles_and_caps_with_bounded_jitter(self):
        lows = [mod.backoff(n, rng=lambda: 0.0) for n in range(1, 12)]
        highs = [mod.backoff(n, rng=lambda: 1.0) for n in range(1, 12)]
        self.assertEqual(lows[0], mod.BASE_DELAY * 0.8)
        self.assertEqual(lows[1], mod.BASE_DELAY * 2 * 0.8)
        self.assertEqual(lows, sorted(lows))
        cap = min(mod.MAX_DELAY * 1.2, mod.HOOK_TIMEOUT - 60)
        self.assertTrue(all(h <= cap + 1e-9 for h in highs))  # 0.8+0.4 is 1.2000000000000002


class HookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="api-recovery-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.state = root / "state"
        self.logf = root / "api-errors.jsonl"
        self.alerts = root / "alerts.jsonl"
        notifier = root / "agent-notify"
        notifier.write_text(f"#!/bin/sh\ncat >> {self.alerts}; echo >> {self.alerts}\n")
        notifier.chmod(0o755)
        self.transcript = root / "t.jsonl"
        self.transcript.write_text(json.dumps({
            "type": "assistant", "isApiErrorMessage": True, "error": "server_error",
            "timestamp": "2026-09-29T04:00:00Z",
            "message": {"content": [{"type": "text", "text": "API Error: 500 boom"}]}}) + "\n")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("API_RECOVERY_", "TMUX"))}
        self.env.update(
            API_RECOVERY_STATE_DIR=str(self.state), API_RECOVERY_LOG=str(self.logf),
            AGENT_NOTIFY_BIN=str(notifier), API_RECOVERY_BASE_DELAY="0.05",
            API_RECOVERY_MAX_DELAY="0.2", API_RECOVERY_POLL="0.02",
            API_RECOVERY_MAX_ATTEMPTS="4", API_RECOVERY_NOTIFY_AT="2", API_RECOVERY_ESCALATE_AT="3",
            API_RECOVERY_DIAG_CMD='cat > "$REPORT"', API_RECOVERY_DIAG_WHERE="background")

    def payload(self, error="server_error", msg="API Error: 500 boom", event="StopFailure", sid="s1", **kw):
        return {"hook_event_name": event, "session_id": sid, "cwd": self.tmp.name,
                "transcript_path": str(self.transcript), "error": error,
                "last_assistant_message": msg, **kw}

    def run_hook(self, payload, args=(), env=None):
        return subprocess.run(["bash", str(WRAPPER), *args], input=json.dumps(payload),
                              capture_output=True, text=True, env=env or self.env, timeout=30)

    def start_hook(self, payload, env=None):
        # stdin from a file, not a pipe we close ourselves: communicate() on Python 3.9
        # (macOS system python) flushes stdin and raises on an already-closed pipe.
        feed = tempfile.TemporaryFile("w+")
        self.addCleanup(feed.close)
        feed.write(json.dumps(payload))
        feed.seek(0)
        return subprocess.Popen(["bash", str(WRAPPER)], stdin=feed, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, env=env or self.env)

    def state_of(self, sid="s1"):
        p = self.state / f"{sid}.json"
        return json.loads(p.read_text()) if p.exists() else None

    def must_state(self, sid="s1"):
        st = self.state_of(sid)
        assert st is not None, "expected a failure streak on record"
        return st

    def alerts_seen(self):
        # Notifier writes are fire-and-forget, so wait until the file stops growing
        # (a fixed short sleep flaked under load).
        deadline, last, stable_since = time.time() + 5, -1, time.time()
        while time.time() < deadline:
            n = len(self.alerts.read_text().splitlines()) if self.alerts.exists() else 0
            if n != last:
                last, stable_since = n, time.time()
            elif time.time() - stable_since > 0.5:
                break
            time.sleep(0.05)
        if not self.alerts.exists():
            return []
        return [json.loads(line)["event"] for line in self.alerts.read_text().splitlines() if line.strip()]

    def alert_messages(self):
        self.alerts_seen()  # waits for the fire-and-forget writes
        return [json.loads(line)["message"] for line in self.alerts.read_text().splitlines() if line.strip()]

    def wait_for(self, path, timeout=5):
        end = time.time() + timeout
        while time.time() < end:
            if path.exists() and path.stat().st_size:
                return True
            time.sleep(0.05)
        return False

    def test_transient_streak_retries_escalates_and_gives_up(self):
        for attempt in range(1, 5):
            r = self.run_hook(self.payload())
            self.assertEqual(r.returncode, 2, r.stderr)
            self.assertIn(f"automatic turn-level retry {attempt} of 4", r.stderr)
            self.assertIn("check its actual state before repeating it", r.stderr)
            self.assertEqual(self.must_state()["attempts"], attempt)
        st = self.must_state()
        self.assertTrue(st["diag_report"], "diagnosis starts at ESCALATE_AT")
        self.assertTrue(self.wait_for(Path(st["diag_report"])))
        brief = Path(st["diag_report"]).read_text()
        self.assertIn("ROOT CAUSE:", brief)
        self.assertIn("API Error: 500 boom", brief, "briefing quotes the transcript's API errors")
        # Retry 4 happens after the report exists, so its wake message carries it.
        # Past MAX_ATTEMPTS: no wake, one "exhausted" alert.
        r = self.run_hook(self.payload())
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stderr, "")
        self.assertEqual(self.alerts_seen(), ["api_error.retrying", "api_error.escalated", "api_error.exhausted"])

    def test_wake_message_includes_finished_diagnosis(self):
        for _ in range(3):
            self.run_hook(self.payload())
        self.assertTrue(self.wait_for(Path(self.must_state()["diag_report"])))
        r = self.run_hook(self.payload())
        self.assertEqual(r.returncode, 2)
        self.assertIn("A diagnostic agent (custom) investigated this failure", r.stderr)

    def test_success_clears_streak_and_reports_recovery(self):
        for _ in range(2):
            self.run_hook(self.payload())
        r = self.run_hook(self.payload(event="Stop"), args=["--stop"])
        self.assertEqual(r.returncode, 0)
        self.assertIsNone(self.state_of())
        self.assertEqual(self.alerts_seen(), ["api_error.retrying", "api_error.recovered"])
        decisions = [json.loads(line)["decision"] for line in self.logf.read_text().splitlines()]
        self.assertEqual(decisions[-1], "recovered")

    def test_quiet_recovery_when_no_alert_went_out(self):
        self.run_hook(self.payload())
        self.run_hook(self.payload(event="Stop"), args=["--stop"])
        self.assertEqual(self.alerts_seen(), [])

    def test_success_during_backoff_cancels_the_pending_wake(self):
        env = {**self.env, "API_RECOVERY_BASE_DELAY": "3", "API_RECOVERY_MAX_DELAY": "3"}
        sleeper = self.start_hook(self.payload(), env=env)
        time.sleep(0.5)
        self.run_hook(self.payload(event="Stop"), args=["--stop"], env=env)
        out, err = sleeper.communicate(timeout=10)
        self.assertEqual(sleeper.returncode, 0)
        self.assertEqual(err, "")

    def test_new_prompt_cancels_the_pending_wake_but_keeps_the_streak(self):
        env = {**self.env, "API_RECOVERY_BASE_DELAY": "3", "API_RECOVERY_MAX_DELAY": "3"}
        sleeper = self.start_hook(self.payload(), env=env)
        time.sleep(0.5)
        r = self.run_hook(self.payload(event="UserPromptSubmit"), args=["--prompt"], env=env)
        self.assertEqual((r.returncode, r.stdout), (0, ""), "prompt hooks print nothing: stdout becomes context")
        _, err = sleeper.communicate(timeout=10)
        self.assertEqual((sleeper.returncode, err), (0, ""), "no stale wake after the user took over")
        self.assertEqual(self.must_state()["attempts"], 1, "the streak survives; only the wake is cancelled")
        r = self.run_hook(self.payload())
        self.assertIn("retry 2 of 4", r.stderr, "a failure in the new turn continues the streak")

    def test_prompt_without_a_streak_is_a_noop(self):
        r = self.run_hook(self.payload(event="UserPromptSubmit"), args=["--prompt"])
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))
        self.assertIsNone(self.state_of())

    def test_newer_failure_supersedes_older_sleeper(self):
        env = {**self.env, "API_RECOVERY_BASE_DELAY": "3", "API_RECOVERY_MAX_DELAY": "3"}
        first = self.start_hook(self.payload(), env=env)
        time.sleep(0.5)
        second = self.start_hook(self.payload(), env=env)
        _, err1 = first.communicate(timeout=10)
        _, err2 = second.communicate(timeout=15)
        self.assertEqual((first.returncode, err1), (0, ""))
        self.assertEqual(second.returncode, 2)
        self.assertIn("retry 2 of 4", err2)

    def test_config_error_diagnoses_once_and_never_retries(self):
        for _ in range(2):
            r = self.run_hook(self.payload(error="model_not_found", msg="There's an issue with the selected model"))
            self.assertEqual((r.returncode, r.stderr), (0, ""))
        st = self.must_state()
        self.assertEqual(st.get("attempts"), 0)
        self.assertEqual(st["failures"], 2)
        self.assertTrue(self.wait_for(Path(st["diag_report"])))
        self.assertEqual(len(list((self.state / "s1").glob("diagnosis-*.md"))), 1)
        self.assertEqual(self.alerts_seen(), ["api_error.config"])
        self.assertIn(f"report: {st['diag_report']}", self.alert_messages()[0], "the alert says where to look")

    def test_quota_alerts_once(self):
        for _ in range(3):
            r = self.run_hook(self.payload(error="rate_limit", msg="You've hit your monthly spend limit"))
            self.assertEqual(r.returncode, 0)
        self.assertEqual(self.alerts_seen(), ["api_error.quota"])

    def test_max_output_tokens_gets_two_short_retries(self):
        for n in (1, 2):
            r = self.run_hook(self.payload(error="max_output_tokens", msg=""), env={**self.env})
            self.assertEqual(r.returncode, 2)
            self.assertIn("maximum output token limit", r.stderr)
        r = self.run_hook(self.payload(error="max_output_tokens", msg=""))
        self.assertEqual(r.returncode, 0)

    def test_subagent_and_disabled_are_ignored(self):
        r = self.run_hook(self.payload(agent_id="a1"))
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        r = self.run_hook(self.payload(), env={**self.env, "API_RECOVERY_DISABLE": "1"})
        self.assertEqual((r.returncode, r.stderr), (0, ""))
        self.assertIsNone(self.state_of())

    def test_stop_without_state_is_a_noop(self):
        r = self.run_hook(self.payload(event="Stop"), args=["--stop"])
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, "", ""))

    def test_garbage_input_fails_open(self):
        r = subprocess.run(["bash", str(WRAPPER)], input="not json", capture_output=True,
                           text=True, env=self.env, timeout=10)
        self.assertEqual((r.returncode, r.stderr), (0, ""))

    def test_diagnosis_is_opt_in(self):
        # No API_RECOVERY_DIAG_CMD and no API_RECOVERY_DIAG_ENGINE: no agent runs.
        env = {k: v for k, v in self.env.items() if k != "API_RECOVERY_DIAG_CMD"}
        self.run_hook(self.payload(error="model_not_found", msg="bad model"), env=env)
        self.assertNotIn("diag_report", self.must_state(), "no agent sees transcripts by default")
        self.assertEqual(self.alerts_seen(), ["api_error.config"])
        self.assertNotIn("diagnostic agent", self.alert_messages()[0], "the alert claims no agent that never ran")
        (self.state / "s1.json").unlink()
        # Opted in: a stand-in `claude` on PATH receives the briefing on stdin.
        fake = Path(self.tmp.name) / "bin"
        fake.mkdir()
        (fake / "claude").write_text("#!/bin/sh\ncat\n")
        (fake / "claude").chmod(0o755)
        opted = {**env, "API_RECOVERY_DIAG_ENGINE": "claude", "PATH": f"{fake}{os.pathsep}{env.get('PATH', '')}"}
        self.run_hook(self.payload(error="model_not_found", msg="bad model"), env=opted)
        report = Path(self.must_state()["diag_report"])
        self.assertTrue(self.wait_for(report), "explicit opt-in works")
        self.assertIn("ROOT CAUSE:", report.read_text())

    def test_diagnostic_agent_runs_with_every_hook_guard(self):
        env = {**self.env, "API_RECOVERY_DIAG_CMD": 'env > "$REPORT"'}
        self.run_hook(self.payload(error="model_not_found", msg="bad model"), env=env)
        report = Path(self.must_state()["diag_report"])
        self.assertTrue(self.wait_for(report))
        seen = report.read_text()
        for guard in mod.CHILD_GUARDS:
            self.assertIn(f"{guard}=1", seen, guard)

    def test_diagnosis_child_env_drops_session_bindings(self):
        os.environ["CLAUDE_CODE_SESSION_ID"] = "parent"
        os.environ["CLAUDECODE"] = "1"
        try:
            env = mod.child_env()
        finally:
            del os.environ["CLAUDE_CODE_SESSION_ID"], os.environ["CLAUDECODE"]
        self.assertNotIn("CLAUDE_CODE_SESSION_ID", env)
        self.assertNotIn("CLAUDECODE", env)
        for guard in ("AGENT_HOOK_CHILD", "API_RECOVERY_DISABLE", "REFLECTOR_DISABLE", "JEV_NUDGE_DISABLE",
                      "CONTEXT_ADVISOR_DISABLE", "AGENT_NOTIFY_DISABLE"):
            self.assertEqual(env[guard], "1", guard)


if __name__ == "__main__":
    unittest.main(verbosity=2)
