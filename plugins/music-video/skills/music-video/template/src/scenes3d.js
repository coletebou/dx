// scenes3d.js - 3D sets built from primitives and code-generated textures (starter: the meadow).
const { THREE, def, MAT, COL, canvasTex, rng, makeSky, makeGrass, envFrom, lights, cam, fog, RoundedBoxGeometry } = window.GL;
const V = (x, y, z) => new THREE.Vector3(x, y, z);
const lerp = (a, b, k) => a + (b - a) * k, clamp01 = k => Math.max(0, Math.min(1, k)), ease = k => k * k * (3 - 2 * k);

// ---------- shared pieces ----------
const turfTex = (seed = 5) => canvasTex(1024, 1024, (g, w, h) => {
  const r = rng(seed); g.fillStyle = '#2B7A3A'; g.fillRect(0, 0, w, h);
  for (let i = 0; i < 26000; i++) { const x = r() * w, y = r() * h, l = 3 + r() * 9; g.strokeStyle = ['#1E6B33', '#2F8A42', '#3C9B4B', '#56B056', '#1A5E2D'][Math.floor(r() * 5)]; g.lineWidth = 1 + r() * 1.5; g.beginPath(); g.moveTo(x, y); g.lineTo(x + (r() - .5) * 3, y - l); g.stroke(); }
}, { repeat: [40, 40] });
function lawn(scene, o = {}) {
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(400, 400), new THREE.MeshStandardMaterial({ map: turfTex(o.seed ?? 5), roughness: 1 }));
  ground.rotation.x = -Math.PI / 2; ground.receiveShadow = true; scene.add(ground);
  const near = makeGrass(o.nearN ?? 150000, { x0: o.x0 ?? -9, x1: o.x1 ?? 9, z0: o.z0 ?? -14, z1: o.z1 ?? 4, h: o.h ?? .4, seed: (o.seed ?? 5) + 1, clear: o.clear });
  const far = makeGrass(o.farN ?? 90000, { x0: -60, x1: 60, z0: -90, z1: o.z0 ?? -14, h: (o.h ?? .4) * 1.1, w: .09, seed: (o.seed ?? 5) + 2 });
  scene.add(near, far); return { ground, near, far };
}
function daisy(scale = 1) {
  const g = new THREE.Group(), petal = new THREE.MeshStandardMaterial({ color: '#FFFFFF', roughness: .6, side: THREE.DoubleSide });
  const stem = new THREE.Mesh(new THREE.CylinderGeometry(.008, .01, .3, 6), new THREE.MeshStandardMaterial({ color: '#2F8A42' })); stem.position.y = .15; g.add(stem);
  const head = new THREE.Group(); head.position.y = .3;
  for (let i = 0; i < 14; i++) { const p = new THREE.Mesh(new THREE.PlaneGeometry(.025, .09), petal); p.position.set(Math.cos(i / 14 * Math.PI * 2) * .05, 0, Math.sin(i / 14 * Math.PI * 2) * .05); p.rotation.set(-Math.PI / 2 + .25, -i / 14 * Math.PI * 2 + Math.PI / 2, 0); head.add(p); }
  const c = new THREE.Mesh(new THREE.SphereGeometry(.03, 16, 8), new THREE.MeshStandardMaterial({ color: '#FFD84A', roughness: .5 })); c.scale.y = .5; head.add(c); g.add(head);
  g.scale.setScalar(scale); return g;
}
function phoneMesh(face = 'down') {
  const g = new THREE.Group();
  const body = new THREE.Mesh(new RoundedBoxGeometry(.72, .06, 1.5, 6, .08), MAT.cobaltGloss()); body.castShadow = true; g.add(body);
  const cam = new THREE.Mesh(new RoundedBoxGeometry(.28, .03, .3, 4, .06), MAT.cobaltGloss()); cam.position.set(-.16, .04, -.5); g.add(cam);
  [[-.22, -.58], [-.1, -.58], [-.22, -.44]].forEach(([x, z]) => { const l = new THREE.Mesh(new THREE.CylinderGeometry(.045, .045, .03, 24), MAT.chrome()); l.position.set(x, .06, z); g.add(l); });
  if (face === 'up') g.rotation.z = Math.PI;
  return g;
}
const screenMat = (col = '#DDE6FF', k = 1.4) => new THREE.MeshStandardMaterial({ color: '#0B1440', emissive: new THREE.Color(col), emissiveIntensity: k, roughness: .2 });

