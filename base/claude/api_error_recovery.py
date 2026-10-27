#!/usr/bin/env python3
"""api_error_recovery — turn-level retry, diagnosis and alerts for API failures.

Claude Code already retries every API request itself (CLAUDE_CODE_MAX_RETRIES,
default 10, exponential backoff). A turn only ends in an API error after that
inner loop gives up, and that is when StopFailure fires — once, not per retry.
This hook adds the OUTER loop, at the turn level:

  StopFailure (asyncRewake) ─┬─ transient ─── sleep(backoff) → exit 2 → Claude
                             │                wakes and continues the task
                             ├─ attempt == ESCALATE_AT → also start a diagnostic
                             │   agent, when one is opted in (Codex suits it: a
                             │   different provider still works during an outage)
                             ├─ config error → no blind retry; diagnose at once
                             │   (when opted in)
                             ├─ auth / quota / billing / safeguard / context →
                             │   no retry; alert once with the fix to apply
                             └─ attempts exhausted → alert, stop
  Stop (sync, fast) ──────────── success → clear the streak; alert "recovered"
                                 if the streak was long enough to have alerted

Why asyncRewake: StopFailure ignores hook output and exit codes (except
terminalSequence), so a hook cannot return "retry". An asyncRewake hook that
exits 2 wakes Claude even when the session is idle, with stderr delivered as a
system reminder. Verified 2026-09-29 on Claude Code 2.1.284: a StopFailure hook
that slept then exited 2 re-sent the model request (shown as "Stop hook
feedback"); three failures chained exactly as counted here.

Cancellation: every StopFailure writes a fresh token into the session's state
file. A sleeping retry re-reads it every POLL seconds and exits quietly when the
state is gone (a later turn succeeded) or holds another token (a newer failure
owns the streak). So typing a new prompt during a backoff never produces a
stale "retry" wake-up.

Env knobs (all optional):
  API_RECOVERY_DISABLE=1          hard off (also set for the diagnostic child)
  API_RECOVERY_MAX_ATTEMPTS       retries per failure streak           (10)
  API_RECOVERY_NOTIFY_AT          alert "still retrying" at attempt    (5)
  API_RECOVERY_ESCALATE_AT        start the diagnostic agent at        (8)
  API_RECOVERY_BASE_DELAY         first backoff, seconds               (15)
  API_RECOVERY_MAX_DELAY          backoff cap, seconds                 (600)
  API_RECOVERY_HOOK_TIMEOUT       the hook's settings.json timeout     (900)
  API_RECOVERY_POLL               cancellation check interval, seconds (5)
  API_RECOVERY_DIAG_ENGINE        none | auto | codex | claude         (none)
                                  The diagnostic agent is opt-in: it runs an
                                  unattended agent (claude -p skips permission
                                  prompts) with transcript error text. auto
                                  picks codex when installed, else claude.
  API_RECOVERY_DIAG_WHERE         auto | tmux | background             (auto)
  API_RECOVERY_DIAG_CMD           test override: shell command run with the
                                  briefing on stdin, report path in $REPORT
  API_RECOVERY_STATE_DIR          (~/.claude/state/api-recovery)
  API_RECOVERY_LOG                (~/.claude/logs/api-errors.jsonl)
  AGENT_NOTIFY_BIN                alert router (~/.dotfiles/scripts/agent-notify)

CLI:
  api_error_recovery.py            hook mode (StopFailure or Stop JSON on stdin)
  api_error_recovery.py status     list sessions with an active failure streak
  api_error_recovery.py classify ERROR [TEXT]   print the class (debugging)
"""

import json
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

HOME = Path.home()


def env_num(name, default):
    try:
        return float(os.environ.get(name, "").strip() or default)
    except ValueError:
        return float(default)


MAX_ATTEMPTS = int(env_num("API_RECOVERY_MAX_ATTEMPTS", 10))
NOTIFY_AT = int(env_num("API_RECOVERY_NOTIFY_AT", 5))
ESCALATE_AT = int(env_num("API_RECOVERY_ESCALATE_AT", 8))
BASE_DELAY = env_num("API_RECOVERY_BASE_DELAY", 15)
MAX_DELAY = env_num("API_RECOVERY_MAX_DELAY", 600)
HOOK_TIMEOUT = env_num("API_RECOVERY_HOOK_TIMEOUT", 900)
POLL = max(0.05, env_num("API_RECOVERY_POLL", 5))
OUTPUT_RETRIES = 2  # max_output_tokens: one or two "continue in smaller pieces" wakes
STALE_STATE_SECONDS = 7 * 24 * 3600

