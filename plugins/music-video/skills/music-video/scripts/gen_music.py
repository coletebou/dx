#!/usr/bin/env python3
"""Generate song candidates from lyrics.json on ElevenLabs Music (engines el25 and el1) and Lyria.

Usage: python3 gen_music.py [el25|el1|lyria ...] [--tag=NAME] [--seed=N] [--ref-strength=low|medium|high|xhigh] [--force]
Writes music/<engine>_<tag>.mp3 and refuses to overwrite an existing take (a paid generation) without --force.
ElevenLabs takes are stored for inpainting (store_for_inpainting): the returned song id is saved to
music/<engine>_<tag>.song_id so a single section can be regenerated later without redoing the song.
Audio reference (el25): set lyrics.json "reference" to {"song_id": ...} (see el_reference.py) and give sections
"ref": [start_s, end_s] (<= 30 s of the reference to condition on) and optionally "ref_strength" (low..xhigh).
Keys come from the environment (ELEVENLABS_API_KEY, GOOGLE_API_KEY); nothing is logged.
Models: EL25_MODEL, EL1_MODEL and LYRIA_MODEL override the defaults below (references/pipeline.md).
"""
import base64, json, os, sys, threading, time, urllib.error, urllib.request

EL_MODELS = {"el25": os.environ.get("EL25_MODEL", "music_v2_5"), "el1": os.environ.get("EL1_MODEL", "music_v1")}
LYRIA_MODEL = os.environ.get("LYRIA_MODEL", "lyria-3.5")
ROOT = os.environ.get("MV_PROJECT") or os.getcwd()   # the project directory, not the skill
OUT = os.path.join(ROOT, "music")
L = json.load(open(os.path.join(ROOT, "lyrics.json")))
G_POS, G_NEG = L["styles"]["positive"], L["styles"]["negative"]
STRENGTH = None


def post(url, body, headers, timeout=900):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        # song-id: set by ElevenLabs when the song is stored for inpainting (returned, not shared: engines run in threads)
        return r.status, r.headers.get("Content-Type", ""), r.read(), r.headers.get("song-id")


def el25_plan():
    chunks, ref = [], L.get("reference", {}).get("song_id")
    for s in L["sections"]:
        text = f"[{s['name']}]\n" + (f"{{{s['direction']}}}\n" if s.get("direction") else "") + "\n".join(s["lines"])
        chunk = {
            "text": text,
            "duration_ms": s["duration_ms"],
            "positive_styles": G_POS + s["local_styles"],
            "negative_styles": s.get("negative_styles", G_NEG),   # per-section override (e.g. from an extracted plan)
            "context_adherence": "high",
        }
        if ref and s.get("ref"):   # condition this section on a slice of the reference song
            a, b = s["ref"]
            chunk["conditioning_ref"] = {"song_id": ref, "range": {"start_ms": int(a * 1000), "end_ms": int(min(b, a + 30) * 1000)}}
            chunk["condition_strength"] = STRENGTH or s.get("ref_strength", L.get("reference", {}).get("strength", "high"))
        chunks.append(chunk)
    return {"chunks": chunks}


def el1_plan():
    return {
        "positive_global_styles": G_POS,
        "negative_global_styles": G_NEG,
        "sections": [{
            "section_name": s["name"],
            "positive_local_styles": s["local_styles"],
            "negative_local_styles": [],
            "duration_ms": s["duration_ms"],
            "lines": s["lines"],
        } for s in L["sections"]],
    }


def lyria_prompt():
    t, parts = 0, []
    for s in L["sections"]:
        a, b = t / 1000, (t + s["duration_ms"]) / 1000
        stamp = f"[{int(a // 60)}:{int(a % 60):02d} - {int(b // 60)}:{int(b % 60):02d}]"
        parts.append(f"{stamp} {s['name']} ({s['direction']}):\n" + "\n".join(s["lines"]))
        t += s["duration_ms"]
    style = "; ".join(G_POS)
    avoid = "; ".join(G_NEG)
    return (f"A {t // 1000}-second pop song titled \"{L['title']}\". Style: {style}. Avoid: {avoid}.\n"
            "Sing these exact lyrics, clearly enunciated, following the timestamps:\n\n" + "\n\n".join(parts))


