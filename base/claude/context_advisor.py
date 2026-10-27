#!/usr/bin/env python3
"""context_advisor — PostToolBatch / UserPromptSubmit: act on a filling context window
before auto-compaction does it bluntly.

Hooks cannot compact, clear, or edit a live conversation's history (there is no
"surgery" API). What they can do is (1) save what matters before compaction loses it and
(2) put the choice in front of the model and the human at the right moment. So, by
share of an *advisory budget* — min(the compaction point, CONTEXT_ADVISOR_WINDOW=900k).
900k sits just under a 1M window's ~967k auto-compaction: long 1M sessions have room, so
the fresh-session advice comes only near real compaction (it was 400k).
A directory that wants it sooner sets a smaller budget in BUDGETS_FILE:

  55%  reflect  start a background reflection (session_reflector.py) unless a stage
                below already saved one — silent
  70%  advise   ask Jev (TypeSafe System One) for calibrated reads — natural boundary?
                fresh session better? mid delicate operation? new topic (on a new
                prompt)? — and inject a short factual recommendation as additionalContext,
                plus a one-line systemMessage for the human
  85%  urge     same, firmer

Separately, reflection STAGES checkpoint the session as it fills the *model* window (not the
advisory budget): REFLECTOR_STAGES="0.2:haiku,0.4:sonnet,0.6:sonnet,0.8:sonnet" by default — a
cheap Haiku reflection at 20%, Sonnet at 40/60/80% — so what the session learned and left open
is in the store long before compaction, and PreCompact only has the last stretch left to read.
Each reflection is incremental, so a stage costs only what was said since the one before.
REFLECTOR_STAGES="" turns stages off.

Bands and stages fire once per compaction cycle (they re-arm when usage drops, i.e. after
/compact or /clear), so Jev runs at most twice per cycle. A session that already handed off
(cc-handoff launch left a marker in HANDOFF_STATE_DIR) is told so instead, and
Jev is not asked: urging a second handoff would put two sessions on the same work.

Token count and window come from the statusline's per-session sensor file (exact, from
Claude Code's own context_window data, on any provider): ~/.claude/state/context/<session>.json.
Without it (statusline off), the transcript's last usage block is read, at most once a
minute. Transcripts record the bare model id on Bedrock and the Anthropic API alike
("claude-opus-5-5", never Claude Code's "[1m]" suffix), so model_window() reads the suffix
off the configured model of the same id or alias. The log's window_source says which
rule decided: statusline, override, tokens, model, configured:<where>, native, default.

`--agent codex` (Codex PostToolUse / UserPromptSubmit) reads tokens and window from the
rollout's newest token_count event, reflects at 55% and adds one factual line at 70/85%:
Codex compacts on its own, so there is no Jev, no handoff and no desktop notification.

Env: CONTEXT_ADVISOR_DISABLE=1, CONTEXT_ADVISOR_WINDOW (900000), CONTEXT_ADVISOR_BANDS
("0.55,0.70,0.85"), CONTEXT_ADVISOR_JEV=0 (skip Jev; it is off by default for the identities
in DF_WORK_IDENTITIES, "work" unless set), TYPESAFE_API_KEY (else read from ~/.env_secrets;
without a key Jev is never asked; MEMORY_BOUNDARY_CMD keeps a restricted session's excerpts
from it, see scripts/lib/memory-boundary.sh), JEV_ADVISOR_MODEL (jev-latest), JEV_ENDPOINT, CONTEXT_ADVISOR_STATE_DIR,
CONTEXT_SENSOR_DIR, CLAUDE_CODE_AUTO_COMPACT_WINDOW (read, as Claude Code does),
CONTEXT_ADVISOR_MODEL_WINDOW (force the model window), CONTEXT_ADVISOR_1M_MODELS (regex of
model ids that are 1M without the suffix; none by default), CODEX_HOME.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HOME = Path.home()
HERE = Path(__file__).resolve().parent
STATE_DIR = Path(os.environ.get("CONTEXT_ADVISOR_STATE_DIR") or HOME / ".claude/state/context-advisor")
SENSOR_DIR = Path(os.environ.get("CONTEXT_SENSOR_DIR") or HOME / ".claude/state/context")
HANDOFF_DIR = Path(os.environ.get("HANDOFF_STATE_DIR") or HOME / ".claude/state/handoff")
LOG_PATH = Path(os.environ.get("CONTEXT_ADVISOR_LOG") or HOME / ".claude/logs/context-advisor.jsonl")
ADVISORY_WINDOW = int(os.environ.get("CONTEXT_ADVISOR_WINDOW") or 900_000)
# Per-directory budgets, read on every hook run so a change applies to sessions that are already
# running (their environment is fixed at launch). JSON object: {"<path prefix>": <tokens>, ...};
# "~" expands; the longest prefix of the hook's cwd wins. CONTEXT_ADVISOR_WINDOW in the
# environment still overrides it.
BUDGETS_FILE = Path(os.environ.get("CONTEXT_ADVISOR_BUDGETS") or HOME / ".config/context-advisor/budgets.json")


def advisory_window(cwd):
    """(window, source): CONTEXT_ADVISOR_WINDOW, else the longest matching prefix in BUDGETS_FILE, else 900k."""
    if os.environ.get("CONTEXT_ADVISOR_WINDOW"):
        return ADVISORY_WINDOW, "env"
    try:
        table = json.loads(BUDGETS_FILE.read_text())
    except (OSError, ValueError):
        return ADVISORY_WINDOW, "default"
    best, value = "", 0
    here = os.path.realpath(os.path.expanduser(cwd or ""))
    for prefix, tokens in (table.items() if isinstance(table, dict) else ()):
        root = os.path.realpath(os.path.expanduser(str(prefix)))
        try:
            n = int(tokens)
        except (TypeError, ValueError):
            continue
        if n > 0 and (here == root or here.startswith(root.rstrip(os.sep) + os.sep)) and len(root) > len(best):
            best, value = root, n
    return (value, f"budgets:{best}") if value else (ADVISORY_WINDOW, "default")
# The wrapper's fast-path floor. Below it nothing can fire, and the wrapper only
# starts Python there while a cycle is live — i.e. exactly when it must re-arm.
MIN_TOKENS = int(os.environ.get("CONTEXT_ADVISOR_MIN_TOKENS") or 100_000)
BAND_NAMES = ("reflect", "advise", "urge")


def _bands(raw, default=(0.55, 0.70, 0.85)):
    """Exactly one threshold per band name, ascending, each in (0, 1]; else the defaults."""
    try:
        vals = sorted(float(x) for x in (raw or "").split(","))
    except ValueError:
        return list(default)
    return vals if len(vals) == len(BAND_NAMES) and all(0 < v <= 1 for v in vals) else list(default)


BANDS = _bands(os.environ.get("CONTEXT_ADVISOR_BANDS"))
DEFAULT_STAGES = "0.2:haiku,0.4:sonnet,0.6:sonnet,0.8:sonnet"


def _stages(raw):
    """Ascending (share of the model window, reflector tier) checkpoints. Unset → the default;
    empty → none; anything malformed → the default."""
    raw = DEFAULT_STAGES if raw is None else raw
    out = []
    for part in (p.strip() for p in raw.split(",")):
        if not part:
            continue
        frac, _, tier = part.partition(":")
        try:
            share = float(frac)
        except ValueError:
            return _stages(DEFAULT_STAGES)
        if not 0 < share < 1 or tier not in ("haiku", "sonnet", "deep"):
            return _stages(DEFAULT_STAGES)
        out.append((share, tier))
    return sorted(out)


STAGES = _stages(os.environ.get("REFLECTOR_STAGES"))
JEV_ENDPOINT = os.environ.get("JEV_ENDPOINT") or "https://api.typesafe.ai/v1/systemone"
JEV_TIMEOUT = float(os.environ.get("JEV_ADVISOR_TIMEOUT") or 6)
SENSOR_MAX_AGE = 900  # seconds; older than this the statusline has stopped rendering


def log(rec):
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a") as f:
            f.write(json.dumps({"ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), **rec}) + "\n")
    except OSError:
        pass


def safe(sid):
    return re.sub(r"[^\w.-]", "_", str(sid))


def identity():
    """The machine's DF_IDENTITY (install.sh persists it in ~/.df-profile), or ""."""
    if os.environ.get("DF_IDENTITY"):
        return os.environ["DF_IDENTITY"].lower()
    try:
        m = re.search(r"(?m)^export DF_IDENTITY=([\w.-]+)$", (HOME / ".df-profile").read_text())
        return m.group(1).lower() if m else ""
    except OSError:
        return ""


