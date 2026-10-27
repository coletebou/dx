// ui.js - phone-UI widgets drawn natively (no screenshots, no brands).
const UI = {
  dark: { card: 'rgba(28,36,84,.92)', text: C.ice, sub: 'rgba(227,234,255,.6)', line: 'rgba(227,234,255,.14)', accent: C.blue },
  light: { card: 'rgba(255,255,255,.96)', text: C.ink, sub: 'rgba(14,36,24,.55)', line: 'rgba(14,36,24,.12)', accent: C.grass },
};

function icon(kind, x, y, s, col, lw = s * .12) {
  ctx.save(); ctx.translate(x, y); ctx.strokeStyle = col; ctx.fillStyle = col; ctx.lineWidth = lw; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  if (kind === 'search') { ctx.beginPath(); ctx.arc(-s * .1, -s * .1, s * .3, 0, TAU); ctx.stroke(); ctx.beginPath(); ctx.moveTo(s * .12, s * .12); ctx.lineTo(s * .38, s * .38); ctx.stroke(); }
  else if (kind === 'heart') { ctx.beginPath(); ctx.moveTo(0, s * .35); ctx.bezierCurveTo(-s * .6, -s * .05, -s * .3, -s * .55, 0, -s * .18); ctx.bezierCurveTo(s * .3, -s * .55, s * .6, -s * .05, 0, s * .35); ctx.fill(); }
  else if (kind === 'lock') { rr(-s * .3, -s * .02, s * .6, s * .44, s * .08); ctx.fill(); ctx.beginPath(); ctx.arc(0, -s * .06, s * .2, Math.PI, 0); ctx.stroke(); }
  else if (kind === 'pin') { ctx.beginPath(); ctx.moveTo(0, s * .5); ctx.bezierCurveTo(-s * .45, 0, -s * .38, -s * .5, 0, -s * .5); ctx.bezierCurveTo(s * .38, -s * .5, s * .45, 0, 0, s * .5); ctx.fill(); ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.arc(0, -s * .15, s * .14, 0, TAU); ctx.fill(); }
  else if (kind === 'check') { ctx.beginPath(); ctx.moveTo(-s * .3, 0); ctx.lineTo(-s * .08, s * .22); ctx.lineTo(s * .32, -s * .22); ctx.stroke(); }
  else if (kind === 'hourglass') { ctx.beginPath(); ctx.moveTo(-s * .25, -s * .35); ctx.lineTo(s * .25, -s * .35); ctx.lineTo(-s * .25, s * .35); ctx.lineTo(s * .25, s * .35); ctx.closePath(); ctx.stroke(); }
  else if (kind === 'camera') { rr(-s * .4, -s * .25, s * .8, s * .55, s * .1); ctx.stroke(); ctx.beginPath(); ctx.arc(0, s * .03, s * .15, 0, TAU); ctx.stroke(); }
  ctx.restore();
}

// Rounded phone; paintScreen(x, y, w, h) draws inside the screen clip.
function phone(x, y, w, h, paintScreen, o = {}) {
  ctx.save();
  if (o.shadow !== false) shadowOn('rgba(0,0,0,.45)', 60, 0, 30);
  ctx.fillStyle = o.body ?? '#0B0E1C'; rr(x, y, w, h, w * .13); ctx.fill(); shadowOff();
  const b = w * .035; ctx.save(); rr(x + b, y + b, w - 2 * b, h - 2 * b, w * .1); ctx.clip();
  paintScreen(x + b, y + b, w - 2 * b, h - 2 * b);
  ctx.restore();
  ctx.fillStyle = o.body ?? '#0B0E1C'; rr(x + w * .36, y + b * 1.6, w * .28, w * .075, w * .04); ctx.fill();  // island
  ctx.restore();
}

