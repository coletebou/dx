// fx.js - paper texture, film grain, vignette, glow, and full-frame transitions.
function mulberry(seed) { return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 2 ** 32; }; }
function offscreen(w, h) { const c = document.createElement('canvas'); c.width = w; c.height = h; return c; }

// Paper: warm base, soft blotches, fibres and flecks. Built once, reused every frame.
const PAPER = (() => {
  const c = offscreen(W, H), g = c.getContext('2d'), R = mulberry(7);
  g.fillStyle = C.paper; g.fillRect(0, 0, W, H);
  for (let i = 0; i < 90; i++) {
    const x = R() * W, y = R() * H, r = 80 + R() * 320, gr = g.createRadialGradient(x, y, 0, x, y, r);
    const tone = R() < .5 ? 'rgba(214,200,168,' : 'rgba(255,252,240,';
    gr.addColorStop(0, tone + (0.05 + R() * .07) + ')'); gr.addColorStop(1, tone + '0)');
    g.fillStyle = gr; g.fillRect(x - r, y - r, 2 * r, 2 * r);
  }
  g.lineCap = 'round';
  for (let i = 0; i < 2600; i++) {
    const x = R() * W, y = R() * H, l = 4 + R() * 22, a = R() * TAU;
    g.strokeStyle = `rgba(120,104,72,${0.04 + R() * .08})`; g.lineWidth = .5 + R() * .9;
    g.beginPath(); g.moveTo(x, y); g.quadraticCurveTo(x + Math.cos(a + 1) * l * .5, y + Math.sin(a + 1) * l * .5, x + Math.cos(a) * l, y + Math.sin(a) * l); g.stroke();
  }
  for (let i = 0; i < 1400; i++) { g.fillStyle = `rgba(90,80,60,${R() * .12})`; g.fillRect(R() * W, R() * H, 1 + R() * 1.6, 1 + R() * 1.6); }
  return c;
})();
function paper(alpha = 1) { ctx.save(); ctx.globalAlpha = alpha; ctx.drawImage(PAPER, 0, 0); ctx.restore(); }
// multiply the paper fibres over whatever is already painted (for "printed" photo cards etc.)
function paperMultiply(k = .35) { ctx.save(); ctx.globalCompositeOperation = 'multiply'; ctx.globalAlpha = k; ctx.drawImage(PAPER, 0, 0); ctx.restore(); }

const GRAIN = Array.from({ length: 6 }, (_, s) => {
  const c = offscreen(512, 512), g = c.getContext('2d'), d = g.createImageData(512, 512), R = mulberry(101 + s);
  for (let i = 0; i < d.data.length; i += 4) { const v = 128 + (R() + R() + R() - 1.5) * 150; d.data[i] = d.data[i + 1] = d.data[i + 2] = v; d.data[i + 3] = 255; }
  g.putImageData(d, 0, 0); return c;
});
function grain(t, k = .07) {
  const f = Math.floor(t * 24), tile = GRAIN[f % GRAIN.length], ox = Math.floor(hash(f) * 512), oy = Math.floor(hash(f + 9) * 512);
  ctx.save(); ctx.globalCompositeOperation = 'overlay'; ctx.globalAlpha = k;
  const pat = ctx.createPattern(tile, 'repeat'); pat.setTransform(new DOMMatrix().translate(-ox, -oy));
  ctx.fillStyle = pat; ctx.fillRect(0, 0, W, H); ctx.restore();
}
function vignette(k = .35, col = '8,20,12') {
  const g = ctx.createRadialGradient(W / 2, H / 2, H * .35, W / 2, H / 2, H * .95);
  g.addColorStop(0, `rgba(${col},0)`); g.addColorStop(1, `rgba(${col},${k})`);
  ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
}
// soft additive glow of a colour at a point (screen light, sun)
function glow(x, y, r, col, a = .5) {
  const g = ctx.createRadialGradient(x, y, 0, x, y, r); g.addColorStop(0, rgba(col, a)); g.addColorStop(1, rgba(col, 0));
  ctx.save(); ctx.globalCompositeOperation = 'lighter'; ctx.fillStyle = g; ctx.fillRect(x - r, y - r, 2 * r, 2 * r); ctx.restore();
}
function flash(k, col = C.white) { if (k <= 0) return; ctx.save(); ctx.globalAlpha = clamp(k); ctx.fillStyle = col; ctx.fillRect(0, 0, W, H); ctx.restore(); }
// duotone a photo region toward a dark/light pair (used to push stills into the screen-world palette)
function tint(col, k, op = 'color') { ctx.save(); ctx.globalCompositeOperation = op; ctx.globalAlpha = k; ctx.fillStyle = col; ctx.fillRect(0, 0, W, H); ctx.restore(); }
// scanline + RGB-split feel for the screen world
function screenFx(t, k = 1) {
  ctx.save(); ctx.globalAlpha = .05 * k; ctx.fillStyle = '#000';
  for (let y = (Math.floor(t * 60) % 3); y < H; y += 3) ctx.fillRect(0, y, W, 1);
  ctx.restore();
}
