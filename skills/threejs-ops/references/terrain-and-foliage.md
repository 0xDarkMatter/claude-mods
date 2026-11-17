# Terrain and foliage - an outdoor world from code, with no assets and no streaming

Build terrain, a forest, ground cover, wind and ambient leaves in JS and GLSL, all resident from load.
Source: https://patch.gg/blendi/oil-paint (MIT code, CC0 art, three.js 0.186), adapted from blendi/oil-paint (MIT).
Counts from code (some estimated); perf: 4.6 ms, 1080p, 4090.
Related: [scale-and-disposal.md](scale-and-disposal.md) (instancing, `LOD`), [physics.md](physics.md) (Rapier init),
[procedural-world.md](procedural-world.md) (hard-surface worlds, rain, particle pools),
[stylised-rendering.md](stylised-rendering.md) (dabs, ring GLSL, shadow sampling).

## Contents

1. Budget - the reference wood (~3,100 trees, ~570k leaf dabs, 18 world draws)
2. One heightmap, CPU/GPU twin
3. The land map - art direction in one RGBA8 texture
4. One spline drives everything
5. A leash plus generation-time LOD instead of streaming
6. Placement - jittered grid, noise stands, hero trees
7. Crowns from sphere lobes, leaves on the shells
8. Distance thinning with no pop
9. Ground rings - camera-following quadtree scatter
10. One wind field for everything
11. Falling leaves - stateless, mod-wrapped round the camera
12. Kicked leaves - a CPU ring buffer fed by footfalls
13. Bake static shade once
14. Risks and memory

## 1. Budget - the reference wood (~3,100 trees, ~570k leaf dabs, 18 world draws)

| Item | Count / size | Draws |
|---|---|---|
| Trunks + limbs merged / bark dabs / leaf dabs | ~280k tris / ~107k / ~570k instances | 1 / 1 / 1 |
| Ground rings (carpet 6 lv, undergrowth 4) / falling / kicked leaves | 663,552 + 221,184 / 2,400 / 260 | 10 / 1 / 1 |
| Underpainting plane (512 seg) / sky dome + strokes | 524k tris / 2,600 | 1 / 2 |
| `tHeight` R32F + `tLand` RGBA8 1025^2 (+ CPU twins); VBOs; shade depth | 8.4 (+8.4) MB; ~42 MB; ~42 MB | once |

## 2. One heightmap, CPU/GPU twin

When: feet, props, particles, physics and shaders must agree exactly on ground height. Cost: N^2 floats twice.
```js
const N = 1025, E = 256, H = new Float32Array(N * N);    // ~0.5 m spacing; fill once (yield every 24 rows)
const tHeight = new THREE.DataTexture(H, N, N, THREE.RedFormat, THREE.FloatType);
tHeight.minFilter = tHeight.magFilter = THREE.LinearFilter; tHeight.needsUpdate = true;
export function heightAt(x, z) {                          // the same bilinear the GPU filter does
  const f = (v) => Math.min(N - 1.001, Math.max(0, ((v + E) / (2 * E)) * (N - 1)));
  const fx = f(x), fz = f(z), i = fx | 0, j = fz | 0, tx = fx - i, tz = fz - j, k = i + j * N;
  return (H[k] + (H[k + 1] - H[k]) * tx) * (1 - tz) + (H[k + N] + (H[k + N + 1] - H[k + N]) * tx) * tz;
}
```
```glsl
uniform float uExtent, uRes;  // pass N (repo hard-codes 1024.0/1025.0); texel centres -> GPU bilinear == CPU
vec2 landUv(vec2 xz) { return (xz + uExtent) / (2.0 * uExtent) * ((uRes - 1.0) / uRes) + 0.5 / uRes; }
float heightAt(vec2 xz) { return texture(tHeight, landUv(xz)).r; }
```
- Normals: central differences at +/-0.75 m. Displace the visible plane from CPU `heightAt`, sunk 4 cm.
- Rapier: resample the twin (384^2 cells over +/-192 m, `out[row + col * (cells + 1)]`) into `heightfield(cells,
  cells, out, { x: 2 * half, y: 1, z: 2 * half })`. Column-major, row = z index, col = x index: the transpose of
  the twin's `H[x + z * N]`. The field is centred on its collider. A transposed field looks right on flat ground:
  test a slope.

