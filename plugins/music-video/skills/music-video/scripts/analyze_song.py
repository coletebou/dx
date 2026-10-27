#!/usr/bin/env python3
"""Beat grid + lyric word timing for the chosen take -> build/timing.json (and build/song.mp3).

Usage: MV_PROJECT=<dir> python3 analyze_song.py <take-id>   (music/<take-id>.mp3 + its .stt.json from score_song.py)

Beat tracking: spectral-flux onset envelope, tempo by autocorrelation (90-160 BPM),
phase by comb-filter fit. Lyrics: intended words aligned to the STT word stream with
difflib; unmatched words are interpolated between matched neighbours and clamped to
their line window from the model's own lyric sheet.
"""
import difflib, json, os, re, sys
import numpy as np

ROOT = os.environ.get("MV_PROJECT") or os.getcwd()   # the project directory, not the skill
SONG = sys.argv[1] if len(sys.argv) > 1 else "lyria_c"
SR = 22050
L = json.load(open(os.path.join(ROOT, "lyrics.json")))


def onset_envelope(x, hop=256, n=1024):
    win = np.hanning(n)
    frames = np.lib.stride_tricks.sliding_window_view(x, n)[::hop] * win
    mag = np.abs(np.fft.rfft(frames, axis=1))
    logm = np.log1p(100 * mag)
    flux = np.maximum(0, np.diff(logm, axis=0)).sum(axis=1)
    flux = np.concatenate([[0], flux])
    flux -= np.convolve(flux, np.ones(16) / 16, mode="same")  # local mean removal
    return np.maximum(flux, 0), hop / SR


def beat_grid(x):
    env, dt = onset_envelope(x)
    lags = np.arange(int(60 / 160 / dt), int(60 / 90 / dt) + 1)
    ac = np.array([np.dot(env[:-l], env[l:]) for l in lags])
    # refine with a fine search around the best lag (sub-frame precision)
    best = lags[np.argmax(ac)] * dt
    cands = np.linspace(best * 0.985, best * 1.015, 301)
    dur = len(env) * dt

    def score(period, phase):
        beats = np.arange(phase, dur, period)
        idx = np.clip(np.round(beats / dt).astype(int), 0, len(env) - 1)
        return env[idx].sum()
    best_s, best_p, best_ph = -1, None, None
    for p in cands:
        for ph in np.linspace(0, p, 64, endpoint=False):
            s = score(p, ph)
            if s > best_s:
                best_s, best_p, best_ph = s, p, ph
    return 60 / best_p, best_p, best_ph, dur


def norm(w):
    w = w.lower().replace("’", "'")
    return re.sub(r"[^a-z0-9']", "", w)


NUMS = {"645": "six hundred forty five", "85000": "eighty five thousand", "85": "eighty five", "100": "one hundred",
        "850": "eight fifty", "12": "twelve", "7": "seven", "10": "ten", "5": "five", "1": "one", "0": "zero"}


def expand(word):
    n = norm(word).replace("%", "")
    n = re.sub(r"[^a-z0-9']", "", n)
    if n in NUMS:
        return NUMS[n].split()
    return [n] if n else []


