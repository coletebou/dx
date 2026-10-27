// post.js - the film look for every set: GTAO ambient occlusion, bloom, depth of field focused on the hiker,
// then tone mapping (OutputPass) and a gentle grade (saturation, contrast, cool lift, warm gain, vignette).
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { GTAOPass } from 'three/addons/postprocessing/GTAOPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { BokehPass } from 'three/addons/postprocessing/BokehPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';
const { THREE, R } = window.GL;

const GradeShader = {
  uniforms: { tDiffuse: { value: null }, uSat: { value: 1.08 }, uCon: { value: 1.06 }, uLift: { value: new THREE.Color('#0B1440') }, uGain: { value: new THREE.Color('#FFF9F0') }, uVig: { value: .28 } },
  vertexShader: 'varying vec2 vUv; void main(){ vUv = uv; gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.); }',
  fragmentShader: `uniform sampler2D tDiffuse; uniform float uSat, uCon, uVig; uniform vec3 uLift, uGain; varying vec2 vUv;
    void main(){ vec3 c = texture2D(tDiffuse, vUv).rgb;
      float l = dot(c, vec3(.2126, .7152, .0722)); c = mix(vec3(l), c, uSat);
      c = (c - .5) * uCon + .5; c = c * uGain + uLift * (1. - c) * .1;
      vec2 d = vUv - .5; c *= 1. - uVig * smoothstep(.35, .95, length(d * vec2(1.25, 1.)));
      gl_FragColor = vec4(clamp(c, 0., 1.), 1.); }`,
};

// o: ao (0..1.5), aoRadius, bloom, bloomThreshold, aperture, maxblur, sat, con, vig
function makePost(scene, camera, o = {}) {
  // GTAO builds its noise textures with Math.random(); seed it while the passes are built so every render worker
  // (and every re-render) gets identical noise and frames stay byte-identical.
  const rnd = Math.random; let seed = o.seed ?? 1234567;
  Math.random = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 2 ** 32; };
  try { return build(scene, camera, o); } finally { Math.random = rnd; }
}
function build(scene, camera, o) {
  const comp = new EffectComposer(R); comp.setPixelRatio(1); comp.setSize(1920, 1080);
  comp.addPass(new RenderPass(scene, camera));
  const ao = new GTAOPass(scene, camera, 1920, 1080); ao.blendIntensity = o.ao ?? .6;
  ao.updateGtaoMaterial({ radius: o.aoRadius ?? .8, distanceExponent: 1.4, thickness: 1.2, scale: 1, samples: 16 });
  ao.updatePdMaterial({ lumaPhi: 10, depthPhi: 2, normalPhi: 3, radius: 6, rings: 2, samples: 16 });
  comp.addPass(ao);
  const bloom = new UnrealBloomPass(new THREE.Vector2(1920, 1080), o.bloom ?? .22, .5, o.bloomThreshold ?? .97); comp.addPass(bloom);
  const dof = new BokehPass(scene, camera, { focus: 6, aperture: o.aperture ?? .00005, maxblur: o.maxblur ?? .0025 }); comp.addPass(dof);
  comp.addPass(new OutputPass());
  const grade = new ShaderPass(GradeShader); grade.uniforms.uSat.value = o.sat ?? 1.14; grade.uniforms.uCon.value = o.con ?? 1.08; grade.uniforms.uVig.value = o.vig ?? .28; comp.addPass(grade);
  return { comp, ao, bloom, dof, grade, render(focus = 8) { dof.uniforms.focus.value = focus; dof.enabled = (o.aperture ?? 1) > 0; comp.render(); } };
}
window.WORLD = Object.assign(window.WORLD || {}, { makePost });
