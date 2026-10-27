---
name: music-video
description: Make an original pop song and a music video for it end to end. Research a topic, write lyrics, generate song takes (Lyria, ElevenLabs Music), pick the take by transcription fidelity plus a Gemini listening pass, time every sung word (ElevenLabs Scribe + a beat grid), then render the video frame by frame in headless Chrome with canvas motion graphics and three.js 3D, optionally mixing in generated stills and image-to-video clips. Mix sound effects, master to -14 LUFS, and cut full, social and how-it's-made versions. Use when the user asks for a music video, a lyric video, "a song about X with visuals", a video for X/Twitter, or to remake a reference video "like this".
---

# music-video

A proven pipeline for original songs with frame-exact kinetic-typography videos. Every frame is a pure function of
song time, painted in headless Chrome by parallel workers, so any shot can be re-rendered alone and QA'd from
contact sheets. The visuals can be **all code** (canvas + three.js, no image or video models) or **hybrid**
(generated stills and clips under code-drawn typography).

## Before spending anything

State the plan first and get a go-ahead: topic and why it's timely, the song's style, which models, the look, and an
API cost estimate. Generated media costs real money (image-to-video is about $0.85 per 6 s clip); a plan costs nothing.
If the user asks for "all code", no image or video model may touch a frame; enforce it with an empty asset manifest.

## Prerequisites

- Env keys as needed: `ELEVENLABS_API_KEY` (music, Scribe, sound effects), `GOOGLE_API_KEY` (Lyria, Gemini
  listening), `OPENAI_API_KEY` (gpt-image stills, Whisper fallback), `XAI_API_KEY` (grok-imagine-video),
  `MESHY_API_KEY` (3D characters). Source them per shell call; never print them. ElevenLabs keys can carry a
  per-key credit cap: a 3-min Music take is ~4,900 credits. The model each script calls is a documented default
  that an environment variable overrides (`references/pipeline.md`, "Model defaults").
- `ffmpeg`, `node` 22.12+ (puppeteer-core 25), `python3` with `numpy` and `PIL`, and a Chrome for Testing (`npx playwright install chromium`).
- Room to work: a 3-min video is ~5,400 JPEG frames (~0.8 GB) plus encodes. Heavy renders also grow swap on the
  system volume, so check free space before a full render; `render.mjs` refuses to start under
  `MV_MIN_FREE_GB` (default 5) free.

## Pipeline

Set `SKILL` to this skill's directory first (`SKILL=${CLAUDE_SKILL_DIR:-$HOME/.claude/skills/music-video}`). Run the
steps from inside the project (`cd <project>`): every script takes the project from `MV_PROJECT`, defaulting to the cwd,
and relative song paths like `music/*.mp3` are expanded by your shell.

| # | Step | Command |
|---|---|---|
| 0 | Scaffold | `$SKILL/scripts/new_project.sh <project>` |
| 1 | Research + lyrics | web search for current, verifiable details; write `<project>/lyrics.json` |
| 2 | Song takes | `python3 $SKILL/scripts/gen_music.py lyria el1 --tag=a` (then more Lyria takes `--tag=b`, `--tag=c`; existing takes are never overwritten without `--force`) |
| 3 | Pick a take | `python3 $SKILL/scripts/score_song.py music/*.mp3` then `listen.py music/<take>.mp3 "<A&R prompt>"` |
| 4 | Timing | `python3 $SKILL/scripts/analyze_song.py <take>` writes `build/timing.json` + `build/song.mp3` |
| 5 | Stills / clips (hybrid only) | `gen_images.py` from `images/prompts.json`; `gen_videos.py` from `clips/jobs.json` |
| 5b | A 3D protagonist (optional) | concept still, then `meshy.py model` / `rig` / `anim` (needs `MESHY_API_KEY`); see references/pipeline.md |
| 6 | Data | `python3 $SKILL/scripts/build_data.py` writes `build/data.js` (timing + asset manifest) |
| 7 | Shots | write `build/src/shots/*.js` and `build/src/scenes3d.js`; list them in `build/studio.html` |
| 8 | QA loop | `cd build && node render.mjs --sheet=<times> --out=out/check/x.jpg`, read the sheet, fix, repeat |
| 9 | Sound | generate effects into `sfx/`, list cues in `cues.json`, `python3 $SKILL/scripts/mix.py` |
| 10 | Render | `node render.mjs --frames=0:<dur> --workers=2` (resumable; delete frames in a range to redo it) |
| 11 | Encode | `node render.mjs --encode --audio=mix.wav --out=out/final.mp4` |
| 12 | Cuts + delivery | social cut, how-it's-made clip, poster, phone copies (see below) |