def run_el(engine, plan, tag, seed=None):
    body = {"composition_plan": plan, "model_id": EL_MODELS[engine], "store_for_inpainting": True}
    if seed is not None:
        body["seed"] = seed
    if engine == "el1":   # the sectioned plan: hold each section to its duration
        body["respect_sections_durations"] = True
    url = "https://api.elevenlabs.io/v1/music?output_format=mp3_44100_192"
    code, ctype, data, sid = post(url, body, {"xi-api-key": os.environ["ELEVENLABS_API_KEY"]})
    path = os.path.join(OUT, f"{tag}.mp3")
    open(path, "wb").write(data)
    if sid: open(os.path.join(OUT, f"{tag}.song_id"), "w").write(sid + "\n")
    return f"{tag}: HTTP {code} {ctype} {len(data)} bytes -> {path}" + (f" (song id {sid}, stored for inpainting)" if sid else "")


def run_lyria(tag):
    body = {"model": LYRIA_MODEL, "input": lyria_prompt()}
    code, ctype, data, _ = post("https://generativelanguage.googleapis.com/v1beta/interactions", body,
                             {"x-goog-api-key": os.environ["GOOGLE_API_KEY"]})
    resp = json.loads(data)
    audio, texts = None, []

    def walk(o):
        nonlocal audio
        if isinstance(o, dict):
            if o.get("type") == "audio" and isinstance(o.get("data"), str):
                audio = (audio or b"") + base64.b64decode(o["data"])
            if o.get("type") == "text" and isinstance(o.get("text"), str):
                texts.append(o["text"])
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)
    walk(resp)
    open(os.path.join(OUT, f"{tag}.txt"), "w").write("\n".join(texts))
    if not audio:
        json.dump(resp, open(os.path.join(OUT, f"{tag}.response.json"), "w"), indent=1)
        return f"{tag}: HTTP {code} but no audio found (response saved)"
    path = os.path.join(OUT, f"{tag}.mp3")
    open(path, "wb").write(audio)
    return f"{tag}: HTTP {code} {len(audio)} bytes -> {path}"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--") and "=" in a)
    force = "--force" in sys.argv
    unknown = [a for a in sys.argv[1:] if a.startswith("--") and a != "--force" and a[2:].split("=", 1)[0] not in ("tag", "seed", "ref-strength")]
    unknown += [a for a in sys.argv[1:] if a.startswith("--") and "=" not in a and a != "--force"]
    engines = args or ["el25", "el1", "lyria"]
    bad = [e for e in engines if e not in ("el25", "el1", "lyria")]
    if unknown or bad:   # e.g. "--tag b" would otherwise run with tag "a" and treat "b" as an engine
        raise SystemExit(f"unknown arguments {sorted(set(unknown + bad))}; use el25|el1|lyria --tag=NAME --seed=N --force")
    suffix = opts.get("tag", "a")
    global STRENGTH
    STRENGTH = opts.get("ref-strength")   # overrides every section's condition_strength for this run
    seed = int(opts["seed"]) if "seed" in opts else None
    os.makedirs(OUT, exist_ok=True)
    json.dump(el25_plan(), open(os.path.join(OUT, "plan_el25.json"), "w"), indent=1)
    json.dump(el1_plan(), open(os.path.join(OUT, "plan_el1.json"), "w"), indent=1)
    open(os.path.join(OUT, "prompt_lyria.txt"), "w").write(lyria_prompt())
    jobs = {
        "el25": lambda: run_el("el25", el25_plan(), f"el25_{suffix}", seed),
        "el1": lambda: run_el("el1", el1_plan(), f"el1_{suffix}", seed),
        "lyria": lambda: run_lyria(f"lyria_{suffix}"),
    }

    def worker(name):
        t0 = time.time()
        take = os.path.join(OUT, f"{name}_{suffix}.mp3")
        if os.path.exists(take) and not force:
            print(f"{name}_{suffix}: exists, skipped (pass --force to replace it)", flush=True)
            return
        try:
            msg = jobs[name]()
        except urllib.error.HTTPError as e:
            msg = f"{name}: HTTP {e.code} {e.read()[:600].decode(errors='replace')}"
        except Exception as e:  # noqa: BLE001 - report every failure mode
            msg = f"{name}: ERROR {type(e).__name__}: {e}"
        print(f"[{time.time() - t0:5.0f}s] {msg}", flush=True)

    threads = [threading.Thread(target=worker, args=(n,)) for n in engines]
    [t.start() for t in threads]
    [t.join() for t in threads]


if __name__ == "__main__":
    main()
