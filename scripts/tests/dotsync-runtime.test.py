#!/usr/bin/env python3
"""dotsync's runtime pieces, one at a time: names and profiles, the peer scripts, timeouts,
staging and the secret gate, the lock, the end of a run, the read-only CLI, and full local runs
against a bare origin. Every repository, HOME, lock and state directory is a temporary one.

    python3 scripts/tests/dotsync-runtime.test.py
"""

import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
MAIN = SCRIPTS / "dotsync"
RUNTIME = SCRIPTS / "lib" / "dotsync-runtime.sh"
PEERS = SCRIPTS / "lib" / "dotsync-peers.sh"
LOCK = SCRIPTS / "lib" / "dotsync-lock.py"
BASH = shutil.which("bash") or "/bin/bash"
GIT = shutil.which("git")


def actual_function(name, text=None):
    """A function's definition from dotsync, failing loudly when its boundary moves."""
    text = text if text is not None else MAIN.read_text()
    start = re.search(r"(?m)^" + re.escape(name) + r"\(\) \{\n", text)
    if not start:
        raise AssertionError("cannot find %s in %s" % (name, MAIN))
    end = re.search(r"(?m)^}\n", text[start.end():])
    if not end:
        raise AssertionError("cannot find the end of %s" % name)
    return text[start.start():start.end() + end.end()]


def snapshot(root):
    result = {}
    for path in sorted(root.rglob("*")):
        info = path.lstat()
        value = ("link", os.readlink(path)) if path.is_symlink() else (
            ("file", path.read_bytes()) if path.is_file() else ("dir",))
        result[str(path.relative_to(root))] = (info.st_mode, info.st_mtime_ns, value)
    return result


