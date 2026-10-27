// gl3d.js - WebGL layer (three.js): procedural environment, materials, instanced grass, and a scene registry.
// Every 3D picture in v2 is built here from geometry + code-generated textures. No images are loaded.
import * as THREE from 'three';
import { RoundedBoxGeometry } from 'three/addons/geometries/RoundedBoxGeometry.js';
window.THREE = THREE;

const glc = document.createElement('canvas'); glc.width = 1920; glc.height = 1080;
const R = new THREE.WebGLRenderer({ canvas: glc, antialias: true, preserveDrawingBuffer: true, alpha: false, powerPreference: 'high-performance' });
R.setPixelRatio(1); R.setSize(1920, 1080, false);
R.outputColorSpace = THREE.SRGBColorSpace; R.toneMapping = THREE.ACESFilmicToneMapping; R.toneMappingExposure = 1.0;
R.shadowMap.enabled = true; R.shadowMap.type = THREE.PCFShadowMap;
const COL = { cobalt: '#1D3FE6', cobalt2: '#3A64FF', deep: '#0B1F9C', sky: '#8FD0FF', grass: '#2F9A4B', grassDk: '#0F5A2C', lime: '#C9F54B', concrete: '#CFCCC5', white: '#F7F8FB' };

// ---------- deterministic noise for textures ----------
function rng(seed) { return () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 2 ** 32; }; }
function canvasTex(w, h, paint, { repeat = [1, 1], srgb = true } = {}) {
  const c = document.createElement('canvas'); c.width = w; c.height = h; paint(c.getContext('2d'), w, h);
  const t = new THREE.CanvasTexture(c); t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(...repeat);
  if (srgb) t.colorSpace = THREE.SRGBColorSpace; t.anisotropy = 8; return t;
}
// board-formed concrete: mottled grey, pits, faint formwork seams
const concreteTex = (seed = 3, rep = [2, 2]) => canvasTex(1024, 1024, (g, w, h) => {
  const r = rng(seed); g.fillStyle = '#C8C5BE'; g.fillRect(0, 0, w, h);
  for (let i = 0; i < 260; i++) { const x = r() * w, y = r() * h, rad = 20 + r() * 140, gr = g.createRadialGradient(x, y, 0, x, y, rad), v = r() < .5 ? '120,116,108' : '236,233,226'; gr.addColorStop(0, `rgba(${v},${.06 + r() * .1})`); gr.addColorStop(1, `rgba(${v},0)`); g.fillStyle = gr; g.fillRect(x - rad, y - rad, rad * 2, rad * 2); }
  for (let i = 0; i < 9000; i++) { g.fillStyle = `rgba(70,66,60,${r() * .35})`; const s = r() * 2.4; g.fillRect(r() * w, r() * h, s, s); }
  g.strokeStyle = 'rgba(90,86,80,.18)'; g.lineWidth = 2; for (let y = 0; y < h; y += 128) { g.beginPath(); g.moveTo(0, y + r() * 2); g.lineTo(w, y + r() * 2); g.stroke(); }
}, { repeat: rep });
const MAT = {
  chrome: () => new THREE.MeshStandardMaterial({ color: '#ffffff', metalness: 1, roughness: .05 }),
  chromeSoft: () => new THREE.MeshStandardMaterial({ color: '#E8EDF7', metalness: 1, roughness: .18 }),
  cobalt: () => new THREE.MeshStandardMaterial({ color: COL.cobalt, metalness: .15, roughness: .32 }),
  cobaltGloss: () => new THREE.MeshPhysicalMaterial({ color: COL.cobalt, metalness: .3, roughness: .12, clearcoat: 1, clearcoatRoughness: .05 }),
  white: () => new THREE.MeshPhysicalMaterial({ color: COL.white, roughness: .28, clearcoat: .6, clearcoatRoughness: .2 }),
  concrete: (seed, rep) => new THREE.MeshStandardMaterial({ map: concreteTex(seed, rep), roughness: .92, metalness: 0 }),
  ground: () => new THREE.MeshStandardMaterial({ color: '#2B7F3E', roughness: 1 }),
};

