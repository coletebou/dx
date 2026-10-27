#!/usr/bin/env python3
"""session_reflector — background reflection of a session's transcript into `reflections`.

Compaction summarises a conversation to keep it going; it is not written to keep what
the session learned, decided or left open. This captures that, from the full transcript:
at checkpoints as the context window fills (the context advisor's `stage` trigger: a cheap
Haiku pass at 20%, Sonnet at 40/60/80% of the model window), right before compaction
(PreCompact) and when the session ends (SessionEnd) — without ever blocking the session:

  hook / spawn ── validate ── double-fork + setsid ── return in ~50 ms
                                      │
                         (detached) condense transcript since the last run
                                      │   user prompts, assistant text, tool calls and
                                      │   errors; tool output dropped, long text clipped
                                      ▼
                         reflections candidates  (ids of related open/stale/closed items)
                                      ▼
                         claude-consolidate (model routing) ── JSON {summary, updates, items}
                                      ▼
                         reflections apply   (close / reopen / edit what the excerpt settled)
                         reflections add --batch  (only what the store does not already hold)
                         one rolling session-summary note per session, edited in place

Works on Claude Code and Codex transcripts (Codex >= 0.157 has PreCompact/SessionEnd).
Each session reflects incrementally: a byte offset per session means a SessionEnd run
after a PreCompact run only reads what came after it.

Models, by tier: haiku → $REFLECTOR_HAIKU_MODEL, else the `haiku` alias; sonnet →
$REFLECTOR_SONNET_MODEL, else `sonnet`; deep (precompact, sessionend, advisor, manual) →
$REFLECTOR_MODEL, else $CLAUDE_CONSOLIDATE_MODEL, else `sonnet`. Any of them may be a full
model id (a Bedrock or Vertex id, say) when that is how this machine reaches Claude. A failed
call retries once on the tier's alias, which takes the machine's default route.

Guards: REFLECTOR_DISABLE=1 or AGENT_HOOK_CHILD=1 (set for every child this starts, so
the child's own SessionEnd can't start a reflection of a reflection); subagents; `-p`
automation sessions (entrypoint sdk-cli) unless REFLECTOR_INCLUDE_PRINT=1; too little new
content; one reflection per session at a time (a per-session lock: a stage run skips when
it is held, precompact/sessionend wait for it so the end of a session is never dropped).

Data boundary: MEMORY_BOUNDARY_CMD (shared with claude-consolidate and session-analyzer; see
scripts/lib/memory-boundary.sh) answers "is this session restricted?" for a session whose data
must never reach the reflection model or the memory tree (a restricted model route, a client's
data). It runs through `sh -c` with the session's environment plus MEMORY_BOUNDARY_TOOL=reflector,
MEMORY_BOUNDARY_PATH (the transcript), MEMORY_BOUNDARY_SESSION and MEMORY_BOUNDARY_TRIGGER.
Exit 0 means restricted, exit 1 means go ahead, and anything else (not found, a crash, a
timeout of MEMORY_BOUNDARY_TIMEOUT seconds, default 20) also means restricted, so a broken
check fails closed. A restricted session's transcript so far is marked consumed, so resuming
it in an unrestricted session later reflects only what comes after.

CLI:
  session_reflector.py hook <precompact|sessionend>     (hook stdin JSON; detaches)
  session_reflector.py spawn --transcript P --session S --cwd D [--trigger T]
                             [--tier haiku|sonnet|deep] [--stage-pct N]          (detaches)
  session_reflector.py run   --transcript P [--session S] [--cwd D] [--trigger manual]
                             [--tier …] [--dry-run]   (foreground; --dry-run prints prompt, no LLM)
  session_reflector.py status                           (recent runs)
  session_reflector.py dedupe --repo R [--apply]        (drop near-duplicate open items; haiku)
"""

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()
# Sibling tools come from this checkout (base/claude/ → repo root), independent of
# REFLECTIONS_DOTFILES, which only relocates the reflections *data* tree.
REPO = Path(__file__).resolve().parents[2]
STATE_DIR = Path(os.environ.get("REFLECTOR_STATE_DIR") or HOME / ".claude/state/reflector")
LOG_PATH = Path(os.environ.get("REFLECTOR_LOG") or HOME / ".claude/logs/session-reflector.jsonl")
REFLECTIONS = os.environ.get("REFLECTIONS_BIN") or str(REPO / "scripts/reflections")
CONSOLIDATE = os.environ.get("CLAUDE_CONSOLIDATE_BIN") or str(REPO / "scripts/claude-consolidate")

