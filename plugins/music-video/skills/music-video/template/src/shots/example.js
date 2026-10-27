// example.js - a working starter: one shot per lyric line over the 3D meadow, stamps on ad-libs, a title card.
// Replace with your own shots. Each shot fn paints the WHOLE frame as a pure function of song time t.
(() => {
  const CAMS = ['low', 'wide', 'side', 'up'];
  shot(0, 'title_in', async (t, lt) => {
    GL.draw('meadow', t, lt, { cam: 'wide' });
    const a = clamp(lt / .6);
    ctx.save(); ctx.globalAlpha = a; shadowOn('rgba(0,0,0,.45)', 30, 0, 10);
    text(window.TITLE ?? 'UNTITLED', W / 2, H / 2, F.display(180, 800), C.white, 'center', 'middle'); shadowOff(); ctx.restore();
  });
  LINES.forEach((ln, i) => {
    shot(L(i), `line_${i}`, async (t, lt) => {
      GL.draw('meadow', t, lt, { cam: CAMS[i % CAMS.length], daisies: .6 });
      const g = ctx.createLinearGradient(0, 0, W * .6, 0); g.addColorStop(0, 'rgba(6,40,20,.45)'); g.addColorStop(1, 'rgba(6,40,20,0)'); ctx.fillStyle = g; ctx.fillRect(0, 0, W, H);
      heroType(t, i, { x: 100, y: 120, w: 1100, h: 820 }, { maxPx: 190, fg: C.white, accent: C.lime, accentActive: true });
      adlibs(i).forEach(a => stamp(t, a.t0, a.text.toUpperCase(), 1400, 820, 84, { bg: C.lime, fg: C.ink, rot: -.08 }));
    });
  });
})();