def work_identity():
    """True on a machine whose identity is one of DF_WORK_IDENTITIES (default "work")."""
    work = (os.environ.get("DF_WORK_IDENTITIES") or "work").lower().split()
    return identity() in work


# ------------------------------------------------------------------ usage ----

def compaction_point(window):
    for raw in (os.environ.get("CLAUDE_CODE_AUTO_COMPACT_WINDOW"), _setting("autoCompactWindow")):
        if raw is None:
            continue
        try:
            acw = int(raw)
        except (TypeError, ValueError):
            continue
        if acw > 0:
            return min(acw, window)
    return int(window * 0.967) if window >= 1_000_000 else window


def _setting(key):
    try:
        return json.loads((HOME / ".claude/settings.json").read_text()).get(key)
    except (OSError, ValueError):
        return None


def _tail_lines(path, nbytes):
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            f.seek(max(0, size - nbytes))
            return f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return None


LARGE_WINDOW, SMALL_WINDOW = 1_000_000, 200_000
_PROVIDER_PREFIX = re.compile(r"^(?:(?:us|us-gov|eu|apac|au|jp|global)\.)?(?:anthropic\.)?")


def model_base(model):
    """Provider-neutral model id: Claude Code's [1m] suffix, Bedrock's region/vendor prefix and
    -v1:0 version, and a dated snapshot (-20251001, Vertex's @20250805) all go."""
    m = re.sub(r"\[[^\]]*\]$", "", (model or "").strip().lower())
    m = re.sub(r"-v\d+(?::\d+)?$", "", _PROVIDER_PREFIX.sub("", m, count=1))
    return re.sub(r"[-@]\d{8}$", "", m)


