// art2d.js - programmatic 2D illustration: pointer-hand cursor, Isotype pictograms, denim knees, mini scenes.

// The classic pointer-hand cursor (index finger up). (x, y) = fingertip; s = height in px; press 0..1 squashes the finger.
function pointerHand(x, y, s, o = {}) {
  const k = s / 100, pr = o.press ?? 0;
  ctx.save(); ctx.translate(x, y); ctx.rotate(o.rot ?? 0); ctx.scale(k, k * (1 - pr * .12));
  ctx.beginPath();
  ctx.moveTo(-6, 0); ctx.quadraticCurveTo(-6, -2, 0, -2); ctx.quadraticCurveTo(6, -2, 6, 0);             // fingertip
  ctx.lineTo(6, 34); ctx.quadraticCurveTo(12, 30, 18, 33); ctx.quadraticCurveTo(24, 30, 30, 35);         // knuckles
  ctx.quadraticCurveTo(36, 33, 40, 40); ctx.lineTo(40, 70); ctx.quadraticCurveTo(40, 92, 22, 98);
  ctx.lineTo(-4, 98); ctx.quadraticCurveTo(-14, 92, -20, 78); ctx.lineTo(-30, 56); ctx.quadraticCurveTo(-34, 46, -24, 44);
  ctx.quadraticCurveTo(-16, 44, -8, 56); ctx.lineTo(-6, 58); ctx.closePath();
  shadowOn('rgba(0,0,0,.3)', 18 / k, 4 / k, 10 / k);
  ctx.fillStyle = o.fill ?? '#FFFFFF'; ctx.fill(); shadowOff();
  ctx.lineWidth = (o.lw ?? 5) / k * (s / 300); ctx.lineJoin = 'round'; ctx.strokeStyle = o.stroke ?? '#0B1440'; ctx.stroke();
  ctx.lineWidth *= .8; ctx.beginPath(); [[6, 36, 6, 52], [18, 34, 18, 52], [30, 37, 30, 54]].forEach(([a, b, c, d]) => { ctx.moveTo(a, b); ctx.lineTo(c, d); }); ctx.stroke();
  ctx.restore();
}
// click ripple rings at (x, y), age in seconds
function clickRipple(x, y, age, col = C.lime) {
  if (age < 0 || age > .9) return;
  for (let i = 0; i < 3; i++) { const a = clamp((age - i * .12) / .6); if (a <= 0) continue; ctx.strokeStyle = rgba(col, 1 - a); ctx.lineWidth = 8 * (1 - a) + 2; ctx.beginPath(); ctx.ellipse(x, y, 30 + a * 180, (30 + a * 180) * .45, 0, 0, TAU); ctx.stroke(); }
}

// Isotype pictogram person. kind 'run' | 'walk' | 'stand'; phase = gait cycle 0..1; s = height px.
function pictogram(x, y, s, kind, phase, col) {
  const k = s / 100, sw = Math.sin(phase * TAU), run = kind === 'run', amp = run ? 1 : kind === 'walk' ? .55 : 0;
  ctx.save(); ctx.translate(x, y); ctx.scale(k, k); ctx.fillStyle = col; ctx.strokeStyle = col; ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.lineWidth = 11;
  const lean = run ? .18 : .04, bob = run ? Math.abs(Math.cos(phase * TAU)) * 4 : 0;
  ctx.translate(0, -bob); ctx.rotate(lean);
  ctx.beginPath(); ctx.arc(0, -86, 10, 0, TAU); ctx.fill();                                      // head
  ctx.beginPath(); ctx.moveTo(0, -72); ctx.lineTo(0, -38); ctx.stroke();                          // torso
  const limb = (ox, oy, a1, a2, l1, l2) => { const x1 = ox + Math.sin(a1) * l1, y1 = oy + Math.cos(a1) * l1; ctx.beginPath(); ctx.moveTo(ox, oy); ctx.lineTo(x1, y1); ctx.lineTo(x1 + Math.sin(a1 + a2) * l2, y1 + Math.cos(a1 + a2) * l2); ctx.stroke(); };
  limb(0, -68, sw * .9 * amp, -.9 * amp - .15, 17, 16); limb(0, -68, -sw * .9 * amp, -.9 * amp - .15, 17, 16);   // arms
  limb(0, -38, sw * .75 * amp, Math.max(0, -sw) * .9 * amp, 20, 20); limb(0, -38, -sw * .75 * amp, Math.max(0, sw) * .9 * amp, 20, 20); // legs
  ctx.restore();
}

