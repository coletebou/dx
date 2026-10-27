#!/usr/bin/env python3
"""Hermetic tests for base/claude/session_reflector.py.

A fake claude-consolidate returns a canned reply (and records the prompt it got),
transcripts are synthetic, and the reflections store lives in a temp dotfiles tree.
"""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "base/claude/session_reflector.py"
WRAPPER = ROOT / "base/claude/session-reflector-hook.sh"
REFLECTIONS = ROOT / "scripts/reflections"

spec = importlib.util.spec_from_file_location("session_reflector", SCRIPT)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

REPLY = {
    "topic": "StopFailure retry hook",
    "summary": "Built the retry hook. Tests pass. Next: wire it into settings.",
    "items": [
        {"kind": "action", "title": "Register the StopFailure hook in settings.base.json",
         "body": "Needs asyncRewake and timeout 900.", "tags": ["hooks"], "priority": 1},
        {"kind": "gotcha", "title": "asyncRewake exit 2 wakes an idle session", "body": "Verified."},
        {"kind": "bogus", "title": "dropped: unknown kind"},
        {"kind": "learning", "title": ""},
    ],
}


def user(text, **kw):
    return {"type": "user", "entrypoint": kw.pop("entrypoint", "cli"),
            "message": {"role": "user", "content": text}, **kw}


def assistant(*blocks, **kw):
    return {"type": "assistant", "message": {"role": "assistant", "content": list(blocks)}, **kw}


def request(model="global.anthropic.claude-opus-5-5"):
    """What Claude Code 2.1.300+ records for a main-thread request: the model id it went to."""
    return {"type": "api-request", "version": "2.1.310", "params": {"model": model}}


class CondenseTest(unittest.TestCase):
    def write(self, entries):
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        self.addCleanup(os.unlink, f.name)
        for e in entries:
            f.write(json.dumps(e) + "\n")
        f.close()
        return f.name

    def test_claude_keeps_dialogue_tools_and_errors_but_not_tool_output(self):
        path = self.write([
            user("<system-reminder>ignore me</system-reminder>"),
            user("please add a retry hook"),
            assistant({"type": "thinking", "thinking": "secret reasoning"},
                      {"type": "text", "text": "Adding it now."},
                      {"type": "tool_use", "name": "Bash", "input": {"command": "pytest -q"}}),
            user([{"type": "tool_result", "is_error": False, "content": "1000 lines of output"}]),
            user([{"type": "tool_result", "is_error": True, "content": "FAILED test_x"}]),
            assistant({"type": "text", "text": "API Error: 500"}, isApiErrorMessage=True),
            user("<command-name>/reflect</command-name><command-args>now</command-args>"),
            user("sidechain", isSidechain=True),
            user("meta", isMeta=True),
        ])
        text, offset, entrypoint, prompts = mod.condense(path, 0)
        self.assertIn("USER: please add a retry hook", text)
        self.assertIn("ASSISTANT: Adding it now.", text)
        self.assertIn("TOOL Bash: command=pytest -q", text)
        self.assertIn("TOOL ERROR: FAILED test_x", text)
        self.assertIn("API ERROR: API Error: 500", text)
        self.assertIn("USER: /reflect now", text)
        for absent in ("ignore me", "secret reasoning", "1000 lines", "sidechain", "meta"):
            self.assertNotIn(absent, text)
        self.assertEqual((entrypoint, prompts), ("cli", 2))
        self.assertEqual(offset, os.path.getsize(path))

    def test_incremental_offset_reads_only_new_complete_lines(self):
        path = self.write([user("first request")])
        _, offset, _, _ = mod.condense(path, 0)
        with open(path, "a") as f:
            f.write(json.dumps(user("second request")) + "\n" + '{"type": "us')  # torn tail
        text, new_offset, _, _ = mod.condense(path, offset)
        self.assertNotIn("first request", text)
        self.assertIn("second request", text)
        self.assertLess(new_offset, os.path.getsize(path), "the torn line is left for next time")

    def test_codex_rollout(self):
        path = self.write([
            {"type": "session_meta", "payload": {"id": "t1"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                  "content": [{"type": "input_text", "text": "# AGENTS.md instructions ..."}]}},
            {"type": "response_item", "payload": {"type": "message", "role": "user",
                                                  "content": [{"type": "input_text", "text": "fix the flaky test"}]}},
            {"type": "response_item", "payload": {"type": "function_call", "name": "exec_command",
                                                  "arguments": json.dumps({"command": "npm test"})}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                                  "content": [{"type": "output_text", "text": "Fixed."}]}},
        ])
        text, _, entrypoint, prompts = mod.condense(path, 0)
        self.assertEqual((entrypoint, prompts), ("codex", 1))
        self.assertIn("TOOL exec_command: command=npm test", text)
        self.assertNotIn("AGENTS.md", text)