def main():
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    src, song, f32 = os.path.join(ROOT, "music", f"{SONG}.mp3"), os.path.join(ROOT, "build", "song.mp3"), os.path.join(ROOT, "build", "song_mono_22k.f32")
    # Compare contents, not mtimes: switching back to an earlier (older) take must still replace build/song.mp3.
    import filecmp, shutil
    if os.path.exists(src) and not (os.path.exists(song) and filecmp.cmp(src, song, shallow=False)):
        shutil.copyfile(src, song)
    if not os.path.exists(f32) or os.path.getmtime(song) > os.path.getmtime(f32):
        import subprocess; subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", song, "-ac", "1", "-ar", str(SR), "-f", "f32le", f32], check=True)
    x = np.fromfile(f32, dtype=np.float32)
    bpm, period, phase, dur = beat_grid(x)
    beats = [round(float(b), 4) for b in np.arange(phase, dur, period)]

    sc = os.path.join(ROOT, "music", f"{SONG}.mp3.scribe.stt.json")
    stt = json.load(open(sc if os.path.exists(sc) else os.path.join(ROOT, "music", f"{SONG}.mp3.whisper.stt.json")))
    stt["words"] = [w for w in stt["words"] if w.get("type", "word") == "word"]
    heard = []  # (normalized token, start, end)
    for w in stt["words"]:
        toks = expand(w["text"])
        if not toks:
            continue
        span = (w["end"] - w["start"]) / len(toks)
        for k, t in enumerate(toks):
            heard.append((t, w["start"] + k * span, w["start"] + (k + 1) * span))

    # model lyric sheet: [t:] line  -> line windows (Lyria writes one; ElevenLabs takes have none)
    sheet_path = os.path.join(ROOT, "music", f"{SONG}.txt")
    sheet_txt = open(sheet_path).read() if os.path.exists(sheet_path) else ""
    sheet = [float(m.group(1)) for m in re.finditer(r"^\[(\d+(?:\.\d+)?):\]", sheet_txt, re.M)]

    lines, want = [], []
    li = 0
    for s in L["sections"]:
        for line in s["lines"]:
            toks = []
            for raw in line.split():
                parts = re.sub(r"[-–]", " ", raw).split()
                for p in parts:
                    n = norm(p)
                    if n:
                        toks.append((raw, n))
            lines.append({"section": s["name"], "text": line, "sheet": sheet[li] if li < len(sheet) else None,
                          "adlib": [m.group(1) for m in re.finditer(r"\((.*?)\)", line)], "tokens": toks})
            for k, (raw, n) in enumerate(toks):
                want.append((li, k, n))
            li += 1

    sm = difflib.SequenceMatcher(None, [w[2] for w in want], [h[0] for h in heard], autojunk=False)
    times = [None] * len(want)
    for a, b, size in sm.get_matching_blocks():
        for k in range(size):
            times[a + k] = (heard[b + k][1], heard[b + k][2])
    # Repeated choruses have identical words, so a global match can pin one chorus's lyrics to another's audio.
    # When the sheet has exactly one entry per line, drop matches that fall outside their line's window.
    if len(sheet) == li:
        for i, (line_i, _, _) in enumerate(want):
            lo = sheet[line_i] - 4
            hi = (sheet[line_i + 1] if line_i + 1 < li else dur) + 4
            if times[i] and not lo <= times[i][0] <= hi:
                times[i] = None
    # interpolate gaps
    known = [i for i, t in enumerate(times) if t]
    for i in range(len(times)):
        if times[i]:
            continue
        prev = max([k for k in known if k < i], default=None)
        nxt = min([k for k in known if k > i], default=None)
        if prev is not None and nxt is not None:
            a, b = times[prev][1], times[nxt][0]
            frac0 = (i - prev) / (nxt - prev)
            frac1 = (i - prev + 1) / (nxt - prev)
            times[i] = (a + (b - a) * frac0 - 0.0, a + (b - a) * frac1)
        elif prev is not None:
            times[i] = (times[prev][1], times[prev][1] + 0.3)
        else:
            times[i] = (max(0, times[nxt][0] - 0.3), times[nxt][0])
    matched = sum(1 for i in range(len(want)) if i in set(known))

    out_lines = []
    for idx, line in enumerate(lines):
        ws = [(want[i], times[i]) for i in range(len(want)) if want[i][0] == idx]
        words = []
        # collapse tokens back to display words (hyphenated words become one)
        disp = []
        for raw in line["text"].split():
            disp.append(raw)
        tok_iter = iter(ws)
        for raw in disp:
            n_parts = len([p for p in re.sub(r"[-–]", " ", raw).split() if norm(p)])
            parts = [next(tok_iter) for _ in range(n_parts)] if n_parts else []
            if parts:
                words.append({"w": raw, "t0": round(parts[0][1][0], 3), "t1": round(parts[-1][1][1], 3)})
            elif words:
                words.append({"w": raw, "t0": words[-1]["t1"], "t1": words[-1]["t1"]})
        start = words[0]["t0"] if words else line["sheet"]
        end = words[-1]["t1"] if words else line["sheet"]
        out_lines.append({"section": line["section"], "text": line["text"], "t0": round(start, 3), "t1": round(end, 3),
                          "sheet": line["sheet"], "words": words})

    sections, prev = [], None
    for ln in out_lines:
        if ln["section"] != prev or (sections and ln["sheet"] and ln["sheet"] - sections[-1]["lines_end"] > 4):
            sections.append({"name": ln["section"], "t0": ln["t0"], "lines_end": ln["t1"]})
            prev = ln["section"]
        sections[-1]["lines_end"] = ln["t1"]

    json.dump({"song": SONG, "duration": round(dur, 3), "bpm": round(bpm, 3), "beat": round(period, 5),
               "beat0": round(float(phase), 4), "beats": beats, "lines": out_lines, "sections": sections,
               "alignment": {"matched_words": matched, "total_words": len(want)}},
              open(os.path.join(ROOT, "build", "timing.json"), "w"), indent=1)
    print(f"bpm={bpm:.3f} beat={period:.4f}s beat0={phase:.3f}s dur={dur:.1f}s  aligned {matched}/{len(want)} words")
    for ln in out_lines:
        print(f"  {ln['t0']:7.2f}-{ln['t1']:7.2f} (sheet {ln['sheet']})  {ln['text'][:70]}")


if __name__ == "__main__":
    main()
