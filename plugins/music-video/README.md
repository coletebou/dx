# music-video

One skill that makes an original pop song and a music video for it, from a topic to delivered cuts.

| Skill | What it does | Runs |
|---|---|---|
| `music-video` | Researches the topic and writes lyrics; generates several song takes (Lyria, ElevenLabs Music) and picks one by word recall against the lyrics plus a Gemini listening pass; times every sung word on a beat grid; renders every frame as a pure function of song time in headless Chrome (canvas motion graphics, kinetic typography, three.js 3D), optionally with generated stills, image-to-video clips and a rigged 3D character; mixes sound effects, masters to -14 LUFS, and cuts full, social and how-it's-made versions. | `scripts/*.py`, `scripts/new_project.sh`, the renderer in `template/` (`node render.mjs`) |

The skill states a plan and a cost estimate before it spends anything, never publishes without an explicit
go-ahead, and keeps a project "all code" (no image or video model touches a frame) when asked to.

## Install

```text
/plugin marketplace add coletebou/dx
/plugin install music-video@dx
```

From a clone, `./install.sh --with music-video` links the skill into `~/.claude/skills`.

## API keys

The scripts read their keys from the environment and send them in request headers or on curl's stdin,
never on a command line. Set only the ones the steps you use need, for example in `~/.env_secrets`:

| Variable | Provider | Used for |
|---|---|---|
| `ELEVENLABS_API_KEY` | [ElevenLabs](https://elevenlabs.io) | song takes (`el25`, `el1`), Scribe transcription and word timing, sound effects |
| `GOOGLE_API_KEY` | [Google AI Studio](https://aistudio.google.com) (Gemini API) | Lyria song takes, Gemini listening (`listen.py`, `ab_ref.py`) and watching (`watch.py`) |
| `OPENAI_API_KEY` | [OpenAI](https://platform.openai.com) | generated stills (`gen_images.py`), the Whisper transcription fallback (`STT=whisper`) |
| `XAI_API_KEY` | [xAI](https://x.ai/api) | image-to-video clips (`gen_videos.py`) |
| `MESHY_API_KEY` | [Meshy](https://www.meshy.ai) | an image-to-3D, rigged and animated character (`meshy.py`) |

These are paid APIs: a 3-minute ElevenLabs Music take is about 4,900 credits, and an image-to-video clip
costs on the order of a dollar per 6 seconds. An all-code video needs only the song and transcription keys.

## Models

Each script calls a default model that an environment variable overrides (`LYRIA_MODEL`, `EL25_MODEL`,
`EL1_MODEL`, `SCRIBE_MODEL`, `WHISPER_MODEL`, `LISTEN_MODEL`, `WATCH_MODEL`, `IMAGE_MODEL`, `VIDEO_MODEL`).
The defaults and which script uses each are in
[`references/pipeline.md`](skills/music-video/references/pipeline.md#model-defaults). Providers rename and
retire models; when a call fails with an unknown model, set the variable to the provider's current id.

## Requirements

- `ffmpeg` and `ffprobe`, `python3` with `numpy` and Pillow, `curl`.
- Node 22.12 or newer; each project's `build/` installs puppeteer-core and three.js from npm
  (`new_project.sh` runs `npm install` there).
- A Chrome for Testing (`npx playwright install chromium`), a system Chrome, or `--chrome=<path>`.
- Disk: a 3-minute video is about 5,400 JPEG frames (0.8 GB) plus encodes; `render.mjs` refuses to start
  with less than `MV_MIN_FREE_GB` (default 5) free.

## Fonts

`template/fonts/` vendors five Google Fonts families (Bricolage Grotesque, Caveat, Instrument Serif, Inter,
JetBrains Mono) so frames render offline and identically everywhere. They are under the SIL Open Font
License 1.1, not MIT: see [`template/fonts/OFL.txt`](skills/music-video/template/fonts/OFL.txt).