## 3. The land map - art direction in one RGBA8 texture

When: many systems must agree on "what lies where". Cost: 4 B/sample; the CPU keeps the `Uint8Array` for planting.
Channels: **r** path (1 in the middle, ragged edge `1 - smoothstep(0.75, 1.9, wayDist + noise)`), **g** open sky
(noisy radial clearing), **b** moss/litter drift (slow noise), **a** free.
```glsl
float chance = max(0.05 + 0.8 * drift, m.g) * (1.0 - m.r);   // m = tLand at the foot: dense in clearing, none on path
```
Gotcha: `wayDist` is a 193-segment scan; evaluate it only in a box round the corridor and write 99 elsewhere.

## 4. One spline drives everything

When: a linear walk, trail or level. Cost: generation only, plus one `wayDist` per frame for the leash.
```js
// 9 control points, uniform Catmull-Rom, 24 samples a span -> 193 points; wayDist = distance to that polyline
h -= 0.28 * Math.exp(-(wd * wd) / 3.2);             // path worn into the ground
if (wd < 2.7 || clearingAt(x, z) > 0.25) continue;  // trees keep off path and clearing
const tier = c < 40 ? 0 : c < 92 ? 1 : 2;           // c = distance to a box round the path (cheap proxy)
const collider = tier === 0 && wd < 60;             // Rapier trunks only where the player can reach
```
Gotcha: per-entity `wayDist` every frame does not scale; bake it into `tLand.r` or a coarse distance grid.

## 5. A leash plus generation-time LOD instead of streaming

When: a bounded diorama that must look endless. Cost: nothing at runtime.
```js
if (wayDist(p.x, p.z) > 78 || p.y < heightAt(p.x, p.z) - 6) respawn();   // every frame
```
Why static LOD is then safe: the player stays ~100 m inside the +/-192 m heightfield, never beside a tier-2 tree
(built from 92 m out), never outside the baked shade box. Detail is decided once from where the player *can be*,
not where the camera *is*. Pick the leash first, then set each tier boundary far enough past it that no tier is
seen closer than it was built for. Gotcha: the repo hard-teleports; a game wants a push-back or a fade.

## 6. Placement - jittered grid, noise stands, hero trees

When: thousands of trees with natural spacing and readable groves. Cost: one pass at load.
```js
const rand = rng(4471), G = 7.2;                         // seeded LCG, own stream per system
for (let gz = -40; gz <= 40; gz++) for (let gx = -40; gx <= 40; gx++) {
  const x = (gx + 0.15 + rand() * 0.7) * G, z = (gz + 0.15 + rand() * 0.7) * G - 8;  // jitter in 70% of cell
  if (corridor(x, z) > 185 || rand() > 0.84) continue;    // ~16% gaps break the grid
  const type = noise(x / 46 + 5, z / 46 - 3) > 0.42 ? BIRCH          // low-frequency noise = stands of one kind
    : noise(x / 31 - 7, z / 31 + 2) > 0.5 ? MAPLE : rand() < 0.04 ? OAK : BEECH;
  add(x, z, type, tierOf(x, z));                           // y from heightAt; lean +/-0.045
}
```
Heroes: hand-placed at named points, tier 0. Gotcha: a new `rand()` reshuffles every later tree; fork streams.

## 7. Crowns from sphere lobes, leaves on the shells

