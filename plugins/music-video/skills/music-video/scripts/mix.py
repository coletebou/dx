#!/usr/bin/env python3
"""Mix sound-effect cues under the song and master to -14 LUFS / -1 dBTP -> build/mix.wav.

Usage: MV_PROJECT=<dir> python3 mix.py [--target -14] [--ceiling -1]
Reads <project>/cues.json, a list of cues. Each cue names an effect file (sfx/<name>.mp3), a gain in dB, and ONE of:
  {"t": 4.05}                          absolute song time
  {"line": 41, "word": "film"}         when that word of lyric line 41 is sung (regex, case-insensitive)
  {"cut": 11}                          the renderer's cut time for line 11 (half-bar grid before the vocal)
optional: "offset" seconds, "fade_in" seconds.
Mastering: measure, apply one linear gain to target, add alimiter (level=0) only if the true peak would exceed the
ceiling, then re-measure and correct once. alimiter level=1 (the default) silently undoes the loudness target.
"""
import json, math, os, re, subprocess, sys

ROOT = os.environ.get("MV_PROJECT") or os.getcwd()
B = os.path.join(ROOT, "build")
T = json.load(open(os.path.join(B, "timing.json")))
BEAT, BEAT0, LINES = T["beat"], T["beat0"], T["lines"]
args = dict(zip(sys.argv[1::2], sys.argv[2::2]))
TARGET, CEIL = float(args.get("--target", -14)), float(args.get("--ceiling", -1))


def cut(i):  # mirror of timeline.js L(i)
    return BEAT0 + math.floor((LINES[i]["t0"] + .12 - BEAT0) / (2 * BEAT)) * 2 * BEAT


def when(c):
    if "t" in c:
        t = c["t"]
    elif "cut" in c:
        t = cut(c["cut"])
    else:
        ws = [w for w in LINES[c["line"]]["words"] if not w["w"].startswith("(")]
        t = next((w["t0"] for w in ws if re.search(c["word"], w["w"], re.I)), ws[0]["t0"])
    return t + c.get("offset", 0)


def measure(path):
    err = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    return float(re.findall(r"I:\s+(-?[\d.]+) LUFS", err)[-1]), float(re.findall(r"Peak:\s+(-?[\d.]+) dBFS", err)[-1])


def ff(*a):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *a], check=True)


def main():
    cues = json.load(open(os.path.join(ROOT, "cues.json")))
    inputs, filt, labels = ["-i", os.path.join(B, "song.mp3")], [], ["[0:a]"]
    for k, c in enumerate(cues, start=1):
        inputs += ["-i", os.path.join(ROOT, "sfx", f"{c['sfx']}.mp3")]
        ms = int(round(when(c) * 1000))
        fade = f",afade=t=in:d={c['fade_in']}" if c.get("fade_in") else ""
        filt.append(f"[{k}:a]aresample=44100,aformat=channel_layouts=stereo{fade},volume={c.get('db', -18)}dB,adelay={ms}|{ms}[s{k}]")
        labels.append(f"[s{k}]")
    filt.append("".join(labels) + f"amix=inputs={len(labels)}:normalize=0:duration=first[m]")
    raw, out = os.path.join(B, "mix_raw.wav"), os.path.join(B, "mix.wav")
    ff(*inputs, "-filter_complex", ";".join(filt), "-map", "[m]", "-c:a", "pcm_s24le", raw)
    i0, tp0 = measure(raw)
    limiter = f"alimiter=limit={10 ** ((CEIL - .3) / 20):.4f}:level=0:attack=5:release=60"
    chain = f"volume={TARGET - i0:.2f}dB"
    if tp0 + (TARGET - i0) > CEIL:
        chain += "," + limiter
    ff("-i", raw, "-af", chain, "-c:a", "pcm_s24le", out)
    i1, tp1 = measure(out)
    if abs(i1 - TARGET) > .3:
        fix = out + ".fix.wav"; ff("-i", out, "-af", f"volume={TARGET - i1:.2f}dB", "-c:a", "pcm_s24le", fix); os.replace(fix, out); i1, tp1 = measure(out)
    if tp1 > CEIL:  # the loudness fix-up above runs after the limiter and can push peaks back over the ceiling
        fix = out + ".fix.wav"; ff("-i", out, "-af", limiter, "-c:a", "pcm_s24le", fix); os.replace(fix, out); i1, tp1 = measure(out)
    print(f"{len(cues)} cues  raw {i0:.1f} LUFS / {tp0:.1f} dBTP  ->  master {i1:.1f} LUFS / {tp1:.1f} dBTP  ({out})")
    for c in cues:
        print(f"  {when(c):7.2f}s  {c['sfx']:12s} {c.get('db', -18):+.0f} dB")


if __name__ == "__main__":
    main()
