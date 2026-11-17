# Procedural world - a dense, believable game world from code on ~100-150 draw calls

Build props, sea, weather and ambient life in JS and GLSL with no downloaded assets, and hold the
frame near 100-150 draw calls by merging per material rather than instancing. Source: the
reference build in SKILL.md section 9. InstancedMesh basics, the
`LOD` object and culling: [scale-and-disposal.md](scale-and-disposal.md); boids: [actors-and-steering.md](actors-and-steering.md).

## Contents

1. Budget first - fill this table before building
2. Material-bucket builder with a matrix stack, plus a weathering bake
3. Template cache with a placeholder-material swap
4. Profile sweep and parametric surfaces
5. Authored LOD, hidden faces, one-draw skyline
6. Layout and seeded RNG
7. Analytic sea (no FFT, no planar reflection)
8. Shader life: flocks and lamps
9. Rain and splashes
10. CPU struct-of-arrays particles into instanced quads
11. AABB world without a physics engine
12. Showcase harness

## 1. Budget first - fill this table before building

| Group | Draws | Lever |
|---|---|---|
| Static level | 40-70 | one mesh per (material, cast, receive); ~35 base materials |
| Dynamic props (movers, explosives, `noMerge`) | 10-30 | own per-material meshes |
| Each hero backdrop asset (crane, ship, boat) | ~7-10 | per-material builder; decals are one more material |
| Skyline incl. mid and far LODs / all lamps / all birds | **1 / 1 / 1** | one vertex-coloured material; shader attributes |
| Ground, sea, quay skirt / rain, splashes / FX pools / sky | 3 / 2 / ~5 / 1 | |
| **Total main pass** | **~100-150** | plus shadow passes over casters only |

Gotcha: a level merged by material spans the map, so frustum culling stops helping; the budget
assumes every draw runs every frame. Give the skyline, lamps, sea, rain and FX `castShadow = false`.

## 2. Material-bucket builder with a matrix stack, plus a weathering bake

When: any prop or structure built from many primitives. Cost: build time only; one draw per material.
```js
import { mergeGeometries } from 'three/addons/utils/BufferGeometryUtils.js';
class Builder {
  stack = [new THREE.Matrix4()]; buckets = new Map(); remap = null; minSize = 0; get top() { return this.stack.at(-1); }
  push(m) { this.stack.push(this.top.clone().multiply(m)); } pop() { this.stack.pop(); }   // m from compose()
  add(mat, geo, { tint = new THREE.Color(1, 1, 1), cast = true } = {}) {
    geo.applyMatrix4(this.top);                         // world space: size test and noise see scale
    if (this.remap) {                                   // authored-LOD mode, section 5
      const r = this.remap(mat, tint); if (!r) return; [mat, tint] = r;
      geo.computeBoundingBox(); const s = geo.boundingBox.getSize(new THREE.Vector3());
      if (Math.max(s.x, s.y, s.z) < this.minSize) return;
    }
    bakeWeathering(geo, tint);                          // after transform, so noise is world-keyed
    const k = mat.uuid + (cast ? '|c' : '');
    (this.buckets.get(k) ?? this.buckets.set(k, { mat, cast, geos: [] }).get(k)).geos.push(geo);
  }
  finish(root) { for (const { mat, cast, geos } of this.buckets.values()) {
    const m = new THREE.Mesh(mergeGeometries(geos), mat);   // mat needs vertexColors: true
    Object.assign(m, { castShadow: cast, receiveShadow: true, matrixAutoUpdate: false }); root.add(m); } }
}
function bakeWeathering(geo, tint, baseY = 0) {         // noise3: any value noise in 0..1
  const p = geo.attributes.position, n = geo.attributes.normal, c = new Float32Array(p.count * 3), S = THREE.MathUtils.smoothstep;
  for (let i = 0; i < p.count; i++) {
    const x = p.getX(i), y = p.getY(i), z = p.getZ(i), up = THREE.MathUtils.clamp(n.getY(i) * 0.6 + 0.62, 0, 1);
    const k = (0.82 + 0.18 * noise3(x * 1.9, y * 1.9, z * 1.9)) * (0.92 + 0.08 * noise3(x * 9, y * 9, z * 9)) * (0.76 + 0.24 * up);
    const g = 1 - S(y - baseY, 0, 0.2), rust = 0.5 * S(noise3(x * 0.35, y * 0.35, z * 0.35), 0.68, 0.75);
    const rgb = [tint.r * (1 - 0.2 * g), tint.g * (1 - 0.3 * g), tint.b * (1 - 0.4 * g)];  // grime band shifts warm
    for (let j = 0; j < 3; j++) c[i * 3 + j] = k * rgb[j] + (RUST[j] - k * rgb[j]) * rust;
  } geo.setAttribute('color', new THREE.BufferAttribute(c, 3));
}
```
Gotchas: `mergeGeometries` returns `null` if attribute sets or indexing differ (give every part
position, normal, uv, color, indexed). Animated parts (spreader, radar) skip the merge (`noMerge`).

