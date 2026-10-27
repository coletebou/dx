#!/usr/bin/env python3
"""Upload a reference song to ElevenLabs Music so new takes can be conditioned on it (audio reference).

Usage: MV_PROJECT=<dir> python3 el_reference.py <reference.mp3> [model]   (default: EL25_MODEL, else the el25 default)
Writes <project>/music/reference.json: {"song_id", "source", "composition_plan"} where composition_plan is the plan
ElevenLabs extracts from the reference (sections, durations, styles, lyrics), useful for matching its structure.
Then set lyrics.json "reference": {"song_id": ..., "strength": "xhigh"} and give each section "ref": [start_s, end_s].
The key travels in a request header via urllib, never on a command line.
"""
import json, os, sys, urllib.request, uuid

ROOT = os.environ.get("MV_PROJECT") or os.getcwd()   # the project directory, not the skill


def main():
    src, model = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else os.environ.get("EL25_MODEL", "music_v2_5")
    boundary = uuid.uuid4().hex
    parts = [(f'--{boundary}\r\nContent-Disposition: form-data; name="extract_composition_plan"\r\n\r\n{model}\r\n').encode(),
             (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{os.path.basename(src)}"\r\n'
              f'Content-Type: audio/mpeg\r\n\r\n').encode() + open(src, "rb").read() + b"\r\n",
             f"--{boundary}--\r\n".encode()]
    req = urllib.request.Request("https://api.elevenlabs.io/v1/music/upload", data=b"".join(parts), method="POST",
                                 headers={"xi-api-key": os.environ["ELEVENLABS_API_KEY"], "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=600) as r:
        res = json.loads(r.read())
    out = {"song_id": res["song_id"], "source": os.path.abspath(src), "composition_plan": res.get("composition_plan")}
    os.makedirs(os.path.join(ROOT, "music"), exist_ok=True)
    json.dump(out, open(os.path.join(ROOT, "music", "reference.json"), "w"), indent=1)
    plan = out["composition_plan"] or {}
    print(f"song_id {out['song_id']}; extracted plan: {len(plan.get('chunks', plan.get('sections', [])))} sections -> music/reference.json")


if __name__ == "__main__":
    main()
