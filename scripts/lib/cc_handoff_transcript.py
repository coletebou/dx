#!/usr/bin/env python3
"""cc_handoff_transcript: reading Claude Code session transcripts for cc-handoff.

  redact        scrub credentials (shapes, plus the literal values in ~/.env_secrets and
                secret-named environment variables) and personal data (emails, phones)
  Info          one pass over a transcript: name, /goal, first reply, open background
                tasks, todo list, sessions it messaged or launched, whether its turn ended
  render        the transcript for a human: user and assistant text in full, one line per
                tool call with its result cut to one line, thinking and injected text left out

Imported by cc_handoff.py; stdlib only, Python 3.8+.
"""

import gzip
import json
import os
import re
from pathlib import Path

HOME = Path.home()
CONFIG_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR") or HOME / ".claude")
DONE_STATES = ("completed", "failed", "killed", "stopped", "error", "cancelled", "canceled")


# ------------------------------------------------------------------ small helpers ----

def hhmm(stamp):
    """'2026-10-23T22:41:44.167Z' -> ('2026-10-23', '22:41Z'); anything else -> ('', '')."""
    m = re.match(r"(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})", stamp or "")
    return (m.group(1), m.group(2) + "Z") if m else ("", "")


def one_line(text):
    return " ".join(str(text).split())


def clip(text, width):
    text = one_line(text)
    return text if len(text) <= width else text[: max(width - 1, 1)] + "…"


def short_path(text):
    home = str(HOME)
    return text.replace(home + "/", "~/") if home and home != "/" else text


def find_transcript(sid):
    """The newest ~/.claude/projects/*/<sid>.jsonl, or None."""
    if not sid or not re.match(r"^[A-Za-z0-9._-]+$", sid):
        return None
    hits = list((CONFIG_DIR / "projects").glob(f"*/{sid}.jsonl"))
    if not hits:
        return None
    return str(max(hits, key=lambda p: p.stat().st_mtime))


def records(path):
    """Every JSON object in a JSONL file; torn or foreign lines are skipped."""
    opener = gzip.open if str(path).endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line[0] != "{":
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if isinstance(r, dict):
                yield r


# ------------------------------------------------------------------- redaction ----
# The shapes match scripts/reflections' redact() (keep them in step), plus a few more
# common token formats, plus the literal values in ~/.env_secrets and in any
# secret-named environment variable: a credential with no recognizable shape is still
# caught when it is one of ours.