// ---------- sky dome: cobalt zenith, pale horizon, sun, drifting fbm clouds (all in the shader) ----------
function makeSky(o = {}) {
  const u = {
    uTime: { value: 0 }, uTop: { value: new THREE.Color(o.top ?? '#0A26C8') }, uHor: { value: new THREE.Color(o.horizon ?? '#8FD0FF') },
    uSunDir: { value: new THREE.Vector3(...(o.sun ?? [0.4, 0.55, -0.7])).normalize() }, uCloud: { value: o.clouds ?? .55 }, uGround: { value: new THREE.Color(o.ground ?? '#2E7A3C') },
  };
  const mat = new THREE.ShaderMaterial({
    uniforms: u, side: THREE.BackSide, depthWrite: false,
    vertexShader: `varying vec3 vDir; void main(){ vDir = normalize(position); vec4 p = projectionMatrix * modelViewMatrix * vec4(position,1.); gl_Position = p.xyww; }`,
    fragmentShader: `
      varying vec3 vDir; uniform float uTime, uCloud; uniform vec3 uTop, uHor, uSunDir, uGround;
      float h(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7))) * 43758.5453); }
      float n(vec2 p){ vec2 i = floor(p), f = fract(p); f = f*f*(3.-2.*f); return mix(mix(h(i), h(i+vec2(1,0)), f.x), mix(h(i+vec2(0,1)), h(i+vec2(1,1)), f.x), f.y); }
      float fbm(vec2 p){ float a = .5, s = 0.; for (int i = 0; i < 6; i++){ s += a * n(p); p = p * 2.03 + 17.1; a *= .5; } return s; }
      void main(){
        vec3 d = normalize(vDir); float y = d.y;
        vec3 col = mix(uHor, uTop, pow(clamp(y, 0., 1.), .38));
        float sun = max(dot(d, uSunDir), 0.); col += vec3(1., .98, .9) * (pow(sun, 900.) * 4. + pow(sun, 12.) * .25);
        if (y > .02) {
          vec2 uv = d.xz / (y + .12) * 1.4 + vec2(uTime * .035, uTime * .01);
          float c = fbm(uv * .8); c = smoothstep(.56 - uCloud * .22, .72, c) * smoothstep(.03, .2, y);
          float shade = fbm(uv * .8 + vec2(.05, .09)); vec3 cc = mix(vec3(1.), vec3(.72, .8, .96), smoothstep(.5, .78, shade) * .75);
          col = mix(col, cc, c * .92);
        } else col = mix(uHor * .9, uGround, smoothstep(0., -.08, y));
        gl_FragColor = vec4(col, 1.);
        #include <colorspace_fragment>
      }`,
  });
  const m = new THREE.Mesh(new THREE.SphereGeometry(500, 48, 24), mat); m.frustumCulled = false; m.renderOrder = -1;
  m.userData.u = u; return m;
}
// environment map for chrome reflections, rendered from a sky + ground scene
const pmrem = new THREE.PMREMGenerator(R);
function envFrom(skyOpts = {}) {
  const s = new THREE.Scene(); const sky = makeSky({ ...skyOpts, clouds: skyOpts.clouds ?? .5 }); sky.scale.setScalar(.2); s.add(sky);
  const g = new THREE.Mesh(new THREE.CircleGeometry(60, 48), new THREE.MeshBasicMaterial({ color: skyOpts.ground ?? '#2E7A3C' })); g.rotation.x = -Math.PI / 2; g.position.y = -2; s.add(g);
  [[-20, 2, -30, 30, 8, 3, '#BDB9B1'], [24, 3, -18, 4, 10, 16, '#C9C6BF'], [8, 1, 26, 18, 4, 3, '#1D3FE6'], [-26, 1.5, 14, 3, 5, 12, '#F4F5F8']].forEach(([x, y, z, w, h, d, col]) => {
    const c = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), new THREE.MeshBasicMaterial({ color: col })); c.position.set(x, y, z); s.add(c); });
  return pmrem.fromScene(s, .02).texture;
}

