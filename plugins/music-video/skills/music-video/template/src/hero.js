// hero.js - the real assets: Meshy's rigged, textured hiker driven by motion-capture clips, plus PBR props
// (pine, round tree, boulder) for instancing. Loaded once per page before any scene builds (window.HERO_READY).
// Poses stay a pure function of song time: every frame sets each clip's time and weight explicitly.
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { clone as skelClone } from 'three/addons/utils/SkeletonUtils.js';
const { THREE } = window.GL;
// window.HERO_CONFIG = { dir: '../char/', rig: 'hero_rigged.glb', clips: { walk: 'hero_walking.glb', ... }, props: { pine: 'pine.glb' } }
const CFG = window.HERO_CONFIG ?? {}, DIR = CFG.dir ?? '../char/', loader = new GLTFLoader();
const load = f => new Promise(ok => loader.load(DIR + f, ok, undefined, e => { console.warn('asset missing ' + f + ' ' + (e?.message ?? '')); ok(null); }));
const HERO = window.HERO = { clips: {}, props: {} };

// one clip per file (Meshy rigging gives walk + run; the rest were applied from its motion library)
const FILES = CFG.clips ?? { walk: 'hero_walking.glb', run: 'hero_running.glb', idle: 'hero_idle.glb' }, PROPS = CFG.props ?? {};
// root motion is baked into Hips.position: remove the net drift (keep sway and bob) so paths drive position
function inPlace(clip) {
  const c = clip.clone();
  for (const tr of c.tracks) if (/Hips\.position$/.test(tr.name)) {
    const v = tr.values, n = v.length / 3, T = tr.times[tr.times.length - 1] || 1, dx = v[(n - 1) * 3] - v[0], dz = v[(n - 1) * 3 + 2] - v[2];
    for (let i = 0; i < n; i++) { const k = tr.times[i] / T; v[i * 3] -= dx * k; v[i * 3 + 2] -= dz * k; }
  }
  return c;
}
// props: one mesh, re-based so its footprint is centred at the origin, sitting on y = 0, one unit tall
function unitProp(g) {
  if (!g) return null;
  let mesh = null; g.scene.updateMatrixWorld(true); g.scene.traverse(o => { if (o.isMesh && !mesh) mesh = o; });
  const geo = mesh.geometry.clone().applyMatrix4(mesh.matrixWorld); geo.computeBoundingBox();
  const b = geo.boundingBox, h = b.max.y - b.min.y; geo.translate(-(b.min.x + b.max.x) / 2, -b.min.y, -(b.min.z + b.max.z) / 2); geo.scale(1 / h, 1 / h, 1 / h);
  const mat = mesh.material; mat.envMapIntensity = .8; if (mat.map) mat.map.anisotropy = 8;
  return { geo, mat };
}

window.HERO_READY = (async () => {
  const keys = Object.keys(FILES), pk = Object.keys(PROPS);
  const got = await Promise.all([...keys.map(k => FILES[k].split('#')[0]), CFG.rig ?? 'hero_rigged.glb', ...pk.map(k => PROPS[k])].map(load));
  const pick = (g, sel) => !g ? null : sel == null ? g.animations[0] : /^\d+$/.test(sel) ? g.animations[+sel] : g.animations.find(c => c.name.includes(sel));
  keys.forEach((k, i) => { const c = pick(got[i], FILES[k].split('#')[1]); if (c) HERO.clips[k] = inPlace(c); });
  HERO.rig = got[keys.length]; pk.forEach((k, i) => { HERO.props[k] = unitProp(got[keys.length + 1 + i]); });
  const rig = HERO.rig;
  console.log('hero clips: ' + Object.entries(HERO.clips).map(([k, c]) => `${k}(${c.duration.toFixed(2)}s)`).join(' ') + (rig ? '' : '  NO RIG'));
})();

// metres per second each locomotion clip covers, so clip time can follow distance walked (no foot sliding)
const SPEED = { walk: 1.25, run: 3.4 };
const LOOP = new Set(['walk', 'run', 'idle', 'sit']);

