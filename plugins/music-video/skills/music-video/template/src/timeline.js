// timeline.js - shot registry, transitions, post, and the renderAt entry point.
const SHOTS = [], XFX = [];
// cut for lyric line i: the half-bar downbeat at/just before the vocal (lines sit on 2-bar phrases)
const L = i => BEAT0 + Math.floor((LINES[i].t0 + .12 - BEAT0) / (2 * BEAT)) * 2 * BEAT;
// shot(t0, name, fn, {mode:'day'|'night'|'paper', grain, vig})
function shot(t0, name, fn, o = {}) { SHOTS.push({ t0, name, fn, ...o }); }
// overlay transition centred on a cut: kind 'grass' | 'flash' | 'whip' ; d = half-duration
function xfx(tc, kind, d = .45, o = {}) { XFX.push({ tc, kind, d, ...o }); }

function finalizeShots() {
  SHOTS.sort((a, b) => a.t0 - b.t0);
  SHOTS.forEach((s, i) => { s.t1 = i + 1 < SHOTS.length ? SHOTS[i + 1].t0 : T.duration + 1; });
}
function shotAt(t) { let s = SHOTS[0]; for (const x of SHOTS) if (x.t0 <= t) s = x; return s; }

async function renderFrame(t) {
  ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = 1; ctx.globalCompositeOperation = 'source-over'; shadowOff(); _cam = 0;
  const s = shotAt(t);
  ctx.save();
  if (/^ch\d_/.test(s.name)) {                         // chorus energy: a zoom bump on every downbeat
    const z = 1 + barPulse(t, 5) * (s.name.startsWith('ch2') ? .022 : .014) + pulse(t, 10) * .004;
    ctx.translate(W / 2, H / 2); ctx.scale(z, z); ctx.translate(-W / 2, -H / 2);
  }
  try { await s.fn(t, t - s.t0, s.t1 - s.t0, s); }
  catch (e) { console.error(`shot ${s.name} @${t.toFixed(3)}: ${e.stack || e}`); fill('#ff00ff'); }
  while (_cam > 0) camEnd();
  ctx.restore();
  for (const x of XFX) {
    const k = (t - (x.tc - x.d)) / x.d;           // 0..2 across the cut
    if (k <= 0 || k >= 2) continue;
    if (x.kind === 'grass') grassWipe(t, k, x.seed ?? 5);
    else if (x.kind === 'flash') flash((k < 1 ? easeIn(k) : 1 - easeOut(k - 1)) * (x.a ?? 1), x.col ?? C.white);
    else if (x.kind === 'dip') flash((k < 1 ? ease(k) : 1 - ease(k - 1)) * (x.a ?? 1), x.col ?? C.night);
  }
  // optional per-frame overlay above every shot (e.g. a corner meter): window.OVERLAY = (t, shot) => {...}
  if (window.OVERLAY && !s.noOverlay) window.OVERLAY(t, s);
  const mode = s.mode ?? 'day';
  if (mode === 'night') { screenFx(t, .6); vignette(.55, '2,4,20'); grain(t, .09); }
  else if (mode === 'cobalt') { vignette(.3, '6,14,90'); grain(t, .07); }
  else if (mode === 'paper') { vignette(.18, '60,50,30'); grain(t, .06); }
  else { vignette(.22); grain(t, .07); }
}

window.renderAt = async (t, type = 'image/jpeg', q = .92) => { await renderFrame(t); return cv.toDataURL(type, q); };
window.renderSheet = async (times, cols = 3, w = 640) => {
  const h = Math.round(w * H / W), rows = Math.ceil(times.length / cols), sh = offscreen(cols * w, rows * h), g = sh.getContext('2d'), ms = [];
  for (let i = 0; i < times.length; i++) {
    const t0 = performance.now(); await renderFrame(times[i]); ms.push(Math.round(performance.now() - t0));
    g.drawImage(cv, (i % cols) * w, Math.floor(i / cols) * h, w, h);
    g.fillStyle = 'rgba(0,0,0,.6)'; g.fillRect((i % cols) * w, Math.floor(i / cols) * h, 150, 30);
    g.fillStyle = '#fff'; g.font = '600 20px Inter'; g.fillText(times[i].toFixed(2) + 's  ' + shotAt(times[i]).name.slice(0, 6), (i % cols) * w + 8, Math.floor(i / cols) * h + 22);
  }
  return { url: sh.toDataURL('image/jpeg', .85), ms };
};
window.shotList = () => SHOTS.map(s => ({ name: s.name, t0: +s.t0.toFixed(3), t1: +s.t1.toFixed(3), mode: s.mode ?? 'day' }));
