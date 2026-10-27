#!/usr/bin/env python3
"""A/B each song take against a reference track the user loves: stitch the reference's chorus, a beep, then the take's
first chorus (found from its transcript), and ask Gemini how close B is to A. Writes music/ab/<take>.mp3 (the stitched clip) and music/ab/<take>.txt,
outside the music/*.mp3 glob so comparison clips never pass for takes.

Usage: python3 ab_ref.py <reference.mp3> <ref_chorus_start_s> "<hook phrase>" music/<take>.mp3 [...]
Run score_song.py first so each take has a transcript; without one, the take's excerpt starts at 45 s.
"""
import glob, json, os, re, subprocess, sys

LISTEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "listen.py")
PROMPT = """This clip has two excerpts separated by a short beep. Excerpt A (before the beep) is a reference song the listener loves.
Excerpt B (after the beep) is a new candidate. Rate 1-10 how close B is to A in overall sound: vocal timbre and delivery, arrangement,
production size, energy and emotional feel. Answer in 4 short lines: SIMILARITY=?, BETTER:, MISSING:, VERDICT:"""


def hook_time(take, phrase):
    js = sorted(glob.glob(take + ".*.stt.json"))
    if not js:
        return 45.0
    words = [w for w in json.load(open(js[0])).get("words", []) if w.get("type", "word") == "word"]
    norm = lambda s: re.sub(r"[^a-z']", "", s.lower())   # the same normalisation on both sides, so "stay, stay" matches
    toks, want = [norm(w["text"]) for w in words], [x for x in map(norm, phrase.split()) if x]
    for i in range(len(toks) - len(want) + 1):
        if toks[i:i + len(want)] == want:
            return max(0.0, words[i]["start"] - 1.5)
    return 45.0


def main():
    ref, ref_t0, hook, takes = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4:]
    for take in takes:
        abdir = os.path.join(os.path.dirname(take), "ab"); os.makedirs(abdir, exist_ok=True)
        base = os.path.join(abdir, os.path.basename(take)[:-4]); t0, clip = hook_time(take, hook), base + ".mp3"
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", str(ref_t0), "-t", "28", "-i", ref,
                        "-f", "lavfi", "-t", "1", "-i", "sine=frequency=1000:sample_rate=44100", "-ss", str(t0), "-t", "28", "-i", take,
                        "-filter_complex", "[0:a]aresample=44100,aformat=channel_layouts=stereo[a];[1:a]aformat=channel_layouts=stereo,volume=0.3[b];"
                        "[2:a]aresample=44100,aformat=channel_layouts=stereo[c];[a][b][c]concat=n=3:v=0:a=1[o]", "-map", "[o]", "-b:a", "160k", clip], check=True)
        out = subprocess.run(["python3", LISTEN, clip, PROMPT], capture_output=True, text=True, timeout=900).stdout
        open(base + ".txt", "w").write(f"[candidate excerpt from {t0:.1f}s]\n{out}")
        sim = re.search(r"SIMILARITY\W*([\d.]+)", out)
        print(f"{os.path.basename(take):20s} similarity {sim.group(1) if sim else '?'}", flush=True)


if __name__ == "__main__":
    main()