@unittest.skipUnless(GIT, "git is required")
class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dotsync-runtime-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / "home"
        self.repo = self.root / "repo"
        self.state = self.root / "state"
        self.lock = self.root / "lockdir" / "lock"
        self.profile = self.root / "profile"
        for path in (self.home, self.repo, self.state):
            path.mkdir()
        self.profile.write_text("export DF_MACHINE=fixture-profile\n")
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "DOTSYNC_", "XDG_"))
                    and k not in {"DF_MACHINE", "DF_IDENTITY", "DF_ROLE", "BASH_ENV", "ENV"}}
        self.env.update(HOME=str(self.home), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_ALLOW_PROTOCOL="file", GIT_AUTHOR_NAME="Fixture",
                        GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_NAME="Fixture",
                        GIT_COMMITTER_EMAIL="fixture@example.invalid", DOTSYNC_NOTIFY="0")
        self.git("init", "-q", "-b", "master")
        (self.repo / "payload").write_text("base\n")
        self.git("add", "payload")
        self.git("commit", "-qm", "fixture")
        self.head = self.git("rev-parse", "HEAD")

    def git(self, *args, repo=None, check=True):
        result = subprocess.run([GIT, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
                                 "-C", str(repo or self.repo), *args],
                                env=self.env, capture_output=True, text=True, timeout=30)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def bash(self, code, *args, env=None, timeout=30, cwd=None):
        return subprocess.run(
            [BASH, "--noprofile", "--norc", "-c",
             'set -euo pipefail\nsource "$1"\nsource "$2"\nshift 2\n' + code,
             "dotsync-runtime-fixture", str(RUNTIME), str(PEERS), *map(str, args)],
            env=env or self.env, cwd=cwd or self.root, capture_output=True, text=True, timeout=timeout)

    def assert_bash_output(self, code, expected, *args, env=None):
        result = self.bash(code, *args, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), expected)

    # ── names and profiles ──
    def test_host_validation_and_case_comparison(self):
        for host in ("box-a", "Box-B", "a1.b2.c3", "host_name", "a.example"):
            with self.subTest(valid=host):
                self.assertEqual(self.bash('dotsync_valid_host "$1"', host).returncode, 0)
        for host in ("", "-option", "user@host", "a:b", "a b", "a\nb", "$(touch x)", "x;true", "*", "a/b", "a..b"):
            with self.subTest(invalid=host):
                self.assertNotEqual(self.bash('dotsync_valid_host "$1"', host).returncode, 0)
        self.assertEqual(self.bash('dotsync_same_host "$1" "$2"', "BOX-A", "box-a").returncode, 0)
        self.assertNotEqual(self.bash('dotsync_same_host "$1" "$2"', "box", "box-a").returncode, 0)

    def test_machine_name_order_env_then_profile_then_hostname(self):
        self.assert_bash_output('dotsync_machine "$1"', "fixture-profile", self.profile)
        self.assert_bash_output('dotsync_machine "$1"', "box-a", self.profile, env=dict(self.env, DF_MACHINE="Box-A"))
        self.assert_bash_output('dotsync_machine "$1"', "unknown-local", self.profile,
                                env=dict(self.env, DF_MACHINE="bad name"))
        hostname = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip().lower()
        if re.fullmatch(r"[a-z0-9][a-z0-9._-]*", hostname or ""):
            self.assert_bash_output('dotsync_machine "$1"', hostname.split(".")[0], self.root / "absent")

    def test_identity_comes_from_env_or_profile_and_fails_closed(self):
        self.profile.write_text("export DF_IDENTITY=example\n")
        self.assert_bash_output('dotsync_identity "$1"', "example", self.profile)
        self.assert_bash_output('dotsync_identity "$1"', "other", self.profile, env=dict(self.env, DF_IDENTITY="other"))
        self.assertNotEqual(self.bash('dotsync_identity "$1"', self.root / "absent").returncode, 0)
        self.assertNotEqual(self.bash('dotsync_identity "$1"', self.profile,
                                      env=dict(self.env, DF_IDENTITY="../x")).returncode, 0)

    def test_profile_is_read_as_literal_data_and_never_executed(self):
        sentinel = self.root / "must-not-exist"
        for prefix in ("", "export "):
            for value in ("example", "'example'", '"example"'):
                self.profile.write_text("touch %s\n%sDF_IDENTITY=%s\nDF_ROLE=server\n" % (sentinel, prefix, value))
                self.assert_bash_output('dotsync_identity "$1"', "example", self.profile)
                self.assert_bash_output('dotsync_profile_value "$1" DF_ROLE', "server", self.profile)
        self.profile.write_text("DF_IDENTITY=$(touch %s)\nDF_MACHINE=x; touch %s\n" % (sentinel, sentinel))
        self.assertNotEqual(self.bash('dotsync_identity "$1"', self.profile).returncode, 0)
        self.assert_bash_output('dotsync_profile_value "$1" DF_MACHINE', "", self.profile)
        self.assertEqual(self.bash('dotsync_profile_value "$1" PATH', self.profile).returncode, 2)
        self.assertFalse(sentinel.exists())

    # ── the peer side ──
    def peer_home(self, profile):
        home = self.root / "peer"
        (home / ".local" / "bin").mkdir(parents=True, exist_ok=True)
        ran = home / "dotsync-ran"
        stub = home / ".local" / "bin" / "dotsync"
        stub.write_text('#!/bin/sh\nprintf "%%s|%%s|%%s\\n" "$*" "$DOTSYNC_EXPECTED_HEAD" "$DOTSYNC_TRIGGERED_BY" > %s\n'
                        % shlex.quote(str(ran)))
        stub.chmod(0o755)
        if profile is None:
            (home / ".df-profile").unlink(missing_ok=True)
        else:
            (home / ".df-profile").write_text(profile)
        return home, ran

    def run_on_peer(self, home, script):
        return subprocess.run(["/bin/sh", "-s"], input=script, env={"HOME": str(home), "PATH": os.environ["PATH"]},
                              capture_output=True, text=True, timeout=10)

    def test_the_peer_script_refuses_another_or_no_identity_before_anything_runs(self):
        result = self.bash('dotsync_peer_script "$1" example box-a "\\$HOME/.local/bin/dotsync"', self.head)
        self.assertEqual(result.returncode, 0, result.stderr)
        script = result.stdout
        for profile, expected in (("export DF_IDENTITY=other\n", 4), ("export DF_IDENTITY=$(id)\n", 5),
                                  ("", 5), (None, 5), ("export DF_IDENTITY='example'\n", 0)):
            with self.subTest(profile=profile):
                home, ran = self.peer_home(profile)
                ran.unlink(missing_ok=True)
                outcome = self.run_on_peer(home, script)
                self.assertEqual(outcome.returncode, expected, outcome.stderr)
                self.assertEqual(ran.exists(), expected == 0)
        self.assertEqual(ran.read_text().strip(), "--local --one-line --peer|%s|box-a" % self.head)

    def test_the_peer_script_takes_only_safe_arguments(self):
        good = [self.head, "example", "box-a", "$HOME/.local/bin/dotsync"]
        for index, bad in ((0, "f" * 39), (0, "HEAD"), (1, "a b"), (1, "$(id)"), (2, "-x"), (3, "dotsync"),
                           (3, "$HOME/bin/dotsync; id"), (3, "~/x")):
            args = list(good)
            args[index] = bad
            with self.subTest(arg=index, value=bad):
                self.assertEqual(self.bash('dotsync_peer_script "$@"', *args).returncode, 2)

    def test_the_probe_reads_identity_and_machine_as_data(self):
        script = self.bash("dotsync_peer_probe_script").stdout
        home, _ = self.peer_home('export DF_IDENTITY=example\nexport DF_MACHINE="box-b"\nDF_ROLE=$(touch x)\n')
        result = self.run_on_peer(home, script)
        self.assertEqual(result.stdout.split(), ["DF_IDENTITY=example", "DF_MACHINE=box-b"])
        home, _ = self.peer_home(None)
        self.assertEqual(self.run_on_peer(home, script).stdout, "")

    def test_peer_timeout_defaults_to_180s_manual_and_600s_scheduled(self):
        text = MAIN.read_text()
        start = text.index('if [[ "$scheduled" -eq 1 ]]; then\n  DOTSYNC_SSH_TIMEOUT=')
        block = text[start:text.index("\nfi\n", start) + 4]
        for scheduled, override, expected in (("0", None, "5 180"), ("1", None, "15 600"), ("0", "45", "5 45")):
            with self.subTest(scheduled=scheduled, override=override):
                env = dict(self.env) if override is None else dict(self.env, DOTSYNC_PEER_TIMEOUT=override)
                self.assert_bash_output("scheduled=%s\n" % scheduled + block +
                                        'printf "%s %s" "$DOTSYNC_SSH_TIMEOUT" "$DOTSYNC_PEER_TIMEOUT"', expected, env=env)

    def test_failure_helper_keeps_the_first_failed_phase(self):
        self.assert_bash_output('EXIT_CODE=0; DOTSYNC_FAILED_PHASE=""; dotsync_fail git-fetch; dotsync_fail git-push; '
                                'printf "%s %s" "$EXIT_CODE" "$DOTSYNC_FAILED_PHASE"', "1 git-fetch")

    def test_mktemp_follows_tmpdir(self):
        scratch = self.root / "scratch"
        scratch.mkdir()
        for tmpdir in (str(scratch), str(scratch) + "/"):
            made = Path(self.bash("dotsync_mktemp", env=dict(self.env, TMPDIR=tmpdir)).stdout.strip())
            self.assertEqual(made.parent, scratch)

    # ── bounded commands ──
    def fallback_env(self, python=True):
        directory = self.root / ("python-only-bin" if python else "empty-bin")
        directory.mkdir(exist_ok=True)
        if python and not (directory / "python3").exists():
            (directory / "python3").symlink_to(sys.executable)
        return dict(self.env, PATH=str(directory))

    def test_python_timeout_preserves_exit_and_signal_statuses(self):
        env = self.fallback_env()
        for code, expected in (("raise SystemExit(0)", 0), ("raise SystemExit(19)", 19),
                               ("import os,signal; os.kill(os.getpid(),signal.SIGTERM)", 143)):
            with self.subTest(expected=expected):
                result = subprocess.run([BASH, "--noprofile", "--norc", "-c", 'source "$1"; dotsync_timeout 5 "$2" -c "$3"',
                                         "x", str(RUNTIME), sys.executable, code], env=env, capture_output=True, timeout=20)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_timeout_rejects_invalid_budgets_and_never_runs_unbounded(self):
        sentinel = self.root / "ran"
        body = "from pathlib import Path; Path(%r).touch()" % str(sentinel)
        for budget in ("0", "00.00", "-1", ".1", "nan", "1;true", "1s"):
            with self.subTest(budget=budget):
                result = self.bash('dotsync_timeout "$1" "$2" -c "$3"', budget, sys.executable, body, env=self.fallback_env())
                self.assertEqual(result.returncode, 2)
                self.assertFalse(sentinel.exists())
        result = subprocess.run([BASH, "--noprofile", "--norc", "-c", 'source "$1"; dotsync_timeout 1 "$2" -c "$3"',
                                 "x", str(RUNTIME), sys.executable, body], env=self.fallback_env(python=False),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 127)
        self.assertIn("cannot enforce timeout", result.stderr)
        self.assertFalse(sentinel.exists())

    def test_timeout_kills_a_term_resistant_process_tree(self):
        pids = self.root / "pids"
        pids.mkdir()
        worker = self.root / "tree.py"
        worker.write_text(
            "import os, signal, subprocess, sys, time\nfrom pathlib import Path\n"
            "role, d = sys.argv[1], Path(sys.argv[2])\n"
            "if role == 'grandchild': signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "(d / (role + '.pid')).write_text(str(os.getpid()))\n"
            "if role != 'grandchild':\n"
            "    subprocess.Popen([sys.executable, __file__, 'child' if role == 'parent' else 'grandchild', str(d)])\n"
            "time.sleep(120)\n")
        # The budget leaves a loaded machine time to start all three; the TERM-resistant grandchild
        # holds the pipes, so if it survived the timeout the harness would wait out its sleep.
        budget = 8
        for env in (self.env, self.fallback_env()):
            with self.subTest(fallback=env is not self.env):
                for path in pids.glob("*.pid"):
                    path.unlink()
                self.addCleanup(self.kill_recorded, pids)
                started = time.monotonic()
                try:
                    result = subprocess.run([BASH, "--noprofile", "--norc", "-c", 'source "$1"; dotsync_timeout "$5" "$2" "$3" parent "$4"',
                                             "x", str(RUNTIME), sys.executable, str(worker), str(pids), str(budget)],
                                            env=env, capture_output=True, timeout=budget + 40)
                except subprocess.TimeoutExpired:
                    self.fail("dotsync_timeout returned, but a descendant it should have killed kept running")
                self.assertEqual(result.returncode, 124, result.stderr)
                self.assertLess(time.monotonic() - started, budget + 15)
                self.assertEqual(sorted(p.stem for p in pids.glob("*.pid")), ["child", "grandchild", "parent"],
                                 "the whole tree must have started for this check to mean anything")
                for path in pids.glob("*.pid"):
                    pid = int(path.read_text())
                    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
                    self.assertTrue(state == "" or state.startswith("Z"), "%s survived the timeout" % path.stem)

    def test_an_interrupted_run_stops_the_command_it_was_waiting_on(self):
        pids = self.root / "pids"
        pids.mkdir()
        self.addCleanup(self.kill_recorded, pids)
        worker = self.root / "tree.py"
        worker.write_text(
            "import os, signal, subprocess, sys, time\nfrom pathlib import Path\n"
            "role, d = sys.argv[1], Path(sys.argv[2])\n"
            "if role == 'grandchild': signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "(d / (role + '.pid')).write_text(str(os.getpid()))\n"
            "if role != 'grandchild':\n"
            "    subprocess.Popen([sys.executable, __file__, 'child' if role == 'parent' else 'grandchild', str(d)])\n"
            "time.sleep(120)\n")
        shell = subprocess.Popen([BASH, "--noprofile", "--norc", "-c",
                                  'source "$1"; trap "dotsync_timeout_cleanup; exit 143" TERM; dotsync_timeout 100 "$2" "$3" parent "$4"',
                                  "x", str(RUNTIME), sys.executable, str(worker), str(pids)], env=self.env,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 60
        while len(list(pids.glob("*.pid"))) < 3 and time.monotonic() < deadline:
            time.sleep(0.2)
        self.assertEqual(len(list(pids.glob("*.pid"))), 3, "the tree never started")
        shell.terminate()
        self.assertEqual(shell.wait(timeout=30), 143)
        deadline = time.monotonic() + 20
        alive = None
        while time.monotonic() < deadline:
            alive = [p.stem for p in pids.glob("*.pid") if self.running(int(p.read_text()))]
            if not alive:
                break
            time.sleep(0.5)
        self.assertEqual(alive, [], "the interrupted run left its command running")

    @staticmethod
    def running(pid):
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return state != "" and not state.startswith("Z")

    def kill_recorded(self, pids):
        for path in pids.glob("*.pid"):
            try:
                os.kill(int(path.read_text()), 9)
            except (OSError, ValueError):
                pass

    # ── staging and the secret gate ──
    def staging(self, command, env=None):
        return self.bash('cd "$1"; shift; ' + command, self.repo, env=env)

    def scanner_env(self, exit_code=0):
        directory = self.root / "scan-bin"
        directory.mkdir(exist_ok=True)
        scanner = directory / "gitleaks"
        scanner.write_text('#!/bin/sh\nprintf "DO_NOT_EMIT_SCANNER_PAYLOAD\\n"; printf "DO_NOT_EMIT\\n" >&2\nexit %d\n' % exit_code)
        scanner.chmod(0o755)
        return dict(self.env, PATH=str(directory) + os.pathsep + self.env["PATH"])

    def test_staging_skips_ignored_content_and_the_check_refuses_it(self):
        (self.repo / ".gitignore").write_text("runtime/\n*.tmp\n")
        (self.repo / "runtime").mkdir()
        ignored = self.repo / "runtime" / "note"
        ignored.write_text("private\n")
        self.git("add", "-f", "runtime/note", ".gitignore")
        self.git("commit", "-qm", "old tracked fixture")
        ignored.write_text("changed private\n")
        (self.repo / "new.tmp").write_text("temp\n")
        (self.repo / "new file").write_text("source\n")
        (self.repo / "payload").unlink()
        self.assertEqual(self.staging("dotsync_stage_changes").returncode, 0)
        self.assertEqual(set(self.git("diff", "--cached", "--name-only").splitlines()), {"payload", "new file"})
        self.git("add", "-f", "runtime/note")
        result = self.staging("dotsync_check_staged", self.scanner_env())
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ignored staged content", result.stderr)
        self.git("rm", "--cached", "-q", "-f", "runtime/note")
        self.assertEqual(self.staging("dotsync_check_staged", self.scanner_env()).returncode, 0)

    def test_deleting_a_tracked_ignored_file_is_staged(self):
        (self.repo / ".gitignore").write_text("runtime/\n")
        (self.repo / "runtime").mkdir()
        (self.repo / "runtime" / "old note").write_text("x\n")
        self.git("add", "-f", "runtime/old note", ".gitignore")
        self.git("commit", "-qm", "tracked ignored fixture")
        (self.repo / "runtime" / "old note").unlink()
        self.assertEqual(self.staging("dotsync_stage_changes").returncode, 0)
        self.assertEqual(self.git("diff", "--cached", "--name-status"), "D\truntime/old note")
        self.assertEqual(self.staging("dotsync_check_staged", self.scanner_env()).returncode, 0)

    def test_batched_ignore_status_matches_the_per_path_check(self):
        (self.repo / ".gitignore").write_text("*.log\n!keep.log\nruntime/\n[ab]*.tmp\n")
        (self.repo / "runtime").mkdir()
        (self.repo / "dir").mkdir()
        names = ["keep.log", "drop.log", "dir/keep.log", "dir/x.log", "runtime/inner", "a1.tmp", "c1.tmp",
                 "with space", "üñí", "-dash", "[glob]*", "line\nbreak", "payload"]
        for name in names:
            (self.repo / name).write_text("x\n")
        result = subprocess.run(
            [BASH, "--noprofile", "--norc", "-c", 'set -euo pipefail; source "$1"; cd "$2"; d="$(dotsync_scratch_dir)";'
             ' printf "%s\\0" "${@:3}" | dotsync_ignore_status "$d"; rm -rf "$d"', "x", str(RUNTIME), str(self.repo), *names],
            env=self.env, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        fields = result.stdout.split(b"\0")[:-1]
        batched = {fields[i + 1].decode(): int(fields[i]) for i in range(0, len(fields), 2)}
        for name in names:
            single = subprocess.run([GIT, "-C", str(self.repo), "check-ignore", "--no-index", "-q", "--", name],
                                    env=self.env, capture_output=True, timeout=30).returncode
            with self.subTest(path=name):
                self.assertEqual(batched[name], single)

    def test_staging_many_paths_uses_a_constant_number_of_git_processes(self):
        counter = self.root / "git-calls"
        directory = self.root / "count-bin"
        directory.mkdir()
        (directory / "git").write_text('#!/bin/sh\nprintf "%%s\\n" "$1" >> %s\nexec %s "$@"\n' % (counter, GIT))
        (directory / "git").chmod(0o755)
        for i in range(300):
            (self.repo / ("file-%03d" % i)).write_text("%d\n" % i)
        env = self.scanner_env()
        env["PATH"] = str(directory) + os.pathsep + env["PATH"]
        result = self.bash('cd "$1"; dotsync_stage_changes && dotsync_check_staged', self.repo, env=env, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.git("diff", "--cached", "--name-only").splitlines()), 300)
        calls = counter.read_text().split()
        self.assertLessEqual(len(calls), 12, calls)
        self.assertEqual(calls.count("add"), 1)

    def test_a_failing_ignore_check_refuses_to_stage_or_commit(self):
        directory = self.root / "broken-bin"
        directory.mkdir()
        (directory / "git").write_text('#!/bin/sh\n[ "$1" = check-ignore ] && exit 128\nexec %s "$@"\n' % GIT)
        (directory / "git").chmod(0o755)
        (self.repo / "new").write_text("x\n")
        env = dict(self.env, PATH=str(directory) + os.pathsep + self.env["PATH"])
        result = self.staging("dotsync_stage_changes", env)
        self.assertIn("ignore check failed", result.stderr)
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
        self.git("add", "new")
        self.assertIn("refusing to commit", self.staging("dotsync_check_staged", env).stderr)
        self.assertFalse(any((self.repo / ".git" / "dotsync-scratch").glob("run.*")), "scratch left behind")

    def test_the_scanner_fails_closed_and_never_prints_its_output(self):
        (self.repo / "source").write_text("fixture\n")
        self.git("add", "source")
        for code, expected in ((0, 0), (1, 1), (2, 1)):
            with self.subTest(scanner_exit=code):
                result = self.staging("dotsync_check_staged", self.scanner_env(code))
                self.assertEqual(result.returncode, expected)
                self.assertNotIn("DO_NOT_EMIT", result.stdout + result.stderr)
        no_scanner = self.root / "no-gitleaks"
        no_scanner.mkdir()
        for tool in ("git", "sh", "cat", "grep", "mkdir", "mktemp", "rm", "dirname", "ls", "sed"):
            found = shutil.which(tool)
            if found:
                (no_scanner / tool).symlink_to(found)
        result = self.staging("dotsync_check_staged", dict(self.env, PATH=str(no_scanner)))
        self.assertEqual(result.returncode, 1)
        self.assertIn("gitleaks is required", result.stderr)
        result = self.bash('cd "$1"; dotsync_scan_outgoing HEAD~1..HEAD', self.repo, env=dict(self.env, PATH=str(no_scanner)))
        self.assertIn("refusing to push", result.stderr)

    def test_unmerged_paths_and_conflict_markers_are_never_committed(self):
        (self.repo / "notes").write_text("<<<<<<< Updated upstream\nmine\n=======\ntheirs\n>>>>>>> Stashed changes\n")
        self.git("add", "notes")
        result = self.staging("dotsync_check_staged", self.scanner_env())
        self.assertEqual(result.returncode, 1)
        self.assertIn("conflict markers", result.stderr)
        self.git("reset", "-q")
        (self.repo / "notes").write_text("Title\n=======\n\ntext\n")
        self.git("add", "notes")
        self.assertEqual(self.staging("dotsync_check_staged", self.scanner_env()).returncode, 0, "a setext heading is fine")
        self.git("commit", "-qm", "notes")
        self.git("switch", "-qc", "side")
        (self.repo / "notes").write_text("side\n")
        self.git("commit", "-qam", "side")
        self.git("switch", "-q", "master")
        (self.repo / "notes").write_text("master\n")
        self.git("commit", "-qam", "master")
        self.git("merge", "-q", "side", check=False)
        result = self.staging("dotsync_check_staged", self.scanner_env())
        self.assertEqual(result.returncode, 1)
        self.assertIn("unmerged paths", result.stderr)

    @unittest.skipUnless(shutil.which("gitleaks"), "gitleaks is not installed")
    def test_real_gitleaks_blocks_a_synthetic_key_without_printing_it(self):
        import secrets
        synthetic = secrets.token_hex(32)
        (self.repo / "source").write_text('api_key="' + synthetic + '"\n')
        self.git("add", "source")
        result = self.staging("dotsync_check_staged")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn(synthetic, result.stdout + result.stderr)

    def test_generic_subject_names_the_host_and_sorted_areas(self):
        for path in ("scripts/a", "base/b", "scripts/c", "README.md"):
            (self.repo / path).parent.mkdir(exist_ok=True)
            (self.repo / path).write_text("x\n")
            self.git("add", "--", path)
        self.assert_bash_output('cd "$1"; dotsync_commit_message box-a', "chore(sync): box-a update README.md, base, scripts", self.repo)

    def test_described_messages_are_off_unless_a_provider_or_command_is_set(self):
        helper = self.root / "helper"
        helper.write_text("#!/bin/sh\necho 'chore(sync): box-a: describe it'\n")
        helper.chmod(0o755)
        code = 'dotsync_describe_staged box-a || echo generic'
        base = dict(self.env, DOTSYNC_COMMIT_MESSAGE_HELPER=str(helper))
        self.assert_bash_output(code, "generic", env=base)
        self.assert_bash_output(code, "generic", env=dict(base, DOTSYNC_COMMIT_MESSAGE_PROVIDER="off"))
        self.assert_bash_output(code, "chore(sync): box-a: describe it", env=dict(base, DOTSYNC_COMMIT_MESSAGE_CMD="cat"))
        self.assert_bash_output(code, "chore(sync): box-a: describe it", env=dict(base, DOTSYNC_COMMIT_MESSAGE_PROVIDER="anthropic"))
        self.assert_bash_output(code, "generic", env=dict(base, DOTSYNC_COMMIT_MESSAGE_PROVIDER="off", DOTSYNC_COMMIT_MESSAGE_CMD="cat"))

    def test_git_ssh_is_shared_per_run_only_in_the_plain_setup(self):
        home = Path(tempfile.mkdtemp(prefix="dsh", dir="/tmp"))
        self.addCleanup(shutil.rmtree, home, True)
        (home / ".ssh").mkdir(mode=0o700)

        def share(config=(), **extra):
            for key, value in config:
                self.git("config", key, value)
            env = dict(self.env, HOME=str(home), **extra)
            result = self.bash('cd "$1"; dotsync_share_ssh; printf "%s|%s" "$$" "$dotsync_ssh_command"', self.repo, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.split("|", 1)
        pid, command = share()
        self.assertEqual(command, "ssh -o ControlMaster=auto -o ControlPath=%s/.ssh/ds%s-%%C -o ControlPersist=10" % (home, pid))
        self.assertEqual(share(GIT_SSH_COMMAND="ssh -i chosen")[1], "")
        self.assertEqual(share(DOTSYNC_SSH_MUX="0")[1], "")
        (home / ".ssh").chmod(0o770)
        self.assertEqual(share()[1], "", "a socket directory others can write")
        (home / ".ssh").chmod(0o700)
        for key, value in (("remote.origin.pushurl", "git@example.com:o/r.git"), ("core.sshCommand", "ssh -i k"),
                           ("fetch.all", "true")):
            with self.subTest(route=key):
                self.assertEqual(share([(key, value)])[1], "")
                self.git("config", "--unset", key)
        self.assertNotEqual(share()[1], "")

    # ── the lock ──
    def test_the_lock_waits_then_releases_without_removing_the_file(self):
        holder = subprocess.Popen([sys.executable, str(LOCK), "--acquire", str(self.lock), "1", sys.executable,
                                   "-c", 'import time; print("held", flush=True); time.sleep(4)'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: holder.poll() is None and holder.kill())
        self.assertEqual(holder.stdout.readline().strip(), "held")
        busy = subprocess.run([sys.executable, str(LOCK), "--acquire", str(self.lock), ".1", "true"], capture_output=True, text=True)
        self.assertEqual(busy.returncode, 75, busy.stderr)
        waited = subprocess.run([sys.executable, str(LOCK), "--acquire", str(self.lock), "60", "true"], capture_output=True, text=True)
        self.assertEqual(waited.returncode, 0, waited.stderr)
        holder.communicate(timeout=5)
        self.assertEqual(self.lock.stat().st_mode & 0o777, 0o600)
        with self.lock.open("r") as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for wait in ("601", "inf", "-1"):
            self.assertEqual(subprocess.run([sys.executable, str(LOCK), "--acquire", str(self.lock), wait, "true"],
                                            capture_output=True).returncode, 75)

    def test_the_lock_refuses_a_symlink_and_an_open_directory(self):
        parent = self.root / "unsafe"
        parent.mkdir(mode=0o700)
        target = self.root / "target"
        target.write_text("preserve")
        (parent / "lock").symlink_to(target)
        self.assertEqual(subprocess.run([sys.executable, str(LOCK), "--acquire", str(parent / "lock"), "0", "true"],
                                        capture_output=True).returncode, 75)
        self.assertEqual(target.read_text(), "preserve")
        (parent / "lock").unlink()
        parent.chmod(0o755)
        self.assertEqual(subprocess.run([sys.executable, str(LOCK), "--acquire", str(parent / "lock"), "0", "true"],
                                        capture_output=True).returncode, 75)

    # ── the end of a run ──
    def finish(self, body="exit 0", extra=None):
        functions = "\n".join(actual_function(name) for name in ("write_heartbeat", "dotsync_result", "dotsync_finish"))
        setup = r'''
HEARTBEAT_FILE="$TEST_STATE/heartbeat.json"; TIMING_LOG_DIR="$TEST_STATE"
_DOTSYNC_HOST=fixture; EXIT_CODE=0; DOTSYNC_PHASE=initialization; DOTSYNC_FAILED_PHASE=""
one_line=1; scheduled=0; peer_run=0; pull_only=0; branch=master; fanout_background=0
defer_reason="${TEST_DEFER:-}"; peers_failed_count="${TEST_PEERS_FAILED:-0}"
finalize_timing() { :; }
publish_heartbeat() { printf 'published\n' >> "$TEST_STATE/published"; }
exec 3>&1
exec > "$TEST_STATE/details.log" 2>&1
trap 'dotsync_finish "$?"' EXIT
echo "ordinary detail"
'''
        env = dict(self.env, DOTFILES_DIR=str(self.repo), TEST_STATE=str(self.state), **(extra or {}))
        result = self.bash(functions + "\n" + setup + "\n" + body, env=env)
        return result, json.loads((self.state / "heartbeat.json").read_text())

    def test_finish_keeps_the_original_failure_and_prints_one_result_line(self):
        result, heartbeat = self.finish("exit 27")
        self.assertEqual(result.returncode, 27)
        self.assertEqual((heartbeat["exit"], heartbeat["result"]), (27, "failed"))
        self.assertEqual(result.stdout.splitlines(), ["result=failed exit=27 phase=initialization branch=master head=%s" % self.head[:12]])
        self.assertIn("ordinary detail", (self.state / "details.log").read_text())
        self.assertEqual((self.state / "published").read_text(), "published\n")

    def test_finish_keeps_the_first_failed_phase_and_the_original_status(self):
        result, heartbeat = self.finish("dotsync_fail git-fetch\nDOTSYNC_PHASE=peer-sync\ndotsync_fail git-push\nexit 0")
        self.assertEqual((result.returncode, heartbeat["phase"]), (1, "git-fetch"))
        result, heartbeat = self.finish("dotsync_fail git-push\nexit 23")
        self.assertEqual((result.returncode, heartbeat["exit"], heartbeat["phase"]), (23, 23, "git-push"))

    def test_finish_reports_a_missing_expected_commit_as_stale_config(self):
        result, heartbeat = self.finish(extra={"DOTSYNC_EXPECTED_HEAD": "f" * 40})
        self.assertEqual((result.returncode, heartbeat["result"]), (3, "stale-config"))
        result, heartbeat = self.finish(extra={"DOTSYNC_EXPECTED_HEAD": self.head})
        self.assertEqual((result.returncode, heartbeat["result"], heartbeat["head"]), (0, "ok", self.head))
        result, heartbeat = self.finish(extra={"DOTSYNC_EXPECTED_HEAD": "f" * 40, "TEST_DEFER": "paused"})
        self.assertEqual((result.returncode, heartbeat["result"]), (0, "deferred"), "a deferred peer is not stale")

    def test_finish_reports_partial_and_deferred(self):
        for extra, expected in (({"TEST_PEERS_FAILED": "2"}, "partial"), ({"TEST_DEFER": "paused"}, "deferred")):
            with self.subTest(expected=expected):
                result, heartbeat = self.finish(extra=extra)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(heartbeat["result"], expected)
                self.assertIn("result=%s exit=0" % expected, result.stdout)

    # ── the read-only CLI ──
    def guard_env(self, **extra):
        guard = self.root / "guard-bin"
        guard.mkdir(exist_ok=True)
        forbidden = guard / "forbidden"
        forbidden.write_text('#!/bin/sh\nprintf "%s\\n" "${0##*/}" >> "$DOTSYNC_TEST_FORBIDDEN"\nexit 99\n')
        forbidden.chmod(0o755)
        # status may ask systemctl or launchctl whether the timer is loaded; nothing else is allowed.
        for name in ("ssh", "rsync", "tailscale", "curl", "wget", "claude", "codex", "osascript", "notify-send"):
            if not (guard / name).exists():
                (guard / name).symlink_to(forbidden)
        return dict(self.env, DOTFILES_DIR=str(self.repo), DOTSYNC_STATE_DIR=str(self.state),
                    DOTSYNC_LOCK_FILE=str(self.lock), DOTSYNC_CONFIG_DIR=str(self.home / "config"),
                    DF_MACHINE="Fixture-CLI", DF_IDENTITY="example",
                    DOTSYNC_TEST_FORBIDDEN=str(self.root / "forbidden.log"),
                    PATH=str(guard) + os.pathsep + self.env["PATH"], **extra)

    def run_cli(self, *args, env=None):
        env = env or self.guard_env()
        before = snapshot(self.root)
        result = subprocess.run([BASH, "--noprofile", "--norc", str(MAIN), *args], env=env,
                                cwd=self.root, capture_output=True, text=True, timeout=30)
        self.assertEqual(before, snapshot(self.root), "a read-only command changed the fixture")
        self.assertFalse((self.root / "forbidden.log").exists())
        return result

    def test_the_json_plan_names_hosts_and_writes_nothing(self):
        result = self.run_cli("--dry-run", "--json", "--host", "box-b", "--host=box-c")
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(result.stdout)
        self.assertEqual((data["machine"], data["identity"], data["explicit_hosts"]), ("fixture-cli", "example", ["box-b", "box-c"]))
        self.assertTrue(data["read_only"])
        (self.home / "config").mkdir()
        (self.home / "config" / "peers").write_text("box-b example local\n# a comment\nbox-c\n")
        data = json.loads(self.run_cli("--dry-run", "--json").stdout)
        self.assertEqual([p["alias"] for p in data["peers"]], ["box-b", "box-c"])
        self.assertEqual(json.loads(self.run_cli("--dry-run", "--json", "--local").stdout)["peers"], [])

    def test_help_and_bad_arguments_change_nothing(self):
        self.assertIn("--host", self.run_cli("--help").stdout)
        for args in (("--unknown",), ("--json",), ("--host",), ("--host=",), ("--dry-run", "--host", "host;true"),
                     ("--dry-run", "--local", "--host", "box-b"), ("status", "--bogus"), ("peers", "x")):
            with self.subTest(args=args):
                self.assertEqual(self.run_cli(*args).returncode, 2)
        result = self.run_cli("--dry-run", "--host", "BOX-B", env=self.guard_env(DOTSYNC_EXCLUDE_HOSTS="box-b"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("conflicts", result.stderr)
        self.assertEqual(self.run_cli("--dry-run", env=self.guard_env(DOTSYNC_EXCLUDE_HOSTS="-unsafe")).returncode, 2)

    def test_status_and_peers_are_read_only(self):
        self.assertEqual(self.run_cli("status").returncode, 0)
        result = self.run_cli("peers")
        self.assertEqual(result.returncode, 0)
        self.assertIn("none listed", result.stdout)

    # ── full local runs ──
    def full_fixture(self):
        scripts = self.repo / "scripts"
        (scripts / "lib").mkdir(parents=True)
        for path in (MAIN, RUNTIME, PEERS, LOCK, SCRIPTS / "lib" / "dotsync-activity.py"):
            target = scripts / path.relative_to(SCRIPTS)
            shutil.copyfile(path, target)
            target.chmod(0o755)
        self.git("add", ".")
        self.git("commit", "-qm", "managed fixture")
        origin = self.root / "origin.git"
        self.git("clone", "--bare", "-q", str(self.repo), str(origin), repo=self.root)
        self.git("remote", "add", "origin", str(origin))
        self.git("fetch", "-q", "origin")
        self.git("branch", "-q", "--set-upstream-to", "origin/master")
        log = self.root / "git-calls"
        bin_dir = self.root / "log-bin"
        bin_dir.mkdir()
        (bin_dir / "git").write_text(
            '#!/bin/sh\ncmd="$1"; [ "$cmd" = -c ] && cmd="$3"; [ "$cmd" = -C ] && cmd="$3"\n'
            'printf "%%s\\n" "$cmd" >> %s\n'
            'if [ "${DOTSYNC_TEST_FETCH_FAIL:-0}" = 1 ] && [ "$cmd" = fetch ]; then exit 42; fi\n'
            'if [ "${DOTSYNC_TEST_FETCH_NOOP:-0}" = 1 ] && [ "$cmd" = fetch ]; then exit 0; fi\n'
            'if [ "${DOTSYNC_TEST_LSREMOTE_FAIL:-0}" = 1 ] && [ "$cmd" = ls-remote ]; then exit 128; fi\n'
            'exec %s "$@"\n' % (log, GIT))
        (bin_dir / "git").chmod(0o755)
        env = self.guard_env(DOTSYNC_NO_INSTALL="1")
        env["PATH"] = str(bin_dir) + os.pathsep + str(self.scanner_env()["PATH"])
        return origin, env, log

    def run_full(self, env, *args):
        result = subprocess.run([BASH, "--noprofile", "--norc", str(self.repo / "scripts" / "dotsync"),
                                 "--local", "--one-line", *args], env=env, cwd=self.root,
                                capture_output=True, text=True, timeout=60)
        self.assertFalse((self.root / "forbidden.log").exists())
        details = self.state / "last-run.log"
        diagnostic = result.stderr + (details.read_text() if details.exists() else "")
        self.assertEqual(len(result.stdout.splitlines()), 1, result.stdout + diagnostic)
        return result, json.loads((self.state / "heartbeat.json").read_text()), diagnostic

    def test_a_local_run_commits_pushes_and_publishes_a_heartbeat(self):
        origin, env, log = self.full_fixture()
        (self.repo / "payload").write_text("work dotsync commits\n")
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual(result.returncode, 0, diagnostic)
        self.assertEqual((heartbeat["result"], heartbeat["exit"], heartbeat["pushed"]), ("ok", 0, 1))
        self.assertEqual(self.git("rev-parse", "HEAD"), self.git("rev-parse", "master", repo=origin))
        self.assertEqual(self.git("log", "-1", "--format=%s", repo=origin), "chore(sync): fixture-cli update payload")
        published = self.git("cat-file", "-p", "refs/dotsync/heartbeats/fixture-cli:heartbeat.json", repo=origin)
        self.assertEqual(json.loads(published)["host"], "fixture-cli")
        self.assertIn("+refs/dotsync/heartbeats/*:refs/dotsync/heartbeats/*",
                      self.git("config", "--get-all", "remote.origin.fetch").splitlines())
        calls = log.read_text().split()
        self.assertEqual(calls.count("ls-remote"), 1, "only the push's race check; a dirty tree skips the fast path")
        self.assertLess(calls.index("commit"), calls.index("push"))

    def test_a_clean_level_run_takes_the_fast_path(self):
        origin, env, log = self.full_fixture()
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual(result.returncode, 0, diagnostic)
        self.assertIn("up to date", diagnostic)
        calls = log.read_text().split()
        self.assertEqual(calls.count("ls-remote"), 1)
        self.assertEqual(calls.count("fetch"), 0)
        self.assertEqual(calls.count("rebase"), 0)

    def test_a_fetch_failure_keeps_the_commit_and_reports_its_phase(self):
        origin, env, log = self.full_fixture()
        before = self.git("rev-parse", "master", repo=origin)
        (self.repo / "payload").write_text("local work awaiting publication\n")
        result, heartbeat, diagnostic = self.run_full(dict(env, DOTSYNC_TEST_FETCH_FAIL="1"))
        self.assertEqual(result.returncode, 1, diagnostic)
        self.assertEqual((heartbeat["exit"], heartbeat["phase"]), (1, "git-fetch"))
        self.assertIn("phase=git-fetch", result.stdout)
        self.assertEqual(self.git("show", "HEAD:payload"), "local work awaiting publication")
        self.assertEqual(self.git("rev-parse", "master", repo=origin), before)

    def test_a_push_routed_away_from_the_scanned_upstream_is_refused(self):
        # The scan covers what the upstream lacks; a push that goes somewhere else would publish
        # what is upstream already (old secrets included) without a scan.
        origin, env, log = self.full_fixture()
        public = self.root / "public.git"
        self.git("init", "-q", "--bare", str(public), repo=self.root)
        self.git("remote", "add", "public", str(public))
        routes = (("branch.master.pushRemote", "public", "branch.master.pushRemote"),
                  ("remote.pushDefault", "public", "remote.pushDefault"),
                  ("remote.origin.pushurl", str(public), "another URL"),
                  ("url.%s.pushInsteadOf" % public, str(origin), "another URL"))
        for number, (key, value, named) in enumerate(routes):
            with self.subTest(route=key):
                self.git("config", key, value)
                (self.repo / "payload").write_text("change %d\n" % number)
                before = self.git("rev-parse", "master", repo=origin)
                result, heartbeat, diagnostic = self.run_full(env)
                self.git("config", "--unset", key)
                self.assertEqual((result.returncode, heartbeat["phase"]), (1, "push-route"), diagnostic)
                self.assertIn(named, diagnostic)
                self.assertEqual(self.git("for-each-ref", "refs/heads", repo=public), "", "something was published")
                self.assertEqual(self.git("rev-parse", "master", repo=origin), before)
        self.git("config", "--add", "remote.origin.url", str(public))
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual((result.returncode, heartbeat["phase"]), (1, "push-route"), diagnostic)
        self.assertIn("several URLs", diagnostic)
        self.git("config", "--unset-all", "remote.origin.url")
        self.git("config", "remote.origin.url", str(origin))
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual(result.returncode, 0, diagnostic)
        self.assertEqual(self.git("rev-parse", "master", repo=origin), self.git("rev-parse", "HEAD"))
        self.assertEqual(self.git("for-each-ref", "refs/heads", repo=public), "")

    def test_the_scan_covers_what_the_destination_lacks_not_a_stale_tracking_ref(self):
        origin, env, log = self.full_fixture()
        writer = self.root / "writer"
        self.git("clone", "-q", str(origin), str(writer), repo=self.root)
        (writer / "incoming").write_text("published, then withdrawn\n")
        self.git("add", "incoming", repo=writer)
        self.git("commit", "-qm", "incoming", repo=writer)
        self.git("push", "-q", "origin", "master", repo=writer)
        self.git("pull", "-q", "--ff-only")
        withdrawn = self.git("rev-parse", "HEAD")
        # The remote drops that commit; this checkout's tracking ref still has it.
        self.git("push", "-q", "--force", "origin", "HEAD~1:master", repo=writer)
        destination = self.git("rev-parse", "master", repo=origin)
        scans = self.root / "scans"
        scanner_dir = self.root / "scan-log-bin"
        scanner_dir.mkdir()
        (scanner_dir / "gitleaks").write_text('#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexit 0\n' % scans)
        (scanner_dir / "gitleaks").chmod(0o755)
        (self.repo / "payload").write_text("local work\n")
        env = dict(env, DOTSYNC_TEST_FETCH_NOOP="1", PATH=str(scanner_dir) + os.pathsep + env["PATH"])
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual(result.returncode, 0, diagnostic)
        outgoing = [line for line in scans.read_text().splitlines() if "--log-opts" in line]
        self.assertEqual(len(outgoing), 1, outgoing)
        self.assertIn("--log-opts=--diff-merges=remerge %s..HEAD" % destination, outgoing[0], "the commit the remote lacks was not scanned")
        republished = subprocess.run([GIT, "-C", str(origin), "merge-base", "--is-ancestor", withdrawn, "master"], env=self.env)
        self.assertEqual(republished.returncode, 0, "the push sends the withdrawn commit, so the scan had to cover it")

    def test_a_push_whose_destination_cannot_be_read_is_refused(self):
        # The remote deleted the branch (dropping a commit); this clone's tracking ref still has
        # it, and ls-remote fails. A push would recreate the branch with that commit unscanned.
        origin, env, log = self.full_fixture()
        writer = self.root / "writer"
        self.git("clone", "-q", str(origin), str(writer), repo=self.root)
        (writer / "withdrawn").write_text("published, then withdrawn\n")
        self.git("add", "withdrawn", repo=writer)
        self.git("commit", "-qm", "withdrawn", repo=writer)
        self.git("push", "-q", "origin", "master", repo=writer)
        self.git("pull", "-q", "--ff-only")
        self.git("update-ref", "-d", "refs/heads/master", repo=origin)
        (self.repo / "payload").write_text("local work\n")
        env = dict(env, DOTSYNC_TEST_FETCH_NOOP="1", DOTSYNC_TEST_LSREMOTE_FAIL="1")
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual((result.returncode, heartbeat["phase"]), (1, "push-destination"), diagnostic)
        self.assertIn("could not read", diagnostic)
        self.assertEqual(self.git("for-each-ref", "refs/heads", repo=origin), "", "the branch was recreated unscanned")

    @unittest.skipUnless(shutil.which("gitleaks"), "gitleaks is not installed")
    def test_a_token_only_a_merge_resolution_adds_is_never_pushed(self):
        origin, env, log = self.full_fixture()
        env = dict(env, PATH=os.pathsep.join((str(self.root / "log-bin"), str(self.root / "guard-bin"), self.env["PATH"])))
        before = self.git("rev-parse", "master", repo=origin)
        # With rebase.rebaseMerges a merge survives dotsync's rebase (without it git flattens the
        # history), so the merge itself reaches the push.
        self.git("config", "rebase.rebaseMerges", "true")
        (self.repo / "notes").write_text("base\n")
        self.git("add", "notes")
        self.git("commit", "-qm", "notes")
        self.git("switch", "-qc", "side")
        (self.repo / "notes").write_text("side\n")
        self.git("commit", "-qam", "side")
        self.git("switch", "-q", "master")
        (self.repo / "notes").write_text("main\n")
        self.git("commit", "-qam", "main")
        self.git("merge", "-q", "side", check=False)
        import secrets
        import string
        token = "gh" + "p_" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36))
        (self.repo / "notes").write_text("export GITHUB_TOKEN=%s\n" % token)
        self.git("add", "notes")
        self.git("commit", "-q", "--no-edit")
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual((result.returncode, heartbeat["phase"]), (1, "secret-scan"), diagnostic)
        self.assertNotIn(token, result.stdout + diagnostic)
        self.assertEqual(self.git("rev-parse", "master", repo=origin), before, "the merge was published")

    @unittest.skipUnless(shutil.which("gitleaks"), "gitleaks is not installed")
    def test_a_token_only_an_octopus_merge_resolution_adds_is_never_pushed(self):
        # --diff-merges=remerge only diffs two-parent merges; a 3+-parent (octopus) merge needs
        # -m instead, or a token its resolution alone adds would reach the remote unscanned.
        origin, env, log = self.full_fixture()
        env = dict(env, PATH=os.pathsep.join((str(self.root / "log-bin"), str(self.root / "guard-bin"), self.env["PATH"])))
        before = self.git("rev-parse", "master", repo=origin)
        self.git("config", "rebase.rebaseMerges", "true")
        self.git("config", "log.diffMerges", "remerge")  # -m alone would follow this and skip the octopus
        (self.repo / "notes").write_text("base\n")
        self.git("add", "notes")
        self.git("commit", "-qm", "notes")
        self.git("switch", "-qc", "side1")
        (self.repo / "notes").write_text("side1\n")
        self.git("commit", "-qam", "side1")
        self.git("switch", "-q", "master")
        self.git("switch", "-qc", "side2")
        (self.repo / "other").write_text("side2\n")
        self.git("add", "other")
        self.git("commit", "-qm", "side2")
        self.git("switch", "-q", "master")
        (self.repo / "notes").write_text("main\n")
        self.git("commit", "-qam", "main")
        master_tip = self.git("rev-parse", "master")
        side1_tip = self.git("rev-parse", "side1")
        side2_tip = self.git("rev-parse", "side2")
        # git's octopus strategy refuses outright on any conflict (no partial state to resolve),
        # so a real conflicting 3-parent merge is built by hand: a plain two-way merge to resolve
        # the conflict, side2's tree added in, then commit-tree names all three parents.
        self.git("merge", "--no-commit", "side1", check=False)
        import secrets
        import string
        token = "gh" + "p_" + "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(36))
        (self.repo / "notes").write_text("export GITHUB_TOKEN=%s\n" % token)
        self.git("add", "notes")
        self.git("checkout", "side2", "--", "other")
        tree = self.git("write-tree")
        commit = self.git("commit-tree", tree, "-p", master_tip, "-p", side1_tip, "-p", side2_tip,
                           "-m", "octopus merge")
        self.git("update-ref", "HEAD", commit)
        self.assertEqual(len(self.git("log", "-1", "--format=%P").split()), 3,
                          "the merge did not keep three parents")
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual((result.returncode, heartbeat["phase"]), (1, "secret-scan"), diagnostic)
        self.assertNotIn(token, result.stdout + diagnostic)
        self.assertEqual(self.git("rev-parse", "master", repo=origin), before, "the merge was published")

    def test_pull_only_never_commits_or_pushes(self):
        origin, env, log = self.full_fixture()
        writer = self.root / "writer"
        self.git("clone", "-q", str(origin), str(writer), repo=self.root)
        (writer / "incoming").write_text("from elsewhere\n")
        self.git("add", "incoming", repo=writer)
        self.git("commit", "-qm", "incoming", repo=writer)
        self.git("push", "-q", "origin", "master", repo=writer)
        (self.repo / "payload").write_text("a local edit\n")
        result, heartbeat, diagnostic = self.run_full(env, "--pull-only")
        self.assertEqual(result.returncode, 0, diagnostic)
        self.assertEqual(heartbeat["result"], "pull-only")
        self.assertEqual((self.repo / "incoming").read_text(), "from elsewhere\n")
        self.assertEqual((self.repo / "payload").read_text(), "a local edit\n")
        self.assertEqual(self.git("rev-parse", "master", repo=origin), self.git("rev-parse", "HEAD"))
        self.assertNotIn("push", log.read_text().split())

    def test_a_pull_that_replaces_the_script_keeps_running_the_parsed_one(self):
        origin, env, log = self.full_fixture()
        writer = self.root / "writer"
        self.git("clone", "-q", str(origin), str(writer), repo=self.root)
        # Longer than the real script, so a shell that kept reading the file after the pull
        # would land on one of these lines wherever it resumed.
        replacement = "#!/bin/bash\n" + "echo replaced; exit 88\n" * 30000
        (writer / "scripts" / "dotsync").write_text(replacement)
        self.git("commit", "-qam", "replace", repo=writer)
        self.git("push", "-q", "origin", "master", repo=writer)
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual((self.repo / "scripts" / "dotsync").read_text(), replacement)
        self.assertEqual((result.returncode, heartbeat["result"]), (0, "ok"), diagnostic)
        self.assertNotIn("replaced", diagnostic)

    def test_a_script_rewritten_in_place_mid_run_keeps_running_the_parsed_one(self):
        # git replaces a file with a new inode, which a running shell never sees; an editor or a
        # copy can rewrite the same inode, which a shell reading as it goes would then execute.
        origin, env, log = self.full_fixture()
        replacement = self.root / "replacement"
        replacement.write_text("#!/bin/bash\n" + "echo replaced; exit 88\n" * 30000)
        hooks = self.home / "config" / "hooks" / "post-pull.d"
        hooks.mkdir(parents=True)
        for directory in (self.home / "config", self.home / "config" / "hooks", hooks):
            directory.chmod(0o700)
        hook = hooks / "10-rewrite-in-place"
        hook.write_text('#!/bin/sh\ncat %s > "$DOTFILES_DIR/scripts/dotsync"\n' % shlex.quote(str(replacement)))
        hook.chmod(0o700)
        result, heartbeat, diagnostic = self.run_full(env)
        self.assertEqual((self.repo / "scripts" / "dotsync").read_text(), replacement.read_text())
        self.assertEqual((result.returncode, heartbeat["result"]), (0, "ok"), diagnostic)
        self.assertNotIn("replaced", diagnostic)
        self.assertNotIn("command not found", diagnostic)


if __name__ == "__main__":
    unittest.main()