## How each step is judged

- **Lyrics**: one concrete, checkable fact per line; a hook that works as on-screen text; ad-libs in parentheses
  (`(touch grass!)`) become stamps or smash cards. Keep real people's names out unless they are public figures.
- **Song choice**: generate 3+ takes. Score each with `score_song.py` (word recall/precision against the lyrics;
  number formatting like "645" vs "six hundred forty-five" is a false miss), then have Gemini listen with a strict
  A&R prompt (ratings, timestamped problems, section starts, weakest moment). Generate both engines: ElevenLabs'
  sectioned engine (`el1`, exact section durations) scored 0.97-0.98 word recall on every song tried, Lyria
  ranged 0.83-0.99 but often wins on production and genre moves, and the chunked engine (`el25`) dropped chorus
  lines. Lyria sometimes clips the last chorus or outro (check the listen report's final 10 s), and its prompt
  filter can block one request and pass an identical one, so retry a block once. Lyria also returns a timed lyric sheet (`[12.0:] line`) that
  cross-checks the alignment.
  When the user points at a track they love, A/B every take against it (`ab_ref.py <ref.mp3> <ref chorus s> "<hook>"
  music/*.mp3`): it caught a variation that had drifted into another genre (2-5/10) when fidelity scores looked fine.
- **Story**: when the brief is a narrative, follow one character through every shot. A primitive-built figure reads
  as a toy; use a generated, rigged character (3D) or keep one consistent generated character via reference sheets
  (`refs` in `images/prompts.json`) for the hybrid look.
- **Look**: a small design system before any shot: palette tokens, two or three typefaces, one accent. Give the
  story a visual arc (for example screen world -> portal -> outdoors). Big type early for the muted-autoplay hook.
- **QA**: every change gets a contact sheet. Check the first and last frame of each shot, frames around every cut,
  and full-res stills wherever text sits near the frame edge or another element. A sheet label can hide text, so
  confirm edge cases at full resolution before "fixing" them.
- **Sound**: effects sit under the song; ask Gemini to listen for audibility, masking and clashes, then adjust gains.
- **Final watch**: before delivery, `watch.py <720p cut> "<critique prompt>"` has Gemini watch the video (Files API upload)
  for story clarity, lyric sync and visual glitches; verify each claim on the frames before changing anything.

## Renderer contract (template)

- `shot(t0, name, async (t, lt, dur) => {...}, { mode })` paints the whole frame. No `Math.random`, no state
  between frames; use `hash(i)`, `noise1`, and the beat helpers (`pulse`, `barPulse`, `beatN`, `L(i)` = the
  half-bar cut before lyric line `i`).
- Lyrics: `heroType` (big popping words), `subType` (karaoke band), `stamp` (stickers), `serifType`, `typed`.
- 3D: `GL.def(name, build)` in `scenes3d.js`; draw with `GL.draw(name, t, lt, params, rect?)`. `GL.project` and
  `GL.unproject` map world and screen points. `params.wire` renders a wireframe for how-it's-made clips.
- Transitions: `xfx(tCut, 'flash' | 'dip' | 'grass', halfDuration)`.
- Details, the portal and grass-shader patterns, and the how-it's-made split: `references/pipeline.md`.

## Cuts and delivery

- **Full**: master at CRF 16-18, plus an X-ready copy (`-crf 21 -maxrate 14M`).
- **Social cut** (~60-75 s): intro through the first chorus, hard cut at a transition into the title card, audio
  crossfaded (`acrossfade=d=0.25`) into the outro. Hooks: a striking first frame, burned-in lyrics, one-beat
  full-frame smash cards on the shouts.
- **How-it's-made** (~20 s): a separate page (`--page=bts.html`) that draws each 3D shot twice, render left and
  wireframe right, with a sweeping divider, then a receipts card. Tech audiences share the how.
- **Poster**: a chorus frame with the hook text.
- Phone delivery through chat attachments caps around 30 MB: send a 720p copy, keep full quality elsewhere.
- When several sessions write to the same output folder, prefix file names with the model name and never
  overwrite files you did not make.

## Guardrails

- Never publish or post anywhere without the user's explicit go-ahead for that post. Goals phrased as outcomes
  ("make it go viral") cannot be met or verified from a session: deliver the best package and say so once.
- No generated likenesses of real people and no brand logos in generated images.
- Report spend per service at the end (exact where the API returns cost, estimated otherwise).

## References

- `references/pipeline.md`: renderer API, 3D patterns, audio and encoding recipes.
- `references/pitfalls.md`: every failure hit so far and its fix. Read it before the first render.