def model_window(model, tokens):
    """(window, source) when Claude Code did not report the window. The first configured id or
    alias for this model decides; an exact id chosen without "[1m]" means 200k, an alias without
    it defers to the family default it stands for."""
    if tokens > SMALL_WINDOW:
        return LARGE_WINDOW, "tokens"
    if "[1m]" in (model or "").lower():
        return LARGE_WINDOW, "model"
    base = model_base(model)
    m = re.match(r"claude-([a-z]+)", base)
    family = m.group(1) if m else ""
    candidates = [("ANTHROPIC_MODEL", os.environ.get("ANTHROPIC_MODEL")), ("settings.model", _setting("model"))]
    if family:
        candidates.append((f"ANTHROPIC_DEFAULT_{family.upper()}_MODEL",
                           os.environ.get(f"ANTHROPIC_DEFAULT_{family.upper()}_MODEL")))
    candidates.append(("ANTHROPIC_CUSTOM_MODEL_OPTION", os.environ.get("ANTHROPIC_CUSTOM_MODEL_OPTION")))
    for name, configured in candidates:
        cbase = model_base(configured) if isinstance(configured, str) else ""
        if not base or not cbase or cbase not in (base, family):
            continue
        if "[1m]" in configured.lower():
            return LARGE_WINDOW, f"configured:{name}"
        if cbase == base:
            break
    native = os.environ.get("CONTEXT_ADVISOR_1M_MODELS") or ""
    try:
        if base and native and re.search(native, base):
            return LARGE_WINDOW, "native"
    except re.error:
        pass
    return SMALL_WINDOW, "default"