## 3. Template cache with a placeholder-material swap

When: many variants of a costly mesh (containers, cars, crates). Cost: one build per key.
```js
const PAINT = { token: 'paint' }, cache = new Map();    // PAINT is never rendered; swapped at placement
function containerParts(type, seed, doors, wear) {      // quantise params or the cache never hits
  const key = `${type}|${seed % 6}|${Math.round(doors * 10)}|${wear < 0.25 ? 0 : wear < 0.75 ? 0.5 : 1}`;
  if (!cache.has(key)) cache.set(key, buildContainer(type, seed % 6, doors, wear));   // -> [{mat, geo, cast}]
  return cache.get(key); }
const place = (b, parts, paint) => parts.forEach(({ mat, geo, cast }) => b.add(mat === PAINT ? paint : mat, geo.clone(), { cast }));
```
8 paints x 6 variants x wear reads as hundreds of boxes. Keep templates unbaked: `add()` bakes per copy.

## 4. Profile sweep and parametric surfaces

When: corrugated walls, jersey barriers, rails, and decals that must follow a deformed surface.
```js
function sweep(profile, stations, fn) {                 // fn(px, py, v, u) -> [x, y, z]
  const u = [0], pos = [], uv = [], idx = [], w = profile.length, F = THREE.Float32BufferAttribute;
  for (let i = 1; i < w; i++) u.push(u[i - 1] + Math.hypot(profile[i][0] - profile[i - 1][0], profile[i][1] - profile[i - 1][1]));
  for (const v of stations) profile.forEach(([px, py], i) => { pos.push(...fn(px, py, v, u[i])); uv.push(u[i], v); });
  for (let s = 0; s < stations.length - 1; s++) for (let i = 0, a; i < w - 1; i++) { a = s * w + i; idx.push(a, a + w, a + 1, a + 1, a + w, a + w + 1); }
  const g = new THREE.BufferGeometry().setIndex(idx).setAttribute('position', new F(pos, 3)).setAttribute('uv', new F(uv, 2));
  g.computeVertexNormals(); return g;
}
```
Corrugation: trapezoid pitch 0.278 m, depth 0.036, flat 0.072, slope 0.068; dents push inside `fn`.
A decal sweeps a sub-range of the same profile 3-5 mm outward, so it follows every fold (inside out?
flip the index order). **Hulls**: `P(s, y, side)`, half-breadth `B/2*sin(PI*t)^0.72` plus flare and
sheer in `s`, central-difference normals, a hash shade per panel (plate seams), split buckets at the
waterline. Name, draft marks and rust runs are sub-patches of `P` offset 1.2-1.4 cm along the normal.

## 5. Authored LOD, hidden faces, one-draw skyline