STATE_DIR = Path(os.environ.get("API_RECOVERY_STATE_DIR") or HOME / ".claude/state/api-recovery")
LOG_PATH = Path(os.environ.get("API_RECOVERY_LOG") or HOME / ".claude/logs/api-errors.jsonl")
NOTIFY_BIN = os.environ.get("AGENT_NOTIFY_BIN") or str(HOME / ".dotfiles/scripts/agent-notify")

# Classes whose failures a plain retry can fix. Everything else needs a human
# or a config change, so retrying would only repeat the same error.
RETRYABLE = {"transient", "output"}

ADVICE = {
    "context": "The conversation no longer fits the model's context. Run /compact "
               "(or /clear after a handoff) in that session.",
    "safeguard": "The model's safeguards flagged a message. Rephrase, switch model, "
                 "or set switchModelsOnFlag: true to switch automatically.",
    "auth": "Credentials expired or are invalid. Run /login (subscription) or "
            "refresh the cloud credentials (e.g. AWS SSO) for that machine.",
    "quota": "A usage or spend limit was reached. Raise the limit or wait for it "
             "to reset; claude.ai limits resume on their own when "
             "autoContinueAtUsageLimit is on.",
    "billing": "The account has a billing problem or is on hold; fix it in the "
               "console before retrying.",
    "config": "The request is misconfigured (model id, provider deployment, or "
              "request option).",
}


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def now_iso():
    return iso(time.time())


def hhmmz():
    return datetime.now(timezone.utc).strftime("%H:%MZ")


# ------------------------------------------------------------ classification --

_QUOTA_RE = re.compile(r"spend limit|usage limit|usage credits|monthly|/usage|credit balance"
                       r"|billing|quota exceeded|plan limit")
_CONTEXT_RE = re.compile(r"prompt is too long|context (length|window)|too many (input )?tokens"
                         r"|exceeds? (the )?(maximum )?context")
_SAFEGUARD_RE = re.compile(r"safeguard|usage polic|/legal/aup|\baup\b|flagged")
_TRANSIENT_TEXT_RE = re.compile(r"\b5\d\d\b|overload|timed? ?out|timeout|econnreset|socket hang up"
                                r"|network|connection|stopped arriving|mid-response|temporar"
                                r"|unavailable|try again")
_CLIENT_ERROR_RE = re.compile(r"\b4\d\d\b")


def classify(error, text=""):
    """Map a StopFailure `error` (+ its details/message) to a recovery class."""
    error = (error or "unknown").strip().lower()
    text = (text or "").lower()
    if error in ("server_error", "overloaded"):
        return "transient"
    if error == "rate_limit":
        return "quota" if _QUOTA_RE.search(text) else "transient"
    if error == "max_output_tokens":
        return "output"
    if error == "invalid_request":
        if _CONTEXT_RE.search(text):
            return "context"
        if _SAFEGUARD_RE.search(text):
            return "safeguard"
        return "config"
    if error in ("model_not_found", "oauth_org_not_allowed"):
        return "config"
    if error in ("authentication_failed", "cloud_credential_error"):
        return "auth"
    if error in ("billing_error", "account_on_hold"):
        return "billing"
    # "unknown" and anything newer than this list: read the text.
    if _CONTEXT_RE.search(text):
        return "context"
    if _TRANSIENT_TEXT_RE.search(text):
        return "transient"
    if _CLIENT_ERROR_RE.search(text):
        return "config"
    return "transient"  # unexplained: a few spaced-out retries are cheap


def backoff(attempt, rng=random.random):
    """Seconds to wait before retry `attempt` (1-based): doubling, capped, ±20% jitter."""
    base = min(MAX_DELAY, BASE_DELAY * (2 ** max(0, attempt - 1)))
    delay = base * (0.8 + 0.4 * rng())
    # Never sleep past the hook's own timeout, or the rewake is killed with it.
    return max(0.0, min(delay, HOOK_TIMEOUT - 60))


# -------------------------------------------------------------------- state --

def safe_name(sid):
    return re.sub(r"[^\w.-]", "_", str(sid))


def state_path(sid):
    return STATE_DIR / f"{safe_name(sid)}.json"


