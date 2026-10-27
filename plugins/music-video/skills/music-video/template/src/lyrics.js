// lyrics.js - kinetic lyric typography driven by word timestamps (window.TIMING.lines[i].words).
const LEAD = .07;          // words appear slightly before they are sung
const isAdlib = w => /^\(/.test(w.w) || /\)$/.test(w.w);
function mainWords(li) {
  const out = []; let inParen = false;
  for (const w of LINES[li].words) {
    const open = w.w.startsWith('('), close = w.w.endsWith(')') || w.w.endsWith(')!') || w.w.endsWith('!)');
    if (open) inParen = true;
    if (!inParen) out.push(w);
    if (close) inParen = false;
  }
  return out;
}
function adlibs(li) {
  const ws = LINES[li].words, out = []; let cur = null;
  for (const w of ws) {
    if (w.w.startsWith('(')) cur = { text: '', t0: w.t0, t1: w.t1 };
    if (cur) { cur.text += (cur.text ? ' ' : '') + w.w.replace(/[()]/g, ''); cur.t1 = w.t1; }
    if (cur && /\)/.test(w.w)) { out.push(cur); cur = null; }
  }
  return out;
}
const clean = s => s.replace(/^["“]|["”,.:]+$/g, '').replace(/["“”]/g, '');

// Greedy layout of words into rows at font px; returns rows [{words:[{w,x,width}], width}]
function layoutWords(words, px, maxW, fontFn, upper) {
  const space = Math.max(measure(' ', fontFn(px)), px * .27), rows = [{ words: [], width: 0 }];
  for (const w of words) {
    const s = upper ? clean(w.w).toUpperCase() : clean(w.w), ww = measure(s, fontFn(px));
    let row = rows[rows.length - 1];
    if (row.words.length && row.width + space + ww > maxW) { row = { words: [], width: 0 }; rows.push(row); }
    row.words.push({ ...w, s, x: row.width + (row.words.length ? space : 0), width: ww });
    row.width = row.words[row.words.length - 1].x + ww;
  }
  return rows;
}

// Big stacked kinetic lyric. box {x, y, w, h}; o: fontFn, maxPx, fg, accent, upper, align, lh, rot, shadow, outline, from
function heroType(t, li, box, o = {}) {
  if (li < 0) return;
  const words = mainWords(li), fontFn = o.fontFn ?? (px => F.display(px, 800)), upper = o.upper ?? true, lh = o.lh ?? .9;
  let px = o.maxPx ?? 230, rows;
  for (; px > 24; px *= .94) { rows = layoutWords(words, px, box.w, fontFn, upper); if (rows.length * px * lh <= box.h && rows.length <= (o.maxRows ?? 4)) break; }
  const totalH = rows.length * px * lh, y0 = box.y + (o.valign === 'top' ? 0 : o.valign === 'bottom' ? box.h - totalH : (box.h - totalH) / 2);
  const cur = words.findIndex(w => t < w.t1 + .02 && t >= w.t0 - LEAD);
  rows.forEach((row, r) => {
    const rx = box.x + (o.align === 'center' ? (box.w - row.width) / 2 : o.align === 'right' ? box.w - row.width : 0);
    row.words.forEach(w => {
      const p = clamp((t - w.t0 + LEAD) / .2); if (p <= 0) return;
      const k = backOut(p, 2.2), x = rx + w.x, y = y0 + (r + 1) * px * lh - px * .12;
      const active = cur >= 0 && words[cur] === words.find(q => q.t0 === w.t0 && q.w === w.w);
      const col = (o.accentWords && o.accentWords.includes(clean(w.w).toLowerCase())) || (o.accentActive && active) ? (o.accent ?? C.lime) : (o.fg ?? C.white);
      ctx.save();
      ctx.translate(x + w.width / 2, y - px * .35);
      ctx.rotate((o.rot ?? 0) + (1 - k) * (hash(w.t0 * 13) - .5) * .5);
      ctx.scale(lerp(.3, 1, k), lerp(.3, 1, k));
      ctx.translate(-w.width / 2, px * .35 + (1 - k) * 40);
      ctx.globalAlpha = clamp(p * 3) * (o.alpha ?? 1);
      if (o.outline || o.chrome) { ctx.lineJoin = 'round'; ctx.lineWidth = px * (o.chrome ? .075 : .09); ctx.strokeStyle = o.outline ?? C.cobaltInk; ctx.font = fontFn(px); shadowOn(o.shadow ?? 'rgba(6,16,90,.5)', px * .14, 0, px * .05); ctx.strokeText(w.s, 0, 0); shadowOff(); }
      if (o.shadow !== false) shadowOn(o.shadow ?? 'rgba(6,24,12,.45)', px * .12, 0, px * .05);
      text(w.s, 0, 0, fontFn(px), o.chrome && col === (o.fg ?? C.white) ? chromeFill(-px * .78, px * .08) : col);
      shadowOff(); ctx.restore();
    });
  });
  return { px, rows, y0, totalH };
}

// Subtitle / karaoke line: centred pill near the bottom, sung words fill in.
function subType(t, li, o = {}) {
  if (li < 0) return;
  const words = mainWords(li), px = o.px ?? 46, fontFn = o.fontFn ?? (p => F.ui(p, 700));
  const s = words.map(w => clean(w.w)).join(' ');
  const tw = measure(s, fontFn(px)), x = (W - tw) / 2, y = o.y ?? H - 86;
  const a = clamp((t - words[0].t0 + .3) / .25) * clamp((LINES[li].t1 + .6 - t) / .25);
  if (a <= 0) return;
  ctx.save(); ctx.globalAlpha = a;
  if (o.pill !== false) { ctx.fillStyle = o.bg ?? 'rgba(8,24,14,.55)'; rr(x - 28, y - px * 1.05, tw + 56, px * 1.5, px * .75); ctx.fill(); }
  let cx = x;
  for (const w of words) {
    const ws = clean(w.w) + ' ', ww = measure(ws, fontFn(px)), sung = clamp((t - w.t0 + .05) / Math.max(.08, w.t1 - w.t0));
    text(ws, cx, y, fontFn(px), o.dim ?? 'rgba(255,255,255,.45)');
    if (sung > 0) { ctx.save(); ctx.beginPath(); ctx.rect(cx, y - px * 1.2, ww * sung, px * 1.6); ctx.clip(); text(ws, cx, y, fontFn(px), o.fg ?? C.white); ctx.restore(); }
    cx += ww;
  }
  ctx.restore();
}

// Sticker stamp that slaps on at t0 (ad-libs, stats). o: bg, fg, rot, font, life, pad
function stamp(t, t0, s, x, y, px, o = {}) {
  const age = t - t0; if (age < -.02) return;
  const life = o.life ?? 99, out = clamp((age - life) / .25);
  if (out >= 1) return;
  const k = backOut(clamp(age / .16), 3), fontFn = o.fontFn ?? (p => F.display(p, 800)), pad = px * (o.pad ?? .32);
  const tw = measure(s, fontFn(px));
  ctx.save(); ctx.translate(x, y); ctx.rotate(o.rot ?? -.06); ctx.scale(lerp(1.8, 1, k) * (1 - out * .4), lerp(1.8, 1, k) * (1 - out * .4));
  ctx.globalAlpha = clamp(age / .06) * (1 - out);
  shadowOn('rgba(0,0,0,.28)', 18, 0, 8);
  ctx.fillStyle = o.bg ?? C.lime; rr(-tw / 2 - pad, -px * .82, tw + pad * 2, px * 1.25, o.radius ?? px * .22); ctx.fill(); shadowOff();
  if (o.border) { ctx.strokeStyle = o.border; ctx.lineWidth = px * .06; ctx.stroke(); }
  text(s, 0, px * .08, fontFn(px), o.fg ?? C.ink, 'center', 'middle');
  ctx.restore();
}

// Elegant italic serif line; words fade/drift in.
function serifType(t, li, x, y, px, col = C.ink, align = 'left', maxW = W - 240) {
  if (li < 0) return;
  const words = mainWords(li), fontFn = p => F.serif(p);
  const rows = layoutWords(words, px, maxW, fontFn, false);
  rows.forEach((row, r) => {
    const rx = align === 'center' ? x - row.width / 2 : x;
    row.words.forEach(w => {
      const p = clamp((t - w.t0 + .1) / .45); if (p <= 0) return;
      ctx.save(); ctx.globalAlpha = easeOut(p); text(w.s, rx + w.x, y + r * px * 1.05 + (1 - easeOut(p)) * 18, fontFn(px), col); ctx.restore();
    });
  });
}

// Characters typed across a word window (search bars, chat).
function typed(t, s, t0, t1) { const n = Math.floor(clamp((t - t0) / Math.max(.05, t1 - t0)) * s.length + 1e-6); return s.slice(0, n); }