class ParseAndModelTest(unittest.TestCase):
    def test_parse_accepts_fenced_json_and_filters_bad_items(self):
        topic, summary, items = mod.parse_reply("```json\n" + json.dumps(REPLY) + "\n```")
        self.assertEqual(topic, "StopFailure retry hook")
        self.assertTrue(summary.startswith("Built"))
        self.assertEqual([i["kind"] for i in items], ["action", "gotcha"])
        self.assertEqual(items[0]["priority"], 1)
        with self.assertRaises(ValueError):
            mod.parse_reply("I could not do that.")

    def test_prompt_calibrates_priority_and_a_copied_placeholder_sets_none(self):
        # The old template showed "priority": 1, which models copied: a third of the
        # store claimed priority 1. The template now holds a placeholder string.
        prompt = mod.build_prompt("USER: hi", "webapp", "test", [])
        self.assertNotIn('"priority": 1', prompt)
        self.assertIn("most items are 3", prompt)
        reply = {"items": [{"kind": "action", "title": "copied", "body": "b",
                            "priority": "action only, 1-5 (see below)"},
                           {"kind": "action", "title": "real", "body": "b", "priority": 2}]}
        _, _, items = mod.parse_reply(json.dumps(reply))
        self.assertNotIn("priority", items[0])
        self.assertEqual(items[1]["priority"], 2)

    def test_deep_tier_prefers_reflector_model_then_consolidate_model_then_sonnet(self):
        saved = dict(os.environ)
        try:
            for k in ("REFLECTOR_MODEL", "CLAUDE_CONSOLIDATE_MODEL"):
                os.environ.pop(k, None)
            self.assertEqual(mod.pick_model(), "sonnet")
            os.environ["CLAUDE_CONSOLIDATE_MODEL"] = "anthropic.claude-opus-4-8[1m]"
            self.assertEqual(mod.pick_model(), "anthropic.claude-opus-4-8[1m]", "a full id is passed through")
            os.environ["REFLECTOR_MODEL"] = "opus"
            self.assertEqual(mod.pick_model(), "opus")
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_tiers_default_to_aliases_and_take_env_overrides(self):
        saved = dict(os.environ)
        try:
            for k in ("REFLECTOR_HAIKU_MODEL", "REFLECTOR_SONNET_MODEL"):
                os.environ.pop(k, None)
            self.assertEqual((mod.pick_model("haiku"), mod.pick_model("sonnet")), ("haiku", "sonnet"))
            os.environ["REFLECTOR_HAIKU_MODEL"] = "claude-haiku-5-5"
            os.environ["REFLECTOR_SONNET_MODEL"] = "us.anthropic.claude-sonnet-5-5"
            self.assertEqual(mod.pick_model("haiku"), "claude-haiku-5-5")
            self.assertEqual(mod.pick_model("sonnet"), "us.anthropic.claude-sonnet-5-5")
            self.assertEqual((mod.fallback_model("haiku"), mod.fallback_model("deep")), ("haiku", "sonnet"))
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_updates_need_offered_ids_known_ops_and_evidence(self):
        data = {"updates": [
            {"op": "done", "id": "#abc12345", "note": " shipped   in  abc "},
            {"op": "done", "id": "notoffer", "note": "x"},
            {"op": "drop", "id": "abc12345"},
            {"op": "edit", "id": "abc12345", "note": "renamed"},
            {"op": "edit", "id": "abc12345", "priority": 2},
            {"op": "nuke", "id": "abc12345", "note": "x"},
            "garbage"]}
        self.assertEqual(mod.parse_updates(data, ["abc12345"]),
                         [{"op": "done", "id": "abc12345", "note": "shipped in abc"},
                          {"op": "edit", "id": "abc12345", "priority": 2}])

    def test_end_of_session_waits_for_a_running_reflection(self):
        import fcntl
        import threading
        with tempfile.NamedTemporaryFile() as f:
            holder = open(f.name, "w")
            fcntl.flock(holder, fcntl.LOCK_EX)
            threading.Timer(1.0, lambda: (fcntl.flock(holder, fcntl.LOCK_UN), holder.close())).start()
            waiter = open(f.name, "w")
            self.assertFalse(mod.acquire(waiter, "stage"), "a stage run does not wait")
            t0 = time.time()
            self.assertTrue(mod.acquire(waiter, "sessionend"))
            self.assertGreater(time.time() - t0, 0.5)
            waiter.close()