def usage_from_transcript(path):
    """(tokens, model) from the newest assistant usage block in the transcript tail."""
    for line in reversed(_tail_lines(path, 2 * 1024 * 1024) or []):
        if '"usage"' not in line or '"assistant"' not in line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        msg = e.get("message") or {}
        u = msg.get("usage") or {}
        tokens = sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens",
                                                   "cache_read_input_tokens"))
        if tokens:
            return tokens, msg.get("model") or ""
    return None


def current_usage(hook, st):
    """(tokens, model window, token source, window source), or None."""
    sensor = SENSOR_DIR / f"{safe(hook.get('session_id'))}.json"
    try:
        s = json.loads(sensor.read_text())
        if time.time() - float(s.get("ts") or 0) < SENSOR_MAX_AGE and int(s.get("tokens") or 0) > 0:
            tokens, size = int(s["tokens"]), int(s.get("size") or 0)
            if size > 0:
                return tokens, size, "statusline", "statusline"
            # Claude Code sent no window size: unknown, so guess it from the model, not 200k.
            if not st.get("model"):
                got = usage_from_transcript(hook.get("transcript_path") or "")
                st["model"] = got[1] if got else ""
            window, wsource = model_window(st["model"], tokens)
            return tokens, window, "statusline", wsource
    except (OSError, ValueError, TypeError):
        pass
    if time.time() - st.get("transcript_checked", 0) < 60:
        return None
    st["transcript_checked"] = time.time()
    got = usage_from_transcript(hook.get("transcript_path") or "")
    if not got:
        return None
    window, wsource = model_window(got[1], got[0])
    return got[0], window, "transcript", wsource


def codex_usage(hook):
    """(tokens, window, "rollout", "codex") from the newest token_count event in a Codex rollout.
    last_token_usage.total_tokens (input, cached included, plus output) is what the context
    holds; total_token_usage is the session's cumulative spend. model_context_window is Codex's
    own figure for the model."""
    for line in reversed(_tail_lines(hook.get("transcript_path") or "", 2 * 1024 * 1024) or []):
        if '"last_token_usage"' not in line:
            continue
        try:
            p = json.loads(line).get("payload") or {}
            info = (p.get("info") or {}) if p.get("type") == "token_count" else {}
            last = info.get("last_token_usage") or {}
            tokens = int(last.get("total_tokens") or 0)
            window = int(info.get("model_context_window") or 0)
        except (ValueError, TypeError, AttributeError):
            continue
        if tokens:
            return (tokens, window, "rollout", "codex") if window > 0 else (tokens, SMALL_WINDOW, "rollout", "default")
    return None


def codex_compaction_point(window):
    """model_auto_compact_token_limit from Codex's config.toml, else the model window (measured:
    Codex compacted between 243k and 277k tokens on a 258.4k window)."""
    try:
        import tomllib  # Python 3.11+; older interpreters just use the window
        with open(Path(os.environ.get("CODEX_HOME") or HOME / ".codex") / "config.toml", "rb") as f:
            limit = int(tomllib.load(f).get("model_auto_compact_token_limit") or 0)
    except (ImportError, OSError, ValueError, TypeError):
        limit = 0
    return min(limit, window) if limit > 0 else window


# -------------------------------------------------------------------- Jev ----

_HARNESS = re.compile(r"^<(system-reminder|local-command|task-notification|command-name|user-prompt-submit-hook)")


