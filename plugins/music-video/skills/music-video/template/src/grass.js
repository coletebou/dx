// grass.js - procedural grass: fields, walls (wipes), and blades that reach toward a point.
const GRASS_COLS = ['#0D4F27', '#156B33', '#1F8440', '#2F9A4B', '#46B055', '#6CC35C', '#A5DE5A', '#C9F54B'];

// One tapered blade from (x, y) with height h, base width w, bend b (px of tip offset), colour col.
function blade(x, y, h, w, b, col, hl) {
  const tx = x + b, ty = y - h, mx = x + b * .35, my = y - h * .55;
  ctx.fillStyle = col;
  ctx.beginPath();
  ctx.moveTo(x - w / 2, y);
  ctx.quadraticCurveTo(mx - w * .28, my, tx, ty);
  ctx.quadraticCurveTo(mx + w * .28, my, x + w / 2, y);
  ctx.closePath(); ctx.fill();
  if (hl) { ctx.strokeStyle = hl; ctx.lineWidth = Math.max(.6, w * .12); ctx.beginPath(); ctx.moveTo(x - w * .1, y - h * .08); ctx.quadraticCurveTo(mx - w * .05, my, tx, ty); ctx.stroke(); }
}

// A field of blades rooted along baseline y0 across [x0, x1].
// o: n (count), h (mean height), hv (height variance), w (width), seed, wind (amplitude px), grow (0..1),
//    cols (palette slice), attract {x, y, k, r}, layers (1..3), lean
function grassField(t, o = {}) {
  const n = o.n ?? 700, x0 = o.x0 ?? -40, x1 = o.x1 ?? W + 40, y0 = o.y0 ?? H + 10, seed = o.seed ?? 1;
  const hMean = o.h ?? 180, hv = o.hv ?? .55, bw = o.w ?? 16, wind = o.wind ?? 26, grow = o.grow ?? 1;
  const cols = o.cols ?? GRASS_COLS, layers = o.layers ?? 3, lean = o.lean ?? 0;
  const gust = noise1(t * .35 + seed) * .6 + .4;
  for (let L = 0; L < layers; L++) {
    const m = Math.floor(n / layers), depth = (L + 1) / layers;     // back to front
    for (let i = 0; i < m; i++) {
      const id = seed * 1000 + L * 10000 + i, r1 = hash(id), r2 = hash(id + .37), r3 = hash(id + .71);
      const x = lerp(x0, x1, (i + r1) / m), yj = y0 + (1 - depth) * -18 + r2 * 10;
      let h = hMean * (1 - hv / 2 + r2 * hv) * (.6 + depth * .5);
      const g = clamp(grow * 1.25 - r3 * .25); if (g <= 0) continue;
      h *= easeOut(g);
      let b = (r1 - .5) * h * .35 + lean * h + Math.sin(t * (1.6 + r3) + x * .006 + seed) * wind * gust * (h / 200);
      if (o.attract) {
        const a = o.attract, dx = a.x - x, dist = Math.abs(dx) + Math.abs(a.y - (yj - h));
        const pull = a.k * Math.exp(-dist / (a.r ?? 300));
        b += dx * pull * .8; h += Math.max(0, (yj - a.y) - h) * pull * .9;
      }
      const ci = Math.min(cols.length - 1, Math.floor((depth * .7 + r3 * .45) * cols.length * .9));
      const col = o.tint ? mix(cols[ci], o.tint, o.tintK ?? .5) : cols[ci];
      blade(x, yj, h, bw * (.6 + depth * .6) * (.7 + r1 * .6), b, col, L === layers - 1 && r2 > .5 ? 'rgba(230,255,190,.35)' : null);
    }
  }
}

// Solid grass wall whose top edge is at yTop and bottom edge at yBot (blades poke above yTop, hang below yBot).
function grassWall(t, yTop, yBot = H + 400, seed = 5) {
  if (yTop > H + 200 || yBot < -200) return;
  const g = ctx.createLinearGradient(0, yTop, 0, yTop + 900); g.addColorStop(0, '#1F8440'); g.addColorStop(1, C.deep);
  ctx.fillStyle = g; ctx.fillRect(-10, yTop, W + 20, yBot - yTop);
  // dense rows of blades all the way down the wall, so it reads as a thick lawn rather than a flat card
  for (let y = Math.max(yTop + 140, -60); y < Math.min(yBot, H + 200); y += 110)
    grassField(t, { y0: y + 40, h: 150, n: 260, seed: seed + Math.round(y / 110), wind: 16, layers: 1, cols: GRASS_COLS.slice(1, 6) });
  grassField(t, { y0: yTop + 30, h: 190, n: 460, seed, wind: 18, layers: 2 });
  if (yBot < H + 200) {
    ctx.save(); ctx.translate(0, 2 * yBot); ctx.scale(1, -1);
    grassField(t, { y0: yBot + 20, h: 120, n: 300, seed: seed + 3, wind: 12, layers: 1, cols: GRASS_COLS.slice(0, 4) });
    ctx.restore();
  }
}

// Wipe driver: k in [0,1] covers from the bottom, [1,2] reveals upward. Returns true while fully covered.
function grassWipe(t, k, seed = 5) {
  if (k <= 0 || k >= 2) return false;
  if (k <= 1) grassWall(t, lerp(H + 220, -260, easeInOut(k)), H + 400, seed);
  else grassWall(t, -600, lerp(H + 260, -220, easeInOut(k - 1)), seed);
  return k > .96 && k < 1.04;
}

// Grass clippings / petals confetti drifting down (deterministic).
function confetti(t, t0, n = 120, seed = 3, cols = ['#C9F54B', '#6CC35C', '#FFFFFF', '#FF8FB8', '#FFE46B', '#A6DCFF']) {
  const age = t - t0; if (age < 0 || age > 6) return;
  for (let i = 0; i < n; i++) {
    const r1 = hash(seed * 77 + i), r2 = hash(seed * 77 + i + .5), r3 = hash(seed * 77 + i + .9);
    const x = r1 * W + Math.sin(age * 2 + i) * 40, y = -40 + (age * (160 + r2 * 260)) - r3 * 500;
    if (y < -60 || y > H + 60) continue;
    ctx.save(); ctx.translate(x, y); ctx.rotate(age * (2 + r3 * 4) + i); ctx.globalAlpha = clamp(3 - age * .5);
    ctx.fillStyle = cols[i % cols.length];
    if (i % 3 === 0) { ctx.beginPath(); ctx.ellipse(0, 0, 9, 5, 0, 0, TAU); ctx.fill(); } else { ctx.fillRect(-2, -12, 4, 24); }
    ctx.restore();
  }
}
