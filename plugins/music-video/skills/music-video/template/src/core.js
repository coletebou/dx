// core.js - canvas, palette, timing, easing, assets and texture helpers.
// Every frame is a pure function of song time t: no Math.random, no state carried between frames.
const W = 1920, H = 1080;
const cv = document.getElementById('c');
const ctx = cv.getContext('2d', { alpha: false });

const C = {
  night: '#070B24', night2: '#0F1640', screen: '#18225A', blue: '#4F7BFF', blue2: '#86A6FF', ice: '#E3EAFF', badge: '#FF4D7A',
  paper: '#F6F1E4', paper2: '#E9E1CC', ink: '#0E2418', inkSoft: '#35513F',
  grass: '#2F9A4B', deep: '#0F5A2C', lime: '#C9F54B', mint: '#A6F0B5', sky: '#A6DCFF', skyDeep: '#3F9FEF',
  sun: '#FFE46B', pink: '#FF8FB8', white: '#FFFFFF', shadow: 'rgba(8,30,16,0.35)',
  cobalt: '#1D3FE6', cobalt2: '#3A64FF', cobaltDeep: '#0B1F9C', cobaltInk: '#081667', concrete: '#CFCCC5', concreteDk: '#8F8C85'
};
// mirror-chrome fill for text/shapes spanning y0..y1 (local coords)
function chromeFill(y0, y1) {
  const g = ctx.createLinearGradient(0, y0, 0, y1);
  [[0, '#FFFFFF'], [.38, '#EAF0FF'], [.5, '#AEBBDD'], [.55, '#FFFFFF'], [.78, '#D3DCF3'], [1, '#FFFFFF']].forEach(([k, c]) => g.addColorStop(k, c));
  return g;
}

// ---------- math / easing ----------
const clamp = (x, a = 0, b = 1) => Math.max(a, Math.min(b, x));
const lerp = (a, b, k) => a + (b - a) * k;
const seg = (t, a, b) => clamp((t - a) / (b - a));
const ease = k => k * k * (3 - 2 * k);
const easeOut = k => 1 - Math.pow(1 - k, 3);
const easeIn = k => k * k * k;
const easeInOut = k => (k < .5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2);
const expoOut = k => (k >= 1 ? 1 : 1 - Math.pow(2, -10 * k));
const backOut = (k, s = 1.8) => 1 + (s + 1) * Math.pow(k - 1, 3) + s * Math.pow(k - 1, 2);
const elasticOut = k => (k <= 0 ? 0 : k >= 1 ? 1 : Math.pow(2, -10 * k) * Math.sin((k * 10 - .75) * (2 * Math.PI) / 3) + 1);
const TAU = Math.PI * 2;
const hash = i => { let x = Math.sin(i * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); };
const hash2 = (i, j) => hash(i * 17.13 + j * 91.7);
const frac = x => x - Math.floor(x);
// smooth 1D value noise, deterministic
const noise1 = x => { const i = Math.floor(x), f = x - i, u = f * f * (3 - 2 * f); return lerp(hash(i), hash(i + 1), u) * 2 - 1; };
const kf = (t, keys, fn = ease) => {
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) if (t <= keys[i][0]) {
    const [t0, v0] = keys[i - 1], [t1, v1] = keys[i], k = fn((t - t0) / (t1 - t0));
    return Array.isArray(v0) ? v0.map((v, j) => lerp(v, v1[j], k)) : lerp(v0, v1, k);
  }
  return keys[keys.length - 1][1];
};
const mix = (a, b, k) => {
  const pa = parseInt(a.slice(1), 16), pb = parseInt(b.slice(1), 16);
  const r = Math.round(lerp(pa >> 16, pb >> 16, k)), g = Math.round(lerp((pa >> 8) & 255, (pb >> 8) & 255, k)), bl = Math.round(lerp(pa & 255, pb & 255, k));
  return '#' + ((1 << 24) + (r << 16) + (g << 8) + bl).toString(16).slice(1);
};
const rgba = (hex, a) => { const p = parseInt(hex.slice(1), 16); return `rgba(${p >> 16},${(p >> 8) & 255},${p & 255},${a})`; };

// ---------- timing (from build/data.js -> window.TIMING) ----------
const T = window.TIMING;
const BEAT = T.beat, BAR = BEAT * 4, BEAT0 = T.beat0;
const beatPos = t => (t - BEAT0) / BEAT;             // fractional beat index
const beatN = t => Math.floor(beatPos(t));
const beatAt = n => BEAT0 + n * BEAT;
const snapBeat = t => beatAt(Math.round(beatPos(t)));
const floorBeat = t => beatAt(Math.floor(beatPos(t) + 1e-6));
const pulse = (t, k = 7) => Math.exp(-k * frac(beatPos(t)) * BEAT);   // 1 on each beat, decays
const barPulse = (t, k = 4) => Math.exp(-k * frac(beatPos(t) / 4) * BAR);
const LINES = T.lines;
const lineAt = t => { let r = -1; for (let i = 0; i < LINES.length; i++) if (LINES[i].t0 - .12 <= t) r = i; return r; };