// ---------- meadow: the chorus world. p: cam preset, press {x,z,k}, reach {x,y,z,k}, phone, daisies ----------
def('meadow', () => {
  const scene = new THREE.Scene(); scene.environment = envFrom(); const sky = makeSky({ clouds: .6 }); scene.add(sky); fog(scene, 20, 110);
  lights(scene, { sunPos: [6, 10, 4], shadowSize: 8 });
  const { near, far } = lawn(scene, { seed: 9, clear: [[.4, -2.2, .62, .95], [0, 0, .75]] });
  const phone = phoneMesh('down'); phone.position.set(.4, .06, -2.2); phone.rotation.y = .5; phone.visible = false; scene.add(phone);
  const flowers = []; const r = rng(21);
  for (let i = 0; i < 70; i++) { const d = daisy(.8 + r() * .7); d.position.set((r() - .5) * 8, 0, -1 - r() * 9); d.rotation.y = r() * 6; scene.add(d); flowers.push(d); }
  const camera = cam(40);
  const PRESETS = {
    low: t => [[Math.sin(t * .15) * .4, .55, 3.2 - t * .05], [0, .35, -3]],
    top: t => [[.4 + Math.sin(t * .1) * .2, 4.2, -2.1], [.4, 0, -2.2], t * .04],
    side: t => [[-3 + t * .12, .8, 1.2], [0, .3, -3]],
    up: t => [[0, .2, 0], [.3, 3.2, -5]],
    wide: t => [[0, 1.6, 6 - t * .06], [0, .8, -10]],
  };
  return { scene, camera, update(t, lt, p) {
    const pre = PRESETS[p.cam ?? 'low'](lt); camera.position.set(...pre[0]); camera.up.set(0, 1, 0);
    if (pre[2] !== undefined) { camera.up.set(Math.sin(pre[2]), 0, -Math.cos(pre[2])); }
    camera.lookAt(...pre[1]); camera.fov = p.fov ?? 40; camera.updateProjectionMatrix();
    for (const g of [near, far]) { g.userData.u.uPress.value.set(p.press?.x ?? 0, p.press?.z ?? 0, p.press?.k ?? 0, p.press?.r ?? .6);
      g.userData.u.uReach.value.set(p.reach?.x ?? 0, p.reach?.y ?? 0, p.reach?.z ?? 0, p.reach?.k ?? 0); g.userData.u.uReachR.value = p.reach?.r ?? 2.5; g.userData.u.uWind.value = p.wind ?? .22; }
    if (p.pressAt) {                                                   // press at a screen point: find the grass under it
      const { sx, sy, k = 1, r = .6 } = p.pressAt, o = camera.position.clone(), d = new THREE.Vector3(sx / W * 2 - 1, 1 - sy / H * 2, .5).unproject(camera).sub(o).normalize();
      const hit = o.add(d.multiplyScalar(-o.y / Math.min(-1e-4, d.y)));
      for (const g of [near, far]) g.userData.u.uPress.value.set(hit.x, hit.z, k, r);
    }
    if (p.reachAt) {                                                   // blades curl up toward a point above the grass under a screen position
      const { sx, sy, k = 1, r = 1.4, y = .7 } = p.reachAt, o = camera.position.clone(), d = new THREE.Vector3(sx / W * 2 - 1, 1 - sy / H * 2, .5).unproject(camera).sub(o).normalize();
      const hit = o.add(d.multiplyScalar(-o.y / Math.min(-1e-4, d.y)));
      for (const g of [near, far]) { g.userData.u.uReach.value.set(hit.x, y, hit.z, k); g.userData.u.uReachR.value = r; }
    }
    phone.visible = !!p.phone; flowers.forEach((f, i) => { const k = p.daisies ?? 1; f.visible = k > 0; f.scale.setScalar((.8 + (i % 5) * .12) * ease(clamp01(k * 1.4 - (i % 7) * .06))); });
  } };
});


// Add your own sets below with def(name, () => ({ scene, camera, update(t, lt, p) {} })).
// Patterns worth copying (see references/pipeline.md): a render-target portal, instanced grass on a sphere,
// an instanced flock updated per frame, a lathe-geometry chrome sculpture, CanvasTexture labels and screens.

window.SCENES3D_READY = true; window.dispatchEvent(new Event('scenes-ready'));