MAX_INPUT_CHARS = int(os.environ.get("REFLECTOR_MAX_CHARS", 160_000))
MIN_NEW_CHARS = {"precompact": 3_000, "sessionend": 8_000, "advisor": 12_000, "stage": 6_000, "manual": 0}
MAX_ITEMS = {"haiku": 6, "sonnet": 8, "deep": 10}
MAX_UPDATES = 25
KINDS = ("action", "question", "handoff", "learning", "decision", "gotcha", "idea")
UPDATE_OPS = ("done", "drop", "reopen", "edit")
CLIP = {"user": 2_000, "assistant": 1_500, "tool": 240, "error": 500, "summary": 4_000}
TRIGGER_WHY = {
    "precompact": "the session is about to be compacted; keep what the compaction summary may drop",
    "sessionend": "the session just ended",
    "advisor": "the context window is filling up; capture the session before it is compacted",
    "stage": "a checkpoint: the context window passed {pct}% of the model's window, so record the "
             "session so far while all of it is still on record",
    "manual": "requested explicitly",
}
# tier → (env override, the alias it defaults to and retries on).
TIERS = {"haiku": ("REFLECTOR_HAIKU_MODEL", "haiku"), "sonnet": ("REFLECTOR_SONNET_MODEL", "sonnet")}
# A stage run can wait for the next stage; the end of a session cannot.
LOCK_WAIT = {"precompact": 900, "sessionend": 900, "manual": 900}
SUMMARY_TAG = "session-summary"
# Every child we start gets these, so none of our hooks run inside a reflection.
CHILD_GUARDS = {"AGENT_HOOK_CHILD": "1", "REFLECTOR_DISABLE": "1", "API_RECOVERY_DISABLE": "1",
                "CONTEXT_ADVISOR_DISABLE": "1"}


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(rec):
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a") as f:
            f.write(json.dumps({"ts": now_iso(), **rec}) + "\n")
    except OSError:
        pass


def clip(text, n):
    text = (text or "").strip()
    if len(text) <= n:
        return text
    head = int(n * 0.7)
    return f"{text[:head]} …[{len(text) - n} chars]… {text[-(n - head):]}"


def boundary_skip(transcript, session_id="", trigger="", tool="reflector"):
    """True when MEMORY_BOUNDARY_CMD says this session must never be reflected (see the module
    docstring). Exit 1 is the only answer that lets a reflection run. The context advisor asks
    the same question before it sends excerpts to Jev, as tool "context-advisor"."""
    cmd = os.environ.get("MEMORY_BOUNDARY_CMD", "").strip()
    if not cmd:
        return False
    env = {**os.environ, **CHILD_GUARDS, "MEMORY_BOUNDARY_TOOL": tool,
           "MEMORY_BOUNDARY_PATH": str(transcript or ""), "MEMORY_BOUNDARY_SESSION": session_id or "",
           "MEMORY_BOUNDARY_TRIGGER": trigger or ""}
    try:
        r = subprocess.run(["sh", "-c", cmd], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=float(os.environ.get("MEMORY_BOUNDARY_TIMEOUT") or 20))
    except (OSError, ValueError, subprocess.SubprocessError):
        return True
    return r.returncode != 1


def disabled():
    return os.environ.get("REFLECTOR_DISABLE") == "1" or os.environ.get("AGENT_HOOK_CHILD") == "1"


# ----------------------------------------------------------- transcripts -----

def read_new_lines(path, offset):
    """Complete lines after `offset`; returns (lines, new_offset at a line boundary)."""
    size = os.path.getsize(path)
    if offset > size:
        offset = 0  # file was replaced; start over
    with open(path, "rb") as f:
        f.seek(offset)
        data = f.read()
    end = data.rfind(b"\n")
    if end == -1:
        return [], offset
    chunk = data[: end + 1]
    return chunk.decode("utf-8", "replace").splitlines(), offset + len(chunk)