**Authored LOD** (a cheap distant copy of a hero asset): re-run the same builder into the
skyline batcher with a remap; every material collapses into one and small parts drop out.
```js
skyline.remap = (mat, tint) => mat.userData.decal ? null : [skylineMat, tint.clone().multiply(TINT.get(mat) ?? WHITE)];
skyline.minSize = 2.6; skyline.push(new THREE.Matrix4().makeTranslation(0, 0, 66)); buildCrane(skyline); skyline.pop(); skyline.remap = null;
const dirs = [['E', 1, 0], ['W', -1, 0], ['N', 0, -1], ['S', 0, 1]];   // hidden faces: emit only if the neighbour is lower
for (let t = 0; t < h[i][j]; t++) {
  const faces = (t === h[i][j] - 1 ? 'T' : '') + dirs.filter(([, di, dj]) => (h[i + di]?.[j + dj] ?? 0) <= t).map((d) => d[0]).join('');
  boxFaces(skyline, i, j, t * 2.59, faces, fade(dist));   // ribs and doors only on exposed faces < 55 m
}
```
Far tier: ~30 boxes per crane. Bake haze in, `fade = 1 - 0.6*smoothstep(38, 160, dist)`; no shadows.

## 6. Layout and seeded RNG

Hand-place the layout (literal coordinates per stack and fence run); RNG only varies it. Use
mulberry32 with `fork()` child streams so a new prop never shifts another subsystem's sequence;
seed each prop from (world seed, prop id). Tiers above the first: +-5 cm x/z, +-0.013 rad yaw.

## 7. Analytic sea (no FFT, no planar reflection)

When: harbour or coastal water seen from a near shore. Cost: 1 draw plus a fat fragment shader.
```js
const WAVES = [[-.92, .39, 9.5, .06], [-.75, -.66, 5.7, .04], [-.99, .12, 3.3, .026], [-.5, .87, 2, .016]]; // dirX, dirZ, lambda m, amp m
const f = (x) => x.toFixed(5);                          // always a decimal point: GLSL ES 3.0 has no int-to-float literals
const vsWaves = WAVES.map(([dx, dz, L, A]) => { const n = Math.hypot(dx, dz), k = 2 * Math.PI / L, w = Math.sqrt(9.81 * k);
  return `{ vec2 D = vec2(${f(dx / n)}, ${f(dz / n)}); float ph = ${f(k)} * dot(D, wp.xz) - ${f(w)} * uTime;
    disp.y += ${f(A)} * sin(ph) * amp; disp.xz += D * (${f(0.6 * A)} * cos(ph) * amp); }`; }).join('\n');
const steps = (a, b, s, g, max) => { const o = [a]; for (let r = a; r < b; s = Math.min(max, s * g)) o.push(r = Math.min(b, r + s)); return o; };
const xs = steps(27.5, 880, 0.75, 1.075, 120);          // 0.75 m cells at the quay, 120 m at the horizon
```
- Mask `amp = 1.0 - smoothstep(50.0, 220.0, distance(wp.xz, vec2(30.0, 0.0)))` keeps the far
  grid flat. Bump `customProgramCacheKey` whenever the tables change.
- Fragment: sum slopes `D*A*k*cos(ph)`, plus 7 short waves faded out 25-110 m (aliasing) and 3
  scrolling detail-normal samples; replace `#include <normal_fragment_maps>` with
  `normal = normalize((viewMatrix * vec4(-sl.x, 1.0, -sl.y, 0.0)).xyz);` (view space).
- SDF foam: `band = 1.0 - smoothstep(0.0, mix(0.6, 1.6, n1), min(wp.x - 30.0, sdRoundBox(...)))`,
  thresholded by a second noise. Glitter: `min(directSpecular, vec3(40.0)) * spark * pow(az, 3.0)`,
  `az = max(dot(normalize(viewDir.xz), normalize(sunDir.xz)), 0.0)`, so it gathers on the sun's bearing.
- Albedo `vec3(0.0045, 0.013, 0.017)`, roughness 0.1-0.32 over 12-380 m, haze 220-860 m, sky PMREM
  reflection, `frustumCulled = false`. CPU twin (same table, mask, clock) answers buoyancy queries.

## 8. Shader life: flocks and lamps

