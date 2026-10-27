#!/usr/bin/env python3
"""Transcribe song candidates (ElevenLabs Scribe by default, STT=whisper for OpenAI) and score lyric fidelity.

Usage: python3 score_song.py music/el25_a.mp3 [...]   (relative paths resolve from the cwd, then from MV_PROJECT)
Writes <song>.stt.json next to each file (word timestamps) and prints a scorecard.
"""
import difflib, json, os, re, subprocess, sys

ROOT = os.environ.get("MV_PROJECT") or os.getcwd()   # the project directory, not the skill
L = json.load(open(os.path.join(ROOT, "lyrics.json")))


def norm(w):
    return re.sub(r"[^a-z0-9']", "", w.lower().replace("’", "'"))


def intended_words():
    out = []
    for s in L["sections"]:
        for line in s["lines"]:
            line = re.sub(r"\(.*?\)", " ", line)  # ad-libs are optional
            out += [norm(w) for w in line.split() if norm(w)]
    return out


def scribe(path):
    engine = os.environ.get("STT", "scribe")
    cache = f"{path}.{engine}.stt.json"
    if os.path.exists(cache) and os.path.getmtime(cache) >= os.path.getmtime(path):  # a regenerated take re-transcribes
        return json.load(open(cache))
    if engine == "scribe":  # ElevenLabs Scribe (preferred; SCRIBE_MODEL overrides the model)
        cmd = ["curl", "-sS", "-f", "-X", "POST", "https://api.elevenlabs.io/v1/speech-to-text",
               "-F", "model_id=" + os.environ.get("SCRIBE_MODEL", "scribe_v2"),
               "-F", "timestamps_granularity=word", "-F", "tag_audio_events=false", "-F", "language_code=en",
               "-F", "file=@" + path]
        header = "xi-api-key: " + os.environ["ELEVENLABS_API_KEY"]
    else:  # OpenAI Whisper fallback (WHISPER_MODEL overrides the model)
        cmd = ["curl", "-sS", "-f", "https://api.openai.com/v1/audio/transcriptions",
               "-F", "model=" + os.environ.get("WHISPER_MODEL", "whisper-1"),
               "-F", "response_format=verbose_json", "-F", "timestamp_granularities[]=word",
               "-F", "timestamp_granularities[]=segment", "-F", "language=en", "-F", "file=@" + path]
        header = "Authorization: Bearer " + os.environ["OPENAI_API_KEY"]
    # the key goes to curl on stdin (-K -), never on the command line where ps can read it
    out = subprocess.run(cmd + ["-K", "-"], input=f'header = "{header}"\n', capture_output=True, text=True, timeout=600)
    if out.returncode:
        raise SystemExit(f"transcription ({engine}) failed for {path}: {out.stderr.strip()} {out.stdout[:300]}")
    raw = json.loads(out.stdout)
    if engine == "scribe":
        data = raw
    else:
        data = {"text": raw.get("text", ""), "segments": raw.get("segments", []),
                "words": [{"type": "word", "text": w["word"], "start": w["start"], "end": w["end"]} for w in raw.get("words", [])]}
    json.dump(data, open(cache, "w"), indent=1)
    return data


def duration(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                         capture_output=True, text=True).stdout
    return float(out.strip() or 0)


def loudness(path):
    err = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    m = re.findall(r"I:\s+(-?[\d.]+) LUFS", err)
    return float(m[-1]) if m else None


def main():
    want = intended_words()
    for arg in sys.argv[1:]:
        path = arg if os.path.exists(arg) else os.path.join(ROOT, arg)
        stt = scribe(path)
        got = [w for w in stt.get("words", []) if w.get("type") == "word"]
        heard = [norm(w["text"]) for w in got if norm(w["text"])]
        sm = difflib.SequenceMatcher(None, want, heard, autojunk=False)
        matched = sum(b.size for b in sm.get_matching_blocks())
        recall = matched / len(want)
        precision = matched / max(1, len(heard))
        first = got[0]["start"] if got else None
        last = got[-1]["end"] if got else None
        print(f"{os.path.basename(path):16s} dur={duration(path):6.1f}s  LUFS={loudness(path)}  words={len(heard):3d}/{len(want)}  "
              f"recall={recall:.2f} precision={precision:.2f}  vocals {first}-{last}s")
        missing = []
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag in ("delete", "replace") and i2 - i1 >= 2:
                missing.append(" ".join(want[i1:i2]) + (f"  ->  {' '.join(heard[j1:j2])}" if tag == "replace" else ""))
        for m in missing[:14]:
            print("    miss:", m)


if __name__ == "__main__":
    main()
