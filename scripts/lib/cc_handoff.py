#!/usr/bin/env python3
"""cc_handoff: the data half of cc-handoff (Claude Code handoff chains).

scripts/cc-handoff (bash) drives tmux, ssh and the launchers. Everything that reads or
writes JSON lives here, so the shell side never parses a transcript:

  render       a session transcript for a human, redacted (cc_handoff_transcript.py does
               the reading, rendering and redaction)
  info         the facts a handoff needs from a transcript (name, goal, first response,
               open background tasks, the todo list, sessions it messaged)
  jobs         the passer's background jobs: live Bash-tool shells under its claude
               process, plus in-process tasks its transcript never saw finish
  brief-init   the next generation's brief skeleton (fixed sections, live facts filled in)
  brief-check  validate a brief before launch; prints the three summary lines
  prepare      record the successor generation and write its inline prompt
  history      the linear history echoed in the successor's window
  watch        close the passer's window once the successor answered and no job blocks it
  probe, adopt, keep, status, mark, redact: small pieces the shell side calls

A chain lives in one directory (default ~/code/.briefs/<name>/):

  chain.json             name, root (successor session names are <root>-<gen>), created
  gen-01/session.json    one record per generation: who ran it, where, what became of it
  gen-01/brief.md        written by generation 1 when it hands off (fixed structure)
  gen-01/transcript.md   generation 1's transcript, rendered and redacted, at handoff
  gen-02/prompt.txt      the inline prompt generation 2 started with
  gen-02/watch.log       ... and so on, one gen-NN directory per generation

Stdlib only, Python 3.8+ (the Command Line Tools python3 on a Mac is 3.9).
"""

import argparse
import fcntl
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

# Transcript reading, redaction and rendering live next door (python puts this file's
# directory on sys.path when it runs it).
from cc_handoff_transcript import (
    Info, clip, find_transcript, hhmm, one_line, redact, render, transcript_info)

VERSION = 1
HOME = Path.home()
STATE_DIR = Path(os.environ.get("HANDOFF_STATE_DIR") or HOME / ".claude/state/handoff")
CHAIN_STATE_DIR = Path(os.environ.get("HANDOFF_CHAIN_STATE_DIR") or HOME / ".claude/state/handoff-chain")

SECTIONS = ["Summary", "What happened", "Done", "Left", "Proposed improvements",
            "Driver and manager", "Background jobs", "IDs and paths", "Rules"]
SUMMARY_KEYS = ["Continuing", "Done", "Left"]
FILL = "<<FILL"            # placeholder token; launch refuses a brief that still has one
SUMMARY_MAX = 300          # characters per summary line in the inline prompt


# ------------------------------------------------------------------ small helpers ----

def now():
    return int(time.time())


def iso(ts=None):
    return datetime.fromtimestamp(ts if ts is not None else time.time(), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def host_id():
    m = os.environ.get("DF_MACHINE") or os.environ.get("CLAUDE_MACHINE")
    if not m:
        try:
            for line in (HOME / ".df-profile").read_text().splitlines():
                if line.startswith("export DF_MACHINE="):
                    m = line.split("=", 1)[1].strip().strip("'\"")
        except OSError:
            pass
    return m or socket.gethostname().split(".")[0].lower()


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_atomic(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def write_json(path, obj):
    write_atomic(path, json.dumps(obj, indent=1, ensure_ascii=False) + "\n")


class ChainLock:
    """One writer at a time per chain: the launcher, the watcher and adopt all update records."""

    def __init__(self, chain_dir):
        self.path = Path(chain_dir) / ".lock"

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.f = open(self.path, "a")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def gen_dir(chain_dir, gen):
    return Path(chain_dir) / f"gen-{int(gen):02d}"


def session_path(chain_dir, gen):
    return gen_dir(chain_dir, gen) / "session.json"


def load_session(chain_dir, gen):
    return read_json(session_path(chain_dir, gen), {}) or {}


def update_session(chain_dir, gen, patch):
    """Deep-merge patch into gen-NN/session.json under the chain lock; returns the result."""
    def merge(a, b):
        for k, v in b.items():
            if isinstance(v, dict) and isinstance(a.get(k), dict):
                merge(a[k], v)
            else:
                a[k] = v
        return a
    with ChainLock(chain_dir):
        cur = load_session(chain_dir, gen)
        merged = merge(cur, patch)
        write_json(session_path(chain_dir, gen), merged)
        return merged


def generations(chain_dir):
    out = []
    for d in sorted(Path(chain_dir).glob("gen-[0-9][0-9]")):
        try:
            out.append(int(d.name[4:]))
        except ValueError:
            pass
    return out


# --------------------------------------------------------------------- jobs ----

_EVAL = re.compile(r"eval '(.*)' \\?< /dev/null(?: && pwd -P|$)", re.S)
_HANDOFF_CMD = re.compile(r"\bcc-handoff\b[^|;&]*\b(?:launch|init|jobs|status)\b")


def shell_command(cmdline):
    """The user command inside a Claude Code Bash-tool shell's command line."""
    m = _EVAL.search(cmdline)
    if not m:
        return ""
    return m.group(1).replace("'\\''", "'")


def ps_table():
    """[(pid, ppid, etime, command)] for every process, portable across GNU and BSD ps, or
    None when ps cannot run (a macOS sandbox refuses the setuid /bin/ps)."""
    try:
        p = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "etime=", "-o", "command="],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    rows = []
    for line in p.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) >= 4 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2], parts[3]))
    return rows if p.returncode == 0 and rows else None


