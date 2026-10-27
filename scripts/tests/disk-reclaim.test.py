#!/usr/bin/env python3
"""disk-reclaim (the toolbox plugin): the survey's own unit tests (scripts/test_survey.py next to
survey.py), plus wt-classify.sh on throwaway checkouts: a clean pushed clone, a dirty one, an
unpushed one, a nested worktree, a plain directory, a checkout reached through a symlink, and the
liveness a tmux pane gives, all without a single write. A fake tmux prints pane paths, so nothing
real is listed or touched.

  python3 scripts/tests/disk-reclaim.test.py
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # keep __pycache__ out of the skill directory
SCRIPTS = Path(__file__).resolve().parents[2] / "plugins/toolbox/skills/disk-reclaim/scripts"
sys.path.insert(0, str(SCRIPTS))
from test_survey import SurveyTests  # noqa: E402,F401  (collected by unittest.main below)

CLASSIFY = SCRIPTS / "wt-classify.sh"


def git(env, cwd, *args):
    subprocess.run(["git", "-c", "init.defaultBranch=main", "-c", "user.name=Test", "-c",
                    "user.email=test@example.com", *args], cwd=cwd, env=env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def snapshot(root):
    """Every path under root with its size and mtime: what a read-only run must leave unchanged."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            st = os.lstat(os.path.join(dirpath, name))
            out[os.path.join(dirpath, name)] = (st.st_size, st.st_mtime_ns)
    return out


class WtClassifyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("git"):
            raise unittest.SkipTest("git not installed")
        cls.temp = tempfile.TemporaryDirectory(prefix="wt-classify-test-")
        root = Path(cls.temp.name).resolve()
        home = root / "home"
        code = home / "code"
        code.mkdir(parents=True)
        # A throwaway HOME, so no global git config (hooks, signing) takes part.
        env = {**os.environ, "HOME": str(home), "GIT_CONFIG_NOSYSTEM": "1",
               "PATH": f"{root / 'bin'}{os.pathsep}{os.environ['PATH']}"}
        env.pop("XDG_CONFIG_HOME", None)

        remote = root / "remote.git"
        git(env, root, "init", "-q", "--bare", str(remote))
        seed = root / "seed"
        git(env, root, "init", "-q", str(seed))
        (seed / "a.txt").write_text("a\n")
        git(env, seed, "add", "a.txt")
        git(env, seed, "commit", "-q", "-m", "first")
        git(env, seed, "remote", "add", "origin", str(remote))
        git(env, seed, "push", "-q", "-u", "origin", "main")

        for name in ("clean", "dirty", "ahead", "broken"):
            git(env, code, "clone", "-q", str(remote), name)
            # Nested worktrees stay out of their repository's status, as .gitignore keeps them.
            (code / name / ".git" / "info" / "exclude").write_text(".claude/\n")
        (code / "dirty" / "new.txt").write_text("untracked\n")
        (code / "dirty" / "sub").mkdir()
        (code / "ahead" / "b.txt").write_text("b\n")
        git(env, code / "ahead", "add", "b.txt")
        git(env, code / "ahead", "commit", "-q", "-m", "local only")
        git(env, code / "clean", "worktree", "add", "-q", "-b", "feature",
            str(code / "clean" / ".claude" / "worktrees" / "feature"))
        # An index git cannot read: `git status` fails while the ref queries still answer.
        (code / "broken" / ".git" / "index").write_bytes(b"not an index")
        (code / "notes").mkdir()
        # A relocated checkout: the real one lives elsewhere, ~/code holds a symlink to it.
        git(env, root, "clone", "-q", str(remote), str(root / "elsewhere" / "moved"))
        (code / "moved").symlink_to(root / "elsewhere" / "moved", target_is_directory=True)

        # A fake tmux: one pane sits in ~/code/dirty/sub, another in the relocated checkout.
        (root / "bin").mkdir()
        fake = root / "bin" / "tmux"
        fake.write_text("#!/bin/sh\nprintf '%s\\n' '{}' '{}'\n".format(
            code / "dirty" / "sub", root / "elsewhere" / "moved"))
        fake.chmod(0o755)

        cls.before = snapshot(root)
        out = subprocess.run(["bash", str(CLASSIFY)], env=env, capture_output=True,
                             text=True, timeout=60, check=True).stdout
        cls.after = snapshot(root)
        cls.lines = out.splitlines()
        cls.rows = {Path(line.split("\t")[0]).name: line.split("\t") for line in cls.lines[1:]}

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_header_names_the_columns(self):
        self.assertEqual(self.lines[0].split("\t"), ["#dir", "kind", "branch", "dirty", "unpushed",
                                                     "on_remote", "last_commit_days", "live"])

    def test_every_checkout_gets_one_row_of_eight_columns(self):
        self.assertEqual(sorted(self.rows), ["ahead", "broken", "clean", "dirty", "feature", "moved", "notes"])
        self.assertTrue(all(len(cols) == 8 for cols in self.rows.values()), self.rows)

    def test_a_clean_pushed_clone_is_idle_and_on_the_remote(self):
        self.assertEqual(self.rows["clean"][1:], ["standalone", "main", "0", "0/0", "yes", "0", "idle"])

    def test_an_untracked_file_makes_a_clone_dirty_and_a_pane_inside_it_live(self):
        cols = self.rows["dirty"]
        self.assertEqual((cols[3], cols[7]), ("1", "live"))  # new.txt; the empty sub/ is not listed

    def test_a_local_commit_is_unpushed_and_off_the_remote(self):
        cols = self.rows["ahead"]
        self.assertEqual((cols[4], cols[5], cols[7]), ("1/1", "no", "idle"))

    def test_a_nested_worktree_is_its_own_row(self):
        cols = self.rows["feature"]
        self.assertEqual(cols[1:3], ["worktree", "feature"])
        self.assertTrue(cols[0].endswith("clean/.claude/worktrees/feature"), cols[0])

    def test_a_status_git_cannot_read_is_unknown_not_clean(self):
        # A failed `git status` must never read as 0 dirty files: that row would look removable.
        self.assertEqual(self.rows["broken"][3], "?")

    def test_a_plain_directory_is_nogit(self):
        self.assertEqual(self.rows["notes"][1:], ["nogit", "-", "-", "-", "-", "-", "idle"])

    def test_a_pane_in_a_relocated_checkout_makes_its_symlink_live(self):
        self.assertEqual(self.rows["moved"][7], "live")

    def test_it_writes_nothing(self):
        # No file, index or lock under the checkouts was created, removed or modified.
        self.assertEqual(self.before, self.after)


if __name__ == "__main__":
    unittest.main(verbosity=2)