def load_state(sid):
    try:
        return json.loads(state_path(sid).read_text())
    except (OSError, ValueError):
        return None


def save_state(sid, st):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = state_path(sid).with_suffix(f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(st, indent=1))
    os.replace(tmp, state_path(sid))


def clear_state(sid):
    try:
        state_path(sid).unlink()
    except OSError:
        pass


def claim_alert(st, key):
    """Record `key` as alerted in this streak; True only the first time."""
    alerted = st.setdefault("alerted", [])
    if key in alerted:
        return False
    alerted.append(key)
    return True


def prune_stale_state():
    cutoff = time.time() - STALE_STATE_SECONDS
    try:
        for p in STATE_DIR.glob("*.json"):
            if p.stat().st_mtime < cutoff:
                p.unlink()
    except OSError:
        pass


def log(rec):
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a") as f:
            f.write(json.dumps({"ts": now_iso(), **rec}) + "\n")
    except OSError:
        pass


# ------------------------------------------------------------------- notify --

def notify(event, severity, title, message, hook, extra=None):
    """Hand an alert to agent-notify (routing lives there). Never blocks the hook."""
    if not (os.path.isfile(NOTIFY_BIN) and os.access(NOTIFY_BIN, os.X_OK)):
        return
    payload = {
        "event": event, "severity": severity, "title": title, "message": message,
        "source": "api-error-recovery", "session_id": hook.get("session_id"),
        "cwd": hook.get("cwd"), "transcript_path": hook.get("transcript_path"),
        **(extra or {}),
    }
    try:
        # Hand off and return: the Stop path runs synchronously at every turn end,
        # so delivery (network, a phone) must never be waited on here.
        p = subprocess.Popen([NOTIFY_BIN], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True)
        if p.stdin:
            p.stdin.write(json.dumps(payload).encode())
            p.stdin.close()
    except (OSError, ValueError):
        pass


def short(text, n=240):
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


# --------------------------------------------------------------- diagnosis --

# Session-bound variables a spawned agent must not inherit, or it would attach
# to this session's messaging socket / Remote Control bridge as its child.
_SESSION_ENV = ("CLAUDECODE", "CLAUDE_PID", "CLAUDE_ENV_FILE", "CLAUDE_EFFORT")
_SESSION_ENV_PREFIXES = ("CLAUDE_CODE_",)
# Every hook in this toolkit stands down in the diagnostic agent's own session, so
# it never reflects, nudges, advises or re-diagnoses itself (same set the
# reflector gives its children).
CHILD_GUARDS = {"AGENT_HOOK_CHILD": "1", "API_RECOVERY_DISABLE": "1", "REFLECTOR_DISABLE": "1",
                "JEV_NUDGE_DISABLE": "1", "CONTEXT_ADVISOR_DISABLE": "1", "AGENT_NOTIFY_DISABLE": "1"}


def child_env():
    env = {k: v for k, v in os.environ.items()
           if k not in _SESSION_ENV and not k.startswith(_SESSION_ENV_PREFIXES)}
    env.update(CHILD_GUARDS)
    return env


def recent_api_errors(transcript, limit=6):
    """Last few API error lines from the transcript, for the briefing."""
    out = []
    try:
        with open(transcript, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 4 * 1024 * 1024))
            for line in f.read().decode("utf-8", "replace").splitlines():
                if '"isApiErrorMessage":true' not in line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                content = e.get("message", {}).get("content") or []
                text = " ".join(b.get("text", "") for b in content if isinstance(b, dict))
                out.append(f"{e.get('timestamp', '?')} [{e.get('error', '?')}] {short(text, 300)}")
    except OSError:
        pass
    return out[-limit:]