def pgrep_children(pid):
    """[(pid, command)] of pid's direct children through pgrep, or None when it cannot run.
    Full argument lists are -lf on BSD and -af on Linux (BSD's -a means ancestors)."""
    flags = "-lf" if sys.platform == "darwin" else "-af"
    try:
        p = subprocess.run(["pgrep", flags, "-P", str(int(pid)), "."], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError, ValueError, TypeError):
        return None
    if p.returncode not in (0, 1):          # 1: no child at all
        return None
    out = []
    for line in p.stdout.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            out.append((int(parts[0]), parts[1]))
    return out


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def live_shells(claude_pid, exclude_ancestors_of=None):
    """Bash-tool shells running under claude_pid, minus the chain above exclude_ancestors_of,
    or None when no tool could list processes (the caller must then assume the worst)."""
    rows = ps_table()
    if rows is None:
        kids = pgrep_children(claude_pid)
        if kids is None:
            return None
        rows = [(pid, claude_pid, "", cmd) for pid, cmd in kids]
    parent = {pid: ppid for pid, ppid, _, _ in rows}
    skip = set()
    p = exclude_ancestors_of
    while p and p in parent and p not in skip:
        skip.add(p)
        p = parent[p]
    out = []
    for pid, ppid, etime, cmd in rows:
        if ppid != claude_pid or pid in skip or "shell-snapshots/snapshot-" not in cmd:
            continue
        inner = shell_command(cmd) or cmd
        if _HANDOFF_CMD.search(inner):
            continue          # the passer's own cc-handoff call, not a job of its work
        out.append({"pid": pid, "etime": etime, "command": inner})
    return out


def scan_jobs(claude_pid, transcript, exclude_ancestors_of=None):
    """Jobs that would die with the passer: live shells (matched to their background task by
    command when possible) plus in-process tasks (agents, workflows) still open in the transcript."""
    info = transcript_info(transcript) if transcript and os.path.exists(transcript) else Info()
    tasks = info.open_tasks()
    shells = live_shells(int(claude_pid), exclude_ancestors_of) if claude_pid and pid_alive(claude_pid) else []
    jobs, used = [], set()
    if shells is None:
        # Neither ps nor pgrep could list processes: fail closed, so nothing is closed blind.
        jobs.append({"id": "unknown", "kind": "unknown", "pid": None, "etime": "", "background": True,
                     "label": "could not list this session's processes (ps and pgrep failed)"})
        shells = []
    for sh in shells:
        match = next((t for t in tasks if t["kind"] == "bash" and t["id"] not in used
                      and t["command"] and t["command"].strip() == sh["command"].strip()), None)
        if match:
            used.add(match["id"])
        jobs.append({"id": match["id"] if match else f"pid:{sh['pid']}", "kind": "bash",
                     "label": match["label"] if match else clip(sh["command"], 160),
                     "pid": sh["pid"], "etime": sh["etime"], "background": bool(match)})
    for t in tasks:
        if t["id"] in used:
            continue
        # Still open in the transcript. A background Bash command that exec'd into its payload
        # (exec python3 worker.py) no longer looks like a tool shell, so a missing shell does not
        # prove it finished: Claude Code records a notification when a task ends.
        label = t["label"] + (" (no tool shell found: it may have exec'd into another program)"
                              if t["kind"] == "bash" else "")
        jobs.append({"id": t["id"], "kind": t["kind"], "label": label, "pid": None,
                     "etime": "", "background": True})
    return jobs


def jobs_table(jobs):
    if not jobs:
        return "None running when this was checked."
    rows = ["| id | kind | running for | what |", "|---|---|---|---|"]
    for j in jobs:
        what = redact(j["label"]).replace("|", "\\|")
        rows.append(f"| {j['id']} | {j['kind']}{'' if j['background'] else ' (foreground?)'} "
                    f"| {j['etime'] or 'unknown'} | {what} |")
    return "\n".join(rows)


# ------------------------------------------------------------------- briefs ----

