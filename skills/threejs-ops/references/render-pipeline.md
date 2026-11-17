# Render pipeline - a game-grade HDR post stack on plain WebGLRenderer

Make a three.js game look expensive without EffectComposer: one HDR world pass, a hand-run chain of fullscreen
triangles, and the adaptive quality and fallbacks that keep it alive on real hardware.
Source: the reference build in SKILL.md section 9. Costs are tap and pass
counts read from code, not measured. Not covered here: motion blur, lens dirt, streak, flare, planar mirrors.

## Contents

0. Why it looks expensive (ranked)
1. HDR target + fullscreen-triangle pass chain
2. Far-plane sky + PMREM ambient + interior probe
3. Fitted static shadow frustum + PCSS chunk patch
4. Shadow-mapped volumetric fog + analytic far haze
5. Tonemap (ACES/AgX blend) + grade
6. Half-res depth, lighting-aware SSAO, joint bilateral upsample
7. Bloom chain with partial Karis
8. GPU auto-exposure + sun visibility in a 1x1 ping-pong
9. Final pass: FXAA + sharpen + grain + dither
10. Viewmodel via `gl.depthRange`
11. Fixed point-light pool
12. Internal resolution, frame-time governor, GPU tier guess
13. Boot self-test, per-subsystem fallback, compileAsync warm-up

## 0. Why it looks expensive (ranked)

1. **One art-directed light**: low fixed sun (elev ~13 deg, (1,.72,.42), intensity 9); the sky is the only ambient.
2. **Contact-hardening shadows**: crisp at a container's foot, soft under a 30 m crane jib.
3. **Fog the shadow map cuts**, coloured by the sky's own horizon function, so distance matches the sky.
4. **Tonemap once, last, from linear HDR**, then a film grade (split tone, S-curve, lifted blacks).
5. **AO only where ambient dominates** (no dirty halos on sunlit pixels); restrained bloom; slow 0.6-2.0 adaptation.
6. **Noise, never banding**: every kernel rotated by interleaved gradient noise (IGN); grain + dither hide it.

## 1. HDR target + fullscreen-triangle pass chain

Cost: 1 scene render into RGBA16F (MSAA 0/2/4 by tier, on the target not the canvas; ~74 MB at 4x, 2.3 Mpx) plus
10-15 fullscreen passes. When: you need more than three's single output tonemap, or depth in post.
```js
const renderer = new THREE.WebGLRenderer({ canvas, antialias: false, powerPreference: 'high-performance' });
renderer.toneMapping = THREE.NoToneMapping;  // tonemap once, in the grade; info.reset() per frame for honest counts
renderer.autoClear = false; renderer.info.autoReset = false;
const hdr = new THREE.WebGLRenderTarget(1, 1, { type: THREE.HalfFloatType, samples: tier.msaa, stencilBuffer: false,
  depthTexture: new THREE.DepthTexture(1, 1, THREE.UnsignedIntType) }); // keep resolveDepthBuffer true: post reads it
const tri = new THREE.BufferGeometry().setAttribute('position',          // one triangle: no diagonal seam
  new THREE.Float32BufferAttribute([-1, -1, 0, 3, -1, 0, -1, 3, 0], 3));
const passMesh = new THREE.Mesh(tri), passCam = new THREE.OrthographicCamera(); passMesh.frustumCulled = false;
const VS = 'out vec2 vUv; void main(){ vUv = position.xy * 0.5 + 0.5; gl_Position = vec4(position.xy, 0.0, 1.0); }';
const makePass = (fragmentShader, uniforms) => new THREE.ShaderMaterial({ glslVersion: THREE.GLSL3, vertexShader: VS,
  fragmentShader, uniforms, depthTest: false, depthWrite: false, blending: THREE.NoBlending, toneMapped: false });
function run(mat, rt) { passMesh.material = mat; renderer.setRenderTarget(rt); renderer.render(passMesh, passCam); }
// a raw ShaderMaterial gets no colorspace_fragment: encode sRGB by hand exactly once, in the grade pass
```

## 2. Far-plane sky + PMREM ambient + interior probe