When: stylised trees, no foliage assets. Cost (load only): lobes 2/limb + 3, 7, 4 by tier; 54 (hero 150)/20/11 each.
```js
away.set(lx - crown.x, ly - crown.y, lz - crown.z).normalize();          // per lobe [lx, ly, lz, lr]
for (let k = 0; k < perLobe; k++) {
  d.set(rand() - 0.5, rand() - 0.5, rand() - 0.5).normalize().addScaledVector(away, 0.5).add(UP15).normalize();
  p.set(lx, ly, lz).addScaledVector(d, lr * (0.72 + rand() * 0.4));          // on the shell, outward-biased
  n.copy(d).multiplyScalar(0.6).addScaledVector(t.subVectors(p, crown).normalize(), 0.55).normalize(); // one mass
  push(p, n, rand() * 1000, lr * touch * (1 + rand() * 0.6), rand() < 0.14 ? (rand() * 4) | 0 : family);
}
pushCores(2);   // big dark dabs inside each lobe: never thinned, pushed back, fill the hollow shell
```
Gotcha: the repo pushes ~5.7M numbers into JS arrays first (peak heap several times the ~28 MB result); preallocate.

## 8. Distance thinning with no pop

When: hundreds of thousands of instanced cards. Cost: a few ALU per instance; dead ones go off-clip.
```glsl
float keep = mix(1.0, 0.3, smoothstep(35.0, 130.0, dist));         // 100% near, 30% by 130 m
alive = isCore ? 1.0 : smoothstep(0.0, 1.0, (keep - hash.w) / 0.12); // own threshold per leaf: hash, never index
size = baseSize / sqrt(isCore ? 1.0 : keep);                         // survivors grow: coverage holds
size = clamp(size, uMinPx * px, uMaxPx * px);                        // px = world size of a pixel at dist
```

## 9. Ground rings - camera-following quadtree scatter