// ---------- instanced grass with wind, press and reach in the vertex shader ----------
function bladeGeometry(w = .06, hgt = 1) {
  const g = new THREE.PlaneGeometry(w, hgt, 1, 5); g.translate(0, hgt / 2, 0);
  const p = g.attributes.position, aH = new Float32Array(p.count);
  for (let i = 0; i < p.count; i++) { const v = p.getY(i) / hgt; aH[i] = v; p.setX(i, p.getX(i) * (1 - Math.pow(v, 1.4))); p.setZ(i, Math.pow(v, 2) * .12); }
  g.setAttribute('aH', new THREE.BufferAttribute(aH, 1)); g.computeVertexNormals(); return g;
}
function grassMaterial() {
  const m = new THREE.MeshStandardMaterial({ color: '#ffffff', roughness: .75, side: THREE.DoubleSide });
  const u = { uTime: { value: 0 }, uWind: { value: .22 }, uPress: { value: new THREE.Vector4(0, 0, 0, 1) }, uReach: { value: new THREE.Vector4(0, 0, 0, 0) }, uReachR: { value: 2 } };
  m.onBeforeCompile = s => {
    Object.assign(s.uniforms, u);
    s.vertexShader = 'attribute float aH; varying float vH; uniform float uTime, uWind, uReachR; uniform vec4 uPress, uReach;\n' + s.vertexShader
      .replace('#include <project_vertex>', `
        vH = aH;
        vec4 wpos = modelMatrix * instanceMatrix * vec4(transformed, 1.0);
        vec3 ip = (modelMatrix * instanceMatrix * vec4(0., 0., 0., 1.)).xyz;
        float w = sin(uTime * 1.6 + ip.x * .35 + ip.z * .23) * .6 + sin(uTime * 2.7 + ip.x * .9 - ip.z * .4) * .25;
        wpos.x += w * uWind * aH * aH; wpos.z += w * uWind * .4 * aH * aH;
        vec2 d = ip.xz - uPress.xy; float dd = length(d); float k = uPress.z * exp(-dd * dd / (uPress.w * uPress.w));
        wpos.xz += (dd > 1e-4 ? d / dd : vec2(0.)) * k * .55 * aH; wpos.y = mix(wpos.y, ip.y + (wpos.y - ip.y) * .35, k);
        vec3 toR = uReach.xyz - ip; float kr = uReach.w * exp(-dot(toR.xz, toR.xz) / (uReachR * uReachR));
        wpos.xyz += toR * kr * aH * aH * .45;
        vec4 mvPosition = viewMatrix * wpos; gl_Position = projectionMatrix * mvPosition;`);
    s.fragmentShader = 'varying float vH;\n' + s.fragmentShader.replace('#include <color_fragment>', '#include <color_fragment>\n diffuseColor.rgb *= mix(.38, 1.18, vH);');
  };
  m.userData.u = u; return m;
}
const GREENS = ['#0F5A2C', '#156B33', '#1F8440', '#2F9A4B', '#46B055', '#6CC35C', '#8FD35A', '#B5E65A'].map(c => new THREE.Color(c));
// field of n blades scattered in a rect (x0..x1, z0..z1) or placed by a custom placer(i, r) -> {pos, normal}
function makeGrass(n, o = {}) {
  const geo = bladeGeometry(o.w ?? .045, 1), mat = grassMaterial(), mesh = new THREE.InstancedMesh(geo, mat, n), r = rng(o.seed ?? 7);
  const M = new THREE.Matrix4(), Q = new THREE.Quaternion(), S = new THREE.Vector3(), P = new THREE.Vector3(), up = new THREE.Vector3(0, 1, 0), E = new THREE.Euler();
  for (let i = 0; i < n; i++) {
    let pos, nrm = up;
    if (o.placer) ({ pos, normal: nrm = up } = o.placer(i, r));
    else for (let tries = 0; tries < 12; tries++) {
      pos = new THREE.Vector3((o.x0 ?? -10) + r() * ((o.x1 ?? 10) - (o.x0 ?? -10)), o.y ?? 0, (o.z0 ?? -10) + r() * ((o.z1 ?? 10) - (o.z0 ?? -10)));
      if (!(o.clear ?? []).some(([cx, cz, rx, rz = rx]) => ((pos.x - cx) / rx) ** 2 + ((pos.z - cz) / rz) ** 2 < 1)) break;
    }
    const hgt = (o.h ?? .5) * (.55 + r() * .9);
    Q.setFromUnitVectors(up, nrm); const q2 = new THREE.Quaternion().setFromEuler(E.set((r() - .5) * .35, r() * Math.PI * 2, (r() - .5) * .35)); Q.multiply(q2);
    M.compose(P.copy(pos), Q, S.set(1 + r() * .6, hgt, 1)); mesh.setMatrixAt(i, M);
    mesh.setColorAt(i, GREENS[Math.min(7, Math.floor(r() * r() * 5 + r() * 4))]);
  }
  mesh.instanceMatrix.needsUpdate = true; mesh.frustumCulled = false; mesh.userData.u = mat.userData.u; return mesh;
}