Cost: ~15 noise fetches per visible sky pixel; PMREM bake once; probe = 6 renders at 128 px once.
When: procedural sky with a `DirectionalLight` as the sun. No `HemisphereLight` or `AmbientLight` at all.
```js
// sky: BoxGeometry(2,2,2), BackSide, depthWrite false, renderOrder -1000, frustumCulled false; vertex shader
// vDir = position; gl_Position = (projectionMatrix * vec4(mat3(viewMatrix) * position, 1.0)).xyww; (far plane)
function bakeSkyEnv(renderer, sky) {          // uEnv = 1: no sun disk, radiance clamped to 6, ground grey 0.06
  const mat = sky.material.clone(); mat.uniforms.uEnv.value = 1;
  mat.uniforms.tNoise.value = sky.material.uniforms.tNoise.value;  // clone() copies textures: share instead
  const s = new THREE.Scene(), m = new THREE.Mesh(sky.geometry, mat); m.frustumCulled = false; s.add(m);
  const pmrem = new THREE.PMREMGenerator(renderer), rt = pmrem.fromScene(s, 0, 0.1, 100);
  mat.dispose(); pmrem.dispose(); return rt;  // scene.environment = rt.texture; environmentIntensity = 2
}
```

No disk in the capture: the sun is not lit twice, PMREM gets no fireflies. Interior probe: HalfFloat 128 px
`CubeCamera` at room centre (y = `min.y + min(2.4, 0.4 * height)`), sky in env mode, `pmrem.fromCubemap()`, as
`envMap` on `userData.interior` materials. Gotcha: `.xyww` breaks under `logarithmicDepthBuffer`/reversed depth.

## 3. Fitted static shadow frustum + PCSS chunk patch

Cost: 8 blocker + 16 filter taps (10 on low) per lit fragment, per overdraw layer: the costliest material
term. Map 2048 (low/med) or 4096, updated every other frame. When: bounded level, fixed sun, no cascades.
```js
const R182 = parseInt(THREE.REVISION, 10) >= 182;   // r182: PCF maps became hardware-compare sampler2DShadow
renderer.shadowMap.type = R182 ? THREE.BasicShadowMap : THREE.PCFShadowMap;   // r182+: only BASIC keeps raw depth
renderer.shadowMap.autoUpdate = false;              // needsUpdate on (frame & 1) === 0
// fit once: light 200 m along sunDir from receiver AABB centre; ortho bounds = its 8 corners in light space (+1 m);
// near extended by a caster AABB (cranes outside play); bake frustum w/h/depth in metres as PCSS defines
const stock = THREE.ShaderChunk.shadowmap_pars_fragment;
const a = stock.indexOf(R182 ? '#else // SHADOWMAP_TYPE_BASIC' : 'float getShadow(');
const b = stock.indexOf(R182 ? '#if NUM_POINT_LIGHT_SHADOWS > 0' : 'vec2 cubeToUV', a);   // search AFTER a
if (a < 0 || b < 0) throw new Error('shadowmap chunk changed');   // never splice at -1: take the section 13 fallback
THREE.ShaderChunk.shadowmap_pars_fragment =
  stock.slice(0, a) + (R182 ? `#else\n${PCSS_GETSHADOW}\n#endif\n` : PCSS_GETSHADOW) + stock.slice(b);
