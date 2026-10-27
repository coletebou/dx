#!/usr/bin/env python3
"""dotsync-commit-message against stub providers: a local HTTP server standing in for the
Anthropic and Bedrock APIs, and a shell command. Repositories, HOME and state are temporary;
nothing leaves the machine.

    python3 scripts/tests/dotsync-commit-message.test.py
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
HELPER = SCRIPTS / "dotsync-commit-message"
RUNTIME = SCRIPTS / "lib" / "dotsync-runtime.sh"
BASH = shutil.which("bash") or "/bin/bash"
GIT = shutil.which("git")
# Credential-shaped fixtures are assembled at run time, so no key-shaped literal sits in the
# repository for a secret scan to stop.
KEY = "fixture-api-key-" + "0123456789abcdef"
FAKE_AWS_KEY = "AKIA" + "ABCDEFGHIJKLMNOP"
FAKE_GITLAB = "glxyz" + "-0123456789"
FAKE_ANTHROPIC = "sk-" + "ant-api03-AbCdEf0123456789xyzXYZ"
FAKE_GITHUB = "gh" + "p_0123456789abcdefghijABCDEFGHIJ"
FAKE_JWT = ".".join(("eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "dozjgNryP4J3jVmNHl0w5N"))

_loader = importlib.machinery.SourceFileLoader("commit_message", str(HELPER))
_spec = importlib.util.spec_from_loader("commit_message", _loader)
cm = importlib.util.module_from_spec(_spec)
_loader.exec_module(cm)

_runtime_spec = importlib.util.spec_from_file_location("runtime_fixture", Path(__file__).with_name("dotsync-runtime.test.py"))
fixture = importlib.util.module_from_spec(_runtime_spec)
_runtime_spec.loader.exec_module(fixture)


def reply(subject, details=(), stop="end_turn"):
    text = json.dumps({"subject": subject, "details": list(details)})
    return 200, {"stop_reason": stop, "content": [{"type": "text", "text": text}]}


class StubAPI:
    """Records each request and answers from a queue, then with a default."""

    def __init__(self):
        self.requests, self.replies, self.during = [], [], None
        self.default = reply("describe the fixture change")
        stub = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
                stub.requests.append({"path": self.path, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": body})
                if stub.during:
                    stub.during()
                status, payload = stub.replies.pop(0) if stub.replies else stub.default
                if status == "hang":
                    time.sleep(payload)
                    status, payload = stub.default
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d/v1/messages" % self.server.server_address[1]

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def user_text(self, index=-1):
        return self.requests[index]["body"]["messages"][0]["content"]


@unittest.skipUnless(GIT, "git is required")
class CommitMessageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="commit-message-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.state = self.root / "state"
        self.home.mkdir()
        self.state.mkdir()
        self.stub = StubAPI()
        self.addCleanup(self.stub.close)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "DOTSYNC_", "AWS_", "ANTHROPIC_"))
                    and k not in {"DF_MACHINE", "DF_IDENTITY", "BASH_ENV", "ENV", "XDG_RUNTIME_DIR", "XDG_STATE_HOME"}}
        self.env.update(HOME=str(self.home), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                        DOTSYNC_COMMIT_MESSAGE_PROVIDER="anthropic", ANTHROPIC_API_KEY=KEY,
                        DOTSYNC_COMMIT_MESSAGE_ENDPOINT=self.stub.url, DOTSYNC_STATE_DIR=str(self.state))
        self.origin = self.root / "origin.git"
        self.repo = self.root / "repo"
        self.git("init", "-q", "--bare", "-b", "master", str(self.origin), cwd=self.root)
        self.git("init", "-q", "-b", "master", str(self.repo), cwd=self.root)
        self.write("README.md", "fixture\n")
        self.commit("feat: start the fixture")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "-u", "origin", "master")

    def git(self, *args, cwd=None, check=True):
        result = subprocess.run([GIT, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", *args],
                                cwd=cwd or self.repo, env=self.env, capture_output=True, text=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message, path=None, text=None):
        if path:
            self.write(path, text if text is not None else message + "\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def helper(self, *args, env=None):
        return subprocess.run([sys.executable, str(HELPER), *args], cwd=self.repo, env=env or self.env,
                              capture_output=True, text=True, timeout=60)

    def bash(self, code, env=None):
        return subprocess.run([BASH, "--noprofile", "--norc", "-c", 'set -euo pipefail\nsource "$1"\n' + code, "x", str(RUNTIME)],
                              cwd=self.repo, env=env or self.env, capture_output=True, text=True, timeout=60)

    def message(self, rev="HEAD"):
        return self.git("log", "-1", "--format=%B", rev)

    # ── providers ──
    def test_off_by_default(self):
        self.write("scripts/tool", "change\n")
        self.git("add", "-A")
        env = dict(self.env)
        del env["DOTSYNC_COMMIT_MESSAGE_PROVIDER"]
        for extra in ({}, {"DOTSYNC_COMMIT_MESSAGE_PROVIDER": "off"}):
            with self.subTest(extra=extra):
                result = self.helper("describe", "--host", "box-a", "--staged", env=dict(env, **extra))
                self.assertEqual((result.returncode, result.stdout), (3, ""))
        self.assertEqual(self.stub.requests, [])

    def test_anthropic_describes_redacted_input_with_the_key_only_in_a_header(self):
        self.write("scripts/tool", "#!/bin/sh\nfor i in 1 2 3; do run && break; done\nkey=" + FAKE_AWS_KEY + "\n")
        self.write("logs/events.jsonl", '{"text": "first entry"}\n{"text": "second entry"}\n')
        self.write("identities/example/vault/secrets.env", "API=supersecretvalue\n")
        self.write("notes.txt", "the key is " + KEY + "\n")
        self.git("add", "-A")
        self.stub.replies.append(reply("Chore(sync): box-a: Add the retry loop to the tool.",
                                       ["- append 2 log entries", "", "append 2 log entries"]))
        result = self.helper("describe", "--host", "box-a", "--staged")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "chore(sync): box-a: add the retry loop to the tool\n\n- append 2 log entries\n")
        request = self.stub.requests[0]
        self.assertEqual(request["headers"].get("x-api-key"), KEY)
        self.assertEqual(request["headers"].get("anthropic-version"), "2026-10-21")
        body = request["body"]
        self.assertEqual(body["model"], "claude-haiku-5-5")
        self.assertEqual(body["thinking"], {"type": "disabled"})
        self.assertEqual(body["output_config"]["format"]["type"], "json_schema")
        self.assertNotIn("temperature", body)
        sent = json.dumps(body)
        self.assertIn("scripts/tool", sent)
        self.assertIn("identities/example/vault/secrets.env  (content withheld)", self.stub.user_text())
        self.assertIn("first entry", sent)
        for secret in ("supersecretvalue", FAKE_AWS_KEY, KEY):
            self.assertNotIn(secret, sent)
        log = (self.state / "commit-message.log").read_text()
        self.assertIn("describe ok", log)
        self.assertNotIn(KEY, log)

    def test_bedrock_uses_its_invoke_shape_and_bearer_key(self):
        self.write("scripts/tool", "change\n")
        self.git("add", "-A")
        env = dict(self.env, DOTSYNC_COMMIT_MESSAGE_PROVIDER="bedrock", AWS_BEARER_TOKEN_BEDROCK=KEY)
        del env["ANTHROPIC_API_KEY"]
        result = self.helper("describe", "--host", "box-a", "--staged", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        request = self.stub.requests[0]
        self.assertEqual(request["headers"].get("authorization"), "Bearer " + KEY)
        self.assertEqual(request["body"]["anthropic_version"], "bedrock-2023-05-31")
        self.assertNotIn("model", request["body"])
        del env["DOTSYNC_COMMIT_MESSAGE_ENDPOINT"]
        saved = dict(os.environ)
        try:
            os.environ.clear()
            os.environ.update(env, DOTSYNC_COMMIT_MESSAGE_REGION="eu-west-1")
            url, _, headers = cm.http_request("bedrock", "summary", KEY)
        finally:
            os.environ.clear()
            os.environ.update(saved)
        self.assertEqual(url, "https://bedrock-runtime.eu-west-1.amazonaws.com/model/us.anthropic.claude-haiku-5-5/invoke")

    def test_a_command_provider_reads_the_prompt_on_stdin(self):
        self.write("scripts/tool", "change " + FAKE_AWS_KEY + "\n")
        self.git("add", "-A")
        seen, answer = self.root / "prompt", self.root / "answer"
        for output, expected in (
                ('{"subject": "add the tool", "details": ["tidy the docs"]}', "chore(sync): box-a: add the tool\n\n- tidy the docs\n"),
                ("Add the retry tool\n- second detail\nnot a detail", "chore(sync): box-a: add the retry tool\n\n- second detail\n")):
            with self.subTest(output=output):
                answer.write_text(output + "\n")
                env = dict(self.env, DOTSYNC_COMMIT_MESSAGE_CMD="cat > %s; cat %s" % (seen, answer))
                del env["DOTSYNC_COMMIT_MESSAGE_PROVIDER"]
                result = self.helper("describe", "--host", "box-a", "--staged", env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
                prompt = seen.read_text()
                self.assertIn("You write commit messages", prompt)
                self.assertIn("scripts/tool", prompt)
                self.assertNotIn(FAKE_AWS_KEY, prompt)
        for command, code in (("exit 4", 3), ("sleep 30", 3), ("echo '[1, 2]'", 3)):
            with self.subTest(command=command):
                env = dict(self.env, DOTSYNC_COMMIT_MESSAGE_PROVIDER="command", DOTSYNC_COMMIT_MESSAGE_CMD=command)
                (self.state / "commit-message.unavailable").unlink(missing_ok=True)
                result = self.helper("describe", "--host", "box-a", "--staged", "--timeout", "2", env=env)
                self.assertEqual((result.returncode, result.stdout), (code, ""))
        self.assertEqual(self.stub.requests, [])

    def test_the_credential_comes_from_the_environment_or_one_line_of_the_env_file(self):
        self.write("scripts/tool", "change\n")
        self.git("add", "-A")
        env = dict(self.env)
        del env["ANTHROPIC_API_KEY"]
        self.assertEqual(self.helper("describe", "--host", "h", "--staged", env=env).returncode, 3)
        self.assertEqual(self.stub.requests, [])
        env_file = self.home / "commit-message.env"
        env_file.write_text('export OTHER_SECRET="not-this-one-0123456789"\nANTHROPIC_API_KEY="from-file-0123456789abc"\n')
        result = self.helper("describe", "--host", "h", "--staged", env=dict(env, DOTSYNC_COMMIT_MESSAGE_ENV_FILE=str(env_file)))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.stub.requests[-1]["headers"].get("x-api-key"), "from-file-0123456789abc")
        self.assertNotIn("not-this-one", json.dumps(self.stub.requests[-1]))

    def test_unusable_and_malformed_replies_print_nothing_and_exit_3(self):
        self.write("scripts/tool", "change\n")
        self.git("add", "-A")
        cases = [reply("record a refused change", stop="refusal"), reply("cut off", stop="max_tokens"),
                 (200, {"stop_reason": "end_turn", "content": [{"type": "text", "text": "not json"}]}),
                 reply("  "), (400, {"message": "bad request"}), (200, [1, 2]),
                 (200, {"stop_reason": "end_turn", "content": "text"}),
                 (200, {"stop_reason": "end_turn", "content": [{"type": "text", "text": "[1, 2]"}]})]
        for case in cases:
            with self.subTest(case=case):
                self.stub.replies.append(case)
                result = self.helper("describe", "--host", "box-a", "--staged")
                self.assertEqual((result.returncode, result.stdout), (3, ""), result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse((self.state / "commit-message.unavailable").exists())

    def test_a_transient_failure_pauses_calls_until_a_success(self):
        self.write("scripts/tool", "change\n")
        self.git("add", "-A")
        self.stub.replies.append((503, {"message": "busy"}))
        self.assertEqual(self.helper("describe", "--host", "h", "--staged").returncode, 3)
        self.assertTrue((self.state / "commit-message.unavailable").exists())
        before = len(self.stub.requests)
        self.assertEqual(self.helper("describe", "--host", "h", "--staged").returncode, 3)
        self.assertEqual(len(self.stub.requests), before, "a paused provider is not called")
        (self.state / "commit-message.unavailable").unlink()
        self.assertEqual(self.helper("describe", "--host", "h", "--staged").returncode, 0)

    def test_describe_commit_uses_the_host_named_in_its_subject(self):
        commit = self.commit("chore(sync): other-box update scripts", "scripts/tool", "x\n")
        result = self.helper("describe", "--host", "box-a", "--commit", commit)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("chore(sync): other-box: describe the fixture change"))

    def test_the_runtime_wrapper_prefers_a_description_and_falls_back_cleanly(self):
        self.write("scripts/tool", "change\n")
        self.git("add", "-A")
        code = "dotsync_describe_staged box-a || dotsync_commit_message box-a"
        env = dict(self.env, DOTSYNC_COMMIT_MESSAGE_HELPER=str(HELPER))
        self.assertEqual(self.bash(code, env).stdout, "chore(sync): box-a: describe the fixture change\n")
        self.stub.replies.append((400, {"message": "bad"}))
        self.assertEqual(self.bash(code, env).stdout, "chore(sync): box-a update scripts\n")
        missing = dict(env, DOTSYNC_COMMIT_MESSAGE_HELPER=str(self.root / "missing"))
        self.assertEqual(self.bash(code, missing).stdout, "chore(sync): box-a update scripts\n")
        self.stub.replies.append(("hang", 5))
        started = time.monotonic()
        slow = self.bash(code, dict(env, DOTSYNC_COMMIT_MESSAGE_TIMEOUT="1"))
        self.assertEqual(slow.stdout, "chore(sync): box-a update scripts\n", slow.stderr)
        self.assertLess(time.monotonic() - started, 10)

    # ── a command provider that outlives its welcome ──
    def slow_provider(self):
        """A provider that starts a TERM-ignoring child (an agent, say) and waits on it."""
        pidfile = self.root / "provider-child.pid"
        script = self.root / "provider.sh"
        script.write_text("#!/bin/sh\ncat >/dev/null\n( trap '' TERM; exec sleep 120 ) &\necho $! > %s\nwait\n" % pidfile)
        script.chmod(0o755)
        env = dict(self.env, DOTSYNC_COMMIT_MESSAGE_PROVIDER="command", DOTSYNC_COMMIT_MESSAGE_CMD=str(script))
        return pidfile, env

    def child_pid(self, pidfile, seconds=60):
        deadline = time.monotonic() + seconds
        while not (pidfile.exists() and pidfile.read_text().strip()) and time.monotonic() < deadline:
            time.sleep(0.1)
        pid = int(pidfile.read_text())
        self.addCleanup(lambda: subprocess.run(["kill", "-9", str(pid)], capture_output=True))
        return pid

    def gone_within(self, pid, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
            if state == "" or state.startswith("Z"):
                return True
            time.sleep(0.2)
        return False

    def test_a_provider_that_times_out_is_stopped_with_everything_it_started(self):
        self.write("scripts/tool", "change\n")
        self.git("add", "-A")
        pidfile, env = self.slow_provider()
        result = self.helper("describe", "--host", "box-a", "--staged", "--timeout", "3", env=env)
        self.assertEqual((result.returncode, result.stdout), (3, ""))
        self.assertTrue(self.gone_within(self.child_pid(pidfile)), "the provider's child outlived the timeout")
        self.assertIn("command timed out", (self.state / "commit-message.log").read_text())

    def test_a_cancelled_helper_stops_its_provider(self):
        self.write("scripts/tool", "change\n")
        self.git("add", "-A")
        pidfile, env = self.slow_provider()
        helper = subprocess.Popen([sys.executable, str(HELPER), "describe", "--host", "box-a", "--staged", "--timeout", "100"],
                                  cwd=self.repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        pid = self.child_pid(pidfile)
        helper.terminate()  # what dotsync's own timeout sends
        out, _ = helper.communicate(timeout=30)
        self.assertNotEqual(helper.returncode, 0)
        self.assertEqual(out, b"")
        self.assertTrue(self.gone_within(pid), "the provider's child outlived the cancelled helper")

    # ── composing and redaction ──
    def test_generic_subjects_and_hosts(self):
        self.assertTrue(cm.is_generic("chore(sync): box-a update base, scripts"))
        self.assertFalse(cm.is_generic("chore(sync): box-a update base", "a hand-written explanation"))
        self.assertEqual(cm.subject_host("chore(sync): Box-A update base"), "box-a")
        for subject in ("chore(sync): box-a: update the zsh aliases", "fix(dotsync): retry the push", "sync: 2026-10-16 04:34"):
            self.assertFalse(cm.is_generic(subject), subject)
        for text in ("update usage log", "box-a update base", "skills update the usage log"):
            self.assertFalse(cm.is_generic(cm.compose("box-a", text, []).splitlines()[0]))

    def test_subjects_are_cleaned_and_bounded(self):
        message = cm.compose("box-a", "docs(memory): Record " + "very " * 40 + "long notes.",
                             ["* " + "x" * 300, "second", "third detail", "fourth detail", "fifth detail"])
        subject, _, body = message.partition("\n\n")
        self.assertTrue(subject.startswith("chore(sync): box-a: record very"))
        self.assertLessEqual(len(subject), cm.MAX_SUBJECT)
        self.assertEqual(len(body.strip().splitlines()), cm.MAX_DETAILS)
        with self.assertRaises(cm.ModelError):
            cm.compose("h", "ok.", [])

    def test_redaction_masks_credentials_and_keeps_hashes_and_paths(self):
        samples = {"aws " + FAKE_AWS_KEY: FAKE_AWS_KEY, "anthropic " + FAKE_ANTHROPIC: "api03-AbCdEf",
                   "token " + FAKE_GITHUB: "0123456789abcdef",
                   "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----": "AAAA",
                   'export GITLAB_TOKEN="' + FAKE_GITLAB + '"': FAKE_GITLAB, "jwt " + FAKE_JWT: "dozjgNryP4J3",
                   "blob QmFzZTY0RW5jb2RlZFNlY3JldFZhbHVlMTIzNDU2Nzg5MEFCQ0RFRg==": "QmFzZTY0",
                   'PASSWORD="correct horse battery staple"': "horse", '"api_key": "a quoted value"': "quoted"}
        for text, secret in samples.items():
            with self.subTest(text=text):
                self.assertNotIn(secret, cm.redact(text))
        kept = "sha 0123456789abcdef0123456789abcdef01234567 at identities/example/claude/settings.json"
        self.assertEqual(cm.redact(kept), kept)
        for path in (".env", "config/.env.local", "id_ed25519", "home/.netrc", "keys/server.pem", "app/api-token.txt"):
            self.assertEqual(cm.file_kind(path), "opaque", path)

    def test_a_renamed_secret_file_stays_withheld(self):
        secret = "postgres" + "://app:" + "hunter2-correct-horse" + "@db/app"
        lines = ["SETTING_%d=value-%d" % (i, i) for i in range(12)]
        self.commit("feat: add local settings", ".env.local", "\n".join(lines + ["DATABASE_URL=" + secret]) + "\n")
        (self.repo / "config").mkdir()
        self.git("mv", ".env.local", "config/app.conf")
        self.write("config/app.conf", "\n".join(lines) + "\n")
        self.git("add", "-A")
        self.assertEqual(self.helper("describe", "--host", "h", "--staged").returncode, 0)
        self.assertIn("(content withheld)", self.stub.user_text())
        self.assertNotIn("hunter2", json.dumps(self.stub.requests[-1]["body"]))

    # ── reword ──
    def test_reword_describes_only_unpublished_generic_commits_of_this_host(self):
        published = self.git("rev-parse", "origin/master")
        human = self.commit("fix: keep a hand-written change", "scripts/a", "a\n")
        generic = self.commit("chore(sync): box-a update scripts", "scripts/b", "b\n")
        other = self.commit("chore(sync): other-box update docs", "docs/c", "c\n")
        trees = {sha: self.git("log", "-1", "--format=%T %an %ad %cn %cd", "--date=raw", sha) for sha in (human, generic, other)}
        self.stub.replies.append(reply("add the b script"))
        result = self.helper("reword", "--host", "box-a")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("described 1 unpublished commit", result.stdout)
        after = self.git("rev-list", "--reverse", "origin/master..HEAD").splitlines()
        self.assertEqual(after[0], human, "commits below the first described one keep their SHA")
        self.assertEqual(self.message(after[1]), "chore(sync): box-a: add the b script")
        self.assertEqual(self.message(after[2]), "chore(sync): other-box update docs")
        for old, new in zip((human, generic, other), after):
            self.assertEqual(self.git("log", "-1", "--format=%T %an %ad %cn %cd", "--date=raw", new), trees[old])
        self.assertEqual(self.git("rev-parse", "origin/master"), published)
        self.assertEqual(len(self.stub.requests), 1)

    def test_reword_leaves_published_detached_merged_and_moved_ranges_alone(self):
        self.commit("chore(sync): box-a update a", "a", "a\n")
        self.git("push", "-q")
        self.assertEqual(self.helper("reword", "--host", "box-a").returncode, 0)
        self.assertEqual(self.stub.requests, [], "published commits are never rewritten")
        tip = self.commit("chore(sync): box-a update b", "b", "b\n")
        self.git("checkout", "-q", "--detach")
        self.assertEqual(self.helper("reword", "--host", "box-a").returncode, 0)
        self.git("checkout", "-q", "master")
        self.assertEqual(self.git("rev-parse", "HEAD"), tip)
        self.git("commit", "-q", "--allow-empty", "-m", "feat: concurrent work")
        concurrent = self.git("rev-parse", "HEAD")
        self.git("reset", "-q", "--soft", "HEAD~1")
        self.stub.during = lambda: self.git("update-ref", "refs/heads/master", concurrent)
        self.assertEqual(self.helper("reword", "--host", "box-a").returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD"), concurrent)
        self.assertIn("moved while describing", (self.state / "commit-message.log").read_text())


class DotsyncRunTest(fixture.RuntimeTest):
    """The real dotsync, offline, with a command provider."""

    def test_a_full_run_ships_a_described_commit(self):
        origin, env, log = self.full_fixture()
        shutil.copyfile(HELPER, self.repo / "scripts" / HELPER.name)
        (self.repo / "scripts" / HELPER.name).chmod(0o755)
        self.git("add", "scripts")
        self.git("commit", "-qm", "add the helper")
        self.git("push", "-q", "origin", "master")
        env = dict(env, DOTSYNC_COMMIT_MESSAGE_CMD="cat >/dev/null; echo 'change the fixture payload'")
        (self.repo / "payload").write_text("work that dotsync commits\n")
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual(result.returncode, 0, diagnostic)
        self.assertEqual(self.git("log", "-1", "--format=%s", "master", repo=origin),
                         "chore(sync): fixture-cli: change the fixture payload")


if __name__ == "__main__":
    suite = unittest.TestSuite()
    suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(CommitMessageTest))
    suite.addTests(DotsyncRunTest(name) for name in DotsyncRunTest.__dict__ if name.startswith("test_"))
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