**Flocks** (birds that never interact; boids when they do): 2 triangles per bird, wingtips weight 1,
`aOrbit = (centre, radius)`, `aPar = (signed speed, phase, flap Hz, wing weight)`, in `begin_vertex`:
```glsl
float a = aPar.y + uTime * aPar.x, dir = sign(aPar.x);
vec3 fw = vec3(-sin(a), 0.0, cos(a)) * dir, rt = vec3(fw.z, 0.0, -fw.x);   // circle tangent frame
float flap = sin(uTime * aPar.z + aPar.y * 7.0) * 0.4 + 0.18;
vec3 p = position; p.y += aPar.w * flap * abs(p.z); p.z *= 1.0 - 0.14 * aPar.w * abs(flap);
vec3 transformed = aOrbit.xyz + vec3(cos(a), 0.0, sin(a)) * aOrbit.w + fw * p.x + rt * p.z
                 + vec3(0.0, p.y - 0.3 * dir * p.z, 0.0);                   // bank into the turn
```
**Lamps** (beacons, lit windows): one merged `MeshBasicMaterial({ vertexColors: true, fog: false })`,
per-vertex `blink = (period, phase, duty)`, HDR colours like `[9, .5, .25]` for bloom, and
`vBlink = mix(0.02, 1.0, smoothstep(0.0, 0.06, ph) * (1.0 - smoothstep(duty, duty + 0.12, ph)))`
with `ph = fract(uTime / period + phase)`. Both: `frustumCulled = false` (CPU bounds are stale).

## 9. Rain and splashes

When: any weather. Cost: one instanced quad each (9000 streaks + 260 drips; 900 splashes).
`p = mod(aSeed.xyz * uBox + uVel * uTime - uCam + 0.5 * uBox, uBox) - 0.5 * uBox + uCam;` wraps a
26 x 15 x 26 m camera box (GLSL `mod` floors, unlike JS `%`). Stretch along the wind, width >= 1 px
with alpha `* w0 / w`, Henyey-Greenstein (g = 0.72) toward the sun; kill indoors or underground via
`gl_Position = vec4(2.0, 2.0, 2.0, 1.0)`. Splashes: centre on `floor(cam.xz / 4.0) * 4.0` (no swimming),
re-hash `seed + cycle`, gate on `textureLod(uMask, uv, 0.0)` (CPU `isPuddle()` reads it too). No culling.

## 10. CPU struct-of-arrays particles into instanced quads

When: smoke, fire, sparks (caps 1400 lit, 3200 additive). Typed array per field, free-list stack,
drag toward wind, gravity, sin/cos turbulence, floor flags (bounce, die, stick). Each frame
insertion-sort the lit pool back to front (nearly sorted, so cheap), write `aPos (xyz, size)`,
`aAxis (axis, roll)`, `aCol (hdr rgb, a)`, `aMisc (frame, mode, age, sunVis)`, then
`attr.addUpdateRange(0, n * 4); attr.needsUpdate = true; geo.instanceCount = n;`. Modes: billboard,
velocity-stretched (1 px clamp, brightness `size / w`), surface-aligned. Lit pool: premultiplied
over, fire as an emissive branch so smoke occludes it; additive pool separate; soft-fade on depth.

## 11. AABB world without a physics engine

When: a lightweight FPS with static cover; use rapier ([physics.md](physics.md)) once anything
tumbles. AABBs come from `userData.colliders` times the placement matrix; a rotated prop
(`|sin 2*theta| > 0.2`) becomes up to 10 slices along its long axis, each world AABB shrunk 7%.
Capsule: substepped XZ circle-vs-AABB push-out (3 iterations, step 0.42 m), vertical resolve on an
analytic ground plane. Nav: same boxes on a 0.5 m grid, A* plus line-of-sight string pulling.

## 12. Showcase harness

Every system exports `{ create, showcase }` (stubs let the game run with any one off); check each against section 1.
```js
const only = new URLSearchParams(location.search).get('show');   // ?show=crane|ship|sea|skyline
if (only) { const s = new THREE.Scene(); SYSTEMS[only].showcase({ scene: s, camera }); renderer.render(s, camera);
  const { triangles: tris, calls: drawCalls } = renderer.info.render; console.log(only, { tris, drawCalls }); }
```