def brief_skeleton(a, info, jobs, chain, gens):
    """The fixed-structure brief generation a.gen writes for generation a.gen + 1."""
    k = a.gen
    when = iso()
    first_prompt = clip(redact(info.first_prompt), 600) if info.first_prompt else "(none recorded)"
    goal = info.active_goal()
    todo = ""
    if info.todos:
        marks = {"completed": "x", "in_progress": "~"}
        todo = "\n".join(f"- [{marks.get(t.get('status'), ' ')}] {redact(one_line(t.get('content', '')))}"
                         for t in info.todos if isinstance(t, dict))
    prev = [f"| {g} | {s.get('session_id', '?')[:8]} {s.get('name', '')} | {s.get('host', '?')} "
            f"| gen-{g:02d}/brief.md |" for g, s in gens if g < k]
    git = a.git or "not a git checkout"
    lines = [
        f"# Handoff brief: {chain['name']}, generation {k} to {k + 1} ({when[:16].replace('T', ' ')}Z)",
        "",
        "Read this whole file before acting: the successor's inline prompt is only a summary of it.",
        "Write every fact from something checked in this session (a command, a file, a test run);",
        "write \"not verified\" rather than guess. Replace every FILL placeholder (the text in double",
        "angle brackets); launch refuses a brief that still has one. Keep each Summary line to one line.",
        "",
        "## Summary",
        "Continuing: <<FILL: one line: the task the next session continues, in plain words>>",
        "Done: <<FILL: one line: the most important things finished and verified>>",
        "Left: <<FILL: one line: what is still open, highest priority first>>",
        "",
        "## What happened",
        "<<FILL: a few bullets: what was asked (quote the latest unfinished request word for word),",
        "what was tried, what worked and what did not>>",
        "",
        "## Done",
        "<<FILL: each finished item with its evidence (commands and results, SHAs, links)>>",
        "",
        "## Left",
        "<<FILL: each open item in priority order: its state, the next concrete action, and",
        "whether it needs the user's go. This is the todo list the successor starts from.>>",
    ]
    if todo:
        lines += ["", "Todo list at the time of this brief (from the session's todo tool):", todo]
    lines += [
        "",
        "## Proposed improvements",
        "<<FILL: what the next session, or the tooling, should do differently; \"none\" if none>>",
        "",
        "## Driver and manager",
        "- Driven by: <<FILL: who sends this session its work: the user directly, a lead session",
        "  (name, pane), a bot, a /goal>>",
        "- Reports to: <<FILL: who hears about progress, and how (drover_send id, a STATUS.md path)>>",
        "- Manages: <<FILL: sessions this one started or steers (name, host, tmux target), or none>>",
        "",
        "Facts read from the transcript (for the lines above):",
        f"- First prompt: {first_prompt}",
        f"- Active /goal: {clip(redact(goal), 600) if goal else 'none'}",
        f"- Sessions it messaged through Drover: {', '.join(info.messaged) or 'none'}",
        f"- Sessions it launched through Drover: {', '.join(info.launched) or 'none'}",
        "",
        "## Background jobs",
        jobs_table(jobs),
        "",
        "- Adopter: <<FILL: for each running job, who takes it over (\"the successor restarts it with",
        "  the same command\", \"finishes on its own by HH:MMZ\"), or \"none running\">>",
        "",
        "The passer's window is closed only after the successor's first reply, and only once these",
        "jobs have finished or the successor ran `cc-handoff adopt`.",
        "",
        "## IDs and paths",
        f"- Chain: {chain['name']} ({a.chain_dir}); this brief is gen-{k:02d}/brief.md, written by",
        f"  generation {k} for generation {k + 1}.",
        f"- Host: {a.host} (identity {os.environ.get('DF_IDENTITY') or 'unknown'})",
        f"- Session: {info.session_id or a.sid}" + (f' "{info.name}"' if info.name else ""),
        f"- Transcript (raw JSONL): {a.transcript or 'unknown'}",
        f"- Resume this session: cd {shlex.quote(a.cwd)} && claude --resume {info.session_id or a.sid}",
        f"- tmux: {a.target or 'not in tmux'}" + (f" (window {a.window}, pane {a.pane})" if a.pane else ""),
        f"- Working directory: {a.cwd} ({git})",
    ]
    if prev:
        lines += ["- Earlier generations:", "", "| gen | session | host | brief |", "|---|---|---|---|"] + prev
    lines += [
        "",
        "## Rules",
        "<<FILL: what the successor may do without asking, and what still needs the user's go",
        "(PRs or MRs, merges, branch deletes, force-pushes, comments, anything outward-facing)>>",
        "",
    ]
    return "\n".join(lines)


def section_bodies(text):
    """{heading: body} for the brief's '## ' sections."""
    out, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            cur = m.group(1)
            out[cur] = []
        elif cur is not None:
            out[cur].append(line)
    return {k: "\n".join(v).strip() for k, v in out.items()}


def check_brief(text):
    problems, summary = [], {}
    bodies = section_bodies(text)
    for s in SECTIONS:
        if s not in bodies:
            problems.append(f"missing section '## {s}'")
        elif not bodies[s]:
            problems.append(f"section '## {s}' is empty (write \"none\" if there is nothing)")
    fills = [i + 1 for i, ln in enumerate(text.splitlines()) if FILL in ln]
    if fills:
        problems.append(f"{len(fills)} <<FILL ...>> marker(s) left (lines {', '.join(map(str, fills[:8]))})")
    for key in SUMMARY_KEYS:
        m = re.search(rf"^{key}:\s*(.+)$", bodies.get("Summary", ""), re.M)
        val = m.group(1).strip() if m else ""
        if len(val) < 3:
            problems.append(f"the Summary has no '{key}:' line")
        summary[key] = clip(redact(val), SUMMARY_MAX)
    return problems, summary


# ------------------------------------------------------------------ prompt ----

def build_prompt(chain, passer, succ, summary, brief, rendered, jobs, go, goal):
    """The successor's inline prompt: about 8 lines, plus the passer's /goal when one was active."""
    who = passer.get("name") or "the previous session"
    where = f"session {passer.get('session_id', '?')[:8]}, host {passer.get('host', '?')}"
    if (passer.get("tmux") or {}).get("target"):
        where += f", tmux {passer['tmux']['target']}"
    n = len(jobs)
    if n:
        jobs_line = (f"Background jobs: {n} still running in the previous session (see the brief's Background jobs "
                     "section). Take over what you need, then run `cc-handoff adopt`; its window stays open "
                     "until they finish or you adopt them.")
    else:
        jobs_line = "Background jobs: none were running; the previous session's window closes after your first reply."
    if go:
        then = ("Then do all of it without asking which item to start; ask only where the brief's Rules say to, "
                "or if something blocks. Anything the Rules do not authorize still needs my go.")
    else:
        then = ("Then verify the live state the brief names, summarize the open items to me and ask which to "
                "start. PRs, merges, branch deletes, force-pushes and comments need my go.")
    body = [
        f"[cc-handoff] You are generation {succ['gen']} (session name {succ['name']}) of handoff chain "
        f"{chain['name']}, continuing {who} ({where}). This message was written by the handoff tool from "
        "that session's brief, not typed by a person.",
        f"It is only a summary. The brief is the source of truth: {brief}",
        f"Continuing: {summary['Continuing']}",
        f"Done: {summary['Done']}",
        f"Left: {summary['Left']}",
        jobs_line,
        f"Before acting: read the brief in full, then check it against the end of the previous session's own "
        f"transcript ({rendered}, rendered and redacted; read at least its last 400 lines; it is also echoed in "
        "this terminal for the user); where they disagree, trust the transcript. Build or refresh your todo "
        "list from the brief's Left section, and tell the sessions named in its Driver and manager section "
        f"your session name ({succ['name']}).",
        then,
    ]
    text = "\n".join(body)
    if goal:
        text = f"/goal {one_line(redact(goal))}\n\n{text}"
    return text + "\n"


# ----------------------------------------------------------------- history ----