// iOS-ish notification card. age drives slide-in.
function notif(t, t0, x, y, w, title, body, o = {}) {
  const age = t - t0; if (age < 0) return;
  const th = o.theme ?? UI.dark, k = backOut(clamp(age / .35), 1.4), out = o.t1 ? clamp((t - o.t1) / .3) : 0;
  const h = o.h ?? 150, yy = y - (1 - k) * (h + 60) - out * (h + 80);
  ctx.save(); ctx.globalAlpha = 1 - out; shadowOn('rgba(0,0,0,.35)', 40, 0, 18);
  ctx.fillStyle = th.card; rr(x, yy, w, h, 34); ctx.fill(); shadowOff();
  ctx.fillStyle = o.iconCol ?? th.accent; rr(x + 28, yy + 30, 62, 62, 16); ctx.fill();
  icon(o.icon ?? 'hourglass', x + 59, yy + 61, 40, '#fff', 4);
  text(o.app ?? 'SCREEN TIME', x + 110, yy + 52, F.ui(24, 700), th.sub);
  text(o.when ?? 'now', x + w - 30, yy + 52, F.ui(24, 500), th.sub, 'right');
  text(title, x + 110, yy + 92, F.ui(34, 800), th.text);
  if (body) text(body, x + 110, yy + 130, F.ui(30, 500), th.text);
  ctx.restore();
}

// Search pill with magnifier and caret.
function searchBar(t, x, y, w, h, s, o = {}) {
  const th = o.theme ?? UI.light;
  ctx.save(); shadowOn(o.shadowCol ?? 'rgba(0,0,0,.25)', 40, 0, 16);
  ctx.fillStyle = th.card; rr(x, y, w, h, h / 2); ctx.fill(); shadowOff();
  icon('search', x + h * .55, y + h / 2, h * .5, th.sub, h * .06);
  const px = o.px ?? h * .42, tx = x + h * 1.0;
  text(s || (o.placeholder ?? ''), tx, y + h / 2 + px * .35, F.ui(px, 500), s ? th.text : th.sub);
  if (o.caret !== false && Math.floor(t * 2.2) % 2 === 0) { const cw = measure(s, F.ui(px, 500)); ctx.fillStyle = th.accent; ctx.fillRect(tx + cw + 6, y + h * .24, 4, h * .52); }
  ctx.restore();
}
function suggestions(t, t0, x, y, w, items, o = {}) {
  const th = o.theme ?? UI.light, rowH = o.rowH ?? 86;
  items.forEach((s, i) => {
    const a = clamp((t - t0 - i * .09) / .18); if (a <= 0) return;
    ctx.save(); ctx.globalAlpha = a; ctx.translate(0, (1 - easeOut(a)) * -20);
    ctx.fillStyle = th.card; rr(x, y + i * rowH, w, rowH - 8, 22); ctx.fill();
    icon('search', x + 44, y + i * rowH + rowH / 2 - 4, 34, th.sub, 3);
    const [head, tail] = [s.slice(0, o.bold ?? 0), s.slice(o.bold ?? 0)];
    text(head, x + 88, y + i * rowH + rowH / 2 + 10, F.ui(34, 500), th.sub);
    text(tail, x + 88 + measure(head, F.ui(34, 500)), y + i * rowH + rowH / 2 + 10, F.ui(34, 800), th.text);
    ctx.restore();
  });
}

// Weekly screen-time bars. vals in hours; grow 0..1; fall 0..1 tips bars over into the grass.
function screenBars(t, x, y, w, h, vals, grow, o = {}) {
  const th = o.theme ?? UI.dark, n = vals.length, gap = w * .045, bw = (w - gap * (n - 1)) / n, max = o.max ?? 9, days = 'MTWTFSS';
  ctx.save();
  ctx.strokeStyle = th.line; ctx.lineWidth = 2;
  for (let i = 0; i <= 3; i++) { const yy = y + h - (h * i) / 3; ctx.beginPath(); ctx.moveTo(x, yy); ctx.lineTo(x + w, yy); ctx.stroke(); }
  vals.forEach((v, i) => {
    const g = easeOut(clamp(grow * 1.4 - i * .07)), bh = (v / max) * h * g, bx = x + i * (bw + gap);
    const fall = o.fall ? clamp(o.fall * 1.6 - (n - 1 - i) * .08) : 0;
    ctx.save(); ctx.translate(bx + bw / 2, y + h);
    if (fall > 0) { ctx.rotate(easeIn(fall) * (i % 2 ? 1.2 : -1.3)); ctx.translate(0, easeIn(fall) * 380); }
    ctx.fillStyle = i === (o.hi ?? n - 1) ? (o.hiCol ?? th.accent) : (o.col ?? rgba(C.blue2, .55));
    rr(-bw / 2, -bh, bw, bh, Math.min(14, bw / 3)); ctx.fill();
    ctx.restore();
    text(days[i], bx + bw / 2, y + h + 44, F.ui(28, 700), th.sub, 'center');
  });
  ctx.restore();
}

