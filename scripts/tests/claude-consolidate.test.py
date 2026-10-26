#!/usr/bin/env python3
"""Hermetic tests for scripts/claude-consolidate.

A fake `claude` first on PATH records its argv, the environment it got and the
composed prompt, then prints a canned reply (or fails), so no model is called.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/claude-consolidate"

FAKE_CLAUDE = r"""#!/usr/bin/env python3
import json, os, sys
out = os.environ["FAKE_DIR"]
args = sys.argv[1:]
open(os.path.join(out, "argv.json"), "w").write(json.dumps(args))
keys = ("CLAUDE_CODE_USE_MANTLE", "CLAUDE_CODE_USE_BEDROCK", "ANTHROPIC_BASE_URL", "AWS_BEARER_TOKEN_BEDROCK",
        "ANTHROPIC_API_KEY", "UNRELATED_SECRET", "IS_SANDBOX")
open(os.path.join(out, "env.json"), "w").write(json.dumps({k: os.environ.get(k) for k in keys}))
if "--settings" in args:
    settings = open(args[args.index("--settings") + 1]).read()
    open(os.path.join(out, "settings.json"), "w").write(settings)
open(os.path.join(out, "prompt.txt"), "w").write(sys.stdin.read())
if os.environ.get("FAKE_EXIT"):
    print("provider said no", file=sys.stderr)
    sys.exit(int(os.environ["FAKE_EXIT"]))