def _text_blocks(content):
    if isinstance(content, str):
        return [content]
    if not isinstance(content, list):
        return []
    return [b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") in ("text", "input_text", "output_text")]


def _tool_args(inp):
    if not isinstance(inp, dict):
        return clip(str(inp), CLIP["tool"])
    for key in ("command", "file_path", "path", "pattern", "url", "query", "skill", "description", "prompt"):
        if inp.get(key):
            return clip(f"{key}={inp[key]}", CLIP["tool"])
    return clip(json.dumps(inp)[:CLIP["tool"]], CLIP["tool"])


_HARNESS = re.compile(r"^<(system-reminder|local-command-(stdout|caveat)|task-notification|user-prompt-submit-hook)")


def condense_claude(entries):
    out, entrypoint = [], None
    for e in entries:
        if e.get("isSidechain"):
            continue
        entrypoint = entrypoint or e.get("entrypoint")
        msg = e.get("message") or {}
        content = msg.get("content")
        if e.get("type") == "user":
            if e.get("isCompactSummary"):
                out.append("COMPACTION SUMMARY: " + clip(" ".join(_text_blocks(content)), CLIP["summary"]))
                continue
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                        text = " ".join(_text_blocks(b.get("content")))
                        out.append("TOOL ERROR: " + clip(text, CLIP["error"]))
            if e.get("isMeta"):
                continue
            for t in _text_blocks(content):
                t = t.strip()
                if not t:
                    continue
                m = re.search(r"<command-name>([^<]*)</command-name>", t)
                if m:
                    args = re.search(r"<command-args>([\s\S]*?)</command-args>", t)
                    out.append(f"USER: {m.group(1).strip()} {clip(args.group(1), 400) if args else ''}".rstrip())
                elif _HARNESS.match(t):
                    if "Stop hook feedback" in t or "api-error-recovery" in t:
                        out.append("[harness] " + clip(re.sub(r"<[^>]+>", " ", t), 300))
                else:
                    out.append("USER: " + clip(t, CLIP["user"]))
        elif e.get("type") == "assistant" and isinstance(content, list):
            if e.get("isApiErrorMessage"):
                out.append("API ERROR: " + clip(" ".join(_text_blocks(content)), 300))
                continue
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    out.append("ASSISTANT: " + clip(b["text"], CLIP["assistant"]))
                elif b.get("type") == "tool_use":
                    out.append(f"TOOL {b.get('name')}: {_tool_args(b.get('input'))}")
    return out, entrypoint


_CODEX_INJECTED = re.compile(r"^(<[A-Za-z_][\w-]*[\s>]|# AGENTS\.md instructions|# Files mentioned by the user)")


def condense_codex(entries):
    out = []
    for e in entries:
        p = e.get("payload") or {}
        if e.get("type") == "compacted":
            hist = p.get("replacement_history") or []
            text = " ".join(" ".join(_text_blocks(h.get("content"))) for h in hist if isinstance(h, dict))
            out.append("COMPACTION SUMMARY: " + clip(text, CLIP["summary"]))
        elif e.get("type") == "response_item":
            if p.get("type") == "message":
                text = " ".join(_text_blocks(p.get("content"))).strip()
                if not text:
                    continue
                if p.get("role") == "user":
                    if _CODEX_INJECTED.match(text):
                        continue
                    out.append("USER: " + clip(text, CLIP["user"]))
                elif p.get("role") == "assistant":
                    out.append("ASSISTANT: " + clip(text, CLIP["assistant"]))
            elif str(p.get("type", "")).endswith("_call"):
                args = p.get("arguments") or p.get("input") or ""
                try:
                    args = json.loads(args) if isinstance(args, str) and args.startswith("{") else args
                except ValueError:
                    pass
                out.append(f"TOOL {p.get('name') or p.get('type')}: {_tool_args(args)}")
    return out, "codex"


def condense(path, offset):
    lines, new_offset = read_new_lines(path, offset)
    entries = []
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict):
            entries.append(e)
    is_codex = any(e.get("type") in ("session_meta", "response_item") for e in entries[:50])
    parts, entrypoint = condense_codex(entries) if is_codex else condense_claude(entries)
    text = "\n".join(parts)
    if len(text) > MAX_INPUT_CHARS:  # keep the start for context, most of the end for state
        head = int(MAX_INPUT_CHARS * 0.15)
        text = text[:head] + "\n…[middle of the session omitted]…\n" + text[-(MAX_INPUT_CHARS - head):]
    return text, new_offset, entrypoint, sum(1 for p in parts if p.startswith("USER: "))


