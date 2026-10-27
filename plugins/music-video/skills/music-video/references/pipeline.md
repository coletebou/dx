# Pipeline reference

## Project layout

```
<project>/
  lyrics.json            title, bpm, styles {positive[], negative[]}, sections[{name, duration_ms, direction, local_styles, lines[]}]
  cues.json              sound-effect cues for mix.py
  music/                 song takes (<engine>_<tag>.mp3), Lyria lyric sheets (.txt), transcripts (.mp3.<stt>.stt.json)
  images/prompts.json    stills for the hybrid look (optional)
  clips/jobs.json        image-to-video jobs (optional)
  sfx/                   sound effects (<name>.mp3)
  build/                 the renderer: studio.html, render.mjs, src/, fonts/, data.js, song.mp3, mix.wav, timing.json, out/
```

## Model defaults

Each script calls the model below unless its environment variable names another. These are the ids the pipeline
was last run with; providers rename and retire models, so check a provider's current list when a call fails with
an unknown-model error, and set the variable rather than editing the script.

| Variable | Default | Used by |
|---|---|---|
| `LYRIA_MODEL` | `lyria-3.5` | `gen_music.py lyria` (Gemini Interactions API) |
| `EL25_MODEL` | `music_v2_5` | `gen_music.py el25`, `el_reference.py` (ElevenLabs Music, chunked plan) |
| `EL1_MODEL` | `music_v1` | `gen_music.py el1` (ElevenLabs Music, sectioned plan) |
| `SCRIBE_MODEL` | `scribe_v2` | `score_song.py` (ElevenLabs speech-to-text, the default `STT=scribe`) |
| `WHISPER_MODEL` | `whisper-1` | `score_song.py` with `STT=whisper` (OpenAI) |
| `LISTEN_MODEL` | `gemini-3.8-flash` | `listen.py`, `ab_ref.py` (Gemini) |
| `WATCH_MODEL` | `gemini-3.8-flash` | `watch.py` (Gemini, Files API) |
| `IMAGE_MODEL` | `gpt-image-2.5-flare` | `gen_images.py` (OpenAI Images) |
| `VIDEO_MODEL` | `grok-imagine-video-1.5` | `gen_videos.py` (xAI) |
| (request field) | `eleven_text_to_sound_v2` | sound effects, sent as `model_id` to ElevenLabs `/v1/sound-generation` |
| (request field) | `latest` | `meshy.py model` (Meshy's `ai_model`) |

## Song generation (`gen_music.py`)

- `lyria` posts to the Gemini Interactions API (`LYRIA_MODEL`) with a prompt that carries timestamped sections
  and the exact lyrics. The response holds base64 audio plus a timed lyric sheet; both are saved.
- `el25` / `el1` post an ElevenLabs composition plan (`el25`: chunks with `[Section]` text and `{directions}`;
  `el1`: sections with `lines`). Artist names in styles are rejected.
- Three Lyria takes cost little and differ a lot; generate several and let the scores decide.

## Scoring and listening

- `score_song.py` transcribes each take (`STT=scribe` default, `STT=whisper` fallback) and prints recall/precision
  of the lyric words plus the biggest misses. Scribe word timestamps are tighter than Whisper's.
- `listen.py <audio> "<prompt>"` sends the file to Gemini (`LISTEN_MODEL`, default a fast Gemini model). Useful
  prompts: an A&R critique (ratings, timestamped problems, section starts, tempo, best/weakest moment), an
  effects-level check on an excerpt (audible / masked / clashing per cue), and an audit of a concatenated sequence
  of effects separated by silence.

## Timing (`analyze_song.py`)

- Beat grid: spectral-flux onsets, autocorrelation for the period, comb fit for the phase. AI songs hold a fixed
  tempo, so one period fits the whole track. Sections start on bars; lyric lines sit on two-bar phrases.
- Words: the lyric tokens are aligned to the transcript tokens with `difflib`; unmatched words are interpolated
  between matched neighbours. Hyphenated words map back to one display word.
- `timing.json`: `bpm`, `beat`, `beat0`, `beats[]`, `lines[{text, t0, t1, words[{w, t0, t1}]}]`, `duration`.

## Renderer

- `studio.html` loads fonts, `data.js`, the classic-script modules, the shots, then the ES modules (`gl3d.js`,
  `scenes3d.js`) through an import map, and sets `window.ready` once fonts and the GL layer are up.
- `render.mjs`: `--sheet=t1,t2,...` (contact sheet, prints ms/frame), `--stills=...` (PNG), `--clip=a:b`
  (MP4 with the song), `--frames=a:b --workers=N --dir=out/frames` (resumable, per-frame 30 s watchdog that
  reopens a stuck page and requeues the frame), `--encode --audio=mix.wav --out=...`, `--shots` (table),
  `--page=other.html`, `--force` (skip the disk preflight). Each run uses its own Chrome profile under `out/` and
  deletes it on exit.
- Frame cost: 2D shots 5-40 ms, 3D shots 40-300 ms (first frame of a scene compiles shaders and builds geometry).

### Lyric typography (`lyrics.js`)

- `heroType(t, line, box, {maxPx, fg, accent, accentWords, accentActive, align, valign, maxRows, chrome, outline})`
  lays words into the box at the largest size that fits and pops each word in 70 ms before it is sung.
- `mainWords(line)` excludes parenthesised ad-libs; `adlibs(line)` returns them with their times.
- `subType` (karaoke pill), `stamp(t, t0, text, x, y, px, opts)`, `serifType`, `typed(t, str, t0, t1)`.

### 3D layer (`gl3d.js`)

- `makeSky(opts)`: shader dome (zenith/horizon colours, sun, drifting fbm clouds). `envFrom(opts)` renders a sky and
  ground scene into a PMREM so metals reflect it. Pass a concrete-grey ground for plaza scenes, or chrome reads green.
- `makeGrass(n, {x0,x1,z0,z1,h,w,seed,clear:[[cx,cz,rx,rz]], placer})`: instanced blades. Uniforms: `uTime`, `uWind`,
  `uPress` (x, z, strength, radius: blades part around a point), `uReach` + `uReachR` (blades curl toward a point).
  `placer(i, rng) -> {pos, normal}` wraps grass around any surface (e.g. a sphere).
- `GL.draw(name, t, lt, params, rect)`: `rect` composites a centred crop into a sub-rectangle (phone screens,
  polaroids, split screens). `params.wire` swaps in a wireframe override and hides shader materials.
- Portal pattern: render the destination scene into a `WebGLRenderTarget`, texture the door plane with a
  `ShaderMaterial` that samples it at `gl_FragCoord.xy / resolution`, and render the destination directly once the
  camera crosses the door plane. Provide `render()` on the scene instance to take over rendering.
- A flock: one `InstancedMesh` of two-triangle wings, matrices recomputed per frame from `t` (flap = sine).
- Lathe (`LatheGeometry`) turns a 2D profile into a chrome bust or vase; `TubeGeometry` + `setDrawRange` grows a
  chrome line chart.

### How-it's-made page

Copy `studio.html` to `bts.html`, load one extra shot file that empties `SHOTS`/`XFX` and registers the reveal.
A split shot:

```js
GL.draw(name, t, lt, p);                                          // render
ctx.save(); ctx.beginPath(); ctx.rect(div, 0, W - div, H); ctx.clip();
GL.draw(name, t, lt, { ...p, wire: true }); ctx.restore();        // wireframe right of the divider
```

Render it with `--page=bts.html --frames=0:20 --dir=out/bts_frames` and encode against a chorus excerpt of the mix.

## A real character (Meshy) in the 3D layer

Primitive figures read as toys. For a protagonist, generate one:

1. Concept: `gen_images.py` with a full-body **front view, A-pose, plain grey background** prompt (two variants).
2. `MV_PROJECT=<p> python3 $SKILL/scripts/meshy.py model images/<id>.png hero` (PBR, A-pose; ~60k tris), then
   `meshy.py rig hero 1.65` (24-bone humanoid; walking + running clips come free), then
   `meshy.py anim hero <name> <action_id>` per extra clip (`meshy.py lib <search>` lists ids: 0 Idle, 32 Chair Sit
   Female, 365 Kneel, 266 Lie Down, 59 Victory Cheer, 122 Texting Walk ...). Props: `meshy.py model <img> pine --prop --poly=14000`.
3. In three.js: `GLTFLoader` (file:// needs Chrome's `--allow-file-access-from-files`, which the template passes),
   `SkeletonUtils.clone(rig.scene)`, one `AnimationMixer`, one action per clip. Every frame set each action's
   `time` and weight explicitly, then `mixer.update(0)`: poses stay a pure function of t. Strip the net
   `Hips.position` x/z drift from clips (keep sway and bob) and drive position from a path; derive locomotion clip
   time from distance walked (u / metres-per-second) so feet do not slide.
4. Poses the library lacks: rotate bones after `mixer.update(0)` about axes in the **character's** frame, converted
   per bone: `local' = parentWorld^-1 * Q * parentWorld * local`. Works whatever the rig's local axis conventions.
5. Props: re-base each prop mesh to unit height centred at the origin and instance it (`InstancedMesh`), scaling
   per instance to metres.

Template modules: add `<script type="module" src="src/hero.js">` and `src/post.js` before `scenes3d.js` in
`studio.html`, set `window.HERO_CONFIG` (file names under `char/`) in a classic script above them, then use
`WORLD.makeHero()`, `WORLD.makeProps(kind, list)` and `WORLD.makePost(scene, camera, opts)` in scenes. A clip entry
may name one clip of a merged file (`meshy.py anim` with several ids): `"hero_moves.glb#2"` or `"hero_moves.glb#Walk"`.

Post stack per scene (`EffectComposer`): `RenderPass` -> `GTAOPass` (blend ~.6) -> `UnrealBloomPass` (threshold ~.97,
or white clothing blooms) -> `BokehPass` (aperture ~5e-5, maxblur ~.0025; focus = camera-to-subject distance every
frame, including scenes that aim their own camera) -> `OutputPass` -> a grade `ShaderPass` (saturation, contrast,
light lift, vignette). Give the scene instance a `render()` so `GL.draw` uses the composer.

## Audio

- Effects: ElevenLabs `POST /v1/sound-generation` (`model_id` from "Model defaults" below, `duration_seconds`,
  `prompt_influence` ~0.55). At most two requests in flight; more returns 429.
- `cues.json` entries: `{"sfx", "db", "t" | "line"+"word" | "cut", "offset"?, "fade_in"?}`. Typical gains -11 to -20 dB.
- `mix.py` masters to -14 LUFS with a linear gain, adds `alimiter ... level=0` only if the true peak would exceed
  -1 dBTP, then re-measures once.

## Cuts

Social cut from rendered frames plus an audio crossfade:

```bash
# hard-link frames 1..N1 (intro to the end of chorus 1) and M1..end (title) into a new sequence
ffmpeg -i build/mix.wav -filter_complex "[0:a]atrim=0:66.1,asetpts=PTS-STARTPTS[a];[0:a]atrim=174.35:179.7,asetpts=PTS-STARTPTS[b];[a][b]acrossfade=d=0.25[o]" -map "[o]" cut.wav
ffmpeg -framerate 30 -i out/cut/c%05d.jpg -i cut.wav -c:v libx264 -crf 20 -maxrate 14M -bufsize 28M -pix_fmt yuv420p -c:a aac -b:a 256k -movflags +faststart -shortest social.mp4
```

Phone copy under 30 MB: `-vf scale=1280:720 -crf 26 -maxrate 2800k -bufsize 5600k -c:a aac -b:a 128k`.