def conversation_state(path):
    """Latest request, earlier requests, and the agent's recent activity (Claude format)."""
    prompts, texts, tools = [], [], {}
    lines = _tail_lines(path, 3 * 1024 * 1024)
    if lines is None:
        return None
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("isSidechain") or e.get("isMeta"):
            continue
        content = (e.get("message") or {}).get("content")
        if e.get("type") == "user":
            text = content if isinstance(content, str) else " ".join(
                b.get("text", "") for b in (content or []) if isinstance(b, dict) and b.get("type") == "text")
            text = text.strip()
            if text and not _HARNESS.match(text) and not text.startswith("Stop hook feedback"):
                prompts.append(text)
                tools = {}
        elif e.get("type") == "assistant" and isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                    texts.append(b["text"].strip())
                elif isinstance(b, dict) and b.get("type") == "tool_use":
                    tools[b.get("name")] = tools.get(b.get("name"), 0) + 1

    def clip(s, n):
        return s if len(s) <= n else s[: int(n * 0.6)] + " …[clipped]… " + s[-int(n * 0.4):]

    if not prompts:
        return None
    return {
        "user_request": {"latest": clip(prompts[-1], 1500),
                         "earlier": [clip(p, 400) for p in prompts[-4:-1]] or "none"},
        "agent_recent_messages": [clip(t, 700) for t in texts[-4:]] or "none",
        "tools_used_since_latest_request": [f"{k}×{v}" for k, v in tools.items()] or "none",
    }


def api_key():
    key = os.environ.get("TYPESAFE_API_KEY", "")
    if key:
        return key
    try:  # only this one key — never load the whole secrets file into the hook
        m = re.search(r"(?m)^(?:export\s+)?TYPESAFE_API_KEY=[\"']?([^\"'\s]+)", (HOME / ".env_secrets").read_text())
        return m.group(1) if m else ""
    except OSError:
        return ""


def boundary_blocks(hook):
    """True when MEMORY_BOUNDARY_CMD keeps this session's excerpts away from Jev. It is the
    reflector's check (the contract in scripts/lib/memory-boundary.sh), asked with
    MEMORY_BOUNDARY_TOOL=context-advisor; a check that cannot even load fails closed."""
    if not os.environ.get("MEMORY_BOUNDARY_CMD", "").strip():
        return False
    try:
        from session_reflector import boundary_skip  # run as the hook, this file's directory is on sys.path
    except Exception:
        return True
    return boundary_skip(hook.get("transcript_path") or "", hook.get("session_id") or "",
                         hook.get("hook_event_name") or "", tool="context-advisor")


def questions(new_prompt):
    q = {
        "natural_boundary": {"type": "noul", "instructions": (
            "Is the agent at or near a natural boundary in the user's request: a sub-task just "
            "finished or was verified, or the next step starts a distinct phase?")},
        "fresh_session_better": {"type": "noul", "instructions": {
            "question": "Would the remaining work go better in a fresh session that starts from a short "
                        "written handoff than by continuing in this long conversation?",
            "guidance": ["Favour a fresh session when the next phase is distinct and most of the "
                         "conversation so far is history it won't need.",
                         "Favour continuing when the agent is mid-investigation with live state that a "
                         "handoff would lose, or the work is nearly done."]}},
        "delicate_operation": {"type": "noul", "instructions": (
            "Is the agent in the middle of a delicate multi-step operation (a rebase, migration, deploy, "
            "or a debugging chain) where stopping now would be risky or wasteful?")},
    }
    if new_prompt:
        q["new_topic"] = {"type": "noul", "instructions": (
            "Is `user_request.latest` a new, distinct task rather than a continuation of the earlier "
            "requests and the agent's recent work?")}
    return q