// ---------- scene registry ----------
// GL.def(name, build) where build() returns { scene, camera, update(t, lt, p) }. Built lazily once per page.
// GL.draw(name, t, lt, p) updates, renders, and composites the WebGL frame into the 2D canvas.
const SCN = {};
function def(name, build) { SCN[name] = { build, inst: null }; }
// rect {x, y, w, h}: composite a centered crop of the frame into a sub-rectangle (phone viewfinders, polaroids)
function draw(name, t, lt = 0, p = {}, rect = null) {
  const s = SCN[name]; if (!s) throw new Error('no 3D scene ' + name);
  if (!s.inst) s.inst = s.build();
  const { scene, camera, update } = s.inst;
  scene.traverse(o => { if (o.userData.u?.uTime) o.userData.u.uTime.value = t; });
  update?.(t, lt, p);
  const wire = p.wire ? (window._wireMat ??= new THREE.MeshBasicMaterial({ color: '#C9F54B', wireframe: true })) : null;
  if (wire) { scene.overrideMaterial = wire; scene.background = new THREE.Color('#0B1F9C'); scene.traverse(o => { if (o.material?.type === 'ShaderMaterial') o.visible = false; }); }
  if (s.inst.render) s.inst.render(); else R.render(scene, camera);
  if (wire) { scene.overrideMaterial = null; scene.background = null; scene.traverse(o => { if (o.material?.type === 'ShaderMaterial') o.visible = true; }); }
  if (!rect) ctx.drawImage(glc, 0, 0, W, H);
  else { const ar = rect.w / rect.h, sw = Math.min(W, H * ar), sh = sw / ar; ctx.drawImage(glc, (W - sw) / 2, (H - sh) / 2, sw, sh, rect.x, rect.y, rect.w, rect.h); }
  return s.inst;
}
const lights = (scene, o = {}) => {
  const hemi = new THREE.HemisphereLight(o.sky ?? '#CFE6FF', o.ground ?? '#3E8A45', o.hemi ?? 1.25); scene.add(hemi);
  const sun = new THREE.DirectionalLight('#FFFFFF', o.sun ?? 2.6); sun.position.set(...(o.sunPos ?? [8, 12, 6]));
  if (o.shadow !== false) { sun.castShadow = true; sun.shadow.mapSize.set(2048, 2048); const c = sun.shadow.camera; c.left = c.bottom = -(o.shadowSize ?? 12); c.right = c.top = o.shadowSize ?? 12; c.far = 60; sun.shadow.bias = -.0004; }
  scene.add(sun); return { hemi, sun };
};
// world point -> screen px for a built scene (call after draw so its camera is current)
function project(name, x, y, z) { const c = SCN[name].inst.camera, v = new THREE.Vector3(x, y, z).project(c); return [(v.x + 1) / 2 * W, (1 - v.y) / 2 * H, v.z]; }
// screen px -> point on the plane y = py (for placing the pointer hand onto the grass)
function unproject(name, sx, sy, py = 0) {
  const c = SCN[name].inst.camera, o = c.position.clone(), d = new THREE.Vector3(sx / W * 2 - 1, 1 - sy / H * 2, .5).unproject(c).sub(o).normalize();
  const k = (py - o.y) / d.y; return o.add(d.multiplyScalar(k));
}
const cam = (fov = 40) => new THREE.PerspectiveCamera(fov, 16 / 9, .05, 1200);
const fog = (scene, near = 22, far = 95, col = '#9ED6FF') => { scene.fog = new THREE.Fog(col, near, far); };
window.GL = { THREE, R, def, draw, project, unproject, MAT, COL, canvasTex, rng, makeSky, makeGrass, envFrom, lights, cam, fog, RoundedBoxGeometry, concreteTex, bladeGeometry, grassMaterial };
window.dispatchEvent(new Event('gl-ready'));