def history_text(chain_dir, gen):
    """Briefs 1..gen-2, then the rendered transcript of gen-1, with separators."""
    chain = read_json(Path(chain_dir) / "chain.json", {}) or {}
    passer_gen = gen - 1
    parts = []
    bar = "═" * 76
    parts.append(bar)
    parts.append(f" cc-handoff · chain {chain.get('name', Path(chain_dir).name)} · generation {gen} starts below")
    briefs = [g for g in range(1, passer_gen) if (gen_dir(chain_dir, g) / "brief.md").exists()]
    order = ", ".join([f"brief {g}" for g in briefs] + [f"generation {passer_gen}'s transcript"])
    parts.append(f" History, oldest first: {order}.")
    parts.append(bar)
    for g in briefs:
        s = load_session(chain_dir, g)
        when = hhmm(((s.get("handoff") or {}).get("launched_iso")) or "")
        parts.append("")
        parts.append(f"──── brief {g} · written by generation {g} (session {s.get('session_id', '?')[:8]}"
                     + (f' "{s.get("name")}"' if s.get("name") else "") + f", {s.get('host', '?')})"
                     + (f" · {when[0]} {when[1]}" if when[0] else "") + " ────")
        parts.append(redact((gen_dir(chain_dir, g) / "brief.md").read_text(errors="replace")).rstrip())
    p = load_session(chain_dir, passer_gen)
    rendered = gen_dir(chain_dir, passer_gen) / "transcript.md"
    parts.append("")
    body = rendered.read_text(errors="replace").rstrip() if rendered.exists() else "(no rendered transcript)"
    parts.append(f"──── generation {passer_gen} transcript · session {p.get('session_id', '?')[:8]}"
                 + (f' "{p.get("name")}"' if p.get("name") else "")
                 + f" · rendered, redacted · {body.count(chr(10)) + 1} lines ────")
    parts.append(body)
    return "\n".join(parts) + "\n"


def footer_text(chain_dir, gen, buffer_note):
    p = load_session(chain_dir, gen - 1)
    s = load_session(chain_dir, gen)
    pd = gen_dir(chain_dir, gen - 1)
    lines = [
        "",
        "──── end of history ────",
        f" Brief for generation {gen} (the new session reads it): {pd / 'brief.md'}",
        f" Rendered transcript: {pd / 'transcript.md'}",
        f" Raw JSONL: {p.get('transcript', '?')} (on {p.get('host', '?')})",
        f" Resume generation {gen - 1}: cd {shlex.quote(p.get('cwd') or '.')} && claude --resume {p.get('session_id', '?')}"
        + (f"   (on {p.get('host')})" if p.get("host") and p.get("host") != s.get("host") else ""),
    ]
    if buffer_note:
        lines.append(f" {buffer_note}")
    lines.append(f" Starting Claude Code as generation {gen} ({s.get('name', '?')}, session {s.get('session_id', '?')}),")
    lines.append(f" with the inline prompt in {gen_dir(chain_dir, gen) / 'prompt.txt'}")
    lines.append("")
    return "\n".join(lines)


# -------------------------------------------------------------- marker files ----

def safe_id(sid):
    return re.sub(r"[^A-Za-z0-9._-]", "_", sid or "")


def write_passer_marker(sid, target, pane, brief, state):
    """~/.claude/state/handoff/<sid>.json, "target" first: statusline.sh reads it with a regex."""
    if not sid:
        return
    marker = STATE_DIR / f"{safe_id(sid)}.json"
    obj = {"target": target, "pane": pane, "brief": brief, "state": state, "ts": now()}
    write_atomic(marker, json.dumps(obj, separators=(",", ":"), ensure_ascii=True) + "\n")


def write_chain_marker(sid, gen, chain_name, chain_dir):
    """~/.claude/state/handoff-chain/<sid>.json, "gen" first: the statusline's ⤷N badge."""
    obj = {"gen": int(gen), "chain": chain_name, "dir": str(chain_dir)}
    write_atomic(CHAIN_STATE_DIR / f"{safe_id(sid)}.json", json.dumps(obj, separators=(",", ":")) + "\n")


def chain_of_session(sid):
    m = read_json(CHAIN_STATE_DIR / f"{safe_id(sid)}.json", None)
    return m if isinstance(m, dict) and m.get("dir") and m.get("gen") else None


# -------------------------------------------------------------------- tmux ----

_KILL_SERVER = re.compile(r"^kill-(ser|serv|serve|server|ses|sess|sessi|sessio|session)$")


def tmux(*args, timeout=10):
    """Every tmux call here. It never kills a server or a session, and closes a window or a
    pane only by an explicit %pane target (a stray kill-server took a whole host's sessions
    down on 2026-10-23). A refused call returns 97 and runs nothing."""
    args = [str(a) for a in args]
    if any(_KILL_SERVER.match(a) for a in args) or "\\;" in args or ";" in args:
        return 97, ""
    if args and args[0] in ("kill-window", "killw", "kill-pane", "killp"):
        if len(args) != 3 or args[1] != "-t" or not re.match(r"^%[0-9]+$", args[2]):
            return 97, ""
    try:
        p = subprocess.run(["tmux", *args], capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return 1, ""


def pane_holds(pane, pid):
    """True when process pid runs inside tmux pane `pane` (the pane's process is an ancestor).
    Walks up with ps, or down from the pane with pgrep -P where ps cannot run."""
    rc, root = tmux("display-message", "-p", "-t", pane, "#{pane_pid}")
    if rc != 0 or not root.isdigit() or not pid:
        return False
    rows = ps_table()
    if rows is not None:
        parent = {p: pp for p, pp, _, _ in rows}
        cur, seen = int(pid), set()
        while cur and cur not in seen:
            if cur == int(root):
                return True
            seen.add(cur)
            cur = parent.get(cur, 0)
        return False
    frontier, seen = [int(root)], set()
    for _ in range(8):
        if int(pid) in frontier:
            return True
        nxt = []
        for f in frontier:
            if f not in seen:
                seen.add(f)
                nxt += [c for c, _ in (pgrep_children(f) or [])]
        if not nxt:
            return False
        frontier = nxt
    return int(pid) in frontier


def ssh(alias, command, timeout=20, stdin=None):
    try:
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", alias, command],
                           capture_output=True, text=True, timeout=timeout, input=stdin)
        return p.returncode, p.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return 255, ""