def request_before(path, offset, floor=0, window=2 * 1024 * 1024):
    """The last human request before `offset` — the goal a continuation segment is
    still working on, when an earlier reflection already consumed the prompt. Never
    reads before `floor`: the end of a span the data boundary kept out (skip_span)."""
    try:
        with open(path, "rb") as f:
            start = max(floor, offset - window)
            if start >= offset:
                return ""
            f.seek(start)
            lines = f.read(offset - start).decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    if start > floor:
        lines = lines[1:]  # partial first line (the floor is a line boundary)
    entries = []
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict):
            entries.append(e)
    is_codex = any(e.get("type") in ("session_meta", "response_item") for e in entries[:50])
    parts, _ = condense_codex(entries) if is_codex else condense_claude(entries)
    return next((p[len("USER: "):] for p in reversed(parts) if p.startswith("USER: ")), "")


# ---------------------------------------------------------------- model ------

def pick_model(tier="deep"):
    """The model for a tier; see the module docstring."""
    if tier in TIERS:
        env, alias = TIERS[tier]
        return os.environ.get(env) or alias
    return os.environ.get("REFLECTOR_MODEL") or os.environ.get("CLAUDE_CONSOLIDATE_MODEL") or "sonnet"


def fallback_model(tier):
    """The alias a failed call retries on: the machine's default route."""
    return TIERS[tier][1] if tier in TIERS else "sonnet"


def child_env():
    """The model call's environment: no session bindings, every hook guard, and fewer
    of Claude Code's own request retries."""
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("CLAUDE_CODE_") and k not in ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_ENV_FILE")}
    env.update(CHILD_GUARDS, CLAUDE_CODE_MAX_RETRIES="3")
    return env


def consolidate(prompt_text, model):
    with tempfile.TemporaryDirectory(prefix="reflector-") as tmp:
        prompt = Path(tmp) / "prompt.md"
        out = Path(tmp) / "reply.md"
        prompt.write_text(prompt_text)
        r = subprocess.run([CONSOLIDATE, "--prompt", str(prompt), "--output", str(out), "--model", model,
                            "--timeout", os.environ.get("REFLECTOR_TIMEOUT", "600")],
                           cwd=tmp, env=child_env(), capture_output=True, text=True, timeout=900)
        if r.returncode != 0 or not out.exists():
            raise RuntimeError(f"claude-consolidate exit {r.returncode}: {clip(r.stderr, 400)}")
        return out.read_text()


def reply_json(reply):
    text = re.sub(r"^```(?:json)?\s*|\s*```\s*$", "", reply.strip())
    start, end = text.find("{"), text.rfind("}")
    if start == -1 or end <= start:
        raise ValueError("no JSON object in reply")
    data = json.loads(text[start: end + 1])
    if not isinstance(data, dict):
        raise ValueError("reply is not a JSON object")
    return data


def parse_updates(data, allowed_ids):
    """The reply's reconcile ops, kept only for ids the prompt offered. A status change must
    say why (its note is the evidence a person reads later); an edit must change something."""
    allowed, out = set(allowed_ids), []
    for up in data.get("updates") or []:
        if not isinstance(up, dict):
            continue
        op, iid = str(up.get("op") or "").lower(), str(up.get("id") or "").strip().lstrip("#")
        if op not in UPDATE_OPS or iid not in allowed:
            continue
        row = {"op": op, "id": iid}
        note = " ".join(str(up.get("note") or "").split())[:600]
        if note:
            row["note"] = note
        if op == "edit":
            if up.get("title"):
                row["title"] = " ".join(str(up["title"]).split())[:200]
            if up.get("body"):
                row["body"] = str(up["body"])[:4000]
            if isinstance(up.get("priority"), int) and 1 <= up["priority"] <= 5:
                row["priority"] = up["priority"]
            if not {"title", "body", "priority"} & row.keys():
                continue
        elif not note:
            continue
        out.append(row)
    return out[:MAX_UPDATES]


def parse_reply(reply, max_items=MAX_ITEMS["deep"]):
    data = reply_json(reply)
    items = []
    for it in data.get("items") or []:
        if not isinstance(it, dict):
            continue
        kind = str(it.get("kind", "")).lower()
        title = " ".join(str(it.get("title") or "").split())
        if kind not in KINDS or not title:
            continue
        row = {"kind": kind, "title": title[:200], "body": str(it.get("body") or "")[:4000],
               "tags": [str(t)[:40] for t in (it.get("tags") or [])][:6]}
        if kind == "action" and isinstance(it.get("priority"), int) and 1 <= it["priority"] <= 5:
            row["priority"] = it["priority"]
        items.append(row)
    return str(data.get("topic") or "").strip()[:90], str(data.get("summary") or "").strip(), items[:max_items]