def briefing(hook, st, klass, report):
    errors = "\n".join(f"  - {line}" for line in recent_api_errors(hook.get("transcript_path"))) \
        or "  (none readable)"
    machine = os.environ.get("DF_MACHINE") or os.uname().nodename
    return f"""You are a diagnostic agent. A Claude Code session on this machine keeps failing
with API errors, and Claude Code's own request retries are already exhausted.
Find the root cause and, if it is safely fixable from this machine, fix it.

Failing session
  machine:        {machine}
  session id:     {hook.get('session_id')}
  cwd:            {hook.get('cwd')}
  transcript:     {hook.get('transcript_path')}
  error:          {hook.get('error')} (recovery class: {klass})
  error details:  {short(hook.get('error_details') or '', 400)}
  last message:   {short(hook.get('last_assistant_message') or '', 400)}
  failure streak: {st.get('attempts', 0)} turn-level retries since {st.get('first_ts')}
Recent API errors from the transcript:
{errors}

Check, citing evidence for each conclusion:
  1. Provider status: is the API itself degraded (e.g. https://status.anthropic.com/api/v2/status.json,
     or the AWS Health / Bedrock status when the session uses Bedrock or Mantle)?
  2. This machine's network path to the API (DNS, TLS, proxies, VPN, any local API proxy that is configured).
  3. Configuration: the model id the session uses and whether this account/provider can serve it;
     ~/.claude/settings.json is GENERATED from ~/.dotfiles (base/claude/settings.base.json +
     identities/*/claude/common.settings.json) — read those sources, never edit the generated file.
  4. Credentials: expired login or cloud credentials (report the command a human must run; do not
     start interactive logins).
  5. Anything in the transcript tail (a huge message, a malformed request) that makes the request itself fail.

Allowed fixes: restarting a local proxy/daemon you prove is broken, clearing a corrupt local cache,
or a machine-local override in ~/.dotfiles/claude/settings.local.json. NOT allowed: editing tracked
dotfiles, committing or pushing, deleting user data, touching other machines, or sending messages.

Finish with a short report in this shape (it is shown to the failing session and to the owner):
  ROOT CAUSE: <one line>
  EVIDENCE: <bullets>
  FIX APPLIED: <what you changed, or "none">
  NEXT STEP: <what the failing session or the owner should do>
Your final message is saved to: {report}
"""


def spawn_diagnosis(hook, st, klass):
    """Start the diagnostic agent; return (engine, report path) or (None, None)."""
    override = os.environ.get("API_RECOVERY_DIAG_CMD")
    # The briefing carries transcript error text and paths, and the agent runs
    # unattended, so it only starts when the machine opts in explicitly.
    engine = os.environ.get("API_RECOVERY_DIAG_ENGINE", "none").strip().lower()
    if override:
        engine = "custom"
    elif engine == "none":
        return None, None
    elif engine == "auto":
        engine = "codex" if shutil.which("codex") else "claude"
    if engine in ("codex", "claude") and not shutil.which(engine):
        return None, None

    sid = str(hook.get("session_id"))
    work = STATE_DIR / safe_name(sid)
    work.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report = work / f"diagnosis-{stamp}.md"
    brief = work / f"brief-{stamp}.md"
    brief.write_text(briefing(hook, st, klass, report))
    cwd = hook.get("cwd") if os.path.isdir(hook.get("cwd") or "") else str(HOME)

    q = shlex.quote
    if engine == "custom":
        cmd = f"export REPORT={q(str(report))}; {override} < {q(str(brief))}"
    elif engine == "codex":
        cmd = (f"codex exec --skip-git-repo-check -C {q(cwd)} "
               f"-c 'model_reasoning_effort=\"medium\"' -o {q(str(report))} - < {q(str(brief))}")
    else:
        cmd = (f"claude -p --dangerously-skip-permissions --output-format text "
               f"< {q(str(brief))} > {q(str(report))}")
    # The tmux window runs in the tmux server's environment, not child_env(), so
    # the guards travel inside the command itself.
    guards = " ".join(f"{k}={v}" for k, v in CHILD_GUARDS.items())
    cmd = f"export {guards}; {cmd}"

    where = os.environ.get("API_RECOVERY_DIAG_WHERE", "auto").strip().lower()
    pane = os.environ.get("TMUX_PANE")
    if where in ("auto", "tmux") and os.environ.get("TMUX") and pane and shutil.which("tmux"):
        # A window right after the failing session's own window, kept open after
        # the agent exits so the verdict stays readable.
        window_cmd = f"{cmd}; echo; echo {q(f'[diagnosis finished — report: {report}]')}"
        try:
            wid = subprocess.run(
                ["tmux", "new-window", "-d", "-a", "-t", pane, "-P", "-F", "#{window_id}",
                 "-n", f"diag:{sid[:6]}", "-c", cwd, window_cmd],
                capture_output=True, text=True, timeout=5).stdout.strip()
            if wid:
                subprocess.run(["tmux", "set-option", "-w", "-t", wid, "remain-on-exit", "on"],
                               capture_output=True, timeout=5)
                return engine, str(report)
        except (OSError, subprocess.SubprocessError):
            pass  # fall through to a detached background run
    try:
        with open(work / f"diagnosis-{stamp}.log", "ab") as logf:
            subprocess.Popen(["/bin/bash", "-c", cmd], cwd=cwd, env=child_env(),
                             stdin=subprocess.DEVNULL, stdout=logf, stderr=subprocess.STDOUT,
                             start_new_session=True)
        return engine, str(report)
    except OSError:
        return None, None