# ------------------------------------------------------------------- watch ----

class Watch:
    """Close the passer once the successor answered, its jobs allow it, and it is quiet.

    Runs on the passer's host as a tmux server job (`tmux run-shell -b`), so killing the
    passer's pane does not kill the watcher. Every decision is written to the passer's
    session.json (handoff.kill) and to gen-NN/watch.log.
    """

    def __init__(self, chain_dir, gen):
        self.chain_dir, self.gen = Path(chain_dir), int(gen)
        self.log_path = gen_dir(chain_dir, gen) / "watch.log"
        env = os.environ.get
        self.poll = float(env("FSH_WATCH_POLL") or 3)
        self.first_timeout = int(env("FSH_FIRST_RESPONSE_TIMEOUT") or 1800)
        self.hold_max = int(env("FSH_HOLD_MAX") or 12 * 3600)
        self.quiet = int(env("FSH_QUIET_SECS") or 10)
        self.quiet_max = int(env("FSH_QUIET_MAX") or 300)
        self.remote_cch = env("FSH_REMOTE_CCH") or "~/.dotfiles/scripts/cc-handoff"

    def log(self, msg):
        with open(self.log_path, "a", encoding="utf-8") as f:
            f.write(f"{iso()} {msg}\n")

    def decide(self, state, reason, **extra):
        self.log(f"kill={state}: {reason}")
        patch = {"handoff": {"kill": dict({"state": state, "reason": reason, "at": now()}, **extra)}}
        merged = update_session(self.chain_dir, self.gen, patch)
        self.mirror(self.gen, patch)
        return merged

    def mirror(self, gen, patch):
        """A successor on another host reads its own copy of the chain: give it the same facts."""
        succ = getattr(self, "succ", None) or {}
        if succ.get("ssh_alias") and succ.get("remote_chain_dir"):
            rc, _ = ssh(succ["ssh_alias"], f"{self.remote_cch} set {shlex.quote(succ['remote_chain_dir'])} "
                        f"{int(gen)} {shlex.quote(json.dumps(patch))}")
            if rc != 0:
                self.log(f"could not update the copy on {succ['ssh_alias']} (rc={rc})")

    def responded(self, succ):
        sid = succ.get("session_id")
        if succ.get("ssh_alias"):
            rc, out = ssh(succ["ssh_alias"], f"{self.remote_cch} probe {shlex.quote(sid)}")
            return rc == 0 and out.split()[:1] == ["responded"]
        path = find_transcript(sid)
        return bool(path) and transcript_info(path).first_response

    def adopted(self, succ):
        """What the successor took over; a remote successor records it on its own host."""
        if succ.get("ssh_alias") and succ.get("remote_chain_dir"):
            rc, out = ssh(succ["ssh_alias"], f"{self.remote_cch} get "
                          f"{shlex.quote(succ['remote_chain_dir'])} {self.gen + 1} adopted")
            try:
                a = json.loads(out) if rc == 0 and out else {}
            except ValueError:
                a = {}
        else:
            a = load_session(self.chain_dir, self.gen + 1).get("adopted") or {}
        a = a if isinstance(a, dict) else {}
        return bool(a.get("all")), set(a.get("ids") or [])

    def run(self):
        passer = load_session(self.chain_dir, self.gen)
        succ = self.succ = load_session(self.chain_dir, self.gen + 1)
        tm = passer.get("tmux") or {}
        pane, sid = tm.get("pane"), passer.get("session_id")
        handoff = passer.get("handoff") or {}
        target = handoff.get("target") or ""
        brief = str(gen_dir(self.chain_dir, self.gen) / "brief.md")
        self.log(f"watching: passer gen {self.gen} ({sid}, pane {pane}) -> gen {self.gen + 1} "
                 f"({succ.get('session_id')}{' via ' + succ['ssh_alias'] if succ.get('ssh_alias') else ''})")
        if os.environ.get("FSH_KILL", "1") == "0" or handoff.get("no_kill"):
            self.decide("kept", "closing the passer is turned off for this handoff (--no-kill)")
            return 0
        start = time.time()
        while not self.responded(succ):
            if (load_session(self.chain_dir, self.gen).get("handoff") or {}).get("kill", {}).get("state") == "kept":
                self.log("kept by request while waiting")
                return 0
            if time.time() - start > self.first_timeout:
                self.decide("skipped", f"the successor did not reply within {self.first_timeout}s; the passer stays")
                return 0
            time.sleep(self.poll)
        update_session(self.chain_dir, self.gen + 1, {"first_response_at": now()})
        self.mirror(self.gen + 1, {"first_response_at": now()})
        write_passer_marker(sid, target, pane or "", brief, "responded")
        self.log("successor replied")
        self.notify(passer, succ)
        held_since, quiet_since = None, time.time()
        while True:
            kill = (load_session(self.chain_dir, self.gen).get("handoff") or {}).get("kill") or {}
            if kill.get("state") == "kept":
                self.log("kept by request")
                return 0
            if not pane or tmux("display-message", "-p", "-t", pane, "#{pane_id}")[1] != pane:
                self.decide("gone", "the passer's pane no longer exists")
                return 0
            # The pane must still be the passer's: the launcher's own tag on its window, and
            # (while the passer runs) its claude process inside that pane. A pane id reused by
            # anything else is never closed.
            src = tmux("show-options", "-wqv", "-t", pane, "@handoff_src")[1]
            if src != f"{pane} {sid}":
                self.decide("kept", "the passer's pane is not tagged as this handoff's any more "
                            "(another session started there, or the tag is gone); it stays")
                return 0
            cpid = passer.get("claude_pid")
            if not cpid or not pid_alive(cpid):
                self.decide("kept", "the passer's Claude process is unknown or has exited, so the pane may be "
                            "in use for something else; it is left as it is")
                return 0
            if not pane_holds(pane, cpid):
                self.decide("kept", f"the passer's claude process is not in pane {pane}; nothing is closed")
                return 0
            transcript = passer.get("transcript") or find_transcript(sid)
            info = transcript_info(transcript) if transcript and os.path.exists(transcript) else Info()
            launched_iso = handoff.get("launched_iso") or ""
            if info.last_user_ts and launched_iso and info.last_user_ts > launched_iso:
                self.decide("kept", "someone typed in the passer after the handoff; it stays open for them")
                return 0
            all_adopted, ids = self.adopted(succ)
            jobs = [] if all_adopted else scan_jobs(passer.get("claude_pid"), transcript)
            blocking = [j for j in jobs if j["id"] not in ids and str(j.get("pid")) not in ids]
            if blocking:
                if held_since is None:
                    held_since = time.time()
                    self.decide("held", f"{len(blocking)} job(s) still running in the passer",
                                jobs=[{"id": j["id"], "label": j["label"]} for j in blocking])
                    write_passer_marker(sid, target, pane, brief, "held")
                    tmux("set-option", "-w", "-t", pane, "@handoff_hold", f"{len(blocking)} job(s)")
                if time.time() - held_since > self.hold_max:
                    self.decide("kept", f"jobs still running after {self.hold_max}s; giving up, the passer stays")
                    return 0
                time.sleep(max(self.poll, 15))
                quiet_since = time.time()
                continue
            if held_since is not None:
                self.log("no job blocks the passer any more")
                held_since = None
                tmux("set-option", "-wu", "-t", pane, "@handoff_hold")
            age = time.time() - (os.path.getmtime(transcript) if transcript and os.path.exists(transcript) else 0)
            quiet = age >= self.quiet and info.turn_ended
            if not quiet and time.time() - quiet_since < self.quiet_max:
                time.sleep(self.poll)
                continue
            return self.kill(pane, sid, transcript, quiet)

    def notify(self, passer, succ):
        manager = (passer.get("handoff") or {}).get("notify")
        if not manager:
            return
        text = (f"[cc-handoff] {passer.get('name') or passer.get('session_id', '?')[:8]} handed off to "
                f"{succ.get('name')} (session {succ.get('session_id')}, {succ.get('host')}"
                f"{', tmux ' + succ['tmux']['target'] if (succ.get('tmux') or {}).get('target') else ''}). "
                f"Brief: {gen_dir(self.chain_dir, self.gen) / 'brief.md'}. Address it as {succ.get('name')} from now on.")
        try:
            p = subprocess.run(["drover", "op", "sessions.message", json.dumps({"id": manager, "text": text})],
                               capture_output=True, text=True, timeout=30)
            self.log(f"notified {manager}: rc={p.returncode}")
        except (OSError, subprocess.SubprocessError) as e:
            self.log(f"notify {manager} failed: {e}")

    def kill(self, pane, sid, transcript, quiet):
        # No re-render or screen capture here: this job runs with the tmux server's environment,
        # not the passer's, so it would redact less than the launch-time render did.
        panes = tmux("display-message", "-p", "-t", pane, "#{window_panes}")[1]
        what = ("kill-window", "the window") if panes == "1" else ("kill-pane", "the pane (its window has other panes)")
        rc, _ = tmux(what[0], "-t", pane)
        if rc != 0:
            self.decide("failed", f"tmux {what[0]} failed")
            return 1
        self.decide("killed", f"closed {what[1]} after the successor replied"
                    + ("" if quiet else f"; it was still busy after {self.quiet_max}s"),
                    resume=f"claude --resume {sid}")
        return 0


