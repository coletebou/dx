#!/usr/bin/env python3
"""Hold a per-user flock across exec, including on stock macOS without flock(1).

    dotsync-lock.py --acquire LOCKFILE WAIT_SECONDS COMMAND...   exec COMMAND holding fd 9
    dotsync-lock.py --check LOCKFILE FD                          does FD hold LOCKFILE?

A busy lock waits up to WAIT_SECONDS, then exits 75. The lock directory must be private to
this user and the lock a regular file it owns (0600); anything else is refused (exit 75), so
another user cannot hold or replace it. The file is never truncated or unlinked.
"""
import fcntl
import math
import os
from pathlib import Path
import stat
import sys
import time

MAX_WAIT = 600


def valid_file(info):
    return stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and not info.st_mode & 0o077


def check(path, fd):
    try:
        held = os.fstat(fd)
        current = path.lstat()
        if not valid_file(held) or (held.st_dev, held.st_ino) != (current.st_dev, current.st_ino):
            return False
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False


def acquire(path, seconds, command):
    if not math.isfinite(seconds) or not 0 <= seconds <= MAX_WAIT or not command:
        raise ValueError("invalid wait or command")
    parent = path.parent
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = parent.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError("unsafe lock directory")
    # O_NOFOLLOW refuses a substituted symlink; nothing is truncated or unlinked.
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    if not valid_file(os.fstat(fd)):
        os.close(fd)
        raise ValueError("unsafe lock file")
    deadline = time.monotonic() + seconds
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                print("dotsync: busy (another dotsync holds the lock); no sync performed", file=sys.stderr)
                return 75
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    if fd != 9:
        os.dup2(fd, 9, inheritable=True)
        os.close(fd)
    else:
        os.set_inheritable(9, True)
    # Keep the caller's spelling: the shell compares this marker before checking the inode.
    os.environ["DOTSYNC_LOCK_HELD"] = sys.argv[2]
    os.execvpe(command[0], command, os.environ)


if __name__ == "__main__":
    try:
        mode, path = sys.argv[1], Path(sys.argv[2])
        if mode == "--check":
            sys.exit(0 if check(path, int(sys.argv[3])) else 1)
        if mode != "--acquire":
            raise ValueError("invalid mode")
        sys.exit(acquire(path, float(sys.argv[3]), sys.argv[4:]))
    except (OSError, ValueError, IndexError):
        print("dotsync: could not acquire a safe per-user lock", file=sys.stderr)
        sys.exit(75)
