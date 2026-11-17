# Procedural PBR materials - photographic surfaces with zero downloaded textures

Bake tiled procedural detail once on the GPU; patch `MeshStandardMaterial` only for what varies per world position, weather or distance.
Source: the reference build in SKILL.md section 9

## Contents

1. Architecture and lazy GPU bake (MRT)
2. Periodic noise kit (tiles by construction)
3. Layer composition and the overlay/coverage tint split
4. onBeforeCompile and cache-key discipline
5. World-space macro variation and rain
6. Normals without tangents, curvature, footprint fading
7. Specular and alpha AA
8. Canvas surfaces, merged per-vertex params
9. Material recipe table

## 1. Architecture and lazy GPU bake (MRT)

A **texture set** (albedo, ORM, normal) bakes on first `mats.get(name)`; a **material def** (tint, rough/metal
multipliers, wet, macro) is a record over a set. **UVs are metres** and `repeat = 1 / tile`, so one set fits every prop.

```glsl
// bake fragment, glslVersion: THREE.GLSL3 - declare your own outputs
layout(location = 0) out vec4 oAlb;   // sqrt(albedo), coverage
layout(location = 1) out vec4 oOrm;   // three reads aoMap.r, roughnessMap.g, metalnessMap.b
layout(location = 2) out vec4 oHgt;   // height as hi byte + lo byte
void emit(vec3 c, float cover, float ao, float rough, float metal, float h) {
  oAlb = vec4(sqrt(clamp(c, 0., 1.)), clamp(cover, 0., 1.));   // sqrt: gamma-2 precision in RGBA8
  oOrm = vec4(ao, clamp(rough, .03, 1.), metal, 1.);
  float q = clamp(h, 0., 1.) * 255.; oHgt = vec4(floor(q) / 255., fract(q), 0., 1.); }  // 16-bit height
```
```js
const scratch = new THREE.WebGLRenderTarget(N, N, { count: 3, depthBuffer: false,
  minFilter: THREE.NearestFilter, magFilter: THREE.NearestFilter });     // read via scratch.textures[i]
const finalRT = (colorSpace) => new THREE.WebGLRenderTarget(N, N, { depthBuffer: false, colorSpace, anisotropy: 8,
  generateMipmaps: true /* default false */, minFilter: THREE.LinearMipmapLinearFilter, wrapS: THREE.RepeatWrapping, wrapT: THREE.RepeatWrapping });
// albedo: copy squaring rgb into finalRT(SRGBColorSpace); ORM: plain copy; normal: 3x3 Sobel on height
sobel.uniforms.uK.value.set(bumpMM * 1e-3 * N / tile[0], bumpMM * 1e-3 * N / tile[1]);  // slope per texel, metres
for (const rt of [albedo, orm, normal]) rt.texture.repeat.set(1 / tile[0], 1 / tile[1]);
```
- **When:** per-pixel procedural is too costly, or you want mips and anisotropy on procedural detail. **Cost:** one
  bake per set (1024^2; 2048^2 hero ground), then plain reads; dispose scratch MRT + bake programs ~4 s after the last bake.
- **Gotchas:** save/restore `getRenderTarget()`, `autoClear`, `xr.enabled`, `shadowMap.autoUpdate` around
  the bake. Warm up behind a loading screen (bake + `compileAsync`) or a set's first use hitches.
  The copy shader outputs *linear* colour: an RGBA8 target with `SRGBColorSpace` is stored as
  `SRGB8_ALPHA8`, and WebGL2 encodes on write in hardware. Don't also encode in the shader.

## 2. Periodic noise kit (tiles by construction)