# --------------------------------------------------------------------- CLI ----

def cmd_render(a):
    out = open(a.out, "w", encoding="utf-8") if a.out else sys.stdout
    try:
        n = render(a.transcript, out, a.host or host_id(), a.results)
    finally:
        if a.out:
            out.close()
    if a.out:
        print(n)
    return 0


def cmd_info(a):
    print(json.dumps(transcript_info(a.transcript).as_dict(), ensure_ascii=False))
    return 0


def cmd_jobs(a):
    jobs = scan_jobs(a.pid, a.transcript, a.exclude_ancestors_of)
    print(json.dumps(jobs) if a.json else jobs_table(jobs))
    return 0


def cmd_redact(_a):
    sys.stdout.write(redact(sys.stdin.read()))
    return 0


def cmd_brief_init(a):
    """Create the chain (when new), this generation's record and its brief skeleton."""
    chain_dir = Path(a.chain_dir)
    with ChainLock(chain_dir):
        chain = read_json(chain_dir / "chain.json", None)
        if not chain:
            chain = {"version": VERSION, "name": chain_dir.name, "root": a.root, "created": iso(),
                     "origin_host": a.host}
            write_json(chain_dir / "chain.json", chain)
    # A generation belongs to one session: another one's record is never taken over (an
    # explicit --chain to someone else's chain, say), even with --force.
    owner = load_session(chain_dir, a.gen).get("session_id")
    if owner and owner != a.sid:
        print(f"generation {a.gen} of {chain_dir} belongs to session {owner}; not taking it over", file=sys.stderr)
        return 2
    info = transcript_info(a.transcript) if a.transcript and os.path.exists(a.transcript) else Info()
    jobs = scan_jobs(a.claude_pid, a.transcript, a.exclude_ancestors_of) if a.claude_pid else []
    update_session(chain_dir, a.gen, {
        "gen": a.gen, "session_id": a.sid, "name": info.name or a.name, "host": a.host, "cwd": a.cwd,
        "transcript": a.transcript, "claude_pid": a.claude_pid,
        "tmux": {"target": a.target, "pane": a.pane, "window": a.window},
    })
    if not chain_of_session(a.sid):       # generation 1, or a session the launcher did not mark
        write_chain_marker(a.sid, a.gen, chain["name"], chain_dir)
    brief = gen_dir(chain_dir, a.gen) / "brief.md"
    if brief.exists() and not a.force:
        print(str(brief))
        return 3
    gens = [(g, load_session(chain_dir, g)) for g in generations(chain_dir)]
    write_atomic(brief, brief_skeleton(a, info, jobs, chain, gens))
    print(str(brief))
    return 0


