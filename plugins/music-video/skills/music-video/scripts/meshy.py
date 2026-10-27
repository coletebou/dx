#!/usr/bin/env python3
"""Meshy client: image -> textured 3D model -> auto-rig -> animations. Files and task ids live in <project>/char/.

  python3 meshy.py lib [search]                    list animation-library entries
  python3 meshy.py model <image.png> <tag> [--prop] [--poly=N]   image-to-3D (PBR; A-pose unless --prop)
  python3 meshy.py rig <tag> [height_m]            auto-rig; downloads <tag>_rigged.glb (+ walking/running)
  python3 meshy.py anim <tag> <name> <id> [id...]  apply 1-10 library actions merged into <tag>_<name>.glb
The key (MESHY_API_KEY) travels in a request header via urllib, never on a command line. Tags and names are file
basenames. A paid task is submitted under a file lock and reused by any concurrent run with the same key; a failed or
cancelled task is dropped from state.json so rerunning the command submits a new one.
"""
import base64, contextlib, fcntl, json, os, re, sys, time, urllib.request

API = "https://api.meshy.ai/openapi/v1"
ROOT = os.environ.get("MV_PROJECT") or os.getcwd()   # the project directory, not the skill
HERE = os.path.join(ROOT, "char"); os.makedirs(HERE, exist_ok=True)
STATE = os.path.join(HERE, "state.json")
SAFE = re.compile(r"^[A-Za-z0-9_-]+$")


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + os.environ["MESHY_API_KEY"], "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read() or b"{}")


@contextlib.contextmanager
def locked():
    with open(STATE + ".lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        yield


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def write(d):
    json.dump(d, open(STATE + ".tmp", "w"), indent=1); os.replace(STATE + ".tmp", STATE)


def claim(key, submit):
    """The task id for key. The submit-or-reuse decision happens under the lock, so two runs never pay twice."""
    with locked():
        d = load()
        if key not in d:
            d[key] = submit(); write(d); print(f"submitted {key} -> {d[key]}", flush=True)
        return d[key]


def need(key):
    tid = load().get(key)
    if not tid: raise SystemExit(f"no {key} task yet; run that step first")
    return tid


def drop(key):
    with locked():
        d = load(); d.pop(key, None); write(d)


def wait(kind, tid, key, every=10, limit=1800):
    t0 = time.time()
    while time.time() - t0 < limit:
        try:
            r = call("GET", f"/{kind}/{tid}")
        except Exception as e:  # noqa: BLE001 - transient poll failures must not lose a paid task
            print(f"  poll error {type(e).__name__}: {e}", flush=True); time.sleep(every); continue
        st = r.get("status")
        print(f"  {kind} {tid[:8]} {st} {r.get('progress', '')}%", flush=True)
        if st == "SUCCEEDED":
            return r
        if st in ("FAILED", "CANCELED", "EXPIRED"):
            drop(key)   # a dead task must not block the retry
            raise SystemExit(f"{kind} {tid} {st}: {json.dumps(r.get('task_error') or r)[:400]}\nrerun the command to submit a new task")
        time.sleep(every)
    raise SystemExit(f"{kind} {tid} still running after {limit}s; rerun the same command to resume")


def fetch(url, name):
    out = os.path.join(HERE, name)
    urllib.request.urlretrieve(url, out); print(f"  -> {out} ({os.path.getsize(out) // 1024} KB)"); return out


def check(*names):
    bad = [n for n in names if not SAFE.match(n)]
    if bad: raise SystemExit(f"tags and names are file basenames (letters, digits, _ and -): {bad}")


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "lib":
        q = f"?search={args[0]}" if args else ""
        r = call("GET", "/animations/library" + q)
        items = r if isinstance(r, list) else r.get("result") or r.get("data") or r.get("items") or []
        for it in items:
            print(it.get("action_id", it.get("id")), it.get("name"), it.get("category"), it.get("sub_category", ""))
        if not items: print(json.dumps(r)[:1500])
    elif cmd == "model":
        img, tag = args[0], args[1]
        prop = "--prop" in args   # props: no pose normalisation, lighter mesh
        poly = int(next((a.split("=")[1] for a in args if a.startswith("--poly=")), 12000 if prop else 60000))
        check(tag); key = f"model:{tag}"
        tid = claim(key, lambda: call("POST", "/image-to-3d", {
            "image_url": "data:image/png;base64," + base64.b64encode(open(img, "rb").read()).decode(), "ai_model": "latest",
            "should_texture": True, "enable_pbr": True, "pose_mode": "" if prop else "a-pose", "should_remesh": True,
            "topology": "triangle", "target_polycount": poly})["result"])
        r = wait("image-to-3d", tid, key)
        fetch(r["model_urls"]["glb"], f"{tag}.glb")
        if r.get("thumbnail_url"): fetch(r["thumbnail_url"], f"{tag}_thumb.png")
    elif cmd == "rig":
        tag, h = args[0], float(args[1]) if len(args) > 1 else 1.65
        check(tag); key, model = f"rig:{tag}", need(f"model:{tag}")
        tid = claim(key, lambda: call("POST", "/rigging", {"input_task_id": model, "height_meters": h})["result"])
        r = wait("rigging", tid, key)["result"]
        fetch(r["rigged_character_glb_url"], f"{tag}_rigged.glb")
        for k in ("walking_glb_url", "running_glb_url"):
            if r.get("basic_animations", {}).get(k): fetch(r["basic_animations"][k], f"{tag}_{k.split('_')[0]}.glb")
    elif cmd == "anim":
        tag, name, ids = args[0], args[1], [int(a) for a in args[2:]]
        check(tag, name); key, rig = f"anim:{tag}:{name}", need(f"rig:{tag}")
        body = {"rig_task_id": rig, **({"action_id": ids[0]} if len(ids) == 1 else {"action_ids": ids}), "post_process": {"operation_type": "change_fps", "fps": 30}}
        tid = claim(key, lambda: call("POST", "/animations", body)["result"])
        r = wait("animations", tid, key)
        res = r.get("result", r)
        fetch(res.get("animation_glb_url") or res.get("processed_animation_fps_glb_url"), f"{tag}_{name}.glb")
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