_SECRET_PATTERNS = [
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----")),
    ("anthropic-key", re.compile(r"sk-ant-[A-Za-z0-9_-]{20,}")),
    ("openai-key", re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}")),
    ("aws-key", re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b")),
    ("bedrock-key", re.compile(r"\bABSK[A-Za-z0-9+/=]{20,}")),
    ("github-token", re.compile(r"\bgh[pousr]_[A-Za-z0-9]{36,}\b")),
    ("github-pat", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{40,}\b")),
    ("gitlab-token", re.compile(r"\bglpat-[A-Za-z0-9_-]{20,}")),
    ("xai-key", re.compile(r"\bxai-[A-Za-z0-9]{32,}")),
    ("slack-token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("jwt", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("bearer", re.compile(r"(?i)(authorization:\s*bearer\s+)[A-Za-z0-9._~+/-]{20,}=*")),
    ("url-credentials", re.compile(r"(\b[a-z][a-z0-9+.-]*://[^/\s:@]+:)[^@\s/]+(@)")),
]
_ASSIGNMENT = re.compile(
    r"(?i)\b([a-z0-9_.-]*(?:secret|token|password|passwd|passphrase|api_?key|access_?key"
    r"|private_?key|credential)[a-z0-9_.-]*)([\"']?\s*[=:]\s*)([\"']?)(?!\$|\[REDACTED)([^\s\"',;]{8,})")
_SECRET_NAME = re.compile(r"(?i)(secret|token|password|passwd|passphrase|api_?key|access_?key|private_?key|credential|bearer)")
# Personal data: email addresses and phone numbers (a customer's number can sit in a
# transcript after a read-only look at a config file). Kept: SSH remotes (git@host:...)
# and obviously non-personal addresses.
_EMAIL = re.compile(r"(?<![\w.%+-])[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?![\w.-]*[\w-])(?!:)")
_EMAIL_KEEP = re.compile(r"(?i)^(git|no-?reply|noreply\+[^@]*)@|@(example\.(com|org|net)|users\.noreply\.github\.com)$")
_PHONES = [
    re.compile(r"(?<![\w+])\+\d{1,3}[-. ]?\(?\d{2,4}\)?[-. ]?\d{3,4}[-. ]?\d{3,4}(?![\w])"),  # +1AAABBBCCCC, +1 AAA BBB CCCC
    re.compile(r"(?<![\w(-])\(\d{3}\) ?\d{3}[-. ]\d{4}(?![\w-])"),                             # (AAA) BBB-CCCC
    re.compile(r"(?<![\w.+-])\d{3}[-.]\d{3}[-.]\d{4}(?![\w.-])"),                                  # AAA-BBB-CCCC, AAA.BBB.CCCC
]
_known_values = None


def known_secret_values():
    """(value, NAME) pairs from ~/.env_secrets and secret-named env vars, longest first."""
    global _known_values
    if _known_values is not None:
        return _known_values
    found = {}
    path = Path(os.environ.get("CC_HANDOFF_SECRETS_FILE") or HOME / ".env_secrets")
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        lines = []
    for line in lines:
        m = re.match(r"\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if not m:
            continue
        name, val = m.group(1), m.group(2).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
            val = val[1:-1]
        if len(val.strip()) >= 12 and "$" not in val:
            found[val] = name
    for name, val in os.environ.items():
        if _SECRET_NAME.search(name) and len(val.strip()) >= 12:
            found.setdefault(val, name)
    _known_values = sorted(found.items(), key=lambda kv: -len(kv[0]))
    return _known_values


def redact(text):
    if not text:
        return text
    for val, name in known_secret_values():
        if val in text:
            text = text.replace(val, f"[REDACTED:{name}]")
    for label, pat in _SECRET_PATTERNS:
        if label == "bearer":
            text = pat.sub(lambda m: m.group(1) + "[REDACTED:bearer]", text)
        elif label == "url-credentials":
            text = pat.sub(lambda m: m.group(1) + "[REDACTED]" + m.group(2), text)
        else:
            text = pat.sub(f"[REDACTED:{label}]", text)
    text = _ASSIGNMENT.sub(lambda m: f"{m.group(1)}{m.group(2)}{m.group(3)}[REDACTED:assignment]", text)
    text = _EMAIL.sub(lambda m: m.group(0) if _EMAIL_KEEP.search(m.group(0)) else "[REDACTED:email]", text)
    for pat in _PHONES:
        text = pat.sub("[REDACTED:phone]", text)
    return text


# ---------------------------------------------------------------- transcript facts ----

def content_text(content):
    """A message or tool_result content (a string or a list of blocks) as plain text."""
    if isinstance(content, str):
        return content
    parts = []
    if isinstance(content, list):
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                parts.append(b.get("text") or "")
            elif b.get("type") == "image":
                parts.append("[image]")
            elif b.get("type") == "tool_reference":
                parts.append(f"[tool {b.get('tool_name', '')}]")
    return "\n".join(parts)


_NOTIF = re.compile(r"<task-notification>(.*?)</task-notification>", re.S)


def notifications(text):
    """(task id, status, summary) for each <task-notification> block that names a task."""
    out = []
    for body in _NOTIF.findall(text or ""):
        tid = re.search(r"<task-id>\s*([^<\s]+)\s*</task-id>", body)
        st = re.search(r"<status>\s*([^<\s]+)\s*</status>", body)
        sm = re.search(r"<summary>(.*?)</summary>", body, re.S)
        if tid:
            out.append((tid.group(1), (st.group(1) if st else "").lower(), one_line(sm.group(1)) if sm else ""))
    return out


def command_parts(text):
    """'<command-name>/goal</command-name>...<command-args>x</command-args>' -> ('/goal', 'x')."""
    name = re.search(r"<command-name>\s*(/?[^<\s]+)\s*</command-name>", text or "")
    if not name:
        return None
    args = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
    return name.group(1), (args.group(1).strip() if args else "")


def genuine_user_text(r):
    """Text the human typed in this record, or None (tool results, meta, commands, tags)."""
    if r.get("type") != "user" or r.get("isMeta") or r.get("isSidechain") or r.get("isCompactSummary"):
        return None
    c = (r.get("message") or {}).get("content")
    text = c if isinstance(c, str) else content_text(c) if isinstance(c, list) and not any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in c) else None
    if not text or not text.strip():
        return None
    if text.lstrip().startswith("<"):        # commands, notifications, cross-session messages, caveats
        return None
    return text


class Info:
    """One pass over a transcript collecting what a handoff needs."""

    def __init__(self):
        self.session_id = ""
        self.name = ""
        self.cwd = ""
        self.first_ts = ""
        self.last_ts = ""
        self.records = 0
        self.user_turns = 0
        self.tool_calls = 0
        self.first_prompt = ""
        self.first_response = False
        self.first_response_ts = ""
        self.goal = None              # {"condition", "met"}
        self.goal_cleared = False
        self.tasks = {}               # id -> {"id","kind","label","command","started","status"}
        self.pending_bg = {}          # tool_use_id -> (kind, label, command)
        self.stopped_ids = set()
        self.todos = None
        self.messaged = []            # drover_send targets, in order, unique
        self.launched = []            # drover_launch names
        self.last_user_ts = ""        # the last text the human typed
        self.turn_ended = False       # the last meaningful record closes a turn

    def feed(self, r):
        self.records += 1
        t = r.get("type")
        ts = r.get("timestamp") or ""
        if r.get("sessionId") and not self.session_id:
            self.session_id = r["sessionId"]
        if r.get("cwd") and not self.cwd:
            self.cwd = r["cwd"]
        if ts:
            self.first_ts = self.first_ts or ts
            self.last_ts = ts
        if t == "agent-name" and r.get("agentName"):
            self.name = r["agentName"]
        elif t == "custom-title" and r.get("customTitle") and not self.name:
            self.name = r["customTitle"]
        if r.get("isSidechain"):
            return
        if t == "user":
            self._user(r, ts)
        elif t == "assistant":
            self._assistant(r, ts)
        elif t == "attachment":
            a = r.get("attachment") or {}
            if a.get("type") == "goal_status" and a.get("condition"):
                self.goal = {"condition": a.get("condition"), "met": bool(a.get("met"))}
                self.goal_cleared = False
            elif a.get("type") == "queued_command":
                prompt = a.get("prompt") if isinstance(a.get("prompt"), str) else ""
                self._notes(prompt)
                # Typed while the agent was busy. Claude Code labels the source (human, peer,
                # task-notification); without a label, notifications and peers start with a tag.
                origin = (a.get("origin") or {}).get("kind") if isinstance(a.get("origin"), dict) else None
                body = prompt.lstrip()
                if origin == "human" or (origin is None and body and not body.startswith("<")):
                    self.last_user_ts = ts
        elif t == "queue-operation":
            self._notes(r.get("content") or "")
        elif t == "system":
            if r.get("subtype") in ("turn_duration", "stop_hook_summary"):
                self.turn_ended = True

    def _notes(self, text):
        for tid, status, _ in notifications(text):
            if status in DONE_STATES and tid in self.tasks:
                self.tasks[tid]["status"] = status

    def _user(self, r, ts):
        self.turn_ended = False
        c = (r.get("message") or {}).get("content")
        text = genuine_user_text(r)
        if text is not None:
            self.user_turns += 1
            self.last_user_ts = ts
            if not self.first_prompt:
                self.first_prompt = text
        if isinstance(c, str):
            cmd = command_parts(c)
            if cmd and not r.get("isMeta"):
                self.last_user_ts = ts          # a slash command someone typed
            if cmd and cmd[0] == "/goal":
                if cmd[1].lower() in ("clear", "off", "stop", "none", ""):
                    self.goal_cleared = True
                elif not self.first_prompt:
                    self.first_prompt = f"/goal {cmd[1]}"
                if cmd[1] and not self.user_turns:
                    self.user_turns += 1
            self._notes(c)
            return
        if not isinstance(c, list):
            return
        raw = r.get("toolUseResult")
        tur = raw if isinstance(raw, dict) else {}
        for b in c:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                self._notes(b.get("text") or "")
            if b.get("type") != "tool_result":
                continue
            tu = b.get("tool_use_id")
            if tu in self.pending_bg:
                kind, label, command = self.pending_bg.pop(tu)
                body = content_text(b.get("content"))
                tid = tur.get("backgroundTaskId") or tur.get("agentId") or tur.get("taskId") or ""
                if not tid:
                    m = re.search(r"running in background with ID: ([A-Za-z0-9_-]+)", body)
                    tid = m.group(1) if m else ""
                if tid and not b.get("is_error"):
                    self.tasks[tid] = {"id": tid, "kind": kind, "label": label, "command": command,
                                       "started": ts, "status": "running"}

    def _assistant(self, r, ts):
        self.turn_ended = False
        msg = r.get("message") or {}
        content = msg.get("content")
        blocks = content if isinstance(content, list) else []
        if not r.get("isApiErrorMessage") and any(
                isinstance(b, dict) and b.get("type") in ("text", "tool_use") for b in blocks):
            if not self.first_response:
                self.first_response, self.first_response_ts = True, ts
        for b in blocks:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            self.tool_calls += 1
            name, raw = b.get("name") or "", b.get("input")
            inp = raw if isinstance(raw, dict) else {}
            if inp.get("run_in_background") or name in ("Workflow",):
                kind = "bash" if name == "Bash" else "agent" if name in ("Agent", "Task") else name.lower()
                label = inp.get("description") or inp.get("command") or inp.get("prompt") or name
                self.pending_bg[b.get("id")] = (kind, clip(label, 160), inp.get("command") or "")
            if name in ("TaskStop", "KillShell", "KillBash"):
                tid = inp.get("task_id") or inp.get("shell_id") or inp.get("bash_id") or inp.get("id")
                if tid and tid in self.tasks:
                    self.tasks[tid]["status"] = "stopped"
            if name == "TodoWrite" and isinstance(inp.get("todos"), list):
                self.todos = inp["todos"]
            if name.endswith("drover_send") and inp.get("id"):
                target = inp["id"] + (f"@{inp['host']}" if inp.get("host") else "")
                if target not in self.messaged:
                    self.messaged.append(target)
            if name.endswith("drover_launch") and inp.get("name"):
                if inp["name"] not in self.launched:
                    self.launched.append(inp["name"])
        if msg.get("stop_reason") == "end_turn":
            self.turn_ended = True

    def open_tasks(self):
        return [t for t in self.tasks.values() if t["status"] == "running"]

    def active_goal(self):
        """The /goal still in force, without the handoff prompt that rode along with it: /goal
        takes every word after it as the condition, so a successor's condition also holds the
        inline summary it was started with (it snowballed across generations, 2026-10-24)."""
        if self.goal and not self.goal["met"] and not self.goal_cleared:
            cond = self.goal["condition"]
            cut = cond.find("[cc-handoff]")
            return (cond[:cut] if cut >= 0 else cond).strip() or None
        return None

    def as_dict(self):
        return {
            "session_id": self.session_id, "name": self.name, "cwd": self.cwd,
            "first_ts": self.first_ts, "last_ts": self.last_ts, "records": self.records,
            "user_turns": self.user_turns, "tool_calls": self.tool_calls,
            "first_prompt": self.first_prompt, "first_response": self.first_response,
            "first_response_ts": self.first_response_ts, "goal": self.active_goal(),
            "open_tasks": self.open_tasks(), "todos": self.todos, "messaged": self.messaged,
            "launched": self.launched, "last_user_ts": self.last_user_ts, "turn_ended": self.turn_ended,
        }


def transcript_info(path):
    info = Info()
    for r in records(path):
        info.feed(r)
    return info


# ------------------------------------------------------------------ render ----

def tool_label(name, inp):
    inp = inp if isinstance(inp, dict) else {}
    if name == "Bash":
        label = short_path(inp.get("command", ""))
        if inp.get("description"):
            label += f"   # {inp['description']}"
        if inp.get("run_in_background"):
            label += "   [background]"
        return label
    if name in ("Read", "Edit", "MultiEdit", "Write", "NotebookEdit"):
        path = short_path(inp.get("file_path") or inp.get("notebook_path") or "")
        offset, limit = inp.get("offset"), inp.get("limit")
        if offset or limit:
            try:
                start = int(offset or 1)
                path += f":{start}" + (f"-{start + int(limit) - 1}" if limit else "")
            except (TypeError, ValueError):
                pass
        return path
    if name == "Grep":
        return f"{inp.get('pattern', '')}  {short_path(inp.get('path') or inp.get('glob') or '')}".strip()
    if name == "Glob":
        return inp.get("pattern", "")
    if name in ("WebFetch", "WebSearch"):
        return inp.get("url") or inp.get("query") or ""
    if name in ("Agent", "Task"):
        bits = [inp.get("subagent_type") or "", inp.get("description") or clip(inp.get("prompt", ""), 80)]
        if inp.get("run_in_background"):
            bits.append("[background]")
        return " ".join(b for b in bits if b)
    if name == "Skill":
        return f"{inp.get('skill', '')} {inp.get('args', '')}".strip()
    if name == "TodoWrite":
        todos = inp.get("todos") or []
        done = sum(1 for t in todos if isinstance(t, dict) and t.get("status") == "completed")
        return f"{len(todos)} todos, {done} done"
    if name == "ToolSearch":
        return inp.get("query", "")
    if name.startswith("mcp__"):
        short = name.split("__")[-1]
        keys = ("id", "host", "name", "target", "query", "op")
        bits = [f"{k}={inp[k]}" for k in keys if isinstance(inp.get(k), (str, int))]
        return f"{short} {' '.join(bits)}".strip()
    return json.dumps(inp, ensure_ascii=False)


def result_summary(block):
    text = redact(content_text(block.get("content")))   # before clipping: a cut secret no longer matches
    lines = [ln for ln in text.splitlines() if ln.strip()]
    if not lines:
        return "✗ (error, no output)" if block.get("is_error") else "(no output)"
    head = clip(lines[0], 160)
    more = f" (+{len(lines) - 1} lines)" if len(lines) > 1 else ""
    return ("✗ " if block.get("is_error") else "") + head + more


class Renderer:
    def __init__(self, out, result_lines=0, user_max=400):
        self.out = out
        self.result_lines = result_lines
        self.user_max = user_max
        self.speaker = None
        self.day = ""
        self.pending = []             # [tool_use_id, label line, result or None]
        self.lines = 0

    def emit(self, text=""):
        for ln in redact(text).split("\n"):
            self.out.write(ln.rstrip() + "\n")
            self.lines += 1

    def flush_tools(self):
        for _tid, label, result in self.pending:
            self.emit(f"  ▸ {label}  ⇒ {result if result is not None else '(no result recorded)'}")
        self.pending = []

    def header(self, who, ts):
        day, at = hhmm(ts)
        if day and day != self.day:
            self.flush_tools()
            self.emit(f"\n──────── {day} ────────")
            self.day = day
        if who != self.speaker:
            self.flush_tools()
            self.emit(f"\n[{at or '--:--'}] {who}")
            self.speaker = who

    def block_text(self, text, cap):
        lines = text.rstrip("\n").split("\n")
        if cap and len(lines) > cap:
            lines = lines[:cap] + [f"… ({len(lines) - cap} more lines in the raw transcript)"]
        self.emit("\n".join(lines))

    def note(self, ts, text):
        self.header("·", ts)
        self.emit(f"  {text}")

    def feed(self, r):
        if r.get("isSidechain"):
            return
        t, ts = r.get("type"), r.get("timestamp") or ""
        if t == "user":
            self._user(r, ts)
        elif t == "assistant":
            self._assistant(r, ts)
        elif t == "attachment":
            a = r.get("attachment") or {}
            if a.get("type") == "queued_command":
                self._queued(a.get("prompt") or "", ts)
        elif t == "system":
            sub = r.get("subtype")
            if sub == "compact_boundary":
                self.note(ts, "──── context compacted here ────")
            elif sub == "local_command":
                cmd = command_parts(r.get("content") or "")
                if cmd:
                    self.note(ts, f"{cmd[0]} {clip(cmd[1], 300)}".strip())
            elif sub == "scheduled_task_fire":
                self.note(ts, f"⏰ {clip(r.get('content') or '', 200)}")
            elif sub == "api_error":
                self.note(ts, f"⚠ API error {clip(json.dumps(r.get('error') or r.get('content') or ''), 200)}")

    def _queued(self, text, ts):
        notes = notifications(text)
        if notes:
            for tid, status, summary in notes:
                self.note(ts, f"⚑ task {tid} {status}: {clip(summary, 200)}")
            return
        m = re.match(r"\s*<cross-session-message[^>]*from-name=\"([^\"]*)\"[^>]*>(.*?)</cross-session-message>", text, re.S)
        if m:
            self.header(f"MESSAGE from {m.group(1)} (another session)", ts)
            self.block_text(m.group(2).strip(), self.user_max)
            return
        self.header("USER (typed while the agent worked)", ts)
        self.block_text(text, self.user_max)

    def _user(self, r, ts):
        msg = r.get("message") or {}
        c = msg.get("content")
        if r.get("isCompactSummary"):
            self.header("SUMMARY of the conversation before compaction", ts)
            self.block_text(content_text(c), 60)
            return
        if r.get("isMeta"):
            return
        if isinstance(c, str):
            cmd = command_parts(c)
            if cmd:
                self.header("USER", ts)
                self.emit(f"{cmd[0]} {cmd[1]}".rstrip())
                return
            if "<task-notification>" in c:
                self._queued(c, ts)
                return
            if c.lstrip().startswith("<cross-session-message"):
                self._queued(c, ts)
                return
            if c.lstrip().startswith("<local-command") or not c.strip():
                return
            self.header("USER", ts)
            self.block_text(c, self.user_max)
            return
        if not isinstance(c, list):
            return
        texts = []
        for b in c:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_result":
                for p in self.pending:
                    if p[0] == b.get("tool_use_id"):
                        p[2] = result_summary(b)
                        if self.result_lines:
                            body = [ln for ln in redact(content_text(b.get("content"))).splitlines() if ln.strip()]
                            p[2] += "".join(f"\n      {clip(ln, 200)}" for ln in body[1:1 + self.result_lines])
            elif b.get("type") in ("text", "image"):
                texts.append(content_text([b]))
        if texts:
            joined = "\n".join(texts).strip()
            if joined and not joined.startswith("<"):
                self.header("USER", ts)
                self.block_text(joined, self.user_max)

    def _assistant(self, r, ts):
        msg = r.get("message") or {}
        content = msg.get("content")
        blocks = content if isinstance(content, list) else []
        if r.get("isApiErrorMessage"):
            self.note(ts, f"⚠ API error: {clip(content_text(blocks), 300)}")
            return
        for b in blocks:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text" and (b.get("text") or "").strip():
                self.header("ASSISTANT", ts)
                self.flush_tools()
                self.block_text(b["text"], 0)
            elif b.get("type") == "tool_use":
                self.header("ASSISTANT", ts)
                label = clip(redact(tool_label(b.get("name") or "", b.get("input"))), 240)
                self.pending.append([b.get("id"), f"{b.get('name')}: {label}", None])

    def finish(self):
        self.flush_tools()


def render(path, out, host="", result_lines=0):
    info = transcript_info(path)
    first_day, first_at = hhmm(info.first_ts)
    last_day, last_at = hhmm(info.last_ts)
    head = [
        "# Claude Code session transcript, rendered for a handoff by cc-handoff",
        f"# Session {info.session_id or '?'}" + (f' "{info.name}"' if info.name else "")
        + (f" on {host}" if host else "") + f", {first_day} {first_at} to {last_day} {last_at}",
        f"# {info.user_turns} user turns, {info.tool_calls} tool calls, {info.records} records. Raw JSONL: {path}",
        "# Shown: user and assistant text in full, one line per tool call (=> its result, cut to one line).",
        "# Left out: thinking, hook and system-injected text, tool output beyond its first line.",
        "# Secrets are redacted. Read the raw JSONL when a detail matters.",
    ]
    goal = info.active_goal()
    if goal:
        head.append(f"# Active /goal: {clip(goal, 400)}")
    rd = Renderer(out, result_lines=result_lines)
    rd.emit("\n".join(head))
    for r in records(path):
        rd.feed(r)
    rd.finish()
    rd.emit("\n# End of transcript.")
    return rd.lines