function bubble(t, t0, x, y, s, side, o = {}) {
  const age = t - t0; if (age < 0) return 0;
  const px = o.px ?? 40, k = backOut(clamp(age / .22), 2), tw = measure(s, F.ui(px, 600)), bw = tw + px * 1.2, bh = px * 1.8;
  const bx = side === 'right' ? x - bw : x;
  ctx.save(); ctx.translate(bx + (side === 'right' ? bw : 0), y + bh); ctx.scale(k, k); ctx.translate(-(bx + (side === 'right' ? bw : 0)), -(y + bh));
  ctx.fillStyle = side === 'right' ? (o.meCol ?? C.blue) : (o.themCol ?? 'rgba(227,234,255,.14)');
  rr(bx, y, bw, bh, bh / 2.2); ctx.fill();
  text(s, bx + px * .6, y + bh / 2 + px * .36, F.ui(px, 600), side === 'right' ? '#fff' : (o.themText ?? C.ice));
  if (o.name) text(o.name, bx + 8, y - 12, F.ui(24, 700), o.nameCol ?? 'rgba(227,234,255,.5)');
  ctx.restore();
  return bh;
}

// "Search interest" line chart. prog 0..1 draws the line; vert 0..1 sends the tail vertical off the top.
function trendChart(t, x, y, w, h, prog, vert, o = {}) {
  const th = o.theme ?? UI.light, pts = [];
  const N = 60;
  for (let i = 0; i <= N; i++) {
    const u = i / N; let v = .08 + .05 * noise1(u * 9 + 3) + .04 * Math.sin(u * 20);
    v += Math.pow(Math.max(0, (u - .72) / .28), 3) * .75;
    pts.push([x + u * w, y + h - v * h]);
  }
  ctx.save();
  ctx.fillStyle = th.card; shadowOn('rgba(0,0,0,.18)', 50, 0, 20); rr(x - 60, y - 120, w + 120, h + 200, 36); ctx.fill(); shadowOff();
  text(o.title ?? 'Interest over time', x, y - 50, F.ui(34, 800), th.text);
  text(o.sub ?? '"how to touch grass"  ·  past 12 months', x, y - 12, F.ui(26, 500), th.sub);
  ctx.strokeStyle = th.line; ctx.lineWidth = 2;
  for (let i = 0; i <= 4; i++) { const yy = y + h - (h * i) / 4; ctx.beginPath(); ctx.moveTo(x, yy); ctx.lineTo(x + w, yy); ctx.stroke(); }
  const m = Math.floor(prog * N);
  ctx.strokeStyle = o.lineCol ?? C.grass; ctx.lineWidth = o.lw ?? 9; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
  ctx.beginPath(); pts.slice(0, m + 1).forEach(([px, py], i) => (i ? ctx.lineTo(px, py) : ctx.moveTo(px, py)));
  let tip = pts[m];
  if (vert > 0) { tip = [pts[N][0], lerp(pts[N][1], y - 1400, easeIn(vert))]; ctx.lineTo(tip[0], tip[1]); }
  ctx.stroke();
  if (m > 2) { ctx.fillStyle = o.lineCol ?? C.grass; ctx.beginPath(); ctx.arc(tip[0], tip[1], 14, 0, TAU); ctx.fill(); glow(tip[0], tip[1], 90, C.lime, .5); }
  ctx.restore();
  return tip;
}

function battery(x, y, w, pct, col) {
  const h = w * .46;
  ctx.save(); ctx.strokeStyle = col; ctx.lineWidth = w * .06; rr(x, y, w, h, h * .22); ctx.stroke();
  ctx.fillStyle = col; rr(x + w + w * .03, y + h * .3, w * .07, h * .4, 4); ctx.fill();
  ctx.fillStyle = pct < .1 ? C.badge : col; rr(x + w * .07, y + h * .14, (w * .86) * clamp(pct), h * .72, h * .14); ctx.fill();
  ctx.restore();
}

function spinner(x, y, r, t, col, a = 1) {
  ctx.save(); ctx.translate(x, y); ctx.rotate(Math.floor(t * 12) * TAU / 12);
  for (let i = 0; i < 12; i++) { ctx.globalAlpha = a * (.15 + (i / 12) * .85); ctx.fillStyle = col; ctx.rotate(TAU / 12); rr(-r * .09, -r, r * .18, r * .45, r * .09); ctx.fill(); }
  ctx.restore();
}
