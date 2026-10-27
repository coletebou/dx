// render.mjs - drive studio.html in headless Chrome.
//   node render.mjs --sheet=6,9,12 [--cols=3] [--w=640] --out=out/check.jpg     contact sheet (fast visual check)
//   node render.mjs --stills=6.5,42.5 --out=out/stills                            full-res PNG stills
//   node render.mjs --clip=40:48 [--fps=30] --out=out/clip.mp4                    short clip with the song
//   node render.mjs --frames=0:180 --workers=4                                    all frames -> out/frames (resumable)
//   node render.mjs --encode --out=out/breakout-search.mp4                        frames + song -> MP4
//   node render.mjs --shots                                                       print the shot list
//   --page=bts.html renders another page; --dir=<frames dir>; --audio=mix.wav; --force skips the disk preflight
import puppeteer from 'puppeteer-core';
import { spawn, execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync, existsSync, statSync, renameSync, readdirSync, rmSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import os from 'node:os';

const args = Object.fromEntries(process.argv.slice(2).map(a => { const [k, v] = a.replace(/^--/, '').split('='); return [k, v ?? true]; }));
// Chrome: --chrome=<path>, $CHROME, the newest Playwright "Chrome for Testing", or a system Chrome.
function findChrome() {
  if (args.chrome || process.env.CHROME) return args.chrome || process.env.CHROME;
  const roots = [`${os.homedir()}/Library/Caches/ms-playwright`, `${os.homedir()}/.cache/ms-playwright`];
  for (const root of roots) {
    if (!existsSync(root)) continue;
    for (const d of readdirSync(root).filter(n => /^chromium-\d+$/.test(n)).sort((a, b) => +b.split('-')[1] - +a.split('-')[1])) {
      for (const bin of ['chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing', 'chrome-mac/Chromium.app/Contents/MacOS/Chromium', 'chrome-linux/chrome', 'chrome-linux64/chrome'])
        if (existsSync(`${root}/${d}/${bin}`)) return `${root}/${d}/${bin}`;
    }
  }
  return ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', '/usr/bin/google-chrome', '/usr/bin/chromium'].find(existsSync)
    ?? (() => { throw new Error('no Chrome found: install one with `npx playwright install chromium` or pass --chrome=<path>'); })();
}
const CHROME = findChrome();
// Preflight: heavy jobs swap on the system volume; refuse to start when it (or the output volume) is short on space.
function preflight(outDir) {
  const min = +(process.env.MV_MIN_FREE_GB || 5), sys = existsSync('/System/Volumes/Data') ? '/System/Volumes/Data' : '/';
  mkdirSync(outDir, { recursive: true });
  for (const v of [sys, outDir]) {
    // No shell (the path is an argument), and Available is the field before Capacity ("81%"): names with spaces shift $4.
    const f = execFileSync('df', ['-Pk', v]).toString().trim().split('\n')[1].split(/\s+/);
    const gb = +f[f.findIndex(x => /^\d+%$/.test(x)) - 1] / 1048576;
    if (gb < min && !args.force) { console.error(`preflight: ${v} has ${gb.toFixed(1)} GB free (< ${min} GB). Free space or pass --force.`); process.exit(75); }
  }
}
const fps = +(args.fps || 30), SONG = args.audio || 'song.mp3', FRAMES = args.dir || 'out/frames';
const run = (cmd, a) => new Promise((ok, bad) => { const p = spawn(cmd, a, { stdio: 'inherit' }); p.on('close', c => (c ? bad(new Error(`${cmd} exited ${c}`)) : ok())); });

if (args.frames || args.encode || args.clip) preflight(dirname(resolve(args.out || FRAMES + '/x')));
if (args.encode) {
  const out = args.out || 'out/breakout-search.mp4', n = readdirSync(FRAMES).filter(f => f.endsWith('.jpg')).length;
  console.log(`encoding ${n} frames -> ${out}`);
  await run('ffmpeg', ['-y', '-loglevel', 'error', '-stats', '-framerate', String(fps), '-i', `${FRAMES}/f%05d.jpg`, '-i', SONG,
    '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'slow', '-crf', '16', '-pix_fmt', 'yuv420p', '-profile:v', 'high',
    '-c:a', 'aac', '-b:a', '256k', '-movflags', '+faststart', '-shortest', out]);
  console.log('wrote ' + out); process.exit(0);
}

const browser = await puppeteer.launch({
  executablePath: CHROME, headless: true, protocolTimeout: 0,
  userDataDir: resolve(`out/chrome-profile-${process.pid}`),
  args: ['--allow-file-access-from-files', '--ignore-gpu-blocklist', '--enable-gpu-rasterization', '--use-angle=metal', '--window-size=1920,1080',
    '--disable-renderer-backgrounding', '--disable-background-timer-throttling', '--disable-backgrounding-occluded-windows'],
});
let errors = 0;
async function openPage(tag = '') {
  const page = await browser.newPage();
  await page.setViewport({ width: 1920, height: 1080 });
  page.on('console', m => { if (['error', 'warn'].includes(m.type())) { errors++; console.log(`[page${tag}]`, m.text()); } });
  page.on('pageerror', e => { errors++; console.log(`[page error${tag}]`, e.message); });
  await page.goto(pathToFileURL(resolve(args.page || 'studio.html')).href + '?render', { waitUntil: 'load' });
  await page.waitForFunction('window.ready === true', { timeout: 60000 });
  return page;
}
const frameOf = async (page, t, type, q) => { const url = await page.evaluate((t, type, q) => window.renderAt(t, type, q), t, type, q); return Buffer.from(url.slice(url.indexOf(',') + 1), 'base64'); };
const times = s => String(s).split(',').map(Number);

if (args.shots) {
  const page = await openPage(); console.table(await page.evaluate(() => window.shotList()));
} else if (args.sheet) {
  const page = await openPage(), out = args.out || 'out/sheet.jpg'; mkdirSync(dirname(out), { recursive: true });
  const { url, ms } = await page.evaluate((ts, c, w) => window.renderSheet(ts, c, w), times(args.sheet), +(args.cols || 3), +(args.w || 640));
  writeFileSync(out, Buffer.from(url.slice(url.indexOf(',') + 1), 'base64'));
  console.log(`${out}  ms/frame: ${ms.join(' ')}`);
} else if (args.stills) {
  const page = await openPage(), out = args.out || 'out/stills'; mkdirSync(out, { recursive: true });
  for (const s of times(args.stills)) { const t0 = Date.now(), buf = await frameOf(page, s, 'image/png'); const f = `${out}/t${s.toFixed(2).replace('.', '_')}.png`; writeFileSync(f, buf); console.log(`${f}  ${Date.now() - t0} ms`); }
} else if (args.frames) {
  const [a, b] = String(args.frames).split(':').map(Number), workers = +(args.workers || 2);
  mkdirSync(FRAMES, { recursive: true });
  const todo = []; for (let i = Math.round(a * fps); i < Math.round(b * fps); i++) { const f = `${FRAMES}/f${String(i + 1).padStart(5, '0')}.jpg`; if (!existsSync(f) || statSync(f).size < 1000) todo.push(i); }
  console.log(`${todo.length} frames to render, ${workers} workers`);
  let next = 0, done = 0; const start = Date.now();
  // watchdog: a frame that takes > 30 s gets a fresh page and goes back on the queue
  const withTimeout = (p, ms) => Promise.race([p, new Promise((_, bad) => setTimeout(() => bad(new Error('frame timeout')), ms))]);
  await Promise.all(Array.from({ length: workers }, async (_, w) => {
    let page = await openPage('#' + w);
    while (next < todo.length) {
      const i = todo[next++], f = `${FRAMES}/f${String(i + 1).padStart(5, '0')}.jpg`;
      let buf;
      try { buf = await withTimeout(frameOf(page, i / fps, 'image/jpeg', .95), 30000); }
      catch (e) { console.log(`worker ${w}: ${e.message} at frame ${i}, reopening page and retrying`); await page.close().catch(() => {}); page = await openPage('#' + w); todo.push(i); continue; }
      writeFileSync(f + '.tmp', buf); renameSync(f + '.tmp', f);
      if (++done % 60 === 0 || done === todo.length) { const el = (Date.now() - start) / 1000; console.log(`frame ${done}/${todo.length}  ${(el / done * 1000).toFixed(0)} ms/frame eff  eta ${((todo.length - done) * el / done / 60).toFixed(1)} min`); }
    }
  }));
} else {
  const page = await openPage(), [a, b] = String(args.clip || '0:6').split(':').map(Number), out = args.out || 'out/clip.mp4';
  mkdirSync(dirname(out), { recursive: true });
  const ff = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-', '-ss', String(a), '-t', String(b - a), '-i', SONG,
    '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'medium', '-crf', '19', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '192k', '-shortest', out], { stdio: ['pipe', 'inherit', 'inherit'] });
  const n = Math.round((b - a) * fps), start = Date.now();
  for (let i = 0; i < n; i++) {
    const buf = await frameOf(page, a + i / fps, 'image/jpeg', .92);
    if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once('drain', r));
    if (i % 30 === 0 || i === n - 1) console.log(`frame ${i + 1}/${n}  ${((Date.now() - start) / (i + 1)).toFixed(0)} ms/frame`);
  }
  ff.stdin.end(); await new Promise(r => ff.on('close', r)); console.log('wrote ' + out);
}
console.log(`page errors/warnings: ${errors}`);
await browser.close();
rmSync(resolve(`out/chrome-profile-${process.pid}`), { recursive: true, force: true });