Every lattice hash wraps with `mod(cell, period)` and every frequency is an integer, so no seam pass is needed.
```glsl
uvec3 pcg3d(uvec3 v) {  // Jarzynski & Olano 2020, "Hash Functions for GPU Rendering"
  v = v * 1664525u + 1013904223u; v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y;
  v ^= v >> 16u;                   v.x += v.y*v.z; v.y += v.z*v.x; v.z += v.x*v.y; return v; }
vec3 hash(vec2 c, vec2 per, float s) { return vec3(pcg3d(uvec3(ivec3(mod(c, per), s)))) / 4294967295.; }
float grad(vec2 i, vec2 o, vec2 f, vec2 per, float s) { return dot(hash(i + o, per, s).xy * 2. - 1., f - o); }
float gnoise(vec2 p, vec2 per, float s) {   // quintic fade: C2, no lattice creases in Sobel normals
  vec2 i = floor(p), f = fract(p), u = f*f*f*(f*(f*6. - 15.) + 10.);
  return mix(mix(grad(i, vec2(0, 0), f, per, s), grad(i, vec2(1, 0), f, per, s), u.x),
             mix(grad(i, vec2(0, 1), f, per, s), grad(i, vec2(1, 1), f, per, s), u.x), u.y); }
float fbm(vec2 uv, vec2 freq, int oct, float s) { float amp = .5, v = 0., n = 0.;   // ~0..1 centred on 0.5
  for (int k = 0; k < oct; k++) { v += amp * gnoise(uv * freq, freq, s + float(k) * 7.); n += amp; amp *= .5; freq *= 2.; }
  return clamp(v / n * 1.8 + .5, 0., 1.); }
vec4 voronoi(vec2 p, vec2 per, float s) {          // x F1, y F2, z id nearest, w id second
  vec2 i = floor(p), f = fract(p); vec4 r = vec4(8., 8., 0., 0.);
  for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) { vec2 o = vec2(x, y); vec3 h = hash(i + o, per, s);
    float d = length(o + h.xy - f); if (d < r.x) r = vec4(d, r.x, h.z, r.z); else if (d < r.y) r.yw = vec2(d, h.z); }
  return r; }
```
- **When:** anything baked into a repeating tile. **Cost:** bake-time only, so octaves are nearly free.
- **Gotchas:** period = integer frequency (`gnoise(uv*f, f)`, even `vec2(2., 300.)`); warps use periodic fbm too;
  one seed per layer. `smoothstep(.55, .85, fbm)` reads as "x% coverage"; `F2 - F1` gives cracks, spangle, mortar.

## 3. Layer composition and the overlay/coverage tint split

Bottom-up: substrate, primer, paint, then chips, scratches, rust runs, grime. Cluster damage with a
low-frequency zone mask (`smoothstep(.58, .82, fbm(uv, vec2(2.), 4, 9.))`) so most panels stay clean.
```glsl
vec3 over = vec3(0.); float cover = 1.;   // over stays premultiplied by (1 - cover)
void layer(vec3 col, float k) { k = clamp(k, 0., 1.); over = mix(over, col, k); cover *= 1. - k; }
// in surf(uv):
float runs = 0.;                          // look UP the surface for damage that drips down
for (int k = 1; k <= 4; k++) runs = max(runs, damage(uv + vec2(0., float(k) * .034)) * (1. - float(k) / 5.));
runs *= smoothstep(.5, .78, fbm(uv, vec2(120., 1.), 4, 31.));   // thin vertical streak gate
layer(dirtCol, film * .42); layer(rustStain, runs * .5);   // dirt film + wash streaks, then oxide runs
layer(primerCol, primer);                 // chips through paint     (rough -> .75)
layer(steelCol, bare);                    // chips through primer    (rough -> .92)
layer(vec3(.55), fresh);                  // fresh scratch           (rough .35, metal .95)
emit(over, cover, ao, rough, metal, h);
```
Runtime `TINT 1`: `diffuseColor.rgb = texel.rgb + diffuse * texel.a;` so one bake serves every `paint_<colour>`.
`TINT 2` = luminance-preserving recolour, alpha = surviving paint (painted concrete); `TINT 3` = alpha is opacity.
- **When:** one surface family, many colours. **Cost:** one MAD. **Gotchas:** runs assume UV `v` points up; wear is a bake param.

## 4. onBeforeCompile and cache-key discipline

```js
const rain = { value: 0 };                                     // ONE object: every material sees it
function makeMaterial(def, set) {
  const m = new THREE.MeshStandardMaterial({ map: set.albedo, aoMap: set.orm, roughnessMap: set.orm,
    metalnessMap: set.orm, normalMap: set.normal, color: def.color, roughness: def.rough, metalness: def.metal });
  m.defines = { ...m.defines, PM_TINT: def.tint, ...(def.alphaCut && { PM_ACUT: '' }) };   // keep STANDARD
  const u = { uRain: rain, uWetP: { value: new THREE.Vector4(...def.wet) }, uMacro: { value: new THREE.Vector4(...def.macro) } };
  m.onBeforeCompile = (sh) => { Object.assign(sh.uniforms, u); patchChunks(sh); };   // per-material via closure
  const key = `pm1|${def.tint}|${def.alphaCut ? 'a' : ''}`;    // three keys defines anyway; pm1 versions the patch text
  m.customProgramCacheKey = () => key; return m; }
```
Patch `<map_fragment>` (sample, tint, macro, wet), `<roughnessmap_fragment>` / `<metalnessmap_fragment>`
(def value times ORM channel), `<aomap_fragment>` (reuse the ORM sample), `<normal_fragment_maps>` (flatten when wet).
- **When:** many variants of one patched material. **Cost:** programs = distinct keys (~4 tints x flags), not materials.
- **Gotchas:** three's program key already includes `defines`, but not the patch text: the default key is
  `onBeforeCompile.toString()`, the same for every closure, so GLSL built from per-material JS values silently
  shares one program unless the key names them. A key holding per-material values (colour) multiplies compiles. three runs `onBeforeCompile` per material even when it reuses a program, so per-material
  uniform objects still work. Since r151 `aoMap` reads UV channel 0; no `uv2`.