// Two flat denim knees; stain 0..1 grows grass-green splotches on them.
function denimKnees(t, stain) {
  const g = ctx.createLinearGradient(0, 0, 0, H); g.addColorStop(0, '#9FD8FF'); g.addColorStop(1, '#E4F4FF'); ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
  grassField(t, { y0: H + 30, h: 240, n: 700, seed: 55, wind: 20, layers: 3 });
  [[640, 700, -.18], [1240, 690, .16]].forEach(([x, y, rot], i) => {
    ctx.save(); ctx.translate(x, y); ctx.rotate(rot);
    ctx.fillStyle = '#3F68C8'; ctx.beginPath(); ctx.ellipse(0, 0, 250, 300, 0, 0, TAU); ctx.fill();
    ctx.save(); ctx.clip(); ctx.strokeStyle = 'rgba(255,255,255,.07)'; ctx.lineWidth = 3;
    for (let d = -600; d < 600; d += 11) { ctx.beginPath(); ctx.moveTo(d, -320); ctx.lineTo(d + 320, 320); ctx.stroke(); }
    ctx.fillStyle = 'rgba(255,255,255,.18)'; ctx.beginPath(); ctx.ellipse(-40, -60, 120, 150, -.3, 0, TAU); ctx.fill();
    for (let k = 0; k < 14; k++) { const a = clamp(stain * 1.5 - k * .05); if (a <= 0) continue; const sx = (hash(k * 3 + i) - .5) * 260, sy = (hash(k * 7 + i) - .5) * 200 + 20, r = (30 + hash(k + i) * 70) * easeOut(a);
      ctx.fillStyle = rgba(k % 3 ? '#3A9A48' : '#6CC35C', .8); ctx.beginPath(); ctx.ellipse(sx, sy, r, r * .7, hash(k) * 3, 0, TAU); ctx.fill(); }
    ctx.restore(); ctx.strokeStyle = 'rgba(255,255,255,.5)'; ctx.setLineDash([14, 10]); ctx.lineWidth = 4; ctx.beginPath(); ctx.ellipse(0, 0, 236, 286, 0, Math.PI * .15, Math.PI * .85); ctx.stroke(); ctx.setLineDash([]);
    ctx.restore();
  });
}

// Tiny procedural "photo" for polaroids and taped cards: sky, sun, hills, grass, optional motif.
function miniScene(x, y, w, h, seed, t, motif) {
  ctx.save(); ctx.beginPath(); ctx.rect(x, y, w, h); ctx.clip();
  const g = ctx.createLinearGradient(0, y, 0, y + h); g.addColorStop(0, mix('#1D3FE6', '#6FB8FF', hash(seed) * .6)); g.addColorStop(1, '#CDEBFF'); ctx.fillStyle = g; ctx.fillRect(x, y, w, h);
  ctx.fillStyle = '#FFFFFF'; for (let i = 0; i < 3; i++) { const cx = x + ((hash(seed + i) * w + t * 12 * (i + 1)) % (w + 80)) - 40, cy = y + h * (.15 + hash(seed + i + 5) * .25); ctx.beginPath(); ctx.ellipse(cx, cy, w * .12, h * .05, 0, 0, TAU); ctx.fill(); }
  if (hash(seed + 9) > .4) { ctx.fillStyle = C.sun; ctx.beginPath(); ctx.arc(x + w * (.2 + hash(seed + 2) * .6), y + h * .22, w * .07, 0, TAU); ctx.fill(); }
  ctx.fillStyle = '#4FA35A'; ctx.beginPath(); ctx.moveTo(x, y + h * .62); ctx.quadraticCurveTo(x + w * .5, y + h * (.45 + hash(seed + 4) * .15), x + w, y + h * .6); ctx.lineTo(x + w, y + h); ctx.lineTo(x, y + h); ctx.fill();
  ctx.save(); ctx.translate(x, y); ctx.scale(w / W, h / H); grassField(t, { y0: H + 20, h: 380, n: 160, seed: seed + 3, wind: 30, layers: 2 }); ctx.restore();
  if (motif) motif(x, y, w, h);
  ctx.restore();
}