When: carpet, grass, undergrowth to the horizon, nothing stored. Cost: a draw per level, all instances run. Per
level an n x n grid (cells twice the last level's) snaps to the camera; an instance hash-descends from its
`gl_InstanceID` cell to one finest cell (its identity), skipped if its parent level owns it (GLSL: stylised-rendering).
```js
follow(x, z) { for (const l of levels) l.origin.set(Math.floor(x / l.cell), Math.floor(z / l.cell)); } // = uOrigin
```
- Carpet: 3 per cell, n 192, cells 0.14-4.48 m over 6 levels, `uNear` 6.2 m, dabs flat on `normalAt`.
- Undergrowth: 6 per cell, n 96, cells 0.42-3.36 m over 4 levels, `uNear` 9.3 m, upright, pinned at the foot.
- `uNear = n * cell0 / 4 * 0.92`; density and kind from `tLand` plus slow noise at the foot. Gotcha: levels share
  one geometry but each needs its own material (uniforms); the stateless ground cannot be disturbed.

## 10. One wind field for everything

When: crowns, undergrowth, falling leaves and cloth must gust together. Cost: two texture taps per call.
```glsl
float gustAt(vec2 xz) {                          // bands travel with the wind, stretched along their fronts
  vec2 w = uWind.xy, q = vec2(dot(xz, w), dot(xz, vec2(-w.y, w.x)));
  float a = texture(tNoise, vec2(q.x - uTime * 4.0, q.y * 0.45) / 95.0).r;        // broad bands, 4 m/s
  float b = texture(tNoise, vec2(q.x - uTime * 6.5, q.y * 0.6) / 23.0 + 0.37).g;  // squalls, 6.5 m/s
  return clamp(smoothstep(0.36, 0.74, a) * 0.8 + (b - 0.5) * 0.6, 0.0, 1.0) * uWind.z;
}
P.xz += uWind.xy * (gust * 0.5 + sin(uTime * (1.1 + r.x) + r.y * 30.0) * (0.05 + 0.16 * gust))
      * clamp((P.y - heightAt(P.xz)) / 20.0, 0.1, 1.0);          // sway grows with height above ground
```
Gotcha: the repo's CPU wind is other noise; for a true twin sample the noise texture's bytes on the CPU, same clock.

## 11. Falling leaves - stateless, mod-wrapped round the camera

When: falling leaves, snow, pollen. Cost: 2,400 instances (900 on low), 1 draw, no CPU work.
```glsl
vec3 p = hash4(id * 1.13 + 3.0).xyz * BOX;                      // BOX = 64 x 26 x 64 m
p.y -= uTime * fall; p.xz += uWind.xy * uTime * drift + flutter;
vec3 origin = vec3(cameraPosition.x, uFocus.y + 11.0, cameraPosition.z);  // hangs over the hero, not the eye
p = mod(p - origin + BOX * 0.5, BOX) - BOX * 0.5 + origin;      // wrap as for rain: procedural-world.md 9
float g = heightAt(p.xz), edge = distance(p.xz, cameraPosition.xz);
alive = smoothstep(q.z * 0.75 - 0.08, q.z * 0.75 + 0.05, gustAt(p.xz) + 0.2)  // most hang on until a gust
      * smoothstep(g, g + 0.5, p.y) * (1.0 - smoothstep(24.3, 32.0, edge));  // sink into carpet; no edge pop
```

## 12. Kicked leaves - a CPU ring buffer fed by footfalls

When: a few hundred short-lived particles driven by gameplay. Cost: 260 slots, ~1.8k floats uploaded a frame.
```js
const rand = rng(seed);                                   // NOT Math.random, which the repo's kick.js uses
owed += grounded && speed > 2.4 ? dt * speed * 5.5 : 0;   // ~27 leaves/s at 5 m/s
while (owed >= 1) { owed -= 1; spawn(next, rand); next = (next + 1) % COUNT; }  // 0.25 m behind feet, up 1-3.4 m/s
// live slots: drag exp(-2.2 dt) on xz, vy = max(vy - 6.5 dt, -1.3), sin flutter; land on heightAt() + 0.04:
// stop, tumble = 0; life -0.35/s airborne, -1.6/s landed. Then attr.needsUpdate = true (DynamicDrawUsage).
```

## 13. Bake static shade once

When: static sun and world. Cost: one boot render into ~42 MB of depth; never again.
```js
shade.add(woodMesh, lobeBalls);   // proxies, not 570k leaves: icosphere(1, 1) per lobe at r * 0.36 (y * 0.8)
const sunCam = new THREE.OrthographicCamera(-165, 165, 104, -104, 10, 800);   // fits the leashed area
sunCam.position.copy(centre).addScaledVector(SUN, 400); sunCam.lookAt(centre); sunCam.updateMatrixWorld(true);
renderer.setRenderTarget(rt); renderer.clear(); renderer.render(shade, sunCam); renderer.setRenderTarget(null);
uShadeMat.copy(BIAS).multiply(sunCam.projectionMatrix).multiply(sunCam.matrixWorldInverse);
```
`rt`: `DepthTexture`, `LessEqualCompare`, `LinearFilter`; sampling: stylised-rendering.md 8. Check `maxTextureSize`.

## 14. Risks and memory

- **Hard-coded resolution**: `1024.0/1025.0` in GLSL breaks the twin silently when `LAND_RES` changes. Pass it.
- **R32F linear filtering** needs `OES_texture_float_linear`, missing on some mobile GPUs; the repo never checks.
  Test `renderer.extensions.has(...)`; else `NearestFilter` plus a manual 4-tap `texelFetch` bilinear (exact),
  or `HalfFloatType` with the CPU twin rounded via `THREE.DataUtils.toHalfFloat` / `fromHalfFloat`.
- **Non-determinism**: `kick.js` uses `Math.random`, so captures differ run to run; all else is `hash4(seed)`.
- **Memory and vertex cost**: VBOs and shade depth (~42 MB each) dominate; CPU twins (8.4 MB) stay. All meshes are
  `frustumCulled = false` (~6.2M vertex invocations a frame), safe only while the leash keeps the world small.