function makeHero() {
  const root = new THREE.Group(), model = skelClone(HERO.rig.scene); root.add(model);
  const B = {};
  model.traverse(o => {
    if (o.isMesh) { o.castShadow = true; o.receiveShadow = true; o.frustumCulled = false; o.material.envMapIntensity = .9; }
    if (o.isBone) B[o.name.replace(/^mixamorig:?/, '')] = o;
  });
  const hand = B.RightHand;
  // rotate a bone about an axis given in the character's own frame (+z forward, +y up, +x its left), whatever the
  // bone's local axis convention: local' = parentWorld^-1 * Q * parentWorld * local
  const _pq = new THREE.Quaternion(), _rq = new THREE.Quaternion(), _q = new THREE.Quaternion();
  const rotC = (name, ax, ang) => {
    const b = B[name]; if (!b || !ang) return;
    b.parent.getWorldQuaternion(_pq); model.getWorldQuaternion(_rq);
    _q.setFromAxisAngle(new THREE.Vector3(...ax).applyQuaternion(_rq), ang);
    b.quaternion.premultiply(_pq.clone().invert().multiply(_q).multiply(_pq)); b.updateMatrixWorld(true);
  };
  const X = [1, 0, 0], Z = [0, 0, 1];
  // three.js only rewrites a bone when its blended value changed since the last update, so a held clip time would
  // leave last frame's procedural rotation in place and the next rotC would stack on it. Snapshot the mixer-driven
  // rotations after every update and restore them before the next one: each pose is then a pure function of its inputs.
  const bones = Object.values(B), snap = bones.map(b => b.quaternion.clone());
  // a phone in the right hand, visible on request
  const phone = new THREE.Group(), body = new THREE.Mesh(new window.GL.RoundedBoxGeometry(.075, .15, .012, 3, .01), window.GL.MAT.cobaltGloss());
  const screen = new THREE.Mesh(new THREE.PlaneGeometry(.064, .136), new THREE.MeshBasicMaterial({ color: '#D8E4FF' })); screen.position.z = .007; phone.add(body, screen);
  if (hand) { hand.add(phone); const s = 1 / (hand.getWorldScale(new THREE.Vector3()).x || 1); phone.scale.setScalar(s); phone.position.set(0, .09 * s, .03 * s); phone.rotation.set(-1.3, 0, 0); }
  const mixer = new THREE.AnimationMixer(model), acts = {};
  for (const [k, c] of Object.entries(HERO.clips)) { const a = mixer.clipAction(c); a.play(); a.enabled = true; a.setEffectiveWeight(0); acts[k] = a; }
  const clipTime = (k, p) => {
    const c = HERO.clips[k]; if (!c) return 0;
    const raw = k in SPEED && (p.walk ?? 1) > 0 ? (p.u ?? 0) / SPEED[k] : (p.actT ?? (p.lt ?? 0) * (p.actSpeed ?? 1)) + (p.actOff ?? 0);
    return LOOP.has(k) ? ((raw % c.duration) + c.duration) % c.duration : Math.min(raw, c.duration - 1e-3);
  };
  // p: act (clip key) or legacy pose flags; blend: [[key, weight, {actT}], ...] overrides; phone: show the phone
  function pose(p = {}) {
    const q = p.pose || p;   // flat legacy flags ({ sit: 1, phone: 1 }) work too
    const act = p.act ?? (q.sit ? 'sit' : q.kneel ? 'kneel' : (p.walk ?? 1) <= .5 && (q.armsUp || q.point || q.lie) ? 'idle'
      : (p.walk ?? 1) > .5 ? (p.run ? 'run' : 'walk') : 'idle');   // the phone is a procedural arm pose on top
    const mixList = p.blend ?? [[q.lie ? 'idle' : act, 1, q.lie ? { actT: 0 } : {}]];
    model.rotation.set(q.lie ? -Math.PI / 2 : 0, 0, 0); model.position.set(0, q.lie ? .14 : 0, 0);
    bones.forEach((b, i) => b.quaternion.copy(snap[i]));
    for (const a of Object.values(acts)) a.setEffectiveWeight(0);
    for (const [k, w, o = {}] of mixList) { const a = acts[k] ?? acts.idle; if (!a) continue; a.setEffectiveWeight(w); a.time = clipTime(k, { ...p, ...o }); }
    mixer.update(0); root.updateMatrixWorld(true); bones.forEach((b, i) => snap[i].copy(b.quaternion));
    // procedural layer (weights 0..1): phone held up to the face, pointing, both arms up, arms spread
    const ph = p.phone ?? (q.phone ?? 0), pt = q.point ?? 0, up = q.armsUp ?? 0, spread = q.spread ?? (q.lie ? 1 : 0);
    rotC('RightArm', X, -.55 * ph - 2.4 * pt); rotC('RightArm', Z, -.25 * ph - .2 * pt); rotC('RightForeArm', X, -1.55 * ph); rotC('Head', X, .32 * ph - .35 * pt);
    rotC('LeftArm', Z, 2.55 * up + 1.2 * spread); rotC('RightArm', Z, -2.55 * up - 1.2 * spread); rotC('Head', X, -.3 * up);
    rotC('Spine02', X, (q.lean ?? 0));
    phone.visible = ph > .5;
  }
  pose({});
  return { root, pose, model, phone, isHero: true };
}

// instanced PBR props from a list [{x, y, z, s (metres tall), rot}]; regrow(fn) rescales like makePines
function makeProps(kind, list, o = {}) {
  const P = HERO.props[kind]; if (!P) return null;
  const mesh = new THREE.InstancedMesh(P.geo, P.mat, list.length), M = new THREE.Matrix4(), Q = new THREE.Quaternion(), E = new THREE.Euler(), V = new THREE.Vector3(), S = new THREE.Vector3();
  const regrow = (fn = () => 1) => { list.forEach((it, i) => { const k = Math.max(.001, fn(i, it)), w = it.s * (it.wide ?? o.wide ?? 1); Q.setFromEuler(E.set(it.tilt ?? 0, it.rot ?? i * 2.39, 0)); M.compose(V.set(it.x, it.y - (o.sink ?? .05) * it.s, it.z), Q, S.set(w * k, it.s * k, w * k)); mesh.setMatrixAt(i, M); }); mesh.instanceMatrix.needsUpdate = true; };
  regrow(); mesh.castShadow = true; mesh.receiveShadow = true; mesh.frustumCulled = false; mesh.userData.regrow = regrow; return mesh;
}
window.WORLD = Object.assign(window.WORLD || {}, { makeHero, makeProps });