// ---------- assets ----------
// window.ASSETS = { img: { id: 'assets/img/id.jpg' }, clip: { id: { dir, n, fps } } }
const _cache = new Map();
function loadImage(src) {
  if (_cache.has(src)) { const v = _cache.get(src); _cache.delete(src); _cache.set(src, v); return v; }
  // resolve on load: img.decode() can stall indefinitely in background headless tabs (seen with 4 render workers)
  const p = new Promise((ok, bad) => { const im = new Image(); im.onload = () => ok(im); im.onerror = () => bad(new Error('load ' + src)); im.src = src; });
  _cache.set(src, p);
  if (_cache.size > 160) _cache.delete(_cache.keys().next().value);
  return p;
}
const img = id => { const s = window.ASSETS.img[id]; if (!s) throw new Error('no image ' + id); return loadImage(s); };
// clip frame at local time lt (seconds into the clip), clamped; speed lets shots slow clips down
async function clip(id, lt, speed = 1) {
  const c = window.ASSETS.clip[id]; if (!c) throw new Error('no clip ' + id);
  const n = clamp(Math.floor(lt * speed * c.fps), 0, c.n - 1);
  return loadImage(`${c.dir}/f${String(n + 1).padStart(4, '0')}.jpg`);
}
const clipLen = id => window.ASSETS.clip[id].n / window.ASSETS.clip[id].fps;

// ---------- drawing helpers ----------
function fill(col) { ctx.fillStyle = col; ctx.fillRect(0, 0, W, H); }
function rr(x, y, w, h, r) { ctx.beginPath(); ctx.roundRect(x, y, w, h, r); }
// draw image covering a box, with zoom z around focus (fx, fy in 0..1) and pan (px, py in px)
function cover(im, x = 0, y = 0, w = W, h = H, z = 1, fx = .5, fy = .5, px = 0, py = 0) {
  const s = Math.max(w / im.width, h / im.height) * z, iw = im.width * s, ih = im.height * s;
  const dx = x + (w - iw) * fx + px, dy = y + (h - ih) * fy + py;
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip(); ctx.drawImage(im, dx, dy, iw, ih); ctx.restore();
}
function shadowOn(col = C.shadow, blur = 30, ox = 0, oy = 12) { ctx.shadowColor = col; ctx.shadowBlur = blur; ctx.shadowOffsetX = ox; ctx.shadowOffsetY = oy; }
function shadowOff() { ctx.shadowColor = 'transparent'; ctx.shadowBlur = 0; ctx.shadowOffsetX = 0; ctx.shadowOffsetY = 0; }

// ---------- type ----------
const F = {
  display: (px, wt = 800, stretch = 'normal') => { ctx.fontStretch = stretch; return `${wt} ${px}px "Bricolage Grotesque"`; },
  serif: (px, it = true) => { ctx.fontStretch = 'normal'; return `${it ? 'italic ' : ''}400 ${px}px "Instrument Serif"`; },
  mono: (px, wt = 600) => { ctx.fontStretch = 'normal'; return `${wt} ${px}px "JetBrains Mono"`; },
  ui: (px, wt = 600) => { ctx.fontStretch = 'normal'; return `${wt} ${px}px "Inter"`; },
  hand: (px, wt = 600) => { ctx.fontStretch = 'normal'; return `${wt} ${px}px "Caveat"`; },
};
function text(s, x, y, font, col, align = 'left', base = 'alphabetic') {
  ctx.font = font; ctx.fillStyle = col; ctx.textAlign = align; ctx.textBaseline = base; ctx.fillText(s, x, y);
}
function measure(s, font) { ctx.font = font; return ctx.measureText(s).width; }
// largest font px (<= maxPx) so that s fits in width w
function fitPx(s, w, fontFn, maxPx) { let px = maxPx; while (px > 10 && measure(s, fontFn(px)) > w) px *= .96; return px; }

// ---------- camera ----------
let _cam = 0;
function camBegin(cx, cy, zoom = 1, rot = 0) { ctx.save(); ctx.translate(W / 2, H / 2); ctx.rotate(rot); ctx.scale(zoom, zoom); ctx.translate(-cx, -cy); _cam++; }
function camEnd() { if (_cam > 0) { ctx.restore(); _cam--; } }
const shake = (t, amt, f = 23) => [noise1(t * f) * amt, noise1(t * f + 77) * amt];