```

Kernel (shadow `bias -1.2e-4`, `normalBias 0.02`, `radius 1` reused as light size `r`):
- IGN `fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))))`; Vogel tap i of n at radius
  `sqrt((i + 0.5) / n)`, angle `i * 2.39996323 + ign(gl_FragCoord.xy) * 2pi`.
- Receiver-plane bias: d(depth)/d(uv) from `dFdx/dFdy` of the shadow coord, clamped to `0.003 / texel`; subtract
  `0.35 * (|dz.x| texel.x + |dz.y| texel.y)`, test each tap against `zr + dot(offset, dz)`. No acne on big floors.
- Search radius `0.55 r / frustumMetres`; penumbra `clamp(dist_m * 0.022 r, 0.012 r, 0.6 r)`; filter radius
  `max(pen / frustumMetres, 1.25 texel)`. Fade to lit over the map's last 2% (`smoothstep(0, 0.02, edge)`).
- Gotchas: patch **before the first compile** (built programs keep the stock chunk); keep the `getShadow`
  signature (`sampler2D shadowMap, shadowMapSize, shadowIntensity, shadowBias, shadowRadius, shadowCoord`, same in
  r180 and r182+) but read depth the version's way: `unpackRGBAToDepth(texture2D(...))` before r182, raw `.r` from
  r182. On r182+ define your own IGN/Vogel helpers (three's exist only under `SHADOWMAP_TYPE_PCF`) and flip each
  compare under `USE_REVERSED_DEPTH_BUFFER`. Keep `stock` for fallback. Per-material `onBeforeCompile` instead?
  Give it a `customProgramCacheKey()`.

## 4. Shadow-mapped volumetric fog + analytic far haze

Cost: half-res, `VOL_STEPS` 10/12/16/24/40 shadow fetches + 7-tap bilateral blur x2; heaviest post on ultra.
When: the scene's only fog, and you want doorways and stacks to cut real beams. Share one `horizonColor(dir)`
GLSL string between sky and fog: that is what melts far geometry into the sky.
```glsl
float shape(float h) { return 0.30 + 0.70 * exp(-h / 5.5); }        // sigma = 0.0034 per metre
float ph = min(hg(mu, 0.78) * 0.55 + hg(mu, 0.25) * 0.45, 1.15);    // two-lobe Henyey-Greenstein
// step i of N: f = (i + 1) / N, t = maxD * f * (0.35 + 0.65 * f), IGN jitter; maxD 170 m (sky pixels 0.55 maxD)
// src = sunRad * ph * shadow * nearW + amb * (0.4 + 0.6 * shadow); nearW 2.3 within 4 m -> 0.55 at 85 m
// past maxD: tau = sigma * farHaze * len * 0.5 * (shape(h1) + shape(h2)); add horizonColor(rd) * 0.5 + amb * 0.6
// sunRad = sun.color * sun.intensity * 0.85; amb = (0.42,0.47,0.52) * 0.2; out (inscatter, T): col * T + inscatter
```

## 5. Tonemap (ACES/AgX blend) + grade

Cost: ALU only, in the grade pass. When: always. Order: bloom -> exposure -> tonemap -> grade -> vignette -> sRGB.
ACES alone burns oranges; the 25% AgX pull rolls highlights off to white.
```glsl
c = mix(acesHill(c * ex * 1.3), agxPunchy(c * ex), 0.25);        // ex = exposure(); AgX look: power 1.18, sat 1.22
float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
c *= mix(vec3(0.80, 1.01, 1.13), vec3(1.07, 1.00, 0.90), smoothstep(0.03, 0.55, l)); // teal lows, warm highs
c = mix(c, c * c * (3.0 - 2.0 * c), 0.22) * 0.988 + vec3(0.006, 0.0085, 0.011);       // S-curve, teal blacks
// vignette 0.3 on a corner-normalised radius; radial CA 0.0013 * r^2 at the start of the pass
fragColor = vec4(srgb, dot(srgb, vec3(0.299, 0.587, 0.114)));  // luma in alpha: free FXAA input, RGBA8 target
```

## 6. Half-res depth, lighting-aware SSAO, joint bilateral upsample

Cost: AO 8/12/16 taps at quarter pixel count, blur 7 taps x2, upsample 4 x 3 fetches full-res. When: medium+.
- Depth: `texelFetch(tDepth, ivec2(gl_FragCoord.xy) * 2, 0)` (never average), as metres in R32F (gotcha:
  needs `renderer.extensions.has('EXT_color_buffer_float')`, else RGBA16F).
- AO: normal from depth, per axis taking the neighbour with the smaller delta (no halos); IGN-rotated spiral
  of N taps over 3 turns; falloff `(R^2 - v.v)^3`; `R = 0.9 m * (0.6 + 0.4 clamp(z / 12))`; fade 70-140 m.
- Blur: 7-tap separable, `(1 - 0.22|i|) * max(0, 1 - |z - zc| / (0.04 zc + 0.02))`. Upsample (AO and fog):
  4 half-res taps, bilinear weight `* 1 / (0.015 + |zh - z| / z)`, so nothing bleeds across silhouettes.
- Composite: `ao = mix(1, ao, 0.95 * (1 - 0.8 * smoothstep(0.16, 0.85, luma * exposure)))`, faint cool tint
  `mix(vec3(ao), vec3(1), vec3(0, 0.03, 0.07))`. Post cannot isolate ambient, so pull AO off lit pixels.

## 7. Bloom chain with partial Karis

Cost: 6 x 13-tap downsamples + 5 x 9-tap tent upsamples from half-res: cheap. When: always; it sells HDR.
Level 0 clamps input to 400 and weights its 13-tap groups by partial Karis `1 / (1 + 0.08 luma)` (full Karis kills
the sun). Upsample `mix(down[i], tent(up[i + 1]), 0.62)`. Apply before exposure as `mix(col, bloom, 0.065)`, not add.

## 8. GPU auto-exposure + sun visibility in a 1x1 ping-pong

Cost: 35 + 12 fetches into one pixel; no `readPixels` stall. When: indoor/outdoor play. Two 1x1 HalfFloat targets,
read one, write the other, swap. R = centre-weighted log-average luma of a 7x5 grid on the smallest bloom mip,
`rate = 1 - exp(-dt / 1.5)`; G = sun visibility, 12 Vogel depth taps round the projected sun (`depth >= 0.99999`
is sky), tau 0.12 s. Snap on the first two frames and teleports; guard NaN. Exposure everywhere:
`manual * mix(1, clamp(pow(0.12 / R, 0.85), 0.6, 2.0), auto)`; the narrow clamp keeps interiors dark.

## 9. Final pass: FXAA + sharpen + grain + dither

Cost: 5 fetches (+4 on edges) per canvas pixel. When: always; it draws `ldr` to the full-DPR canvas, so it is also
the upscaler. FXAA 3.11 console (luma from alpha); unsharp 0.3 on the same taps, gated `1 - smoothstep(0.04, 0.22,
contrast)`; animated triangular grain 0.02 kept off highlights and black; TPDF dither +-1/255 last (sky banding).

## 10. Viewmodel via `gl.depthRange`

Cost: one GL call. When: first-person weapons or hands that must never clip and must skip post effects.
Gotchas: every depth consumer treats `depth < 0.05` as viewmodel and skips AO, fog, motion blur and the sun test;
take depth copies first. Own key light on layer 1 ((0.78,0.86,1.0), 0.9); interior env swapped in indoors.
```js
renderer.render(scene, camera); const gl = renderer.getContext(); // world into hdr, layer 0
gl.depthRange(0, 0.05);                         // gun depths land in [0, 0.05]: always win, no clearDepth
try { renderer.render(scene, viewCam); }        // FOV 54, near 0.01, far 10, layer 1, matrixWorld from camera
finally { gl.depthRange(0, 1); }                // three's state cache never restores this for you
```

## 11. Fixed point-light pool

Cost: N lights shaded per lit fragment even at intensity 0. When: muzzle flashes, explosions. Create 6
`PointLight(0xffffff, 0, 12, 2)` at boot, never add or remove: light count is in the program key, so a change
recompiles every lit material mid-fight. `flash(pos, color, 30, 10, 0.06)` takes a free light or steals the one
with least `ttl` left, decaying linearly; `acquire()` lends one for good.

## 12. Internal resolution, frame-time governor, GPU tier guess

When: any shipped game. Canvas `css * min(dpr, 2)`; targets that `* tierScale * dynScale`, then `* sqrt(budget / px)`.

| Tier | Scale | MSAA | Shadow | Vol steps | AO taps | Budget |
|---|---|---|---|---|---|---|
| low | 0.7 | 0 | 2048 | 12 | off | 1.0 Mpx |
| medium | 0.85 | 2 | 2048 | 16 | 12 | 1.5 Mpx |
| high | 1.0 | 4 | 4096 | 24 | 12 | 2.3 Mpx |
| ultra | 1.0 | 4 | 4096 | 40 | 16 | 3.7 Mpx |

Governor: mean ms over 45 frames or 900 ms; skip gaps > 1.5 s; settle 3.5 s after loads, 1 s after each change.
Above 21.5 ms drop 0.1 (0.2 above 30, straight to 0.6 above 45) and double the up-delay (max 60 s); below 17.4 ms
step up 0.1 once it expires, resetting it to 4 s when stable at 1.0. Two windows at the 0.6 floor above 26 ms drop
a tier and restart at 0.8. Tier guess: mobile -> low; `WEBGL_debug_renderer_info` (else `gl.RENDERER`) matching
SwiftShader/llvmpipe/Software/Mali/Adreno/PowerVR, or non-Arc Intel -> medium; else high; ultra opt-in only.

## 13. Boot self-test, per-subsystem fallback, compileAsync warm-up

When: always; WebGL driver bugs are per-machine and will not show up in your own testing.
- Tag each custom shader with a marker comment (`// GAME_POST bloom`, `// GAME_SHADOW`); in
  `renderer.debug.onShaderError = (gl, prog, vs, fs) => ...` read `gl.getShaderSource(fs)` and route by marker.
- Render one full-pipeline frame with a test cube at boot. PCSS fails: restore `stock`, use `PCFSoftShadowMap`
  radius 2, or `PCFShadowMap` from r182 (Soft is deprecated there and falls back to PCF, whose stock filter is
  already a 5-tap Vogel disk). The type change alters the program key, forcing rebuilds. Post fails or anything throws later: draw
  to the canvas with `ACESFilmicToneMapping`, exposure x0.6, viewmodel after `clearDepth()`.
- Level ready: shadow update, probe capture, `await renderer.compileAsync(scene, camera)` with **`hdr` bound** (its
  output colour space differs from the canvas: warm the canvas and the first frame still hitches); viewmodel too.