def store_lines(candidates):
    lines = []
    for c in candidates:
        age = f"{c.get('age_days', 0):g}d"
        mine = "; this session" if c.get("this_session") else ""
        lines.append(f"- [{c['kind']}/{c['status']}] {c['title']}  (#{c['id']}; {age}{mine})")
        if c.get("body"):
            lines.append(f"    {c['body']}")
    return "\n".join(lines) or "(none)"


def build_prompt(condensed, repo, why, candidates, summary_so_far="", max_items=MAX_ITEMS["deep"]):
    earlier = (f"\nSUMMARY OF THIS SESSION SO FAR (written by an earlier checkpoint; fold it into your summary):\n"
               f"{summary_so_far}\n") if summary_so_far else ""
    return f"""You keep the durable record of one AI coding session — what it learned, decided and left
open — in a store that the next session and other agents read. Below is a condensed excerpt of
its transcript (tool output omitted, long text clipped). Repo: {repo}. Why now: {why}.
{earlier}
STORE — items already recorded for {repo} that may relate to this excerpt (kind/status, then
#id and age; "this session" marks items this same session recorded at an earlier checkpoint):
{store_lines(candidates)}

Return ONLY a JSON object — no prose, no code fences:
{{
  "topic": "what the whole session is about, <= 80 chars",
  "summary": "4-8 sentences on the WHOLE session so far: goal, what got done, where it stands, what comes next",
  "updates": [
    {{"op": "done|drop|reopen|edit", "id": "an id from STORE",
      "note": "the evidence in this excerpt: commit, command, file, test result, or the user's words",
      "title": "edit only", "body": "edit only", "priority": "edit only, 1-5"}}
  ],
  "items": [
    {{"kind": "action|question|decision|gotcha|learning|idea",
      "title": "one specific line, <= 120 chars (name files, commands, components)",
      "body": "2-5 sentences of evidence: paths, commands, error text, and why it matters",
      "tags": ["2-4", "short", "topics"],
      "priority": "action only, 1-5 (see below)"}}
  ]
}}

First reconcile the STORE with this excerpt:
- done: the excerpt shows that item's work finished (verified, merged, shipped, answered).
- drop: the excerpt shows it was abandoned, superseded or wrong (the user changed course).
- reopen: a done, dropped or stale item is clearly live again (it regressed, or work resumed).
- edit: the same work whose title, body or priority is now out of date — fix it instead of adding
  a near-copy.
Only use ids listed in STORE, and only when the excerpt settles it; when unsure, leave it alone.
Every done/drop/reopen needs its evidence in "note".

Then add at most {max_items} NEW items, only for what the STORE does not already cover (same
meaning, even if worded differently); an empty list is fine and fewer, sharper items beat padding:
- action: work still unfinished at the END of this excerpt that the user asked for or the agent
  explicitly deferred. Never finished work, never the step the agent was about to take anyway.
  Priority is calibrated, most items are 3: 1 = urgent and rare (a live security exposure, an
  outage, data loss, or it blocks the user right now), 2 = important this week, 3 = normal
  backlog, 4 = low, 5 = someday. Session sequencing is not priority.
- question: a decision or answer the session is waiting on from the user.
- decision: a choice that was made, with its reason, so it is not re-litigated.
- gotcha / learning: a non-obvious fact verified in this session (tool quirk, environment fact,
  root cause) that would save the next session time. Not general knowledge, not what the code shows.
- idea: a promising follow-up that was mentioned but not started.
Never copy secrets, tokens, passwords or credentials into any field.

TRANSCRIPT EXCERPT:
{condensed}
"""


# ------------------------------------------------------------- reflection -----

def run_reflections(args, cwd, stdin=None):
    r = subprocess.run([REFLECTIONS, *args], cwd=cwd, input=stdin, capture_output=True, text=True,
                       timeout=60, env={**os.environ, **CHILD_GUARDS})
    if r.returncode != 0:
        raise RuntimeError(f"reflections {args[0]} failed: {clip(r.stderr, 300)}")
    return r.stdout