class BoundaryTest(unittest.TestCase):
    """MEMORY_BOUNDARY_CMD: exit 0 skips, exit 1 reflects, anything else skips (fails closed)."""

    def skip(self, cmd, tool="reflector", **env):
        saved = dict(os.environ)
        try:
            os.environ.pop("MEMORY_BOUNDARY_CMD", None)
            if cmd is not None:
                os.environ["MEMORY_BOUNDARY_CMD"] = cmd
            os.environ.update(env)
            return mod.boundary_skip("/tmp/t.jsonl", "s9", "sessionend", tool=tool)
        finally:
            os.environ.clear()
            os.environ.update(saved)

    def test_exit_codes(self):
        self.assertFalse(self.skip(None), "no command: every session may be reflected")
        self.assertTrue(self.skip("exit 0"))
        self.assertFalse(self.skip("exit 1"))
        self.assertTrue(self.skip("exit 3"), "an unexpected answer fails closed")
        self.assertTrue(self.skip("/nonexistent/boundary-check"), "a missing command fails closed")
        self.assertTrue(self.skip("sleep 5", MEMORY_BOUNDARY_TIMEOUT="0.2"), "a hung command fails closed")

    def test_the_command_sees_the_session(self):
        cmd = ('[ "$MEMORY_BOUNDARY_TOOL" = reflector ] && [ "$MEMORY_BOUNDARY_SESSION" = s9 ] && '
               '[ "$MEMORY_BOUNDARY_TRIGGER" = sessionend ] && [ "$MEMORY_BOUNDARY_PATH" = /tmp/t.jsonl ] && '
               '[ "$RESTRICTED" = 1 ] || exit 1')
        self.assertTrue(self.skip(cmd, RESTRICTED="1"))
        self.assertFalse(self.skip(cmd, RESTRICTED="0"))

    def test_another_tool_asks_under_its_own_name(self):
        cmd = '[ "$MEMORY_BOUNDARY_TOOL" = context-advisor ] || exit 1'
        self.assertTrue(self.skip(cmd, tool="context-advisor"))
        self.assertFalse(self.skip(cmd))


class EndToEndTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="reflector-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name).resolve()
        self.dot = root / "dotfiles"
        (self.dot / "claude").mkdir(parents=True)
        (self.dot / "claude/memory-homes.conf").write_text("")
        self.prompt_seen = root / "prompt-seen.md"
        fake = root / "claude-consolidate"
        self.models_seen = root / "models-seen.txt"
        self.reply_file = root / "reply.json"  # when present, replaces the canned REPLY
        fake.write_text(f"""#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
prompt = open(args[args.index("--prompt") + 1]).read()
open({str(self.prompt_seen)!r}, "a").write(prompt + "\\n=====\\n")
if os.environ.get("AGENT_HOOK_CHILD") != "1":
    sys.exit(9)  # the reflector must always mark its children
if "--isolated" not in args:
    sys.exit(8)  # transcript text must never reach a model that has tools
model = args[args.index("--model") + 1]
open({str(self.models_seen)!r}, "a").write(model + "\\n")
if model.startswith("anthropic."):
    sys.exit(3)  # an unreachable route: forces the sonnet retry
reply = open({str(self.reply_file)!r}).read() if os.path.exists({str(self.reply_file)!r}) else {json.dumps(json.dumps(REPLY))}
open(args[args.index("--output") + 1], "w").write(reply)
""")
        fake.chmod(0o755)
        self.cwd = root / "work/shop"
        self.cwd.mkdir(parents=True)
        self.transcript = root / "t.jsonl"
        # Several real turns: each message is clipped when condensed, so size must come
        # from turns, as in a real session, to clear the sessionend threshold.
        with open(self.transcript, "w") as f:
            for n in range(6):
                for e in (user(f"step {n}: build the retry hook " + "x" * 3000), request(),
                          assistant({"type": "text", "text": f"step {n} done " + "y" * 3000}, version="2.1.310")):
                    f.write(json.dumps(e) + "\n")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CLAUDE", "REFLECT", "AGENT_", "CODEX", "API_RECOVERY", "MEMORY_BOUNDARY"))}
        self.env.update(REFLECTIONS_DOTFILES=str(self.dot), MEMORY_HOMES_CONF=str(self.dot / "claude/memory-homes.conf"),
                        REFLECTIONS_INDEX=str(root / "index.sqlite"), REFLECTIONS_CLAUDE_PROJECTS=str(root / "projects"),
                        CODEX_HOME=str(root / "codex"), REFLECTIONS_HOST="host-a", DF_IDENTITY="personal",
                        REFLECTOR_STATE_DIR=str(root / "state"), REFLECTOR_LOG=str(root / "reflector.jsonl"),
                        CLAUDE_CONSOLIDATE_BIN=str(fake), CLAUDE_CONSOLIDATE_MODEL="anthropic.claude-opus-4-8[1m]")
        self.log = root / "reflector.jsonl"

    def reflections(self, *args):
        r = subprocess.run([str(REFLECTIONS), *args], cwd=self.cwd, env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def run_reflector(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.cwd, env=self.env,
                              capture_output=True, text=True, timeout=60)

    def test_a_restricted_session_is_never_reflected(self):
        # 1. The hook and a stage spawn in a restricted session: no model call at all.
        env = dict(self.env, MEMORY_BOUNDARY_CMD='[ "$RESTRICTED" = 1 ] || exit 1', RESTRICTED="1")
        hook = json.dumps({"transcript_path": str(self.transcript), "session_id": "g1", "cwd": str(self.cwd)})
        r = subprocess.run([sys.executable, str(SCRIPT), "hook", "sessionend"], input=hook, cwd=self.cwd, env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = subprocess.run([sys.executable, str(SCRIPT), "spawn", "--transcript", str(self.transcript),
                            "--session", "g1", "--cwd", str(self.cwd), "--trigger", "stage", "--tier", "haiku",
                            "--stage-pct", "20"], cwd=self.cwd, env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        # 2. A check on the transcript itself, from a manual run whose own environment looks fine.
        with open(self.transcript, "a") as f:
            f.write(json.dumps(assistant({"type": "text", "text": "client-confidential turn"})) + "\n")
        self.env["MEMORY_BOUNDARY_CMD"] = 'grep -q client-confidential "$MEMORY_BOUNDARY_PATH" || exit 1'
        r = self.run_reflector("run", "--transcript", str(self.transcript), "--session", "g2",
                               "--cwd", str(self.cwd), "--trigger", "sessionend")
        self.assertEqual(r.returncode, 0, r.stderr)
        time.sleep(0.5)  # the hook path may have detached a child; give it time to (not) call the model
        self.assertFalse(self.models_seen.exists(), "a restricted transcript reached a model")
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])["skipped"], "data boundary")

    def test_a_broken_boundary_check_fails_closed(self):
        self.env["MEMORY_BOUNDARY_CMD"] = "/nonexistent/boundary-check"
        args = ["run", "--transcript", str(self.transcript), "--session", "b1", "--cwd", str(self.cwd),
                "--trigger", "sessionend"]
        self.assertEqual(self.run_reflector(*args).returncode, 0)
        self.assertFalse(self.models_seen.exists())
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])["skipped"], "data boundary")
        self.env["MEMORY_BOUNDARY_CMD"] = "exit 1"
        r = self.run_reflector(*args)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.models_seen.exists(), "exit 1 lets the reflection run")

    def wait_for_log(self, needle, timeout=30):
        deadline = time.time() + timeout
        while time.time() < deadline and not (self.log.exists() and needle in self.log.read_text()):
            time.sleep(0.2)
        return self.log.exists() and needle in self.log.read_text()

    def test_a_restricted_span_is_never_reflected_after_an_unrestricted_resume(self):
        restricted = dict(self.env, MEMORY_BOUNDARY_CMD='[ "$RESTRICTED" = 1 ] || exit 1', RESTRICTED="1")
        hook = json.dumps({"transcript_path": str(self.transcript), "session_id": "g3", "cwd": str(self.cwd)})
        r = subprocess.run([sys.executable, str(SCRIPT), "hook", "sessionend"], input=hook, cwd=self.cwd,
                           env=restricted, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.models_seen.exists())
        # Resumed in an unrestricted session: only what that session adds is reflected.
        with open(self.transcript, "a") as f:
            for n in range(6):
                for e in (user(f"unrestricted step {n}: wire the hook " + "c" * 3000), request(),
                          assistant({"type": "text", "text": f"unrestricted {n} done " + "d" * 3000},
                                    version="2.1.310")):
                    f.write(json.dumps(e) + "\n")
        r = subprocess.run([sys.executable, str(SCRIPT), "hook", "sessionend"], input=hook, cwd=self.cwd,
                           env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.wait_for_log('"items"'))
        prompt = self.prompt_seen.read_text()
        self.assertIn("unrestricted step", prompt)
        self.assertNotIn("build the retry hook", prompt, "the restricted span reached a model")

    def test_the_request_look_back_stops_at_a_restricted_span(self):
        restricted = dict(self.env, MEMORY_BOUNDARY_CMD='[ "$RESTRICTED" = 1 ] || exit 1', RESTRICTED="1")
        hook = json.dumps({"transcript_path": str(self.transcript), "session_id": "g4", "cwd": str(self.cwd)})
        r = subprocess.run([sys.executable, str(SCRIPT), "hook", "sessionend"], input=hook, cwd=self.cwd,
                           env=restricted, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        # Resumed unrestricted, the same turn keeps working with no new prompt, so the reflector
        # looks back for the request in progress: that request is in the restricted span.
        with open(self.transcript, "a") as f:
            for n in range(6):
                f.write(json.dumps(request()) + "\n")
                f.write(json.dumps(assistant({"type": "text", "text": f"later step {n} " + "z" * 3000},
                                             version="2.1.310")) + "\n")
        r = self.run_reflector("run", "--transcript", str(self.transcript), "--session", "g4",
                               "--cwd", str(self.cwd), "--trigger", "sessionend")
        self.assertEqual(r.returncode, 0, r.stderr)
        prompt = self.prompt_seen.read_text()
        self.assertIn("later step 5", prompt)
        self.assertNotIn("build the retry hook", prompt, "the look-back reached into the restricted span")

    def test_run_writes_items_retries_on_sonnet_and_is_incremental(self):
        r = self.run_reflector("run", "--transcript", str(self.transcript), "--session", "s1",
                               "--cwd", str(self.cwd), "--trigger", "sessionend")
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = json.loads(self.reflections("list", "--json", "--status", "all"))
        kinds = sorted(r["kind"] for r in rows)
        self.assertEqual(kinds, ["action", "gotcha", "handoff"])
        action = next(r for r in rows if r["kind"] == "action")
        self.assertEqual((action["status"], action["origin"], action["session_id"], action["repo"]),
                         ("open", "sessionend", "s1", "shop"))
        handoff = next(r for r in rows if r["kind"] == "handoff")
        self.assertEqual(handoff["status"], "note")
        runs = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(runs[0].get("retry"), "sonnet")
        self.assertEqual((runs[-1]["model"], runs[-1]["items"]), ("sonnet", 3))
        # Nothing new in the transcript → next run is skipped, not re-reflected.
        r = self.run_reflector("run", "--transcript", str(self.transcript), "--session", "s1",
                               "--cwd", str(self.cwd), "--trigger", "sessionend")
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])["skipped"], "too little new content")

    def test_continuation_without_a_new_prompt_is_still_reflected(self):
        args = ["run", "--transcript", str(self.transcript), "--session", "s5", "--cwd", str(self.cwd),
                "--trigger", "advisor"]
        self.assertEqual(self.run_reflector(*args).returncode, 0)
        with open(self.transcript, "a") as f:  # the same turn keeps working: no new user prompt
            for n in range(6):
                f.write(json.dumps(request()) + "\n")
                f.write(json.dumps(assistant({"type": "text", "text": f"later step {n} " + "z" * 3000},
                                             {"type": "tool_use", "name": "Bash", "input": {"command": "make"}},
                                             version="2.1.310")) + "\n")
        self.prompt_seen.unlink()
        args[-1] = "sessionend"
        self.assertEqual(self.run_reflector(*args).returncode, 0)
        last = json.loads(self.log.read_text().splitlines()[-1])
        self.assertNotIn("skipped", last, "the finished tail of a long turn is reflected")
        prompt = self.prompt_seen.read_text()
        self.assertIn("USER (the request still in progress", prompt)
        self.assertIn("step 5: build the retry hook", prompt, "the goal comes from before the offset")
        self.assertIn("later step 5", prompt)

    def test_first_segment_without_any_prompt_is_skipped(self):
        with open(self.transcript, "w") as f:
            f.write(json.dumps(request()) + "\n")
            for n in range(6):
                f.write(json.dumps(assistant({"type": "text", "text": "z" * 3000}, version="2.1.310")) + "\n")
        self.run_reflector("run", "--transcript", str(self.transcript), "--session", "s6",
                           "--cwd", str(self.cwd), "--trigger", "sessionend")
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])["skipped"], "too little new content")

    def test_prompt_lists_existing_items_so_the_model_can_skip_them(self):
        self.reflections("add", "--kind", "action", "--title", "Already known item")
        self.run_reflector("run", "--transcript", str(self.transcript), "--session", "s2",
                           "--cwd", str(self.cwd), "--trigger", "precompact")
        self.assertIn("- [action/open] Already known item", self.prompt_seen.read_text())

    def test_hook_detaches_and_honours_guards(self):
        payload = json.dumps({"hook_event_name": "PreCompact", "session_id": "s3", "cwd": str(self.cwd),
                              "transcript_path": str(self.transcript), "trigger": "auto"})
        t0 = time.time()
        r = subprocess.run(["bash", str(WRAPPER), "precompact"], input=payload, env=self.env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        self.assertLess(time.time() - t0, 3, "the hook must not wait for the reflection")
        deadline = time.time() + 30
        while time.time() < deadline and not (self.log.exists() and '"items"' in self.log.read_text()):
            time.sleep(0.2)
        self.assertIn('"trigger": "precompact"', self.log.read_text())
        before = self.log.read_text()
        for env in ({**self.env, "AGENT_HOOK_CHILD": "1"}, {**self.env, "REFLECTOR_DISABLE": "1"}):
            subprocess.run(["bash", str(WRAPPER), "sessionend"], input=payload, env=env, text=True, timeout=30)
        sub = json.dumps({**json.loads(payload), "agent_id": "a1"})
        subprocess.run(["bash", str(WRAPPER), "sessionend"], input=sub, env=self.env, text=True, timeout=30)
        time.sleep(1.5)
        self.assertEqual(self.log.read_text(), before, "guarded and subagent events start nothing")

    def grow_transcript(self, tag):
        with open(self.transcript, "a") as f:
            for n in range(4):
                for e in (user(f"{tag} {n}: keep going " + "q" * 2500), request(),
                          assistant({"type": "text", "text": f"{tag} {n} done " + "r" * 2500}, version="2.1.310")):
                    f.write(json.dumps(e) + "\n")

    def test_reflection_reconciles_the_store_with_offered_ids_only(self):
        finished = json.loads(self.reflections("add", "--kind", "action", "--title", "Wire the retry hook",
                                               "--json"))["items"][0]["id"]
        renamed = json.loads(self.reflections("add", "--kind", "action", "--title", "Retry hook docs",
                                              "--json"))["items"][0]["id"]
        later = json.loads(self.reflections("add", "--kind", "action", "--title", "Unrelated later work",
                                            "--json"))["items"][0]["id"]
        other_cwd = self.cwd.parent / "elsewhere"
        other_cwd.mkdir()
        r = subprocess.run([str(REFLECTIONS), "add", "--kind", "action", "--title", "Other repo item", "--json"],
                           cwd=other_cwd, env=self.env, capture_output=True, text=True)
        foreign = json.loads(r.stdout)["items"][0]["id"]
        self.reply_file.write_text(json.dumps({
            "topic": "Retry hook", "summary": "Finished the retry hook.",
            "updates": [
                {"op": "done", "id": finished, "note": "tests green in step 5"},
                {"op": "edit", "id": renamed, "title": "Document the retry hook in docs/claude-hooks.md"},
                {"op": "drop", "id": later},                          # no evidence → ignored
                {"op": "done", "id": foreign, "note": "not offered"},  # another repo → never offered
                {"op": "done", "id": "zzzzzzzz", "note": "made up"},
            ],
            "items": [{"kind": "learning", "title": "Bash 3.2 lacks mapfile", "body": "Seen on macOS."}],
        }))
        r = self.run_reflector("run", "--transcript", str(self.transcript), "--session", "s7",
                               "--cwd", str(self.cwd), "--trigger", "precompact")
        self.assertEqual(r.returncode, 0, r.stderr)
        prompt = self.prompt_seen.read_text()
        self.assertIn(f"(#{finished}; 0d)", prompt, "the prompt offers ids to reconcile")
        self.assertNotIn(foreign, prompt)
        rows = {x["id"]: x for x in json.loads(self.reflections("list", "--json", "--status", "all"))}
        self.assertEqual(rows[finished]["status"], "done")
        self.assertIn("[reflector precompact] tests green in step 5", rows[finished]["notes"])
        self.assertEqual(rows[renamed]["title"], "Document the retry hook in docs/claude-hooks.md")
        self.assertEqual(rows[later]["status"], "open", "a status change without evidence is ignored")
        r = subprocess.run([str(REFLECTIONS), "list", "--json"], cwd=other_cwd, env=self.env,
                           capture_output=True, text=True)
        self.assertEqual(json.loads(r.stdout)[0]["status"], "open")
        run = json.loads(self.log.read_text().splitlines()[-1])
        self.assertEqual((run["updates"], run["updates_skipped"]), (2, 0))

    def test_stage_tiers_pick_models_and_the_summary_is_rewritten_in_place(self):
        args = ["run", "--transcript", str(self.transcript), "--session", "s8", "--cwd", str(self.cwd),
                "--trigger", "stage"]
        r = self.run_reflector(*args, "--tier", "haiku", "--stage-pct", "20")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("passed 20% of the model's window", self.prompt_seen.read_text())
        notes = json.loads(self.reflections("list", "--json", "--status", "note", "--kind", "handoff"))
        self.assertEqual(len(notes), 1)
        self.grow_transcript("phase two")
        self.reply_file.write_text(json.dumps({**REPLY, "summary": "Retry hook built and documented."}))
        self.prompt_seen.unlink()
        r = self.run_reflector(*args, "--tier", "sonnet", "--stage-pct", "40")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("SUMMARY OF THIS SESSION SO FAR", self.prompt_seen.read_text())
        self.assertIn("Built the retry hook.", self.prompt_seen.read_text())
        notes = json.loads(self.reflections("list", "--json", "--status", "note", "--kind", "handoff"))
        self.assertEqual(len(notes), 1, "one summary per session, edited at each checkpoint")
        self.assertTrue(notes[0]["body"].startswith("Retry hook built and documented."))
        self.assertEqual(self.models_seen.read_text().split(),
                         ["haiku", "sonnet"])
        runs = [json.loads(x) for x in self.log.read_text().splitlines()]
        self.assertEqual([(x["tier"], x.get("stage_pct")) for x in runs], [("haiku", 20), ("sonnet", 40)])

    def test_print_mode_sessions_are_skipped(self):
        with open(self.transcript, "w") as f:
            f.write(json.dumps(user("automation " + "y" * 9000, entrypoint="sdk-cli")) + "\n")
            f.write(json.dumps(request()) + "\n")
        self.run_reflector("run", "--transcript", str(self.transcript), "--session", "s4",
                           "--cwd", str(self.cwd), "--trigger", "sessionend")
        self.assertEqual(json.loads(self.log.read_text().splitlines()[-1])["skipped"], "non-interactive (-p) session")


if __name__ == "__main__":
    unittest.main(verbosity=2)
