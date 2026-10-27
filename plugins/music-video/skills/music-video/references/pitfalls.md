# Pitfalls (each one happened)

## Rendering

- **`img.decode()` hangs in background tabs.** With several puppeteer pages in one headless Chrome, only the
  foreground page decodes; the others hung forever on their first image and one worker rendered everything.
  Resolve image loads on `onload` (the template does) and keep the per-frame watchdog.
- **Swap fills the disk.** Four workers plus an x264 `-preset slow` encode grew macOS swap from 3 GB to 9 GB on the
  system volume and took free space to 0 B, which also broke the agent's shell (ENOSPC on its own temp files).
  Use two workers, encode after rendering (not alongside), keep the project on a roomy volume, and trust the
  preflight. If the shell dies with ENOSPC, a streaming/monitor tool can still run cleanup commands.
- **ffmpeg without `drawtext`.** Some Homebrew builds lack freetype. Draw all text in the canvas renderer.
- **WebGL in headless Chrome.** Chrome for Testing gives WebGL2; on Apple silicon pass `--use-angle=metal`
  (the template does). Verify with a one-frame still before writing scenes.
- **A sheet label can cover text.** A heading that looks clipped on a contact sheet may be fine; check a full-res
  still before moving layouts.

## 3D

- **Euler order.** A cylinder rotated onto its side (`rotation.z = PI/2`) spins around the world axis with the
  default `XYZ` order. Set `rotation.order = 'ZYX'` so `.y` spins it on its own axle (slot reels).
- **Cylinder UVs wrap the circumference in u.** Lay reel symbols out along the canvas width, rotated -90°, and offset
  the stop angle by half a symbol to centre one.
- **Random noise on non-indexed meshes cracks them.** `IcosahedronGeometry` duplicates vertices per face; displace by
  position only, never by a per-vertex random draw.
- **Chrome reflects the environment's ground.** A green env ground makes every chrome object on a plaza look green.
- **Grass through props.** Blades grow through anything placed on the lawn; clear an ellipse in `makeGrass`.
- **A lawn plane can swallow a room.** A large outdoor plane at sill height covered an interior floor and the prop on it.
- **Reach too strong.** A reach uniform aimed at the camera turns near blades into screen-filling shards; aim it at
  the contact point, keep strength under ~1.

## Characters and assets

- **Meshy credits go fast.** An animation clip costs 3 credits and a merged 10-clip request more; a 402 means the
  balance is out (`GET /openapi/v1/balance`). Buy the clips that are hard to fake (sitting, kneeling) and pose the
  rest procedurally.
- **Parallel clients clobber a shared state file.** Two `meshy.py` runs each rewrote the whole `state.json` and one
  task id was lost (recoverable from `GET /openapi/v1/rigging?sort_by=-created_at`). `save()` now merges under a lock.
- **Chair-sit clips carry the hips at chair height.** On a ledge, drop the root about 0.4 m and move it forward so
  the thighs clear the edge.
- **Classic shot scripts run before the ES-module 3D layer.** Do not build `THREE` objects at load time in a shot
  file; make those parameters functions evaluated at draw time.
- **`PCFSoftShadowMap` is gone in three r18x** (it silently falls back to PCF); soften with `light.shadow.radius`.
- **A helper named like a local array gets shadowed.** `rocks(rocks, ...)` inside a scene called the array.
- **Low grass-level cameras fill the frame with blades** once the grass is taller than the lens height.

## Audio and APIs

- **ElevenLabs per-key caps.** A key can hit its own credit cap (401 `quota_exceeded`) while the account has plenty.
  Music takes are expensive (~4,900 credits per 3 min); transcription is cheap.
- **ElevenLabs concurrency is per subscription, not per endpoint.** A Creator key allows two requests in flight
  across Music, sound effects and Scribe combined; a third returns 429 `concurrent_limit_exceeded`. Queue takes two at a time.
- **ffmpeg duration syntax.** `afade=d=.3` fails; write `d=0.3`.
- **`alimiter` default `level=1` undoes loudness normalisation.** Use `level=0` and re-measure.
- **Reference conditioning: `xhigh` copies the sound, not the words.** Conditioning each section on the matching
  <= 30 s slice of a loved reference (`el_reference.py`, then `ref` per section) at `xhigh` scored 9.5-10/10 in the A/B
  with 98-99% lyric recall and no bleed; at `high` two of three takes sang the reference's own outro words. Reuse the
  reference's extracted plan (section durations and styles) and write new lyrics with the same line counts.
- **Lyria picks its own tempo.** Three Lyria songs asked for 122, 124 and 150 BPM all came out at 160 (80 half-time),
  and a Gemini listen just echoes the prompt's BPM back. Trust `analyze_song.py`'s grid; ElevenLabs' `el1` engine did
  follow the requested 116. The tracker searches 90-160 BPM, so a song faster than 160 needs a wider range.
- **Transcripts write numbers as digits.** "645" vs "six hundred forty-five" shows as a miss in fidelity scores.
- **Whisper word times drift.** Scribe's are tighter; Lyria's own lyric sheet cross-checks both.

## Shell (zsh on macOS)

- `"$name[$i:a]"` inside a string is an array subscript. Build ffmpeg filter graphs in Python.
- An unmatched glob aborts the whole command; wrap loops in `bash -c 'shopt -s nullglob; ...'`.
- `stat` may be GNU coreutils; use `/bin/ls -ld -D %Y-%m-%d` or `/usr/bin/stat` for mtimes.

## Delivery

- Chat file attachments to phones cap around 30 MB; send 720p copies.
- Shared output folders collect files from parallel sessions; prefix yours and never overwrite theirs.
- Background jobs that wait on a log line that never appears (because the job was killed) spin forever; kill them
  when you kill the job.
