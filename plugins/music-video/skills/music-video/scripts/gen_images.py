#!/usr/bin/env python3
"""Generate stills from images/prompts.json with OpenAI's gpt-image (IMAGE_MODEL overrides the model; skips ids that already exist).

Usage: python3 gen_images.py [id ...] [--force] [--workers=5]

Each item: {"id", "prompt", optional "look": "<style key in prompts.json>" (or the older "night"/"surreal" flags),
"size", and "refs": ["<id>", ...]}. Items with refs go through /v1/images/edits with those stills attached, which
keeps a recurring character consistent: generate a reference sheet first, then list it in every scene's refs.
Referenced stills (and their own refs) are generated first, in dependency order, even when only some ids are requested.
"""
import base64, json, os, re, subprocess, sys, tempfile, threading, time

ROOT = os.environ.get("MV_PROJECT") or os.getcwd()   # the project directory, not the skill
IMG = os.path.join(ROOT, "images")
SPEC = json.load(open(os.path.join(IMG, "prompts.json")))
MODEL = os.environ.get("IMAGE_MODEL", "gpt-image-2.5-flare")


def style_for(item):
    if item.get("look"):
        return SPEC[item["look"]]
    return SPEC["surreal_style"] if item.get("surreal") else SPEC["night_style"] if item.get("night") else SPEC["style"]


def generate(item):
    out = os.path.join(IMG, item["id"] + ".png")
    prompt = item["prompt"] + " " + style_for(item)
    size = item.get("size", SPEC["size"])
    auth = f'header = "Authorization: Bearer {os.environ["OPENAI_API_KEY"]}"\n'   # key via stdin, not argv
    req = None
    if item.get("refs"):   # multipart edit; --form-string keeps ";" and "@" in the prompt literal
        cmd = ["curl", "-sS", "https://api.openai.com/v1/images/edits", "-K", "-",
               "--form-string", f"model={MODEL}", "--form-string", f"prompt={prompt}",
               "--form-string", f"size={size}", "--form-string", "quality=high", "--form-string", "n=1"]
        if SPEC.get("input_fidelity"):
            cmd += ["--form-string", f"input_fidelity={SPEC['input_fidelity']}"]
        for ref in item["refs"]:
            cmd += ["-F", f"image[]=@{os.path.join(IMG, ref + '.png')};type=image/png"]
    else:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"model": MODEL, "prompt": prompt, "size": size, "quality": "high", "n": 1}, f)
            req = f.name
        cmd = ["curl", "-sS", "https://api.openai.com/v1/images/generations", "-K", "-",
               "-H", "Content-Type: application/json", "-d", "@" + req]
    try:
        r = subprocess.run(cmd, input=auth, capture_output=True, text=True, timeout=600)
    finally:
        if req:
            os.remove(req)
    data = json.loads(r.stdout or "{}")
    if not data.get("data"):
        return f"{item['id']}: FAILED {json.dumps(data)[:300]}"
    open(out, "wb").write(base64.b64decode(data["data"][0]["b64_json"]))
    return f"{item['id']}: ok ({data.get('usage', {}).get('output_tokens')} out tokens)"


def main():
    ids = [a for a in sys.argv[1:] if not a.startswith("--")]
    force = "--force" in sys.argv
    workers = int(next((a.split("=")[1] for a in sys.argv if a.startswith("--workers=")), 5))
    safe = re.compile(r"^[A-Za-z0-9_-]+$")   # ids and refs are basenames under images/, never paths
    bad = sorted({x for i in SPEC["images"] for x in [i["id"], *i.get("refs", [])] if not safe.match(x)})
    if bad:
        raise SystemExit(f"unsafe image ids or refs (use letters, digits, _ and -): {bad}")
    by_id = {i["id"]: i for i in SPEC["images"]}
    have = lambda x: os.path.exists(os.path.join(IMG, x + ".png"))
    missing = sorted({r for i in SPEC["images"] for r in i.get("refs", []) if r not in by_id and not have(r)})
    if missing:
        raise SystemExit(f"refs name stills that neither exist nor are listed: {missing}")
    # the requested stills plus, transitively, every listed reference they need that is not on disk yet
    want, stack = set(), list(ids or by_id)
    while stack:
        x = stack.pop()
        if x in want or x not in by_id: continue
        want.add(x); stack += [r for r in by_id[x].get("refs", []) if not have(r)]
    todo = [i for i in SPEC["images"] if i["id"] in want and (force or not have(i["id"]))]
    print(f"{len(todo)} images to generate with {MODEL}", flush=True)
    # phases in dependency order: an item runs once every still it references exists on disk
    while todo:
        ready = [i for i in todo if all(have(r) for r in i.get("refs", []))]
        if not ready:
            raise SystemExit(f"cannot generate {[i['id'] for i in todo]}: their refs failed or form a cycle")
        run_phase(ready, workers)
        failed = [i["id"] for i in ready if not have(i["id"])]
        if failed:
            print(f"not generated: {failed}", flush=True)   # anything that references them stops at the check above
        todo = [i for i in todo if i not in ready]


def run_phase(items, workers):
    lock, queue = threading.Lock(), list(items)

    def worker():
        while True:
            with lock:
                if not queue:
                    return
                item = queue.pop(0)
            t0 = time.time()
            try:
                msg = generate(item)
            except Exception as e:  # noqa: BLE001 - keep the batch going, report failures
                msg = f"{item['id']}: ERROR {e}"
            print(f"[{time.time() - t0:4.0f}s] {msg}", flush=True)

    threads = [threading.Thread(target=worker) for _ in range(min(workers, len(items)))]
    [t.start() for t in threads]
    [t.join() for t in threads]


if __name__ == "__main__":
    main()