def acquire(lock, trigger):
    """The per-session lock: a stage run skips when it is held, the end of a session waits."""
    deadline = time.time() + LOCK_WAIT.get(trigger, 0)
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            if time.time() >= deadline:
                return False
            time.sleep(2)


def summary_note(cwd, sid):
    """This session's rolling summary note, if an earlier checkpoint wrote one."""
    rows = json.loads(run_reflections(["list", "--json", "--status", "note", "--kind", "handoff",
                                       "--session", sid, "--limit", "5"], cwd))
    return next((r for r in rows if SUMMARY_TAG in (r.get("tags") or [])), None)


def store_candidates(condensed, sid, cwd):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", prefix="reflector-q-", delete=False) as f:
        f.write(condensed)
    try:
        return json.loads(run_reflections(["candidates", "--json", "--session", sid, "--query-file", f.name], cwd))
    finally:
        os.unlink(f.name)


def reflect(transcript, session_id, cwd, trigger, dry_run=False, tier="deep", stage_pct=None):
    sid = session_id or Path(transcript).stem
    safe_sid = re.sub(r"[^\w.-]", "_", sid)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state_file = STATE_DIR / f"{safe_sid}.json"
    lock = open(STATE_DIR / f"{safe_sid}.lock", "w")
    if not acquire(lock, trigger):
        log({"session_id": sid, "trigger": trigger, "skipped": "another reflection is running"})
        lock.close()
        return 0
    try:
        state = json.loads(state_file.read_text()) if state_file.exists() else {"offset": 0, "runs": []}
        cwd = cwd if cwd and os.path.isdir(cwd) else str(HOME)
        offset = int(state.get("offset", 0))
        # The data boundary is checked here too, so a manual run (or a spawn the hook
        # never saw) cannot send a restricted transcript to a model either.
        if boundary_skip(transcript, sid, trigger):
            log({"session_id": sid, "trigger": trigger, "skipped": "data boundary"})
            return 0
        condensed, new_offset, entrypoint, prompts = condense(transcript, offset)
        base = {"session_id": sid, "trigger": trigger, "tier": tier, "cwd": cwd, "chars": len(condensed)}
        if stage_pct:
            base["stage_pct"] = stage_pct
        if entrypoint == "sdk-cli" and os.environ.get("REFLECTOR_INCLUDE_PRINT") != "1" and trigger != "manual":
            log({**base, "skipped": "non-interactive (-p) session"})
            return 0
        # A session's first segment must contain a human request. A later segment
        # may not: one long autonomous turn spans several reflections, and its
        # tail is exactly the finished work worth keeping.
        if len(condensed) < MIN_NEW_CHARS.get(trigger, 5_000) or (prompts == 0 and offset == 0 and trigger != "manual"):
            log({**base, "skipped": "too little new content"})
            return 0
        if prompts == 0 and offset > 0:
            earlier = request_before(transcript, offset, int(state.get("skipped_until", 0)))
            if earlier:
                condensed = f"USER (the request still in progress, from before this excerpt): {earlier}\n{condensed}"
        found = store_candidates(condensed, sid, cwd)
        repo, candidates = found["repo"], found["items"]
        note = summary_note(cwd, sid)
        so_far = re.sub(r"\n\nsession \S+\s*$", "", (note or {}).get("body") or "")
        why = TRIGGER_WHY.get(trigger, trigger).format(pct=stage_pct or "?")
        max_items = MAX_ITEMS.get(tier, MAX_ITEMS["deep"])
        prompt = build_prompt(condensed, repo, why, candidates, so_far, max_items)
        if dry_run:
            print(prompt)
            return 0
        model, t0 = pick_model(tier), time.time()
        try:
            reply = consolidate(prompt, model)
        except (RuntimeError, subprocess.SubprocessError) as exc:
            fallback = fallback_model(tier)
            if model == fallback:
                raise
            log({**base, "model": model, "retry": fallback, "error": str(exc)[:300]})
            model = fallback
            reply = consolidate(prompt, model)
        topic, summary, items = parse_reply(reply, max_items)
        updates = parse_updates(reply_json(reply), [c["id"] for c in candidates])
        label = f"[reflector {trigger}{f' {stage_pct}%' if stage_pct else ''}] "
        if summary:
            date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
            title = f"{topic or 'Session'} — session summary ({trigger}, {date})"[:200]
            body = f"{summary}\n\nsession {sid}"
            if note:  # one summary per session, rewritten at each checkpoint
                updates.append({"op": "edit", "id": note["id"], "title": title, "body": body})
            else:
                items.append({"kind": "handoff", "status": "note", "tags": [SUMMARY_TAG], "title": title, "body": body})
        for u in updates:
            if u.get("note"):
                u["note"] = label + u["note"]
        result = {"applied": [], "skipped": []}
        if updates:
            result = json.loads(run_reflections(["apply", "--batch", "-", "--json", "--repo", repo,
                                                 "--agent", "reflector"], cwd, json.dumps(updates)))
        added = json.loads(run_reflections(
            ["add", "--batch", "-", "--json", "--session", sid, "--origin", trigger,
             "--agent", "codex" if entrypoint == "codex" else "claude"], cwd, json.dumps(items)))
        new = [i for i in added["items"] if not i.get("duplicate")]
        state["offset"] = new_offset
        state["runs"] = (state.get("runs") or [])[-19:] + [{"ts": now_iso(), "trigger": trigger, "tier": tier,
                                                            "items": len(new), "updates": len(result["applied"])}]
        state_file.write_text(json.dumps(state))
        log({**base, "model": model, "repo": added["repo"], "items": len(new),
             "duplicates": len(added["items"]) - len(new), "updates": len(result["applied"]),
             "updates_skipped": len(result["skipped"]), "candidates": len(candidates),
             "seconds": round(time.time() - t0, 1)})
        return 0
    except Exception as exc:  # background job: record, never raise into a hook
        log({"session_id": sid, "trigger": trigger, "error": f"{type(exc).__name__}: {str(exc)[:400]}"})
        return 1
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()


