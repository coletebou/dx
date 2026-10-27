#!/usr/bin/env python3
"""Hermetic tests for base/claude/context_advisor.py and its fast-path wrapper.

A local HTTP server stands in for Jev (TypeSafe System One); the statusline sensor file
and transcripts are synthetic; the reflector is disabled so nothing is spawned."""

import importlib.util
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "base/claude/context_advisor.py"
WRAPPER = ROOT / "base/claude/context-advisor-hook.sh"

spec = importlib.util.spec_from_file_location("context_advisor", SCRIPT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class FakeJev(BaseHTTPRequestHandler):
    answers = {}
    status = 200
    requests = []

    def do_POST(self):
        FakeJev.requests.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(FakeJev.status)
        self.end_headers()
        self.wfile.write(json.dumps({"answers": {k: {"noul": v} for k, v in FakeJev.answers.items()}}).encode())

    def log_message(self, format, *args):  # keep test output quiet
        pass


class CompactionPointTest(unittest.TestCase):
    def test_windows(self):
        saved = os.environ.pop("CLAUDE_CODE_AUTO_COMPACT_WINDOW", None)
        try:
            setattr(mod, "_setting", lambda key: None)
            self.assertEqual(mod.compaction_point(200_000), 200_000)
            self.assertEqual(mod.compaction_point(1_000_000), 967_000)
            os.environ["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = "300000"
            self.assertEqual(mod.compaction_point(1_000_000), 300_000)
            self.assertEqual(mod.compaction_point(200_000), 200_000, "capped at the model window")
        finally:
            os.environ.pop("CLAUDE_CODE_AUTO_COMPACT_WINDOW", None)
            if saved is not None:
                os.environ["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = saved


class AdvisoryWindowTest(unittest.TestCase):
    """Per-directory budgets file: longest prefix of the hook cwd wins; env overrides; bad entries ignored."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "films" / "film-a" / "sub").mkdir(parents=True)
        self.file = self.root / "budgets.json"
        self.saved = (mod.BUDGETS_FILE, os.environ.pop("CONTEXT_ADVISOR_WINDOW", None))
        mod.BUDGETS_FILE = self.file
        self.addCleanup(self.restore)

    def restore(self):
        mod.BUDGETS_FILE = self.saved[0]
        if self.saved[1] is not None:
            os.environ["CONTEXT_ADVISOR_WINDOW"] = self.saved[1]

    def test_missing_file_is_default(self):
        self.assertEqual(mod.advisory_window(str(self.root)), (mod.ADVISORY_WINDOW, "default"))

    def test_longest_prefix_wins_and_siblings_do_not_match(self):
        films = str(self.root / "films")
        self.file.write_text(json.dumps({films: 600000, films + "/film-a": 700000, "bad": "x", films + "-other": 900000}))
        self.assertEqual(mod.advisory_window(films + "/film-a/sub")[0], 700000)
        self.assertEqual(mod.advisory_window(films)[0], 600000)
        self.assertEqual(mod.advisory_window(str(self.root)), (mod.ADVISORY_WINDOW, "default"))

    def test_env_overrides_file(self):
        self.file.write_text(json.dumps({str(self.root): 700000}))
        os.environ["CONTEXT_ADVISOR_WINDOW"] = "500000"
        try:
            self.assertEqual(mod.advisory_window(str(self.root))[1], "env")
        finally:
            os.environ.pop("CONTEXT_ADVISOR_WINDOW", None)


class BandsTest(unittest.TestCase):
    def test_band_list_must_match_the_band_names(self):
        self.assertEqual(mod._bands("0.5,0.6,0.9"), [0.5, 0.6, 0.9])
        self.assertEqual(mod._bands("0.9,0.5,0.6"), [0.5, 0.6, 0.9], "sorted ascending")
        for bad in (None, "", "0.5,0.6", "0.5,0.6,0.7,0.8", "a,b,c", "0.5,0.6,1.5", "0,0.5,0.6"):
            self.assertEqual(mod._bands(bad), [0.55, 0.70, 0.85], bad)


class ModelWindowTest(unittest.TestCase):
    """The window when Claude Code did not report one. Transcripts record the bare model id on
    Bedrock and the Anthropic API alike ("claude-opus-5-5"), never Claude Code's "[1m]" suffix."""

    def window(self, model, tokens=120_000, settings_model=None, **env):
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(mod, "_setting", lambda key: settings_model if key == "model" else None):
            return mod.model_window(model, tokens)

    def test_model_base_strips_provider_decoration(self):
        for raw, base in (("us.anthropic.claude-opus-5-5[1m]", "claude-opus-5-5"),
                          ("global.anthropic.claude-sonnet-5-5", "claude-sonnet-5-5"),
                          ("us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0", "claude-sonnet-4-5"),
                          ("anthropic.claude-haiku-4-5-20251001-v1:0", "claude-haiku-4-5"),
                          ("claude-haiku-4-5-20251001", "claude-haiku-4-5"),
                          ("claude-opus-4-1@20250805", "claude-opus-4-1"),
                          ("claude-opus-5-5", "claude-opus-5-5"),
                          ("opus[1m]", "opus")):
            self.assertEqual(mod.model_base(raw), base, raw)

    def test_bedrock_family_default_with_the_suffix_means_1m(self):
        self.assertEqual(self.window("claude-opus-5-5", ANTHROPIC_DEFAULT_OPUS_MODEL="us.anthropic.claude-opus-5-5[1m]"),
                         (1_000_000, "configured:ANTHROPIC_DEFAULT_OPUS_MODEL"))

    def test_direct_api_model_with_the_suffix_means_1m(self):
        self.assertEqual(self.window("claude-opus-5-5", ANTHROPIC_MODEL="claude-opus-5-5[1m]"),
                         (1_000_000, "configured:ANTHROPIC_MODEL"))

    def test_settings_alias_with_the_suffix_means_1m(self):
        self.assertEqual(self.window("claude-sonnet-5-5", settings_model="sonnet[1m]"),
                         (1_000_000, "configured:settings.model"))

    def test_an_alias_without_the_suffix_defers_to_the_family_default(self):
        self.assertEqual(self.window("claude-opus-5-5", settings_model="opus",
                                     ANTHROPIC_DEFAULT_OPUS_MODEL="us.anthropic.claude-opus-5-5[1m]"),
                         (1_000_000, "configured:ANTHROPIC_DEFAULT_OPUS_MODEL"))

    def test_the_custom_model_option_counts(self):
        self.assertEqual(self.window("claude-opus-5", ANTHROPIC_CUSTOM_MODEL_OPTION="us.anthropic.claude-opus-5[1m]",
                                     ANTHROPIC_DEFAULT_OPUS_MODEL="us.anthropic.claude-opus-5-5[1m]"),
                         (1_000_000, "configured:ANTHROPIC_CUSTOM_MODEL_OPTION"))

    def test_an_exact_id_chosen_without_the_suffix_is_200k(self):
        self.assertEqual(self.window("claude-opus-5-5", ANTHROPIC_MODEL="us.anthropic.claude-opus-5-5",
                                     ANTHROPIC_DEFAULT_OPUS_MODEL="us.anthropic.claude-opus-5-5[1m]"),
                         (200_000, "default"))

    def test_a_suffix_on_another_model_does_not_count(self):
        self.assertEqual(self.window("claude-opus-5-5", ANTHROPIC_DEFAULT_OPUS_MODEL="us.anthropic.claude-opus-5[1m]"),
                         (200_000, "default"))

    def test_an_unconfigured_model_under_200k_is_200k(self):
        self.assertEqual(self.window("claude-opus-5-5"), (200_000, "default"))

    def test_the_suffix_on_the_id_itself_and_more_than_200k_tokens_mean_1m(self):
        self.assertEqual(self.window("claude-opus-5-5[1m]"), (1_000_000, "model"))
        self.assertEqual(self.window("claude-opus-5-5", tokens=250_000), (1_000_000, "tokens"))

    def test_natively_large_models_are_configurable(self):
        self.assertEqual(self.window("claude-sonnet-5-5", CONTEXT_ADVISOR_1M_MODELS="^claude-sonnet-5"),
                         (1_000_000, "native"))
        self.assertEqual(self.window("claude-opus-5-5", CONTEXT_ADVISOR_1M_MODELS="^claude-sonnet-5"),
                         (200_000, "default"))
        self.assertEqual(self.window("claude-opus-5-5", CONTEXT_ADVISOR_1M_MODELS="(unbalanced"),
                         (200_000, "default"), "a bad pattern is ignored")


class HookCase(unittest.TestCase):
    """A temp HOME, a fake Jev and an environment stripped of the caller's advisor, model and identity settings."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="advisor-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sensor_dir = self.root / "sensor"
        self.sensor_dir.mkdir()
        self.server = HTTPServer(("127.0.0.1", 0), FakeJev)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        FakeJev.answers, FakeJev.status, FakeJev.requests = {}, 200, []
        # DF_* goes too: the caller's DF_IDENTITY=work would turn Jev off. With HOME below there is
        # no ~/.df-profile either, so identity() is "" unless a test sets DF_IDENTITY itself.
        # ANTHROPIC_* and CODEX_* go because the window fallback and Codex config read them.
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CONTEXT_", "TYPESAFE", "JEV_", "AGENT_", "CLAUDE_CODE_AUTO", "DF_",
                                         "ANTHROPIC_", "CODEX_", "MEMORY_BOUNDARY"))}
        self.env.update(CONTEXT_SENSOR_DIR=str(self.sensor_dir), CONTEXT_ADVISOR_STATE_DIR=str(self.root / "state"),
                        CONTEXT_ADVISOR_LOG=str(self.root / "advisor.jsonl"), REFLECTOR_DISABLE="1",
                        AGENT_NOTIFY_BIN="/nonexistent", TYPESAFE_API_KEY="test-key",
                        JEV_ENDPOINT=f"http://127.0.0.1:{self.server.server_port}/v1/systemone",
                        HOME=str(self.root))  # no ~/.claude/settings.json → default compaction point

    def last_log(self):
        return json.loads((self.root / "advisor.jsonl").read_text().splitlines()[-1])


    def record_spawns(self):
        """Let reflections start, through a stand-in reflector that records its arguments."""
        self.spawned = self.root / "spawned.jsonl"
        fake = self.root / "fake_reflector.py"
        fake.write_text("import json, sys\nopen(%r, 'a').write(json.dumps(sys.argv[1:]) + '\\n')\n" % str(self.spawned))
        self.env.pop("REFLECTOR_DISABLE", None)
        self.env["REFLECTOR_SCRIPT"] = str(fake)

    def spawns(self):
        """[(trigger, tier, stage pct or None)] in the order they started."""
        if not self.spawned.exists():
            return []
        out = []
        for line in self.spawned.read_text().splitlines():
            a = json.loads(line)
            pct = a[a.index("--stage-pct") + 1] if "--stage-pct" in a else None
            out.append((a[a.index("--trigger") + 1], a[a.index("--tier") + 1], pct and int(pct)))
        return out


class AdvisorTest(HookCase):
    def setUp(self):
        super().setUp()
        self.transcript = self.root / "t.jsonl"
        with open(self.transcript, "w") as f:
            f.write(json.dumps({"type": "user", "message": {"content": "migrate the auth module"}}) + "\n")
            f.write(json.dumps({"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Migration done and tests pass."},
                {"type": "tool_use", "name": "Bash", "input": {"command": "pytest"}}]}}) + "\n")

    def sense(self, tokens, size=200_000, age=0):
        (self.sensor_dir / "s1.json").write_text(json.dumps({"tokens": tokens, "size": size, "ts": time.time() - age}))

    def hook(self, event="PostToolBatch", **kw):
        payload = {"hook_event_name": event, "session_id": "s1", "cwd": str(self.root),
                   "transcript_path": str(self.transcript), **kw}
        r = subprocess.run(["bash", str(WRAPPER)], input=json.dumps(payload), capture_output=True, text=True,
                           env=self.env, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout) if r.stdout.strip() else {}

    def state(self):
        p = self.root / "state/s1.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def test_fast_path_never_starts_python_below_the_floor(self):
        self.sense(30_000)  # the floor: 100k, or the first stage (20%) of a smaller window — 40k here
        self.assertEqual(self.hook(), {})
        self.assertEqual(self.state(), {}, "under the floor the wrapper exits before Python")

    def test_reflect_band_is_silent_then_advise_band_consults_jev_once(self):
        self.sense(115_000)  # 57.5% of a 200k window → reflect band
        self.assertEqual(self.hook(), {})
        self.assertEqual(self.state()["band"], 0)
        self.assertEqual(FakeJev.requests, [])
        FakeJev.answers = {"natural_boundary": 0.82, "fresh_session_better": 0.77, "delicate_operation": 0.05}
        self.sense(145_000)  # 72.5% → advise
        out = self.hook()
        self.assertTrue(out)
        ctx = out["hookSpecificOutput"]
        self.assertEqual(ctx["hookEventName"], "PostToolBatch")
        self.assertIn("145k tokens, 72% of its 200k advisory budget", ctx["additionalContext"])
        self.assertIn("good point to hand off", ctx["additionalContext"])
        self.assertIn("run the `fresh-session-handoff` skill on your own", ctx["additionalContext"])
        self.assertNotIn("/handoff", ctx["additionalContext"], "no longer offers the clipboard handoff")
        self.assertNotIn("background reflection", ctx["additionalContext"], "reflector was disabled")
        self.assertIn("fresh session", out["systemMessage"])
        self.assertEqual(self.state()["hint"], "handoff")
        sent = FakeJev.requests[0]
        self.assertEqual(sent["state"]["user_request"]["latest"], "migrate the auth module")
        self.assertEqual(set(sent["questions"]), {"natural_boundary", "fresh_session_better", "delicate_operation"})
        self.assertEqual(self.hook(), {}, "the same band never fires twice")
        self.assertEqual(len(FakeJev.requests), 1)

    def test_a_session_that_already_handed_off_is_told_so_and_jev_is_not_asked(self):
        FakeJev.answers = {"natural_boundary": 0.9, "fresh_session_better": 0.9, "delicate_operation": 0.05}
        marker = self.root / ".claude/state/handoff/s1.json"  # launch.sh's marker, under the test HOME
        marker.parent.mkdir(parents=True)
        marker.write_text(json.dumps({"target": "handoffs:work-2", "state": "ok"}) + "\n")
        self.sense(150_000)
        out = self.hook()
        ctx = out["hookSpecificOutput"]["additionalContext"]
        self.assertIn("already handed off to tmux window handoffs:work-2", ctx)
        self.assertNotIn("run the `fresh-session-handoff` skill", ctx)
        self.assertIn("handed off to handoffs:work-2", out["systemMessage"])
        self.assertEqual(FakeJev.requests, [], "no Jev call once handed off")
        self.assertEqual(self.state()["hint"], "handed-off")

    def test_a_restricted_session_never_sends_excerpts_to_jev(self):
        FakeJev.answers = {"natural_boundary": 0.9, "fresh_session_better": 0.9, "delicate_operation": 0.05}
        asked = self.root / "boundary-asked"
        self.env.update(MEMORY_BOUNDARY_CMD=f'echo "$MEMORY_BOUNDARY_TOOL $MEMORY_BOUNDARY_PATH" > {asked}; '
                                            '[ "$RESTRICTED" = 1 ] || exit 1', RESTRICTED="1")
        self.sense(150_000)
        out = self.hook()
        self.assertIn("advisory budget", out["hookSpecificOutput"]["additionalContext"], "the advice still comes")
        self.assertEqual(FakeJev.requests, [], "a restricted session's excerpts reached Jev")
        self.assertEqual(self.last_log()["jev_skipped"], "data boundary")
        self.assertEqual(asked.read_text().split(), ["context-advisor", str(self.transcript)])

    def test_a_broken_boundary_check_fails_closed_and_exit_1_lets_jev_be_asked(self):
        FakeJev.answers = {"natural_boundary": 0.9, "fresh_session_better": 0.9, "delicate_operation": 0.05}
        self.env["MEMORY_BOUNDARY_CMD"] = "/nonexistent/boundary-check"
        self.sense(150_000)
        self.hook()
        self.assertEqual(FakeJev.requests, [], "a check that cannot run must keep the excerpts back")
        (self.root / "state/s1.json").unlink()  # a fresh cycle, so the advise band fires again
        self.env["MEMORY_BOUNDARY_CMD"] = "exit 1"
        self.hook()
        self.assertEqual(len(FakeJev.requests), 1, "exit 1 means unrestricted")
        self.assertNotIn("jev_skipped", self.last_log())

    def test_delicate_operation_says_keep_going(self):
        FakeJev.answers = {"natural_boundary": 0.2, "fresh_session_better": 0.7, "delicate_operation": 0.9}
        self.sense(150_000)
        out = self.hook()
        self.assertIn("mid-operation", out["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.state()["hint"], "lean")

    def test_new_prompt_on_a_new_topic_suggests_fresh_session(self):
        FakeJev.answers = {"natural_boundary": 0.3, "fresh_session_better": 0.4, "delicate_operation": 0.1,
                           "new_topic": 0.9}
        self.sense(150_000)
        out = self.hook("UserPromptSubmit", prompt="now redesign the billing page")
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "UserPromptSubmit")
        self.assertIn("new, separate task", out["hookSpecificOutput"]["additionalContext"])
        self.assertIn("new_topic", FakeJev.requests[0]["questions"])

    def test_top_band_without_jev_runs_the_fresh_session_handoff_skill(self):
        self.env["CONTEXT_ADVISOR_JEV"] = "0"
        self.sense(150_000)  # 75% of a 200k budget: advise band keeps today's wording
        ctx = self.hook()["hookSpecificOutput"]["additionalContext"]
        self.assertIn("consider recording open items and suggesting a fresh session", ctx)
        self.assertNotIn("fresh-session-handoff", ctx)
        self.sense(175_000)  # 87.5%: the top (urge) band
        ctx = self.hook()["hookSpecificOutput"]["additionalContext"]
        self.assertIn("175k tokens, 88% of its 200k advisory budget", ctx)
        self.assertIn("At the next natural stopping point", ctx)
        self.assertIn("run the `fresh-session-handoff` skill on your own", ctx)
        self.assertIn("tell the user", ctx)
        self.assertNotIn("consider recording open items", ctx)
        self.assertEqual(FakeJev.requests, [], "Jev was off")
        self.assertEqual(self.state()["band"], 2)

    def test_jev_failure_and_missing_key_fall_back_to_plain_numbers(self):
        FakeJev.status = 500
        self.sense(150_000)
        out = self.hook()
        self.assertIn("Keep tool output lean", out["hookSpecificOutput"]["additionalContext"])
        log = [json.loads(line) for line in (self.root / "advisor.jsonl").read_text().splitlines()]
        self.assertTrue(log[-1]["jev_error"])
        self.env.pop("TYPESAFE_API_KEY")
        (self.root / "state/s1.json").unlink()
        FakeJev.requests = []
        out = self.hook()
        self.assertIn("Keep tool output lean", out["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(FakeJev.requests, [], "no key → Jev is never called")

    def test_bands_rearm_after_compaction_with_the_real_fast_path_floor(self):
        FakeJev.answers = {"natural_boundary": 0.1, "fresh_session_better": 0.1, "delicate_operation": 0.1}
        self.sense(150_000)                       # 75% of a 200k budget: advise
        self.assertTrue(self.hook())
        self.sense(160_000)
        self.assertEqual(self.hook(), {}, "same band stays silent")
        self.sense(30_000)                        # compacted: under the 100k floor
        self.assertEqual(self.hook(), {})
        self.assertEqual(self.state()["band"], -1, "a live cycle lets Python re-arm below the floor")
        state_file = self.root / "state/s1.json"
        before = state_file.stat().st_mtime_ns
        self.sense(35_000)                        # still under the 40k floor of a 200k window
        self.assertEqual(self.hook(), {})
        self.assertEqual(state_file.stat().st_mtime_ns, before, "once re-armed, the fast path skips Python again")
        self.sense(150_000)
        self.assertTrue(self.hook(), "a new cycle advises again")

    def test_stages_checkpoint_the_model_window_once_per_cycle(self):
        self.record_spawns()
        self.env["CONTEXT_ADVISOR_JEV"] = "0"
        self.sense(210_000, size=1_000_000)
        self.hook()
        self.assertEqual(self.spawns(), [("stage", "haiku", 20)])
        self.sense(230_000, size=1_000_000)
        self.hook()
        self.assertEqual(len(self.spawns()), 1, "a stage fires once per cycle")
        self.sense(420_000, size=1_000_000)
        self.hook()
        self.sense(700_000, size=1_000_000)       # crosses 60%: one Sonnet reflection
        self.hook()
        self.assertEqual(self.spawns()[1:], [("stage", "sonnet", 40), ("stage", "sonnet", 60)])
        self.assertNotIn(("advisor", "deep", None), self.spawns(),
                         "band 0 does not reflect again when a stage already did")
        self.sense(60_000, size=1_000_000)        # compacted
        self.hook()
        self.sense(210_000, size=1_000_000)
        self.hook()
        self.assertEqual(self.spawns()[-1], ("stage", "haiku", 20), "a new cycle starts the stages over")
        entry = [json.loads(x) for x in (self.root / "advisor.jsonl").read_text().splitlines() if '"stage"' in x][0]
        self.assertEqual((entry["stage"], entry["tier"], entry["started"]), (20, "haiku", True))

    def test_a_resumed_session_fires_only_the_highest_crossed_stage(self):
        self.record_spawns()
        self.env["CONTEXT_ADVISOR_JEV"] = "0"
        self.sense(650_000, size=1_000_000)
        self.hook()
        self.assertEqual(self.spawns(), [("stage", "sonnet", 60)])

    def test_small_windows_get_their_first_stage_below_the_old_floor(self):
        self.record_spawns()
        self.sense(45_000)                        # 22% of 200k: under 100k, over the 40k stage floor
        self.hook()
        self.assertEqual(self.spawns(), [("stage", "haiku", 20)])

    def test_with_stages_off_the_reflect_band_reflects_as_before(self):
        self.record_spawns()
        self.env["REFLECTOR_STAGES"] = ""
        self.sense(115_000)                       # 57.5% of 200k: band 0
        self.hook()
        self.assertEqual(self.spawns(), [("advisor", "deep", None)])

    def test_stage_overrides_and_bad_values(self):
        self.record_spawns()
        self.env["REFLECTOR_STAGES"] = "0.5:deep"
        self.sense(110_000)
        self.hook()
        self.assertEqual(self.spawns(), [("stage", "deep", 50)])
        self.assertEqual(mod._stages("0.3:opus,nonsense"), mod._stages(None), "malformed → the default")
        self.assertEqual(mod._stages(""), [])

    def test_a_small_budget_below_the_token_floor_fires_its_band_once(self):
        self.record_spawns()
        self.env["REFLECTOR_STAGES"] = ""
        self.env["CONTEXT_ADVISOR_WINDOW"] = "120000"   # band 0 at 66k, under the old 100k floor
        self.sense(70_000)
        self.hook()
        self.sense(72_000)
        self.hook()
        self.assertEqual(self.spawns(), [("advisor", "deep", None)], "no re-arm while usage keeps growing")
        self.assertEqual(self.state()["band"], 0)

    def test_a_small_directory_budget_fires_its_first_band_on_time_in_a_1m_window(self):
        # The wrapper's floor is 100k here (20% of 1M is more); a 100k budget's bands are 55/70/85k.
        self.record_spawns()
        self.env["REFLECTOR_STAGES"] = ""
        budgets = self.root / "budgets.json"
        budgets.write_text(json.dumps({str(self.root): 100_000}))
        self.env["CONTEXT_ADVISOR_BUDGETS"] = str(budgets)
        self.sense(60_000, size=1_000_000)
        self.hook()
        self.assertEqual(self.state().get("band"), 0, "the reflect band fires at 60% of the budget")
        self.assertEqual(self.spawns(), [("advisor", "deep", None)])

    def test_large_window_uses_the_advisory_budget(self):
        FakeJev.answers = {"natural_boundary": 0.1, "fresh_session_better": 0.1, "delicate_operation": 0.1}
        self.sense(650_000, size=1_000_000)  # 65% of 1M (silent reflect band), but 72% of the 900k budget
        out = self.hook()
        self.assertIn("of its 900k advisory budget (auto-compaction would run near 967k)",
                      out["hookSpecificOutput"]["additionalContext"])

    def test_stale_sensor_falls_back_to_the_transcript(self):
        self.sense(150_000, age=3600)
        with open(self.transcript, "a") as f:
            f.write(json.dumps({"type": "assistant", "message": {"model": "claude-opus-5-5", "content": [], "usage": {
                "input_tokens": 10, "cache_read_input_tokens": 140_000, "cache_creation_input_tokens": 5_000}}}) + "\n")
        FakeJev.answers = {"natural_boundary": 0.1, "fresh_session_better": 0.1, "delicate_operation": 0.1}
        out = self.hook()
        self.assertEqual(self.state()["source"], "transcript")
        self.assertIn("145k tokens", out["hookSpecificOutput"]["additionalContext"])

    def append_usage(self, tokens, model="claude-opus-5-5"):
        with open(self.transcript, "a") as f:
            f.write(json.dumps({"type": "assistant", "message": {"model": model, "content": [], "usage": {
                "input_tokens": 10, "cache_read_input_tokens": tokens - 10, "cache_creation_input_tokens": 0}}}) + "\n")

    def test_transcript_fallback_reads_the_1m_suffix_off_the_configured_model(self):
        self.env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "us.anthropic.claude-opus-5-5[1m]"
        self.append_usage(145_000)  # no sensor: 36% of the 400k budget, not 72% of a 200k window
        self.assertEqual(self.hook(), {})
        st = self.state()
        self.assertEqual((st["source"], st["window_source"], st["band"]),
                         ("transcript", "configured:ANTHROPIC_DEFAULT_OPUS_MODEL", -1))

    def test_a_sensor_without_a_window_size_is_unknown_not_200k(self):
        self.env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "us.anthropic.claude-opus-5-5[1m]"
        self.append_usage(150_000)
        self.sense(150_000, size=0)
        self.assertEqual(self.hook(), {}, "37% of the 400k budget")
        st = self.state()
        self.assertEqual((st["source"], st["window_source"]), ("statusline", "configured:ANTHROPIC_DEFAULT_OPUS_MODEL"))

    def test_the_window_override_beats_the_sensor(self):
        self.env["CONTEXT_ADVISOR_MODEL_WINDOW"] = "1000000"
        self.sense(150_000, size=200_000)
        self.assertEqual(self.hook(), {}, "37% of the 400k budget")
        self.assertEqual(self.state()["window_source"], "override")

    def test_the_log_says_which_source_set_the_window(self):
        self.env["CONTEXT_ADVISOR_JEV"] = "0"
        self.sense(150_000, size=200_000)
        self.assertTrue(self.hook())
        log = self.last_log()
        self.assertEqual((log["window_source"], log["model_window"], log["window"]), ("statusline", 200_000, 200_000))

    def test_work_identity_never_sends_conversation_to_jev_unless_opted_in(self):
        FakeJev.answers = {"natural_boundary": 0.9, "fresh_session_better": 0.9, "delicate_operation": 0.0}
        self.env["DF_IDENTITY"] = "work"
        self.sense(150_000)
        out = self.hook()
        self.assertEqual(FakeJev.requests, [])
        self.assertIn("Keep tool output lean", out["hookSpecificOutput"]["additionalContext"])
        (self.root / "state/s1.json").unlink()
        self.env["CONTEXT_ADVISOR_JEV"] = "1"
        self.hook()
        self.assertEqual(len(FakeJev.requests), 1, "explicit opt-in on work")

    def test_work_identities_are_configurable(self):
        FakeJev.answers = {"natural_boundary": 0.9, "fresh_session_better": 0.9, "delicate_operation": 0.0}
        self.env.update(DF_IDENTITY="client", DF_WORK_IDENTITIES="work client")
        self.sense(150_000)
        self.hook()
        self.assertEqual(FakeJev.requests, [], "an identity listed in DF_WORK_IDENTITIES is work")
        (self.root / "state/s1.json").unlink()
        self.env["DF_IDENTITY"] = "example"
        self.hook()
        self.assertEqual(len(FakeJev.requests), 1, "any other identity consults Jev when a key is set")

    def test_subagents_and_disabled_do_nothing(self):
        self.sense(150_000)
        self.assertEqual(self.hook(agent_id="a1"), {})
        self.env["CONTEXT_ADVISOR_DISABLE"] = "1"
        self.assertEqual(self.hook(), {})
        self.assertEqual(self.state(), {})


# Codex 0.162.1's PostToolUse output schema has additionalProperties: false.
CODEX_OUTPUT_KEYS = {"continue", "decision", "hookSpecificOutput", "reason", "stopReason", "suppressOutput",
                     "systemMessage"}


class CodexAdvisorTest(HookCase):
    """`context-advisor-hook.sh codex`: tokens and window come from the rollout's token_count
    events (Codex has no statusline sensor). 55% reflects; 70/85% add one factual line. No Jev,
    no handoff, no desktop notification."""

    def setUp(self):
        super().setUp()
        self.rollout = self.root / "rollout.jsonl"
        with open(self.rollout, "w") as f:
            f.write(json.dumps({"type": "session_meta", "payload": {"id": "c1", "model_provider": "amazon-bedrock"}}) + "\n")
            f.write(json.dumps({"type": "response_item", "payload": {"type": "message", "role": "user", "content": [
                {"type": "input_text", "text": "render the next shot"}]}}) + "\n")
        self.notified = self.root / "notified"
        notifier = self.root / "notify.sh"
        notifier.write_text(f"#!/bin/sh\ncat >> {self.notified}\n")
        notifier.chmod(0o755)
        self.env["AGENT_NOTIFY_BIN"] = str(notifier)

    def tokens(self, n, window=258_400):
        """Append a token_count event; total_token_usage is the session's cumulative spend, not the context."""
        with open(self.rollout, "a") as f:
            f.write(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": {
                "total_token_usage": {"input_tokens": 90_000_000, "output_tokens": 500_000, "total_tokens": 90_500_000},
                "last_token_usage": {"input_tokens": n - 300, "cached_input_tokens": n - 2_000, "output_tokens": 300,
                                     "total_tokens": n},
                "model_context_window": window}, "rate_limits": None}}) + "\n")

    def hook(self, event="PostToolUse", **kw):
        payload = {"hook_event_name": event, "session_id": "c1", "cwd": str(self.root), "turn_id": "t1",
                   "transcript_path": str(self.rollout), "model": "openai.gpt-6.1-sol", **kw}
        if event == "PostToolUse":
            payload.update(tool_name="exec_command", tool_use_id="u1")
        r = subprocess.run(["bash", str(WRAPPER), "codex"], input=json.dumps(payload), capture_output=True, text=True,
                           env=self.env, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout) if r.stdout.strip() else {}

    def state(self):
        p = self.root / "state/c1.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def test_fast_path_never_starts_python_below_the_floor(self):
        self.tokens(40_000)
        self.assertEqual(self.hook(), {})
        self.assertEqual(self.state(), {})

    def test_codex_stages_follow_the_rollout_window(self):
        self.record_spawns()
        self.tokens(60_000)                       # 23% of 258.4k; the wrapper floor is 51.7k
        self.hook()
        self.assertEqual(self.spawns(), [("stage", "haiku", 20)])
        self.tokens(110_000)
        self.hook()
        self.assertEqual(self.spawns()[-1], ("stage", "sonnet", 40))

    def test_reflect_band_is_silent(self):
        self.tokens(150_000)  # 58% of 258.4k
        self.assertEqual(self.hook(), {})
        st = self.state()
        self.assertEqual((st["band"], st["source"], st["window_source"]), (0, "rollout", "codex"))
        self.assertEqual(self.last_log()["agent"], "codex")

    def test_advise_and_urge_bands_state_the_numbers_without_handoff_or_jev(self):
        FakeJev.answers = {"natural_boundary": 0.9, "fresh_session_better": 0.9, "delicate_operation": 0.0}
        self.tokens(190_000)  # 73.5%: advise
        out = self.hook()
        self.assertLessEqual(set(out), CODEX_OUTPUT_KEYS)
        ctx = out["hookSpecificOutput"]
        self.assertEqual(set(ctx), {"hookEventName", "additionalContext"})
        self.assertEqual(ctx["hookEventName"], "PostToolUse")
        text = ctx["additionalContext"]
        self.assertIn("190k tokens, 74% of its 258k advisory budget (auto-compaction would run near 258k)", text)
        self.assertIn("Keep tool output lean", text)
        for word in ("handoff", "hand off", "fresh session", "fresh-session"):
            self.assertNotIn(word, text)
        self.assertEqual(out["systemMessage"], "◔ context 74% of 258k budget")
        self.assertEqual(FakeJev.requests, [], "Codex never consults Jev")
        self.assertFalse(self.notified.exists(), "Codex bands do not notify")
        self.tokens(195_000)
        self.assertEqual(self.hook(), {}, "the same band never fires twice")
        self.tokens(225_000)  # 87%: urge
        self.assertIn("87% of its 258k", self.hook()["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.state()["band"], 2)

    def test_user_prompt_submit_advises_too(self):
        self.tokens(190_000)
        out = self.hook("UserPromptSubmit", prompt="next shot")
        self.assertEqual(out["hookSpecificOutput"]["hookEventName"], "UserPromptSubmit")

    def test_the_newest_token_count_wins_and_rate_limit_only_events_are_skipped(self):
        self.tokens(120_000)
        self.tokens(190_000)
        with open(self.rollout, "a") as f:
            f.write(json.dumps({"type": "event_msg", "payload": {"type": "token_count", "info": None,
                                                                 "rate_limits": {"limit_id": "codex"}}}) + "\n")
        self.assertIn("190k tokens", self.hook()["hookSpecificOutput"]["additionalContext"])

    def test_bands_rearm_after_codex_compacts(self):
        self.tokens(190_000)
        self.assertTrue(self.hook())
        self.tokens(30_000)  # compacted: under the 100k floor
        self.assertEqual(self.hook(), {})
        self.assertEqual(self.state()["band"], -1)
        self.tokens(190_000)
        self.assertTrue(self.hook(), "a new cycle advises again")

    def test_the_claude_window_override_does_not_touch_codex(self):
        self.env["CONTEXT_ADVISOR_MODEL_WINDOW"] = "1000000"  # exported for Claude, inherited by Codex
        self.tokens(190_000)
        self.assertIn("74% of its 258k", self.hook()["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.state()["window_source"], "codex")

    @unittest.skipUnless(importlib.util.find_spec("tomllib"), "tomllib needs Python 3.11+")
    def test_auto_compact_limit_from_codex_config(self):
        (self.root / ".codex").mkdir()
        (self.root / ".codex/config.toml").write_text('model = "openai.gpt-6.1-sol"\nmodel_auto_compact_token_limit = 200000\n')
        self.tokens(150_000)  # 58% of the window, but 75% of the 200k compaction limit
        self.assertIn("150k tokens, 75% of its 200k advisory budget (auto-compaction would run near 200k)",
                      self.hook()["hookSpecificOutput"]["additionalContext"])

    def test_subagents_and_claude_events_do_nothing(self):
        self.tokens(190_000)
        self.assertEqual(self.hook(agent_id="a1"), {})
        self.assertEqual(self.hook("PostToolBatch"), {})
        self.assertEqual(self.state(), {})


if __name__ == "__main__":
    unittest.main(verbosity=2)
