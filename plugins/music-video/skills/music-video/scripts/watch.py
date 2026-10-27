#!/usr/bin/env python3
"""Ask Gemini to watch a video and critique it (a second pair of eyes). Uploads through the Files API, so large
files work; the key travels in a header via urllib, never on a command line.

Usage: python3 watch.py <video.mp4> "<prompt>"      (WATCH_MODEL overrides the model)
"""
import json, os, sys, time, urllib.request

KEY, MODEL = os.environ["GOOGLE_API_KEY"], os.environ.get("WATCH_MODEL", "gemini-3.8-flash")
BASE = "https://generativelanguage.googleapis.com"


def req(url, data=None, headers=None, method=None):
    r = urllib.request.Request(url, data=data, method=method, headers={"x-goog-api-key": KEY, **(headers or {})})
    with urllib.request.urlopen(r, timeout=600) as resp:
        return resp.headers, resp.read()


def upload(path):
    size = os.path.getsize(path)
    h, _ = req(f"{BASE}/upload/v1beta/files", data=json.dumps({"file": {"display_name": os.path.basename(path)}}).encode(), method="POST",
               headers={"X-Goog-Upload-Protocol": "resumable", "X-Goog-Upload-Command": "start", "X-Goog-Upload-Header-Content-Length": str(size),
                        "X-Goog-Upload-Header-Content-Type": "video/mp4", "Content-Type": "application/json"})
    with open(path, "rb") as fh:   # streamed in blocks by http.client, never read whole into memory
        _, body = req(h["X-Goog-Upload-URL"], data=fh, method="POST",
                      headers={"X-Goog-Upload-Offset": "0", "X-Goog-Upload-Command": "upload, finalize", "Content-Length": str(size)})
    f = json.loads(body)["file"]
    while f.get("state") == "PROCESSING":
        time.sleep(4); f = json.loads(req(f"{BASE}/v1beta/{f['name']}")[1])
    if f.get("state") != "ACTIVE":
        raise SystemExit(f"upload failed: {f}")
    return f


def main():
    path, prompt = sys.argv[1], sys.argv[2]
    f = upload(path)
    body = {"contents": [{"parts": [{"file_data": {"mime_type": "video/mp4", "file_uri": f["uri"]}}, {"text": prompt}]}], "generationConfig": {"temperature": .2}}
    _, out = req(f"{BASE}/v1beta/models/{MODEL}:generateContent", data=json.dumps(body).encode(), method="POST", headers={"Content-Type": "application/json"})
    r = json.loads(out)
    try:
        print("".join(p.get("text", "") for p in r["candidates"][0]["content"]["parts"]))
    except (KeyError, IndexError):
        print(json.dumps(r)[:1500])
    try:
        req(f"{BASE}/v1beta/{f['name']}", method="DELETE")
    except Exception:  # noqa: BLE001 - uploads expire on their own after 48 h
        pass


if __name__ == "__main__":
    main()
