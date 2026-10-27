#!/usr/bin/env python3
"""Bounded read-only disk shortlist. Sizes are observations, never delete approval."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import time


@dataclass(frozen=True)
class Target:
    path: Path
    label: str
    kind: str = "inspect"


CHECKS = {
    "cache": "Verify cache location and no active install/build before cleanup.",
    "runtime": "Check running versions, open files, and rebuild/download cost.",
    "data": "Inventory only; confirm ownership, contents, and explicit removal scope.",
    "inspect": "Determine ownership and active use; size does not imply disposability.",
}


def default_targets(home, system, environ):
    cache = Path(environ.get("XDG_CACHE_HOME") or home / ".cache")
    items = [
        (home / ".npm/_cacache", "npm content cache", "cache"),
        (cache / "uv", "uv cache", "cache"),
        (home / ".bun/install/cache", "Bun cache", "cache"),
        (home / ".npm/_npx", "npx / MCP installs", "runtime"),
        (cache / "codex-runtimes", "Codex runtime cache", "runtime"),
        (cache / "mongodb-binaries", "MongoDB test binaries", "runtime"),
        (home / ".codex/packages/standalone/releases", "Legacy Codex releases", "runtime"),
    ]
    if system == "Darwin":
        items = [
            (home / "Library/Caches/Homebrew/downloads", "Homebrew downloads", "cache"),
            *items,
            (home / "Library/Caches/pip", "pip cache", "cache"),
            (home / "Library/Caches/node-gyp", "node-gyp cache", "cache"),
            (home / "Library/Developer/Xcode/DerivedData", "Xcode DerivedData", "cache"),
            (home / "Library/pnpm/store", "pnpm store versions", "runtime"),
            (home / "Library/Caches/ms-playwright", "Playwright browsers", "runtime"),
            (home / "Library/Developer/Xcode/iOS DeviceSupport", "Xcode device support", "runtime"),
            (home / "Library/Developer/Xcode/Archives", "Xcode archives", "data"),
            (home / "Library/Developer/CoreSimulator/Devices", "Simulator devices", "data"),
            (home / ".Trash", "Trash", "data"),
            (Path(environ.get("COLIMA_HOME") or home / ".colima") / "_lima/_disks",
             "Colima sparse disks", "data"),
            (home / "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
             "Docker Desktop sparse disk", "data"),
        ]
    else:
        items += [
            (cache / "pip", "pip cache", "cache"),
            (home / ".local/share/pnpm/store", "pnpm store versions", "runtime"),
            (cache / "ms-playwright", "Playwright browsers", "runtime"),
            (Path("/var/cache/apt/archives"), "APT downloads", "cache"),
            (Path("/var/log/journal"), "System journal", "data"),
            (home / ".local/share/Trash", "Trash", "data"),
        ]
    for temp in (environ.get("TMPDIR"), "/tmp", "/private/tmp" if system == "Darwin" else None):
        if temp:
            items.append((Path(temp) / ".pnpm-store", "Temporary pnpm store", "runtime"))
    return [Target(*item) for item in items]


def command(argv, timeout):
    """Only called for single native df/du processes; timeout kills and reaps them."""
    if timeout <= 0:
        return {"status": "budget", "stdout": "", "detail": "Command budget exhausted"}
    try:
        result = subprocess.run(
            argv, capture_output=True, text=True, errors="replace", timeout=timeout,
            env={**os.environ, "LC_ALL": "C"}, stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "stdout": "", "detail": "Unmeasured; command timed out"}
    except OSError as exc:
        return {"status": "error", "stdout": "", "detail": str(exc)}
    return {
        "status": "ok" if result.returncode == 0 else "error",
        "stdout": result.stdout,
        "detail": result.stderr.strip()[:500],
    }


def capacity(path, executable, timeout):
    result = command([executable, "-kP", str(path)], timeout)
    result["path"] = str(path)
    if result["status"] == "ok":
        match = re.search(
            r"^(.+?)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(.+)$",
            result["stdout"], re.MULTILINE,
        )
        if match:
            result.update(filesystem=match[1], total_kib=int(match[2]),
                          used_kib=int(match[3]), available_kib=int(match[4]),
                          used_percent=int(match[5]), mount=match[6])
        else:
            result.update(status="error", detail="Could not parse native df -kP output")
    return result


def prepare(targets):
    rows, seen = [], {}
    for target in targets:
        path = target.path.expanduser().absolute()
        row = {"path": str(path), "label": target.label, "kind": target.kind,
               "next_check": CHECKS[target.kind], "size_kib": None}
        try:
            # Do not follow a leaf symlink and mistake its destination for a cache.
            if path.is_symlink():
                row.update(status="symlink", detail=f"Inspect link target: {os.readlink(path)}")
            else:
                path.lstat()  # Permission failures must not masquerade as nonexistent paths.
                resolved = str(path.resolve(strict=True))
                row["resolved_path"] = resolved
                if resolved in seen:
                    row.update(status="duplicate", detail=f"Same target as {seen[resolved]}")
                else:
                    seen[resolved] = str(path)
                    row["status"] = "pending"
        except FileNotFoundError:
            row["status"] = "missing"
        except (OSError, RuntimeError) as exc:
            row.update(status="error", detail=str(exc))
        rows.append(row)
    # Prefer the specific shortlist over a redundant walk of its parent tree.
    pending = [row for row in rows if row["status"] == "pending"]
    for row in pending:
        descendants = [other["path"] for other in pending if
                       Path(row["resolved_path"]) in Path(other["resolved_path"]).parents]
        if descendants:
            row.update(status="overlap", detail=f"Deferred ancestor; measuring specific targets: {descendants}")
    return rows


def measure(row, executable, deadline, per_path):
    started = time.monotonic()
    result = command([executable, "-skx", row["resolved_path"]],
                     min(per_path, deadline - started))
    match = re.match(r"\s*(\d+)\s", result["stdout"])
    row = {**row, "status": result["status"], "detail": result["detail"],
           "elapsed_seconds": round(time.monotonic() - started, 3)}
    if match:
        row["size_kib"] = int(match[1])
        if result["status"] != "ok":
            row["status"] = "partial"  # du may print a subtotal despite unreadable children.
    elif result["status"] == "ok":
        row.update(status="error", detail="No usable du summary; size unknown")
    return row


def overlaps(rows):
    paths = [Path(r["resolved_path"]) for r in rows if r["status"] != "duplicate"
             and "resolved_path" in r]
    return [[str(a), str(b)] for i, a in enumerate(paths) for b in paths[i + 1:]
            if a in b.parents or b in a.parents]


def survey(targets, filesystem, budget=20, per_path=3, workers=2, system=None):
    started = time.monotonic()
    deadline = started + budget
    system = system or platform.system()
    df = "/bin/df" if system == "Darwin" else (shutil.which("df") or "df")
    du = "/usr/bin/du" if system == "Darwin" else (shutil.which("du") or "du")
    baseline = capacity(filesystem.expanduser().absolute(), df, min(3, budget))
    rows = prepare(targets)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pending = {i: pool.submit(measure, row, du, deadline, per_path)
                   for i, row in enumerate(rows) if row["status"] == "pending"}
        for i, future in pending.items():
            rows[i] = future.result()
    return {
        "schema_version": 1,
        # A stable machine id when the shell exports one; never guessed from the hostname.
        "machine": os.environ.get("CLAUDE_MACHINE") or os.environ.get("DF_MACHINE") or "unidentified-local",
        "os": system, "read_only": True,
        "coverage": "Targeted shortlist; active use and deletion safety are NOT evaluated.",
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "command_budget_seconds": budget, "workers": workers,
        "capacity_before": baseline, "candidates": rows,
        "status_counts": dict(Counter(row["status"] for row in rows)),
        "overlapping_paths": overlaps(rows),
        "measurement_complete": baseline["status"] == "ok" and all(
            r["status"] in ("ok", "missing", "duplicate") for r in rows),
    }


def human(kib):
    return "unknown" if kib is None else f"{kib / 1024 ** 2:.2f} GiB"


def display(report):
    print(f"{report['machine']} | {report['os']} | {report['elapsed_seconds']:.1f}s | read-only")
    baseline = report["capacity_before"]
    if baseline["status"] == "ok":
        print(f"Available: {human(baseline['available_kib'])} | {baseline['used_percent']}% used | {baseline['mount']}")
    else:
        print(f"Capacity UNKNOWN: {baseline['detail']}")
    print(report["coverage"])
    print("Directory usage below is NOT predicted reclaim. Sizes must not be summed.\n")
    order = {"cache": 0, "runtime": 1, "data": 2, "inspect": 3}
    candidates = sorted(report["candidates"], key=lambda r: (order[r["kind"]], -(r["size_kib"] or 0)))
    for row in candidates:
        if row["status"] in ("missing", "duplicate"):
            continue
        size = human(row["size_kib"])
        if row["status"] == "partial":
            size += " (partial)"
        # repr makes newlines and other path control characters visible in a terminal.
        print(f"{size:>20} | {row['kind']:7} | {row['status']:7} | {row['label']}: {row['path']!r}")
        if row.get("resolved_path") and row["resolved_path"] != row["path"]:
            print(f"  Resolved destination: {row['resolved_path']!r}")
        if row.get("detail"):
            print(f"  {row['detail']!r}")
    print(f"\nCoverage: {report['status_counts']}")
    for kind in dict.fromkeys(r["kind"] for r in candidates if r["status"] != "missing"):
        print(f"{kind}: {CHECKS[kind]}")
    if report["overlapping_paths"]:
        print("Ancestor scans deferred to avoid duplicate I/O; request an ancestor separately only if needed.")


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--path", type=Path, action="append", help="Exact target; repeatable, replaces default shortlist")
    parser.add_argument("--filesystem", type=Path, default=Path.home(), help="Path for baseline df (default: home)")
    parser.add_argument("--budget", type=positive, default=20, help="Shared command budget in seconds (default: 20)")
    parser.add_argument("--timeout", type=positive, default=3, help="Maximum seconds per du command (default: 3)")
    parser.add_argument("--workers", type=int, choices=(1, 2), default=2)
    parser.add_argument("--format", choices=("text", "json"), default="text")
    args = parser.parse_args()
    targets = ([Target(path, "Selected path") for path in args.path] if args.path else
               default_targets(Path.home(), platform.system(), os.environ))
    report = survey(targets, args.filesystem.expanduser(), args.budget, args.timeout, args.workers)
    if args.format == "json":
        print(json.dumps(report, indent=2))
    else:
        display(report)
    return 0 if report["capacity_before"]["status"] == "ok" else 1


if __name__ == "__main__":
    raise SystemExit(main())