def cmd_brief_check(a):
    problems, summary = check_brief(Path(a.brief).read_text(errors="replace"))
    print(json.dumps({"ok": not problems, "problems": problems, "summary": summary}, ensure_ascii=False))
    return 0 if not problems else 1


def cmd_prepare(a):
    """Record generation gen+1 and write its prompt; prints the prompt path."""
    chain_dir = Path(a.chain_dir)
    chain = read_json(chain_dir / "chain.json", {}) or {}
    passer = load_session(chain_dir, a.gen)
    brief = gen_dir(chain_dir, a.gen) / "brief.md"
    problems, summary = check_brief(brief.read_text(errors="replace"))
    if problems:
        print("; ".join(problems), file=sys.stderr)
        return 2
    info = transcript_info(passer["transcript"]) if passer.get("transcript") and os.path.exists(passer["transcript"]) else Info()
    goal = None if a.no_goal else (a.goal or info.active_goal())
    jobs = scan_jobs(passer.get("claude_pid"), passer.get("transcript"), a.exclude_ancestors_of)
    succ_gen = a.gen + 1
    succ = {"gen": succ_gen, "session_id": a.successor_sid, "name": a.successor_name, "host": a.successor_host,
            "cwd": a.successor_cwd, "launcher": a.launcher, "model": a.model, "effort": a.effort,
            "claude_args": json.loads(a.claude_args or "[]"), "env": json.loads(a.successor_env or "{}"),
            "prepared_at": now(), "go": bool(a.go), "bypass": bool(a.bypass),
            "goal": goal, "tmux": {}, "ssh_alias": a.ssh_alias or "",
            "remote_chain_dir": a.remote_chain_dir or ""}
    # Every launch makes a new successor id: nothing of an earlier attempt's record (its
    # environment, its window) may carry into this one, so it is replaced, not merged.
    with ChainLock(chain_dir):
        write_json(session_path(chain_dir, succ_gen), succ)
    sd = gen_dir(chain_dir, succ_gen)
    rendered = gen_dir(chain_dir, a.gen) / "transcript.md"
    remote_root = a.remote_chain_dir or str(chain_dir)
    brief_for_succ = str(Path(remote_root) / brief.relative_to(chain_dir))
    rendered_for_succ = str(Path(remote_root) / rendered.relative_to(chain_dir))
    text = build_prompt(chain, passer, succ, summary, brief_for_succ, rendered_for_succ, jobs, a.go, goal)
    write_atomic(sd / "prompt.txt", text)
    update_session(chain_dir, a.gen, {"handoff": {
        "to_gen": succ_gen, "launched_at": now(), "launched_iso": iso(), "brief": f"gen-{a.gen:02d}/brief.md",
        "rendered": f"gen-{a.gen:02d}/transcript.md", "jobs_at_launch": jobs, "notify": a.notify or "",
        "no_kill": bool(a.no_kill), "target": a.passer_target or "", "kill": {"state": "waiting"}}})
    print(json.dumps({"prompt": str(sd / "prompt.txt"), "jobs": len(jobs), "goal": bool(goal),
                      "summary": summary}))
    return 0


def cmd_history(a):
    text = history_text(a.chain_dir, a.gen)
    lines = text.split("\n")
    if a.max_lines and len(lines) > a.max_lines:
        cut = len(lines) - a.max_lines
        lines = lines[:4] + [f"… {cut} earlier lines are left out of this echo so tmux keeps the rest "
                             "(history-limit); the files below are complete."] + lines[4 + cut:]
    sys.stdout.write("\n".join(lines))
    return 0


def cmd_footer(a):
    sys.stdout.write(footer_text(a.chain_dir, a.gen, a.buffer_note))
    return 0


def cmd_watch(a):
    return Watch(a.chain_dir, a.gen).run()


def cmd_probe(a):
    path = find_transcript(a.sid)
    if not path:
        print("waiting")
    else:
        print("responded" if transcript_info(path).first_response else "started")
    return 0


def cmd_adopt(a):
    cur = load_session(a.chain_dir, a.gen).get("adopted") or {}
    ids = sorted(set(cur.get("ids") or []) | set(a.ids))
    update_session(a.chain_dir, a.gen, {"adopted": {"all": bool(a.all or cur.get("all")), "ids": ids, "at": now()}})
    print(json.dumps(load_session(a.chain_dir, a.gen).get("adopted")))
    return 0


def cmd_keep(a):
    update_session(a.chain_dir, a.gen, {"handoff": {"kill": {"state": "kept", "reason": "kept by request", "at": now()}}})
    return 0


def cmd_mark(a):
    if a.kind == "passer":
        write_passer_marker(a.sid, a.target, a.pane, a.brief, a.state)
    else:
        write_chain_marker(a.sid, a.gen, a.chain_name, a.chain_dir)
    return 0


def cmd_set(a):
    update_session(a.chain_dir, a.gen, json.loads(a.json))
    return 0