def detach(transcript, session_id, cwd, trigger, tier="deep", stage_pct=None):
    """Double-fork into a new session so the hook returns at once and the work survives
    the hook's process group (macOS has no setsid binary; this does the same)."""
    if os.fork() > 0:
        return
    os.setsid()
    if os.fork() > 0:
        os._exit(0)
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        errlog = os.open(str(LOG_PATH.with_suffix(".stderr.log")), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        os.dup2(errlog, 1)
        os.dup2(errlog, 2)
    except OSError:
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
    os._exit(reflect(transcript, session_id, cwd, trigger, tier=tier, stage_pct=stage_pct))


def skip_span(transcript, session_id, trigger):
    """Move this session's reflection offset past everything written so far, so the lines a
    restricted session wrote are never reflected, even after it is resumed in an unrestricted
    one where the boundary check says go ahead."""
    sid = session_id or Path(transcript).stem
    safe_sid = re.sub(r"[^\w.-]", "_", sid)
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        state_file = STATE_DIR / f"{safe_sid}.json"
        with open(STATE_DIR / f"{safe_sid}.lock", "w") as lock:
            if not acquire(lock, trigger):
                return
            state = json.loads(state_file.read_text()) if state_file.exists() else {"offset": 0, "runs": []}
            _, end = read_new_lines(transcript, int(state.get("offset", 0)))
            state["offset"] = max(int(state.get("offset", 0)), end)
            state["skipped_until"] = state["offset"]
            state_file.write_text(json.dumps(state))
    except (OSError, ValueError):
        return
    log({"session_id": sid, "trigger": trigger, "skipped": "data boundary"})


def cmd_hook(trigger):
    if disabled():
        return 0
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    transcript, sid = hook.get("transcript_path"), hook.get("session_id")
    if hook.get("agent_id") or not transcript or not os.path.isfile(transcript):
        return 0
    if boundary_skip(transcript, sid, trigger):
        skip_span(transcript, sid, trigger)
        return 0
    detach(transcript, sid, hook.get("cwd"), trigger)
    return 0


DEDUPE_PROMPT = """Below are the open items of one repo's reflections store, recorded by many
sessions. Find groups that describe the SAME work (the same unfinished task, question or
follow-up, even if worded differently). For each group keep the most complete/most recent item
and drop the rest. Items that only share a topic are not duplicates. When unsure, leave them.

Return ONLY a JSON object: {{"groups": [{{"keep": "<id>", "drop": ["<id>", ...], "why": "<= 15 words"}}]}}

ITEMS (#id · updated · kind · title — body):
{items}
"""


def cmd_dedupe(repo, cwd, apply, limit):
    """Drop near-duplicate open items of one repo (keeping one per group), on the haiku tier.
    Prints the proposal; --apply records it (drops are reversible with `reflections reopen`)."""
    rows = json.loads(run_reflections(["list", "--json", "--repo", repo, "--status", "open,stale",
                                       "--limit", str(limit)], cwd))
    if len(rows) < 2:
        print(f"{repo}: fewer than two open items")
        return 0
    lines = [f"#{r['id']} · {(r.get('updated_at') or '')[:10]} · {r['kind']} · {r['title']} — "
             f"{' '.join((r.get('body') or '').split())[:160]}" for r in rows]
    ids = {r["id"] for r in rows}
    data = reply_json(consolidate(DEDUPE_PROMPT.format(items="\n".join(lines)), pick_model("haiku")))
    ops, seen = [], set()
    for g in data.get("groups") or []:
        if not isinstance(g, dict):
            continue
        keep = str(g.get("keep") or "").lstrip("#")
        drop = [str(d).lstrip("#") for d in g.get("drop") or []]
        drop = [d for d in drop if d in ids and d != keep and d not in seen]
        if keep not in ids or keep in seen or not drop:
            continue
        seen.update([keep, *drop])
        why = " ".join(str(g.get("why") or "").split())[:120]
        ops += [{"op": "drop", "id": d, "note": f"duplicate of #{keep}" + (f": {why}" if why else "")} for d in drop]
        print(f"keep #{keep}  drop {', '.join('#' + d for d in drop)}  ({why})")
    print(f"{repo}: {len(ops)} duplicate(s) among {len(rows)} open items"
          + ("" if apply else " — dry run; --apply records them"))
    if apply and ops:
        result = json.loads(run_reflections(["apply", "--batch", "-", "--json", "--repo", repo,
                                             "--agent", "reflector"], cwd, json.dumps(ops)))
        print(f"applied {len(result['applied'])}, skipped {len(result['skipped'])}")
    return 0


def cmd_status():
    try:
        lines = LOG_PATH.read_text().splitlines()[-15:]
    except OSError:
        print("no reflector runs yet")
        return 0
    for line in lines:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        what = r.get("error") or r.get("skipped") or (
            f"{r.get('items')} new, {r.get('updates', 0)} updated ({r.get('model')}, {r.get('seconds')}s)")
        trig = r.get("trigger", "?") + (f" {r['stage_pct']}%" if r.get("stage_pct") else "")
        print(f"{r['ts']}  {trig:10} {str(r.get('session_id', ''))[:8]}  {r.get('repo', '')}  {what}")
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="session_reflector.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    h = sub.add_parser("hook")
    h.add_argument("trigger", choices=["precompact", "sessionend"])
    for name in ("spawn", "run"):
        s = sub.add_parser(name)
        s.add_argument("--transcript", required=True)
        s.add_argument("--session")
        s.add_argument("--cwd")
        s.add_argument("--trigger", default="manual", choices=list(TRIGGER_WHY))
        s.add_argument("--tier", default="deep", choices=["deep", *TIERS])
        s.add_argument("--stage-pct", type=int, help="the checkpoint a stage run marks (20, 40, …)")
        if name == "run":
            s.add_argument("--dry-run", action="store_true")
    sub.add_parser("status")
    d = sub.add_parser("dedupe", help="drop near-duplicate open items of a repo (haiku tier)")
    d.add_argument("--repo", required=True)
    d.add_argument("--apply", action="store_true")
    d.add_argument("--limit", type=int, default=400)
    args = p.parse_args(argv)
    if args.cmd == "hook":
        return cmd_hook(args.trigger)
    if args.cmd == "status":
        return cmd_status()
    if args.cmd == "dedupe":
        return cmd_dedupe(args.repo, os.getcwd(), args.apply, args.limit)
    if args.cmd == "spawn":
        if disabled():
            return 0
        if boundary_skip(args.transcript, args.session, args.trigger):
            skip_span(args.transcript, args.session, args.trigger)
            return 0
        detach(args.transcript, args.session, args.cwd, args.trigger, args.tier, args.stage_pct)
        return 0
    return reflect(args.transcript, args.session, args.cwd, args.trigger, dry_run=args.dry_run,
                   tier=args.tier, stage_pct=args.stage_pct)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