sys.stdout.write(os.environ.get("FAKE_REPLY", "the reply\n"))
"""


class ConsolidateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="consolidate-test-")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.bin = root / "bin"
        self.bin.mkdir()
        (self.bin / "claude").write_text(FAKE_CLAUDE)
        (self.bin / "claude").chmod(0o755)
        self.fake = root / "fake"
        self.fake.mkdir()
        self.prompt = root / "prompt.md"
        self.prompt.write_text("Summarize the inputs.\n")
        self.out = root / "out/reply.md"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("CLAUDE", "ANTHROPIC", "AWS_", "MEMORY_BOUNDARY"))}
        self.env.update(PATH=f"{self.bin}:{os.environ['PATH']}", FAKE_DIR=str(self.fake))
        self.root = root

    def run_it(self, *extra, **env):
        return subprocess.run([str(SCRIPT), "--prompt", str(self.prompt), "--output", str(self.out), *extra],
                              env={**self.env, **env}, capture_output=True, text=True, timeout=60)

    def argv(self):
        return json.loads((self.fake / "argv.json").read_text())

    def seen_env(self):
        return json.loads((self.fake / "env.json").read_text())

    def test_composes_inputs_and_writes_the_reply(self):
        notes = self.root / "notes.md"
        notes.write_text("a note\n")
        tree = self.root / "tree"
        (tree / "sub").mkdir(parents=True)
        (tree / "b.txt").write_text("bee\n")
        (tree / "sub/a.txt").write_text("ay\n")
        r = self.run_it("--input", str(notes), "--input", str(tree))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.out.read_text(), "the reply\n")
        prompt = (self.fake / "prompt.txt").read_text()
        self.assertTrue(prompt.startswith("Summarize the inputs.\n"))
        self.assertIn("--- INPUT: notes.md ---\n```\na note\n", prompt)
        self.assertLess(prompt.index("--- INPUT: b.txt"), prompt.index("--- INPUT: sub/a.txt"), "dir inputs sort")
        argv = self.argv()
        self.assertEqual(argv[:1], ["--print"])
        self.assertIn("bypassPermissions", argv)
        self.assertEqual(argv[argv.index("--model") + 1], "haiku", "the default model is the haiku alias")
        self.assertNotIn("--settings", argv, "an alias takes the machine's normal route")

    def test_model_flag_and_env_default(self):
        self.run_it(CLAUDE_CONSOLIDATE_MODEL="sonnet")
        self.assertEqual(self.argv()[self.argv().index("--model") + 1], "sonnet")
        self.run_it("--model", "opus", CLAUDE_CONSOLIDATE_MODEL="sonnet")
        self.assertEqual(self.argv()[self.argv().index("--model") + 1], "opus")

    def test_failures_leave_no_output(self):
        r = self.run_it(FAKE_EXIT="1")
        self.assertEqual(r.returncode, 3)
        self.assertIn("provider said no", r.stderr)
        self.assertEqual(self.run_it(FAKE_REPLY="").returncode, 4, "an empty reply fails")
        r = self.run_it("--format", "json", FAKE_REPLY="not json")
        self.assertEqual(r.returncode, 5)
        self.assertFalse(self.out.exists())
        self.assertEqual(self.run_it("--format", "json", FAKE_REPLY='{"ok": 1}').returncode, 0)
        self.assertEqual(json.loads(self.out.read_text()), {"ok": 1})

    def test_mantle_id_gets_a_per_call_mantle_route(self):
        r = self.run_it("--model", "anthropic.claude-opus-5-5", CLAUDE_CODE_USE_BEDROCK="1",
                        ANTHROPIC_BASE_URL="http://example.invalid")
        self.assertEqual(r.returncode, 0, r.stderr)
        settings = json.loads((self.fake / "settings.json").read_text())["env"]
        self.assertEqual((settings["CLAUDE_CODE_USE_MANTLE"], settings["ANTHROPIC_MODEL"]),
                         ("1", "anthropic.claude-opus-5-5"))
        env = self.seen_env()
        self.assertEqual((env["CLAUDE_CODE_USE_MANTLE"], env["CLAUDE_CODE_USE_BEDROCK"], env["ANTHROPIC_BASE_URL"]),
                         ("1", None, None), "Mantle is the only provider this call can reach")

    def test_runtime_id_gets_bedrock_runtime_in_the_callers_region(self):
        r = self.run_it("--model", "global.anthropic.claude-sonnet-5-5", AWS_REGION="eu-west-1",
                        CLAUDE_CODE_USE_MANTLE="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        settings = json.loads((self.fake / "settings.json").read_text())["env"]
        self.assertEqual((settings["CLAUDE_CODE_USE_BEDROCK"], settings["AWS_REGION"]), ("1", "eu-west-1"))
        self.assertEqual((self.seen_env()["CLAUDE_CODE_USE_BEDROCK"], self.seen_env()["CLAUDE_CODE_USE_MANTLE"]),
                         ("1", None))

    def test_isolated_mode_strips_tools_and_unwraps_the_json_result(self):
        wrapped = json.dumps({"is_error": False, "result": "```json\n{\"a\": 1}\n```", "total_cost_usd": 0.01,
                              "duration_ms": 5, "num_turns": 1, "usage": {}, "modelUsage": {}})
        r = self.run_it("--isolated", "--format", "json", FAKE_REPLY=wrapped)
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = self.argv()
        for flag in ("--setting-sources", "--tools", "--strict-mcp-config", "--no-session-persistence"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--tools") + 1], "")
        self.assertEqual(json.loads(self.out.read_text()), {"a": 1}, "the fence the model added is dropped")
        meta = json.loads(Path(str(self.out) + ".meta.json").read_text())
        self.assertEqual((meta["model"], meta["total_cost_usd"]), ("haiku", 0.01))
        r = self.run_it("--isolated", FAKE_REPLY=json.dumps({"is_error": True, "result": "refused"}))
        self.assertEqual(r.returncode, 3)

    def test_the_data_boundary_refuses_before_any_model_call(self):
        r = self.run_it(MEMORY_BOUNDARY_CMD='[ "$MEMORY_BOUNDARY_TOOL" = consolidate ] && [ "$CLIENT_MODE" = 1 ]',
                        CLIENT_MODE="1")
        self.assertEqual(r.returncode, 3, "an environment rule refuses the whole call")
        self.assertIn("restricts prompt.md", r.stderr)
        secret = self.root / "client.md"
        secret.write_text("acme-confidential numbers\n")
        plain = self.root / "plain.md"
        plain.write_text("fine\n")
        rule = 'grep -q acme-confidential "$MEMORY_BOUNDARY_PATH"'
        r = self.run_it("--input", str(plain), "--input", str(secret), MEMORY_BOUNDARY_CMD=rule)
        self.assertEqual(r.returncode, 3)
        self.assertIn("restricts client.md", r.stderr)
        tree = self.root / "tree"
        (tree / "deep").mkdir(parents=True)
        (tree / "deep/client.md").write_text("acme-confidential too\n")
        r = self.run_it("--input", str(tree), MEMORY_BOUNDARY_CMD=rule)
        self.assertEqual(r.returncode, 3, "each file of a directory input is asked about")
        self.prompt.write_text("Summarize. acme-confidential context pasted in.\n")
        r = self.run_it("--input", str(plain), MEMORY_BOUNDARY_CMD=rule)
        self.assertEqual(r.returncode, 3, "the prompt itself is asked about")
        self.prompt.write_text("Summarize the inputs.\n")
        self.assertFalse((self.fake / "argv.json").exists(), "nothing reached the model")
        r = self.run_it("--input", str(plain), MEMORY_BOUNDARY_CMD=rule)
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_it(MEMORY_BOUNDARY_CMD="/nonexistent/boundary-check")
        self.assertEqual(r.returncode, 3, "a broken boundary check fails closed")

    def test_env_file_supplies_only_the_auth_keys_and_only_when_absent(self):
        env_file = self.root / "secrets.env"
        env_file.write_text("export AWS_BEARER_TOKEN_BEDROCK=from-file\nUNRELATED_SECRET=nope\n")
        self.run_it(CLAUDE_CONSOLIDATE_ENV_FILE=str(env_file))
        env = self.seen_env()
        self.assertEqual((env["AWS_BEARER_TOKEN_BEDROCK"], env["UNRELATED_SECRET"]), ("from-file", None))
        self.run_it(CLAUDE_CONSOLIDATE_ENV_FILE=str(env_file), ANTHROPIC_API_KEY="already-set")
        self.assertIsNone(self.seen_env()["AWS_BEARER_TOKEN_BEDROCK"], "an existing credential wins")
        self.run_it()
        self.assertIsNone(self.seen_env()["AWS_BEARER_TOKEN_BEDROCK"], "no file is read unless named")


if __name__ == "__main__":
    unittest.main(verbosity=2)