def diagnosis_started(st):
    """What an alert says about the diagnostic agent: nothing unless one was started."""
    if not st.get("diag_report"):
        return ""
    return f" A diagnostic agent ({st.get('diag_engine')}) is looking for the cause; report: {st['diag_report']}"


def diagnosis_excerpt(st, n=1200):
    path = st.get("diag_report")
    if not path:
        return ""
    try:
        text = Path(path).read_text().strip()
    except OSError:
        return f"\nA diagnostic agent ({st.get('diag_engine')}) is investigating; its report will be at {path}."
    if not text:
        return ""
    return (f"\nA diagnostic agent ({st.get('diag_engine')}) investigated this failure "
            f"(full report: {path}):\n{text[:n]}")


# -------------------------------------------------------------------- hooks --

def on_stop_failure(hook):
    sid = hook.get("session_id")
    if not sid or hook.get("agent_id"):
        return 0
    prune_stale_state()
    error = hook.get("error") or "unknown"
    text = " ".join(filter(None, [hook.get("error_details"), hook.get("last_assistant_message")]))
    klass = classify(error, text)

    st = load_state(sid) or {"attempts": 0, "failures": 0, "first_ts": now_iso(), "alerted": []}
    st["failures"] = st.get("failures", 0) + 1
    st["last_ts"] = now_iso()
    st["last_error"] = error
    st["last_class"] = klass
    st["last_text"] = short(text, 400)
    token = uuid.uuid4().hex
    st["token"] = token
    base = {"session_id": sid, "cwd": hook.get("cwd"), "error": error, "class": klass,
            "machine": os.environ.get("DF_MACHINE") or os.uname().nodename}

    if klass not in RETRYABLE:
        if klass == "config" and not st.get("diag_report"):
            engine, report = spawn_diagnosis(hook, st, klass)
            if report:
                st.update(diag_engine=engine, diag_report=report)
        # One alert per class per streak: a user retyping into a broken session
        # must not turn into a stream of texts.
        first_alert = claim_alert(st, klass)
        save_state(sid, st)
        if first_alert:
            notify(f"api_error.{klass}", "error" if klass in ("config", "auth", "billing") else "warn",
                   f"Claude session stuck: {error}",
                   f"{short(text, 200)}\n{ADVICE.get(klass, '')}{diagnosis_started(st)}", hook,
                   {"class": klass, "diag_report": st.get("diag_report")})
        log({**base, "decision": "no-retry", "failures": st["failures"]})
        return 0

    limit = OUTPUT_RETRIES if klass == "output" else MAX_ATTEMPTS
    if st.get("attempts", 0) >= limit:
        if claim_alert(st, "exhausted"):
            message = f"{error}: {short(text, 200)}"
            if st.get("diag_report"):
                message += f"\nDiagnosis: {st['diag_report']}"
            notify("api_error.exhausted", "error", f"Claude session gave up after {limit} retries",
                   message, hook, {"class": klass, "attempts": st.get("attempts")})
        save_state(sid, st)
        log({**base, "decision": "exhausted", "attempts": st.get("attempts")})
        return 0

    st["attempts"] = attempt = st.get("attempts", 0) + 1
    if attempt >= ESCALATE_AT and not st.get("diag_report"):
        engine, report = spawn_diagnosis(hook, st, klass)
        if report:
            st.update(diag_engine=engine, diag_report=report)
            notify("api_error.escalated", "warn", "Claude session: diagnosing repeated API errors",
                   f"Retry {attempt}/{limit} for {error}. {engine} is investigating: {report}",
                   hook, {"class": klass, "attempts": attempt})
    if attempt == NOTIFY_AT and claim_alert(st, "retrying"):
        notify("api_error.retrying", "warn", f"Claude session retrying ({attempt}/{limit})",
               f"{error}: {short(text, 200)}", hook, {"class": klass, "attempts": attempt})
    delay = 5.0 if klass == "output" else backoff(attempt)
    st["next_retry_ts"] = iso(time.time() + delay)
    save_state(sid, st)
    log({**base, "decision": "retry", "attempt": attempt, "delay_s": round(delay, 1)})

    # Sleep, but give up the retry the moment another turn takes over.
    deadline = time.time() + delay
    while time.time() < deadline:
        time.sleep(min(POLL, max(0.0, deadline - time.time())))
        cur = load_state(sid)
        if not cur or cur.get("token") != token:
            log({**base, "decision": "cancelled", "attempt": attempt})
            return 0

    cur = load_state(sid) or st
    if klass == "output":
        msg = (f"[api-error-recovery] The previous response hit the maximum output token limit and "
               f"was cut off (automatic retry {attempt} of {limit}). Continue from where it stopped, "
               f"and write long content in smaller pieces (several Edit calls or files) instead of "
               f"one very large response.")
    else:
        msg = (f"[api-error-recovery] The previous turn ended with an API error at {hhmmz()}: "
               f"{error} — \"{short(text, 220)}\". Claude Code's built-in request retries were "
               f"exhausted; this is automatic turn-level retry {attempt} of {limit}, after a "
               f"{round(delay)}s backoff. Continue the user's task from where it stopped. If the "
               f"interrupted step may have partly run (a command, an edit, a push), check its "
               f"actual state before repeating it.")
    msg += diagnosis_excerpt(cur)
    sys.stderr.write(msg + "\n")
    return 2


