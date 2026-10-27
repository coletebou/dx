#!/usr/bin/env python3
"""Is someone working in the checkout right now? dotsync's guard for unattended runs.

    dotsync-activity.py --repo DIR [--quiet-minutes N] [--session-minutes M]

Exit 0 and print the reason when the checkout is busy, 1 when it is not, 2 on an error (dotsync
then defers, to be safe). Busy means either:

  - a file with uncommitted changes was modified in the last N minutes (default 10): someone is
    mid-edit, and an automatic commit would cut the edit in half;
  - a Claude Code or Codex session whose working directory is the checkout (or inside it) wrote
    its transcript in the last M minutes (default 30): an agent is working there, and a rebase
    would change files under it.

Zero minutes turns a check off. Read-only: it lists git status, stats files and reads the ends
of recent transcripts; it writes nothing and prints no file content.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

TAIL_BYTES = 256 * 1024
CWD = re.compile(rb'"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"')


def inside(path, repo):
    return path == repo or path.startswith(repo.rstrip("/") + "/")


def recent_edits(repo, minutes):
    if minutes <= 0:
        return None
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
    out = subprocess.run(["git", "-C", repo, "status", "--porcelain=v1", "-z", "--untracked-files=all"],
                         capture_output=True, env=env, timeout=30)
    if out.returncode != 0:
        raise RuntimeError("git status failed")
    cutoff = time.time() - minutes * 60
    fields = out.stdout.split(b"\0")
    recent = 0
    index = 0
    while index < len(fields):
        entry = fields[index]
        index += 1
        if len(entry) < 4:
            continue
        status, name = entry[:2], entry[3:]
        if status[:1] in (b"R", b"C"):
            index += 1  # the rename's source follows as its own field
        try:
            if os.lstat(os.path.join(repo, os.fsdecode(name))).st_mtime >= cutoff:
                recent += 1
        except OSError:
            continue
    if recent:
        return "%d uncommitted file%s edited in the last %d minutes" % (recent, "" if recent == 1 else "s", minutes)
    return None


def cwds(path):
    """Working directories a transcript names, from its first and last bytes."""
    found = set()
    try:
        with open(path, "rb") as stream:
            head = stream.read(64 * 1024)
            size = os.fstat(stream.fileno()).st_size
            stream.seek(max(0, size - TAIL_BYTES))
            tail = stream.read(TAIL_BYTES)
    except OSError:
        return found
    for chunk in (head, tail):
        for match in CWD.finditer(chunk):
            try:
                found.add(json.loads(b'"' + match.group(1) + b'"'))
            except ValueError:
                continue
    return found


def recent_files(root, pattern, cutoff, depth):
    if not root.is_dir():
        return
    base = len(root.parts)
    for current, dirs, files in os.walk(root):
        if len(Path(current).parts) - base >= depth:
            dirs[:] = []
        for name in files:
            if not name.endswith(".jsonl") or not pattern(name):
                continue
            path = Path(current) / name
            try:
                if path.stat().st_mtime >= cutoff:
                    yield path
            except OSError:
                continue


def claude_session(repo, cutoff):
    projects = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "projects"
    if not projects.is_dir():
        return None
    # Claude Code names a project directory after its working directory, every character that
    # is not a letter or digit replaced by a dash; a subdirectory's name extends it.
    slug = re.sub(r"[^A-Za-z0-9]", "-", repo)
    for entry in projects.iterdir():
        if entry.name != slug and not entry.name.startswith(slug + "-"):
            continue
        for path in recent_files(entry, lambda name: True, cutoff, 3):
            if any(inside(cwd, repo) for cwd in cwds(path)):
                return "a Claude Code session is working in the checkout"
    return None


def codex_session(repo, cutoff):
    sessions = Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex") / "sessions"
    if not sessions.is_dir():
        return None
    # Codex files rollouts by date: only the last two days can hold a recent one.
    today = datetime.date.today()
    for day in (today, today - datetime.timedelta(days=1)):
        folder = sessions / ("%04d" % day.year) / ("%02d" % day.month) / ("%02d" % day.day)
        for path in recent_files(folder, lambda name: name.startswith("rollout-"), cutoff, 1):
            if any(inside(cwd, repo) for cwd in cwds(path)):
                return "a Codex session is working in the checkout"
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--quiet-minutes", type=float, default=10)
    parser.add_argument("--session-minutes", type=float, default=30)
    args = parser.parse_args()
    repo = os.path.realpath(args.repo)
    reason = recent_edits(repo, args.quiet_minutes)
    if not reason and args.session_minutes > 0:
        cutoff = time.time() - args.session_minutes * 60
        reason = claude_session(repo, cutoff) or codex_session(repo, cutoff)
    if reason:
        print(reason)
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("activity check failed: %s" % type(error).__name__, file=sys.stderr)
        sys.exit(2)