def cmd_get(a):
    s = load_session(a.chain_dir, a.gen)
    for key in a.key.split("."):
        s = s.get(key) if isinstance(s, dict) else None
    if isinstance(s, (dict, list)):
        print(json.dumps(s))
    elif s is not None:
        print(s)
    return 0


def cmd_chain_of(a):
    m = chain_of_session(a.sid)
    if not m:
        return 1
    print(f"{m['dir']}\t{m['gen']}")
    return 0


def cmd_status(a):
    chain_dir = Path(a.chain_dir)
    chain = read_json(chain_dir / "chain.json", {}) or {}
    print(f"chain {chain.get('name', chain_dir.name)}  ({chain_dir})")
    print(f"{'gen':>3}  {'session':<8}  {'name':<20} {'host':<18} {'state'}")
    for g in generations(chain_dir):
        s = load_session(chain_dir, g)
        kill = (s.get("handoff") or {}).get("kill") or {}
        bits = []
        if s.get("first_response_at"):
            bits.append(f"replied {iso(s['first_response_at'])[11:16]}Z")
        if kill:
            bits.append(f"window {kill.get('state')}: {kill.get('reason', '')}")
        if s.get("adopted"):
            bits.append(f"adopted {'all' if s['adopted'].get('all') else ','.join(s['adopted'].get('ids') or [])}")
        print(f"{g:>3}  {s.get('session_id', '?')[:8]:<8}  {clip(s.get('name') or '', 20):<20} "
              f"{clip(s.get('host') or '?', 18):<18} {'; '.join(bits) or '-'}")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="cc_handoff.py", description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("render"); s.add_argument("transcript"); s.add_argument("--out")
    s.add_argument("--host", default=""); s.add_argument("--results", type=int, default=0)
    s.set_defaults(fn=cmd_render)
    s = sub.add_parser("info"); s.add_argument("transcript"); s.set_defaults(fn=cmd_info)
    s = sub.add_parser("jobs"); s.add_argument("--pid", type=int, required=True); s.add_argument("--transcript")
    s.add_argument("--exclude-ancestors-of", type=int); s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_jobs)
    s = sub.add_parser("redact"); s.set_defaults(fn=cmd_redact)

    s = sub.add_parser("brief-init")
    for opt in ("--chain-dir", "--sid", "--host", "--cwd"):
        s.add_argument(opt, required=True)
    for opt in ("--transcript", "--name", "--root", "--target", "--pane", "--window", "--git"):
        s.add_argument(opt, default="")
    s.add_argument("--gen", type=int, required=True); s.add_argument("--claude-pid", type=int)
    s.add_argument("--exclude-ancestors-of", type=int); s.add_argument("--force", action="store_true")
    s.set_defaults(fn=cmd_brief_init)
    s = sub.add_parser("brief-check"); s.add_argument("brief"); s.set_defaults(fn=cmd_brief_check)

    s = sub.add_parser("prepare")
    s.add_argument("--chain-dir", required=True); s.add_argument("--gen", type=int, required=True)
    for opt in ("--successor-sid", "--successor-name", "--successor-host", "--successor-cwd", "--launcher"):
        s.add_argument(opt, required=True)
    for opt in ("--model", "--effort", "--claude-args", "--successor-env", "--goal", "--notify", "--ssh-alias",
                "--remote-chain-dir", "--passer-target"):
        s.add_argument(opt, default="")
    s.add_argument("--go", action="store_true"); s.add_argument("--no-goal", action="store_true")
    s.add_argument("--bypass", action="store_true", help="start the successor with permission checks off")
    s.add_argument("--no-kill", action="store_true"); s.add_argument("--exclude-ancestors-of", type=int)
    s.set_defaults(fn=cmd_prepare)

    s = sub.add_parser("history"); s.add_argument("chain_dir"); s.add_argument("gen", type=int)
    s.add_argument("--max-lines", type=int, default=0); s.set_defaults(fn=cmd_history)
    s = sub.add_parser("footer"); s.add_argument("chain_dir"); s.add_argument("gen", type=int)
    s.add_argument("--buffer-note", default=""); s.set_defaults(fn=cmd_footer)
    s = sub.add_parser("watch"); s.add_argument("chain_dir"); s.add_argument("gen", type=int)
    s.set_defaults(fn=cmd_watch)
    s = sub.add_parser("probe"); s.add_argument("sid"); s.set_defaults(fn=cmd_probe)
    s = sub.add_parser("adopt"); s.add_argument("chain_dir"); s.add_argument("gen", type=int)
    s.add_argument("--all", action="store_true"); s.add_argument("ids", nargs="*"); s.set_defaults(fn=cmd_adopt)
    s = sub.add_parser("keep"); s.add_argument("chain_dir"); s.add_argument("gen", type=int)
    s.set_defaults(fn=cmd_keep)
    s = sub.add_parser("mark"); s.add_argument("kind", choices=["passer", "chain"]); s.add_argument("--sid", required=True)
    for opt in ("--target", "--pane", "--brief", "--state", "--chain-name", "--chain-dir"):
        s.add_argument(opt, default="")
    s.add_argument("--gen", type=int, default=0); s.set_defaults(fn=cmd_mark)
    s = sub.add_parser("set"); s.add_argument("chain_dir"); s.add_argument("gen", type=int); s.add_argument("json")
    s.set_defaults(fn=cmd_set)
    s = sub.add_parser("get"); s.add_argument("chain_dir"); s.add_argument("gen", type=int); s.add_argument("key")
    s.set_defaults(fn=cmd_get)
    s = sub.add_parser("chain-of"); s.add_argument("sid"); s.set_defaults(fn=cmd_chain_of)
    s = sub.add_parser("status"); s.add_argument("chain_dir"); s.set_defaults(fn=cmd_status)

    a = p.parse_args(argv)
    try:
        return a.fn(a)
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main())
