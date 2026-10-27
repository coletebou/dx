#!/usr/bin/env python3
"""Ask Gemini to listen to an audio file and critique it (a second pair of ears)."""
import base64, json, os, subprocess, sys
model = os.environ.get("LISTEN_MODEL", "gemini-3.8-flash")
path, prompt = sys.argv[1], sys.argv[2]
body = {"contents": [{"parts": [
    {"inline_data": {"mime_type": "audio/mpeg", "data": base64.b64encode(open(path, "rb").read()).decode()}},
    {"text": prompt}]}], "generationConfig": {"temperature": 0.2}}
tmp = path + ".listen_req.json"; json.dump(body, open(tmp, "w"))
out = subprocess.run(["curl", "-sS", "-X", "POST",
    f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
    "-K", "-", "-H", "Content-Type: application/json", "-d", "@" + tmp],
    input=f'header = "x-goog-api-key: {os.environ["GOOGLE_API_KEY"]}"\n',  # stdin, so the key stays out of ps
    capture_output=True, text=True, timeout=600)
os.remove(tmp)
r = json.loads(out.stdout)
try:
    print("".join(p.get("text", "") for p in r["candidates"][0]["content"]["parts"]))
except Exception:
    print(json.dumps(r)[:1500])