def ask_jev(state, qs):
    body = json.dumps({"state": state, "model": os.environ.get("JEV_ADVISOR_MODEL") or "jev-latest",
                       "questions": qs}).encode()
    req = urllib.request.Request(JEV_ENDPOINT, data=body, method="POST", headers={
        "Authorization": f"Bearer {api_key()}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=JEV_TIMEOUT) as r:
        answers = json.loads(r.read()).get("answers") or {}
    return {k: (v or {}).get("noul") for k, v in answers.items()}


# ----------------------------------------------------------------- advice ----

def fmt_k(n):
    return f"{n / 1000:.0f}k"


def handed_off(sid):
    """The tmux window this session already handed off to (launch.sh's marker), else None."""
    try:
        target = json.loads((HANDOFF_DIR / f"{safe(sid)}.json").read_text()).get("target")
    except (OSError, ValueError, AttributeError):
        return None
    return target if isinstance(target, str) and target else None


SAVED = (" A background reflection of the session so far has been saved to the reflections store "
         "(`reflections list`).")


def budget_line(tokens, window, compaction):
    return (f"Context budget: this session holds about {fmt_k(tokens)} tokens, {round(100 * tokens / window)}% "
            f"of its {fmt_k(window)} advisory budget (auto-compaction would run near {fmt_k(compaction)}).")


def advise_codex(tokens, window, compaction, reflected):
    """Codex compacts on its own and gets no handoff here: the numbers and the saved reflection."""
    pct = round(100 * tokens / window)
    return (budget_line(tokens, window, compaction) + " Keep tool output lean (targeted reads, filtered "
            "commands)." + (SAVED if reflected else "") + " Codex compacts on its own and the reflector saves "
            "the session first, so carry on with the task.",
            f"◔ context {pct}% of {fmt_k(window)} budget")


def advise(band, tokens, window, compaction, p, reflected, handed=None):
    pct = round(100 * tokens / window)
    head = budget_line(tokens, window, compaction)
    saved = SAVED if reflected else ""
    if handed:
        return (head + f" This session already handed off to tmux window {handed}. Do not launch another "
                "handoff unless the user asks for one; answer what they ask here with lean tool output." + saved,
                f"◔ context {pct}% · handed off to {handed}", "handed-off")
    if not p:
        if band >= 2:
            guide = (" Keep tool output lean. At the next natural stopping point (a step just finished or "
                     "verified, not mid-operation), run the `fresh-session-handoff` skill on your own: "
                     "`cc-handoff init` writes this generation's brief skeleton, you fill it, and "
                     "`cc-handoff launch` opens the successor right after this window with the chain's "
                     "history and a session-specific prompt, then closes this window after its first reply. "
                     "Then tell the user the brief path and how to attach. Do not wait to be asked.")
        else:
            guide = (" Keep tool output lean (targeted reads, filtered commands); at the next natural "
                     "stopping point, consider recording open items and suggesting a fresh session.")
        return (head + guide + saved, f"◔ context {pct}% of {fmt_k(window)} budget", "lean")
    reads = " · ".join(f"{k.replace('_', '-')} {v:.2f}" for k, v in p.items() if isinstance(v, (int, float)))
    boundary, fresh = p.get("natural_boundary") or 0, p.get("fresh_session_better") or 0
    delicate, new_topic = p.get("delicate_operation") or 0, p.get("new_topic") or 0
    if delicate >= 0.6:
        return (head + f" Jev reads the agent as mid-operation [{reads}], so continuing is right; keep "
                "tool output lean until the operation is done, then reassess." + saved,
                f"◔ context {pct}% · Jev: mid-operation, keep going", "lean")
    if new_topic >= 0.6 or (fresh >= 0.6 and (boundary >= 0.55 or band >= 2)):
        why = ("The latest request looks like a new, separate task" if new_topic >= 0.6
               else "This looks like a good point to hand off")
        return (head + f" {why} [{reads}]. Finish the current step, record anything still open with "
                "`reflections add --kind action …`, then run the `fresh-session-handoff` skill on your own: "
                "`cc-handoff init` writes this generation's brief skeleton, you fill it, and `cc-handoff launch` "
                "opens the successor right after this window with the chain's history and a session-specific "
                "prompt, then closes this window after its first reply. Then tell the user the brief path and "
                "how to attach. Do not wait to be asked."
                + saved,
                f"◔ context {pct}% · Jev: good point for a fresh session", "handoff")
    return (head + f" Jev sees no clean handoff point yet [{reads}]; keep going with lean tool output and "
            "reassess at the next natural boundary." + saved,
            f"◔ context {pct}% · Jev: continue, stay lean", "lean")


def spawn_reflection(hook, trigger="advisor", tier="deep", pct=None):
    if os.environ.get("REFLECTOR_DISABLE") == "1" or not hook.get("transcript_path"):
        return False  # never claim a reflection that was not started
    script = os.environ.get("REFLECTOR_SCRIPT") or str(HERE / "session_reflector.py")
    cmd = [sys.executable, script, "spawn", "--trigger", trigger, "--tier", tier,
           "--transcript", hook["transcript_path"], "--session", str(hook.get("session_id")),
           "--cwd", hook.get("cwd") or str(HOME)]
    if pct:
        cmd += ["--stage-pct", str(pct)]
    try:
        subprocess.run(cmd, timeout=10, capture_output=True)
        return True
    except (OSError, subprocess.SubprocessError):
        return False


def notify(hook, text, pct):
    bin_ = os.environ.get("AGENT_NOTIFY_BIN") or str(HERE.parents[1] / "scripts/agent-notify")
    if not os.access(bin_, os.X_OK):
        return
    try:
        p = subprocess.Popen([bin_], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
        if p.stdin:
            p.stdin.write(json.dumps({"event": "context.high", "severity": "info", "title": f"context {pct}%",
                                      "message": text, "source": "context-advisor",
                                      "session_id": hook.get("session_id"), "cwd": hook.get("cwd")}).encode())
            p.stdin.close()
    except OSError:
        pass


def run(hook, agent="claude"):
    event = hook.get("hook_event_name")
    sid = hook.get("session_id")
    events = ("PostToolUse", "UserPromptSubmit") if agent == "codex" else ("PostToolBatch", "UserPromptSubmit")
    if event not in events or not sid or hook.get("agent_id"):
        return None
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    state_file = STATE_DIR / f"{safe(sid)}.json"
    st: dict[str, Any]
    try:
        st = json.loads(state_file.read_text())
    except (OSError, ValueError):
        st = {"band": -1}
    usage = codex_usage(hook) if agent == "codex" else current_usage(hook, st)
    if not usage:
        state_file.write_text(json.dumps(st))
        return None
    tokens, model_window, source, window_source = usage
    try:  # Claude only: a shell export would otherwise override Codex's own exact window too
        forced = int(os.environ.get("CONTEXT_ADVISOR_MODEL_WINDOW") or 0) if agent == "claude" else 0
    except ValueError:
        forced = 0
    if forced > 0:
        model_window, window_source = forced, "override"
    compaction = codex_compaction_point(model_window) if agent == "codex" else compaction_point(model_window)
    budget, budget_source = advisory_window(hook.get("cwd"))
    window = min(compaction, budget)
    share = tokens / window
    model_share = tokens / model_window
    # Compacted or cleared: start a new cycle. A big drop says so directly; the share tests
    # catch a cycle whose drop happened while the wrapper was not starting Python.
    band_live, stage_live = st.get("band", -1) >= 0, st.get("stage", -1) >= 0
    dropped = (band_live or stage_live) and tokens < int(st.get("tokens") or 0) * 0.6
    # Not `tokens < MIN_TOKENS`: a small per-directory budget fires bands below that floor,
    # which would re-arm (and re-fire) on every hook. The drop above catches compaction.
    band_low = band_live and share < BANDS[0] * 0.7
    stage_low = stage_live and bool(STAGES) and model_share < STAGES[0][0] * 0.7
    if dropped or band_low or stage_low:
        st = {"band": -1, "stage": -1, "rearmed_at": time.time()}
    band = max((i for i, b in enumerate(BANDS) if share >= b), default=-1)
    st.update(tokens=tokens, share=round(share, 3), source=source, window_source=window_source)
    stage = max((i for i, (s, _) in enumerate(STAGES) if model_share >= s), default=-1)
    if stage > st.get("stage", -1):
        st["stage"] = stage  # several crossed at once (a resumed session): the highest one covers them
        pct, tier = round(100 * STAGES[stage][0]), STAGES[stage][1]
        started = spawn_reflection(hook, "stage", tier, pct)
        st["reflected"] = st.get("reflected") or started
        log({"session_id": sid, "event": event, "stage": pct, "tier": tier, "started": started,
             "tokens": tokens, "model_window": model_window, "window_source": window_source,
             **({"agent": "codex"} if agent == "codex" else {})})
    out = None
    if band > st.get("band", -1):
        st["band"] = band
        if not st.get("reflected") and hook.get("transcript_path"):
            st["reflected"] = spawn_reflection(hook)
        entry = {"session_id": sid, "event": event, "band": BAND_NAMES[band], "tokens": tokens,
                 "window": window, "model_window": model_window, "window_source": window_source,
                 "budget_source": budget_source}
        if agent == "codex":
            entry["agent"] = "codex"
        if band >= 1 and agent == "codex":
            text, banner = advise_codex(tokens, window, compaction, st.get("reflected"))
            st["hint"] = "lean"
            log({**entry, "hint": "lean"})
            out = {"hookSpecificOutput": {"hookEventName": event, "additionalContext": text},
                   "systemMessage": banner}
        elif band >= 1:
            p, err, skipped = None, None, None
            handed = handed_off(sid)
            # Jev sees conversation excerpts; on a work identity that is company content
            # going to a third-party API, so it is opt-in there (CONTEXT_ADVISOR_JEV=1).
            # A session the data boundary restricts never sends any.
            jev_default = "0" if work_identity() else "1"
            if not handed and os.environ.get("CONTEXT_ADVISOR_JEV", jev_default) != "0" and api_key():
                if boundary_blocks(hook):
                    cs, skipped = None, "data boundary"
                else:
                    cs = conversation_state(hook.get("transcript_path") or "")
                if cs:
                    cs["context"] = {"tokens": tokens, "advisory_budget": window, "share": round(share, 2),
                                     "auto_compaction_at": compaction}
                    try:
                        p = ask_jev(cs, questions(event == "UserPromptSubmit"))
                    except Exception as exc:  # Jev is advice, never a dependency
                        err = str(exc)[:200]
            text, banner, hint = advise(band, tokens, window, compaction, p, st.get("reflected"), handed)
            st["hint"] = hint
            log({**entry, "p": p, "jev_error": err, "hint": hint, **({"jev_skipped": skipped} if skipped else {})})
            notify(hook, banner, round(100 * share))
            out = {"hookSpecificOutput": {"hookEventName": event, "additionalContext": text},
                   "systemMessage": banner}
        else:
            log({**entry, "reflected": st.get("reflected")})
    state_file.write_text(json.dumps(st))
    return out


def main():
    if os.environ.get("CONTEXT_ADVISOR_DISABLE") == "1" or os.environ.get("AGENT_HOOK_CHILD") == "1":
        return 0
    ap = argparse.ArgumentParser(description="context-budget advisor hook (reads the hook payload on stdin)")
    ap.add_argument("--agent", choices=("claude", "codex"), default="claude")
    agent = ap.parse_args().agent
    try:
        out = run(json.loads(sys.stdin.read() or "{}"), agent)
    except Exception as exc:  # advice must never break a turn
        log({"error": f"{type(exc).__name__}: {str(exc)[:300]}"})
        return 0
    if out:
        print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