## 5. World-space macro variation and rain

```glsl
// in the <map_fragment> patch; vWorld from your own vertex varying, vnoise3 = cheap 3D value noise
float mac = vnoise3(vWorld * uMacro.z) * .65 + vnoise3(vWorld * uMacro.z * 3.7 + 11.) * .35 - .5;
diffuseColor.rgb *= 1. + 2. * uMacro.x * mac;                                   // breaks tiling at range
float grime = smoothstep(.5, .85, mac + .5 + (1. - orm.r) * .3) * uMacro.w;      // pools in baked AO
vec3 wn = inverseTransformDirection(normalize(vNormal), viewMatrix);
float up = smoothstep(.15, .85, wn.y), exposed = smoothstep(-.4, -.05, wn.y);   // undersides stay dry
float wet = uRain * exposed * mix(uWetP.z * streaks, .75 + .5 * mac, up);       // streaks: world noise on (x+z, y*k)
diffuseColor.rgb *= 1. - uWetP.x * wet;                                          // roughness *= mix(1., uWetP.y, wet)
float beadFade = clamp(1. - length(fwidth(vWorld)) * 120., 0., 1.);             // beads only where resolvable
```
- **When:** tiling shows at distance; weather without new textures. **Cost:** 2 value-noise taps plus ALU.
- **Gotchas:** `worldpos_vertex` is define-gated: write `vWorld` after `<project_vertex>` yourself (apply
  `instanceMatrix` under `USE_INSTANCING`). Good defaults: macro `(.14, .1, .8 per m, .2)`, wet `(.42, .38, .5, 0)`.

## 6. Normals without tangents, curvature, footprint fading

```glsl
vec3 bumpN(vec3 n, vec3 p, float h) {   // Mikkelsen 2010 surface gradient; h and p both in METRES
  vec3 dx = dFdx(p), dy = dFdy(p), r1 = cross(dy, n), r2 = cross(n, dx); float det = dot(dx, r1);
  return normalize(abs(det) * n - sign(det) * (dFdx(h) * r1 + dFdy(h) * r2)); }
normal = bumpN(normal, -vViewPosition, -engrave.a * 5e-5);   // after <normal_fragment_maps>: 50 um engraving
float near = 1. - smoothstep(2e-4, 7.5e-4, length(fwidth(vObj)));   // metres/pixel: gone before a 0.28 mm stud is 2 px
h += stud * 2.8e-4 * near; rough += .1 * (1. - near);  // vanished detail folds into roughness
```
CPU curvature for edge wear and cavity grime: per triangle edge `k = dot(n1 - n0, p1 - p0) / |p1 - p0|^2`
(1/m), keep max and min per vertex, store `aCurv = (smoothstep(110, 520, max) * wear, smoothstep(110, 520, -min))`.
- **When:** decals, engravings, micro detail, code-built props with no tangents. **Cost:** 4 derivatives; one CPU pass.
- **Gotchas:** derivatives work per 2x2 quad, so `h` must be continuous and branch-free. 110-520 per m suits
  hand props (2-9 mm bevels); rescale for buildings. Split normals give zero curvature, and `mergeVertices` hashes
  every attribute so never welds them: weld a copy with `normal`/`uv` deleted, `computeVertexNormals`, map back by position.

## 7. Specular and alpha AA

