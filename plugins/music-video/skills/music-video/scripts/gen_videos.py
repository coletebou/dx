#!/usr/bin/env python3
"""Image-to-video with xAI's grok-imagine-video (VIDEO_MODEL overrides the model): submit every clip in clips/jobs.json, poll, download.

Usage: python3 gen_videos.py [id ...] [--force] [--max-wait=MINUTES]
Skips clips whose mp4 already exists. Logs cost per clip (cost_in_usd_ticks / 1e10 = USD).
Submitted request ids are saved to clips/pending.json as they are accepted, so an interrupted run (or a crash
while polling) resumes those paid jobs instead of submitting them again.
"""
import base64, io, json, os, re, subprocess, sys, tempfile, time

ROOT = os.environ.get("MV_PROJECT") or os.getcwd()   # the project directory, not the skill
CLIPS = os.path.join(ROOT, "clips")
JOBS = json.load(open(os.path.join(CLIPS, "jobs.json")))
PENDING = os.path.join(CLIPS, "pending.json")
MODEL = os.environ.get("VIDEO_MODEL", "grok-imagine-video-1.5")
STYLE = " Natural 35mm film look, bright clean daylight, true-to-life greens and blues, no text, no orange tint."
SAFE = re.compile(r"^[A-Za-z0-9_-]+$")   # job ids and image names are file basenames, never paths


def api(method, path, body=None):
    cmd = ["curl", "-sS", "--max-time", "280", "-X", method, "https://api.x.ai/v1" + path, "-K", "-"]
    tmp = None
    if body is not None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump(body, f)
            tmp = f.name
        cmd += ["-H", "Content-Type: application/json", "-d", "@" + tmp]
    try:  # the key reaches curl on stdin, so it never shows up in process listings
        out = subprocess.run(cmd, input=f'header = "Authorization: Bearer {os.environ["XAI_API_KEY"]}"\n',
                             capture_output=True, text=True, timeout=300)
    finally:
        if tmp:
            os.remove(tmp)
    return json.loads(out.stdout or "{}")


def image_data_url(name):
    from PIL import Image
    im = Image.open(os.path.join(ROOT, "images", name + ".png")).convert("RGB")
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=92)
    return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()


def save_pending(pending):
    tmp = PENDING + ".tmp"
    json.dump(pending, open(tmp, "w"), indent=1)
    os.replace(tmp, PENDING)


def main():
    ids = [a for a in sys.argv[1:] if not a.startswith("--")]
    force = "--force" in sys.argv
    max_wait = 60 * float(next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--max-wait=")), 30))
    bad = [j for j in JOBS if not SAFE.match(j["id"]) or not SAFE.match(j["image"])]
    if bad:
        raise SystemExit(f"unsafe id/image names (use letters, digits, _ and -): {[j['id'] for j in bad]}")
    pending = json.load(open(PENDING)) if os.path.exists(PENDING) else {}   # request_id -> job
    if pending:
        print(f"resuming {len(pending)} submitted job(s) from {PENDING}", flush=True)
    in_flight = {j["id"] for j in pending.values()}
    todo = [j for j in JOBS if (not ids or j["id"] in ids) and j["id"] not in in_flight
            and (force or not os.path.exists(os.path.join(CLIPS, j["id"] + ".mp4")))]
    for j in todo:
        style = j.get("style", STYLE)
        body = {"model": MODEL, "prompt": j["prompt"] + style, "image": {"url": image_data_url(j["image"])},
                "duration": j.get("duration", 6), "aspect_ratio": j.get("aspect_ratio", "16:9"), "resolution": "720p"}
        try:
            r = api("POST", "/videos/generations", body)
        except (ValueError, subprocess.TimeoutExpired) as e:
            r = {"error": f"{type(e).__name__}: {e}"}
        if "request_id" in r:
            pending[r["request_id"]] = j
            save_pending(pending)
            print(f"submitted {j['id']} -> {r['request_id']}", flush=True)
        else:
            print(f"SUBMIT FAILED {j['id']}: {json.dumps(r)[:300]}", flush=True)
        time.sleep(1)
    total, deadline = 0.0, time.time() + max_wait
    while pending and time.time() < deadline:
        time.sleep(8)
        for rid, j in list(pending.items()):
            try:
                r = api("GET", f"/videos/{rid}")
                st = r.get("status")
                if st == "done":
                    subprocess.run(["curl", "-sS", "-f", "-o", os.path.join(CLIPS, j["id"] + ".mp4"), r["video"]["url"]],
                                   check=True, timeout=300)
                    cost = r.get("usage", {}).get("cost_in_usd_ticks", 0) / 1e10
                    total += cost
                    print(f"done {j['id']}  ${cost:.2f}", flush=True)
                elif st in ("failed", "expired") or (st is None and "error" in json.dumps(r).lower()):
                    print(f"FAILED {j['id']}: {json.dumps(r)[:300]}", flush=True)
                else:
                    continue
            except (ValueError, KeyError, subprocess.SubprocessError) as e:   # one bad poll never drops paid jobs
                print(f"poll error {j['id']} ({type(e).__name__}); retrying", flush=True)
                continue
            del pending[rid]
            save_pending(pending)
    if pending:
        print(f"gave up waiting after {max_wait / 60:.0f} min; {len(pending)} job(s) kept in {PENDING}, rerun to resume", flush=True)
    else:
        os.path.exists(PENDING) and os.remove(PENDING)
    print(f"total ${total:.2f}", flush=True)


if __name__ == "__main__":
    main()
