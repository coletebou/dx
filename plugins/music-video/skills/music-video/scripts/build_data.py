#!/usr/bin/env python3
"""Regenerate build/data.js (timing + asset manifest) and extract clip frames for any new clips."""
import glob, json, os, subprocess
from PIL import Image
ROOT = os.environ.get("MV_PROJECT") or os.getcwd()  # project dir, not the skill dir
B = os.path.join(ROOT, 'build')
os.makedirs(os.path.join(B, 'assets', 'img'), exist_ok=True)
for f in glob.glob(os.path.join(ROOT, 'images', '*.png')):
    out = os.path.join(B, 'assets', 'img', os.path.splitext(os.path.basename(f))[0] + '.jpg')
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(f):
        Image.open(f).convert('RGB').save(out, quality=90)
for f in glob.glob(os.path.join(ROOT, 'clips', '*.mp4')):
    cid = os.path.splitext(os.path.basename(f))[0]; d = os.path.join(B, 'assets', 'clips', cid)
    if not os.path.isdir(d) or not glob.glob(d + '/f*.jpg') or os.path.getmtime(d) < os.path.getmtime(f):
        os.makedirs(d, exist_ok=True)
        for old in glob.glob(d + '/f*.jpg'):  # a shorter replacement clip must not inherit the old tail frames
            os.remove(old)
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-y', '-i', f, '-an', '-q:v', '3', f'{d}/f%04d.jpg'], check=True)
assets = {"img": {}, "clip": {}}
for f in sorted(glob.glob(f'{B}/assets/img/*.jpg')):
    assets["img"][os.path.splitext(os.path.basename(f))[0]] = os.path.relpath(f, B)
for d in sorted(glob.glob(f'{B}/assets/clips/*/')):
    cid = os.path.basename(os.path.dirname(d)); n = len(glob.glob(d + 'f*.jpg'))
    assets["clip"][cid] = {"dir": os.path.relpath(d, B).rstrip('/'), "n": n, "fps": 24}
timing = json.load(open(f'{B}/timing.json'))
open(f'{B}/data.js', 'w').write('window.TIMING = ' + json.dumps(timing) + ';\nwindow.ASSETS = ' + json.dumps(assets) + ';\n')
print(f"data.js: {len(assets['img'])} images, {len(assets['clip'])} clips, {len(timing['lines'])} lines")
