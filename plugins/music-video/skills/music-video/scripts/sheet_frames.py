#!/usr/bin/env python3
"""Tile rendered frames (out/frames/fNNNNN.jpg) at given times: python3 sheet_frames.py START END STEP OUT [cols] [w]"""
import sys, os
from PIL import Image, ImageDraw, ImageFont
a, b, step, out = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
cols = int(sys.argv[5]) if len(sys.argv) > 5 else 8; w = int(sys.argv[6]) if len(sys.argv) > 6 else 240; h = w * 9 // 16
ts = []; t = a
while t <= b + 1e-6: ts.append(round(t, 3)); t += step
rows = (len(ts) + cols - 1) // cols
sheet = Image.new('RGB', (cols * w, rows * h), 'black'); d = ImageDraw.Draw(sheet)
font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf', 14)
for i, t in enumerate(ts):
    f = f'out/frames/f{int(round(t * 30)) + 1:05d}.jpg'
    x, y = (i % cols) * w, (i // cols) * h
    if os.path.exists(f): sheet.paste(Image.open(f).resize((w, h)), (x, y))
    d.rectangle([x, y, x + 52, y + 17], fill=(0, 0, 0)); d.text((x + 3, y + 1), f'{t:.1f}', fill=(255, 255, 0), font=font)
sheet.save(out, quality=85); print(out, len(ts))