```glsl
float nl = length(texture2D(normalMap, vNormalMapUv).xyz * 2. - 1.);   // < 1 where mips averaged disagreeing normals
roughnessFactor = clamp(sqrt(roughnessFactor * roughnessFactor + (1. - nl) * .6), .045, 1.);   // Toksvig-style
vec2 fw = fwidth(vMapUv) * texSize; float lod = log2(max(max(fw.x, fw.y), 1e-4));
float th = .5 * exp2(-clamp(lod - 1., 0., 4.));                        // wires thin per mip -> lower threshold
float ign = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(.06711056, .00583715))));   // Jimenez 2014 IGN
th = mix(th, .05 + .8 * ign, smoothstep(3.5, 5.5, lod));               // far: stable dithered veil
diffuseColor.a = step(th, texel.a);                                     // with material.alphaTest = .5
diffuseColor.rgb *= mix(1., .45, smoothstep(1.5, 4.5, lod));           // no white sheets in sun
```
- **When:** baked normals sparkle at range; fences, grilles, foliage cards vanish or shimmer. **Cost:** 1 tap + ALU.
  **Gotchas:** Toksvig needs auto mips of unnormalised RGB (BC5 rebuilds z and loses it); bake alpha with a 1-texel analytic edge.

## 8. Canvas surfaces, merged per-vertex params

- **Road markings** (when: lines, stencils, big decals; cost: one canvas): draw in world metres via `setTransform`,
  `'lighter'`, R yellow / G white / B rubber, `NoColorSpace`; threshold like an SDF, `smoothstep(.5 - kw, .5 + kw,
  mask + noise)`, `kw = clamp(px * .5, .16, .5)`, bicubic when `px < 1`. Gotcha: world noise must chip paint, not texels.
- **Decals** (when: any canvas texture with transparency): seed RNG per name (`mulberry32(fnv1a(name))`); fill the
  paint colour at ~1.2% alpha so mips never halo to black; distress with `destination-out`; `depthWrite: false`,
  `polygonOffset` -2/-2. Gotcha: redraw text when `document.fonts.load()` resolves, then `needsUpdate`.
  **Atlas:** shelf-pack, 4 px gutters filled by drawing each image stretched, real image on top.
- **Merged per-vertex params** (when: hundreds of static lamps; cost: one draw call): constant `blink = (period s,
  phase, duty)` attribute, `mergeGeometries`, one shared `uTime`. Gotcha: identical attribute sets, all indexed or not.

## 9. Material recipe table

Tile in metres, bump in mm of height range; roughness/metal are the ranges the bakes emit.

| Material | Layer stack | Tile / bump | Rough | Metal |
|---|---|---|---|---|
| Asphalt | 2 Voronoi aggregate layers (110, 230 cells) jagged by fbm, dark binder, crack-seal band on an fbm iso-line, oil fbm | 2 / 1.6 | 0.74-0.93 | 0 |
| Concrete | stretched fbm form ties, Voronoi pores, warped F2-F1 cracks, chips to aggregate, joint stain | 3 / 2.5 | 0.65-0.95 | 0 |
| Brick | running bond, per-brick hash tint, fbm-wobbled mortar, pits, soot, efflorescence | 1.8 / 6 | 0.8-0.95 | 0 |
| Galvanised steel | warped 2-scale Voronoi spangle, F2-F1 relief, white-rust wash | 1 / low | 0.25-0.6, to 0.9 rusted | 1 - wear, lower where rusted |
| Painted corrugated | `cos` profile 10 per tile, lap line, paint stack (s3), rust at the drip end, fasteners | 0.762 x 2.286 / 19 | paint 0.4-0.7, bare 0.92 | 0; bare 0.15; scratch 0.95 |
| Rust | warped fbm, terraced flakes `floor(x*4)/4`, Voronoi pits, mill-scale islands | 1.2 / 3 | 0.77-0.97 | 0-0.35 (mill scale) |
| Brushed aluminium | anisotropic fbm `vec2(2, 300)`, tar smudges, tinted | 0.5 / low | 0.2-0.5 | 1 |
| Rubber (tyre) | zig-zag tread, lateral grooves, sipes, sidewall ribs | 0.5 x 0.3 / 7 | 0.75-0.9 | 0 |
| Glass | dust coverage drives alpha, Voronoi droplets, rain trails; tint 3, transparent | n/a | 0.03-0.55 | 0 |
| Tarp | ridged `1 - abs(gnoise)` folds at 2 warped scales, scrim grid | 1.5 / 20 | 0.4-0.8 | 0 |
| Wood | ring phase bent by Voronoi knot centres, early/late rings, saw marks, greying, checks | 1.2 / low | 0.6-0.95 | 0 |