def on_stop(hook):
    sid = hook.get("session_id")
    st = load_state(sid) if sid else None
    if not st:
        return 0
    clear_state(sid)
    attempts = st.get("attempts", 0)
    log({"session_id": sid, "cwd": hook.get("cwd"), "decision": "recovered",
         "attempts": attempts, "failures": st.get("failures"), "error": st.get("last_error")})
    # Only close the loop on the phone if the phone heard about the streak.
    if any(a in st.get("alerted", []) for a in ("retrying", "exhausted")) or st.get("diag_report"):
        notify("api_error.recovered", "info", "Claude session recovered",
               f"Back after {attempts} automatic retries ({st.get('last_error')}).", hook,
               {"attempts": attempts})
    return 0


def on_prompt(hook):
    """A new prompt takes the session over: cancel any pending wake, whose sleeper
    sees the token change and exits quietly. Counters and alert flags stay, so a
    failure in the new turn continues the streak (and its escalation) instead of
    restarting it. Prints nothing: UserPromptSubmit stdout becomes model context."""
    sid = hook.get("session_id")
    st = load_state(sid) if sid else None
    if not st or not st.get("token"):
        return 0
    st["token"] = None
    st.pop("next_retry_ts", None)
    save_state(sid, st)
    log({"session_id": sid, "cwd": hook.get("cwd"), "decision": "superseded-by-prompt",
         "attempts": st.get("attempts")})
    return 0


def run_hook():
    if os.environ.get("API_RECOVERY_DISABLE") == "1":
        return 0
    try:
        hook = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    event = hook.get("hook_event_name")
    if event == "StopFailure":
        return on_stop_failure(hook)
    if event == "Stop":
        return on_stop(hook)
    if event == "UserPromptSubmit":
        return on_prompt(hook)
    return 0


def run_status():
    rows = []
    for p in sorted(STATE_DIR.glob("*.json")):  # a missing dir globs to nothing
        try:
            st = json.loads(p.read_text())
        except (OSError, ValueError):
            continue
        row = (f"{p.stem[:8]}  {st.get('last_class', '?'):9} {st.get('last_error', '?'):22} "
               f"attempts={st.get('attempts', 0)} failures={st.get('failures', 0)} "
               f"last={st.get('last_ts')} next={st.get('next_retry_ts', '-')}")
        if st.get("diag_report"):
            row += f"\n          diagnosis: {st['diag_report']}"
        rows.append(row)
    print("\n".join(rows) if rows else "no active API-error streaks")
    return 0


def main(argv):
    if argv[:1] == ["status"]:
        return run_status()
    if argv[:1] == ["classify"] and len(argv) >= 2:
        print(classify(argv[1], " ".join(argv[2:])))
        return 0
    try:
        return run_hook()
    except Exception as exc:  # a recovery hook must never become the failure
        log({"decision": "crash", "error": repr(exc)})
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
