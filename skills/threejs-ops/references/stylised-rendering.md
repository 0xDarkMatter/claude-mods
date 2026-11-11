# Stylised rendering - a painterly (NPR) renderer that never shimmers or pops

Build a stylised look as the renderer itself (world-pinned marks, picked palettes), so it stays temporally stable.
Source: https://patch.gg/blendi/oil-paint (MIT code, CC0 art; three.js 0.186, WebGL2); snippets adapted from
blendi/oil-paint (MIT). Costs are read from code.

## Contents

0. The art style is a renderer architecture, not a filter
1. The dab primitive: one instanced quad, a GLSL struct to fill
2. Strokes along a world direction, projected to view
3. On-canvas size clamp (`uPixel`)
4. Procedural brush atlas + screen-space impasto
5. Three-mix palette lighting, linear output, no tone mapping
6. Alpha-to-coverage on 4x MSAA instead of blending
7. The steady infinite ground: snapped quadtree rings
8. Shade: whole-dab static shadow, per-pixel glaze for movers
9. Mist per dab, sun in the mist per pixel
10. Finish pass: the canvas, not a filter
11. Draw order and stable stacking
12. Budget
Stability checklist (any stylised look)
Adapting to other styles

## 0. The art style is a renderer architecture, not a filter

A post filter (Kuwahara, edge strokes, screen hatching) keys its marks on pixels, so they swim and boil as the camera
moves. Here every leaf, trunk, ground patch and fold of cloth is a **dab** (one brush touch, one mixed colour) pinned
to a world point, so the paint stays on things. Unlike [render-pipeline.md](render-pipeline.md) (HDR radiance,
tonemapped and graded in post), colours are display-referred paints picked per mark; post is a thin finish (10).

## 1. The dab primitive: one instanced quad, a GLSL struct to fill

When: many stylised marks (strokes, scales, hatch ticks, grass cards) sharing projection and shading but differing
in placement. Cost: 4 verts per instance; `makeDab` runs at all 4 corners (redundant, but no extra pass).
```js
const VERT = (head, body) => `${COMMON}
struct Dab { vec3 pos; vec3 dir; vec2 size; vec3 c1; vec3 c2; float seed; float alive; float lift; float glaze; };
${head}  /* your attributes, palettes */  void makeDab(inout Dab d);  ${body}  /* your makeDab */
void main() { Dab d; d.seed = float(gl_InstanceID); d.alive = 1.0; d.lift = 0.6; /* ...defaults */ makeDab(d);
  vec4 vc = viewMatrix * vec4(d.pos, 1.0);
  if (d.alive < 0.004 || -vc.z < 0.1) { gl_Position = vec4(2.0, 2.0, 2.0, 1.0); return; } // off-clip: culled
  /* shared: orient (2), clamp (3), lift (11), brush cell, varyings */ }`;
const mat = new THREE.ShaderMaterial({ glslVersion: THREE.GLSL3, vertexShader: VERT(head, body),
  fragmentShader: FRAG, uniforms, side: THREE.DoubleSide, alphaToCoverage: true });
const g = new THREE.InstancedBufferGeometry().setIndex([0, 1, 2, 0, 2, 3]);   // per-dab data: instanced attrs, or none
g.setAttribute('position', new THREE.Float32BufferAttribute([-1,-1,0, 1,-1,0, 1,1,0, -1,1,0], 3)); g.instanceCount = n;
const mesh = new THREE.Mesh(g, mat); mesh.frustumCulled = false; mesh.matrixAutoUpdate = false;
```
- Many kinds need **no attributes**: everything derives from `gl_InstanceID` or a world cell (7). Defaults sit in
  `main()` before the call, so a kind sets only what it needs.
- Gotchas: positions come from the shader, so CPU bounds mean nothing: `frustumCulled = false`, the clip stage
  culls. A dropped dab writes the same **off-clip** vertex at all 4 corners and returns before the costly work.

## 2. Strokes along a world direction, projected to view

When: grain, hair, cloth fall, flow lines on camera-facing cards. Cost: a few ALU per vertex.
```glsl
vec3 vd = mat3(viewMatrix) * normalize(d.dir); float flat_ = length(vd.xy);
vec2 along = flat_ > 1e-4 ? vd.xy / flat_ : vec2(0.0, 1.0); float a0 = r.x * TAU;   // a0: FIXED per-dab angle
along = normalize(mix(vec2(cos(a0), sin(a0)), along, smoothstep(0.08, 0.4, flat_)));
vec2 across = vec2(along.y, -along.x);
vc.xy += across * position.x * half_.x + along * position.y * half_.y;   // quad built in view space
```
- Gotcha: a stroke aimed at the eye has no canvas direction; blend to its **own** seeded angle, not a view-derived
  one, or strokes spin as the view crosses the axis (a trunk seen from below).
- Ground dabs instead **lie** (`lie = 1`): a real world patch in the tangent plane, foreshortened, never turning
  with the eye. Seen edge-on, push the thin screen axis up to `minPx` so it stays a stroke, not a hair.

## 3. On-canvas size clamp (`uPixel`)

When: any world-sized billboard that must not sparkle far away or smear near. Cost: one clamp.
```glsl
// JS: uPixel = 2 * Math.tan(degToRad(cam.fov) / 2) / gl.drawingBufferHeight   (metres per pixel at 1 m)
float px = -vc.z * uPixel;                                   // metres per pixel at this depth
vec2 half_ = clamp(d.size, uMinPx * px, uMaxPx * px) * 0.5 * d.alive;   // per axis: across, along
```
- `minPx` kills sub-pixel marks (the main shimmer source): distance reads as fewer, larger touches. Per kind:
  leaves `[5,8]..[64,100]`, sky `[10,20]..[900,1800]`. Gotcha: use the drawing-buffer height (tracks pixel ratio)
  and refresh on resize and fov change. `alive` multiplies size: appearing is growing, never alpha.

## 4. Procedural brush atlas + screen-space impasto

When: mark-based NPR (paint, ink, chalk) that should feel physical. Cost: one 512x512 RGBA8 (CPU, boot); 5 taps/px.
- 4x2 cells of 128x256: 8 marks (long dry stroke, fat ragged dab, curve). **R** thickness, **G** coverage, **B**
  bristle streak of a picked-up second colour. Mipmapped, anisotropy 4, 10% empty margin so mips don't bleed.
- Per dab: cell from the seed, random mirror, optional end-for-end; pass `vAxis = (across*flip, along*end)`.
```glsl
vec4 t = texture(tBrush, vUv); if (t.g < 0.3) discard; vec2 e = vec2(1.5 / 512.0, 0.0);
float hu = texture(tBrush, vUv + e.xy).r - texture(tBrush, vUv - e.xy).r;
float hv = texture(tBrush, vUv + e.yx).r - texture(tBrush, vUv - e.yx).r;
float rake = dot(vAxis.xy * hu + vAxis.zw * hv, vec2(0.5, -0.7));   // gallery lamp at the canvas's upper left
vec3 col = mix(vC1, vC2, smoothstep(0.52, 0.78, t.b)) * mix(0.95, 1.04, t.r);
col = col * (1.0 + rake * 1.25) + vec3(1.0, 0.97, 0.9) * pow(max(rake, 0.0), 2.0) * 1.2;
outC = vec4(col, smoothstep(0.3, 0.62, t.g));                       // alpha feeds coverage (6)
```
- Gotcha: rotate the gradient to screen by the dab's own axes (flips included), or the lamp follows the stroke.

## 5. Three-mix palette lighting, linear output, no tone mapping

When: cel or painterly looks where an art director picks the shade colours and HDR range is unwanted.
```glsl
vec3 paint3(vec3 L, vec3 M, vec3 S, float lit, float r) {   // lit 0..1 SELECTS a paint, never multiplies
  lit += (r - 0.5) * 0.2;                                    // per-dab jitter: zone edges break dab by dab
  return mix(mix(S, M, smoothstep(0.24, 0.36, lit)), L, smoothstep(0.56, 0.7, lit)); }
```
- `lit` = `sunAt(pos) * clamp(N.L * k + b)`, **once per dab**; `jitter()` (hue turn about the grey axis, saturation
  and value push) gives broken colour; `hazed()` (distance mist, denser sunward) too: one colour per touch.
- `outputColorSpace = THREE.LinearSRGBColorSpace` + raw `ShaderMaterial`s + RGBA8: picked display values reach the
  screen untouched, nothing to tonemap. Gotcha: built-in lit materials assume linear radiance; keep them out.

## 6. Alpha-to-coverage on 4x MSAA instead of blending

When: soft, ragged edges on millions of overlapping marks with no sort. Cost: 4x MSAA colour + depth. All dabs are
opaque, depth-tested and -written, `alphaToCoverage: true`: order-independent, so nothing pops on reorder.
```js
new THREE.WebGLRenderer({ antialias: false });  // MSAA on the target (no samples = A2C is a hard cutout)
const rt = new THREE.WebGLRenderTarget(w, h, { samples: 4, depthTexture: new THREE.DepthTexture(w, h) });
```

## 7. The steady infinite ground: snapped quadtree rings

When: endless grass, litter, rocks or decals with distance LOD and zero swimming. Cost: one geometry of `n*n*per`
instances shared by L meshes (carpet 192*192*3 x 6 levels = 664k instances, most exit early).
```glsl
vec2 block = uOrigin + vec2(mod(k, N), floor(k / N)) - N * 0.5;   // uOrigin = floor(cam / cell): whole cells
if (uLevel < uTop - 0.5) { vec2 p = floor(block * 0.5);           // parent picks one quadrant; it draws that one
  if (p * 2.0 + step(0.5, hash4(p, s + (uLevel + 1.0) * 3.3).xy) == block) return false; }
vec2 cell = block;   // descend to the FINEST cell, the dab's identity, with the same hash + salt as the skip test:
for (float i = uLevel; i > 0.5; i -= 1.0) cell = cell * 2.0 + step(0.5, hash4(cell, s + i * 3.3).xy);
float lod = max(dist / uNear, 1.0); d.size *= lod;                // all properties from hash(finest cell)
d.alive = smoothstep(0.0, 1.0, uLevel + 1.0 - log2(lod));         // shrink out over one doubling
```
- Far dabs **are** near dabs: a coarse level redraws one finest child (same spot, colour, seed) larger; nearing, it
  shrinks back as its siblings grow in. `uNear = N * cell0 / 4 * 0.92`: each level is gone before its grid edge.
- Overlap order: lying dabs sit at a **fixed per-dab height** (`(0.03 + 0.07 * q.z) * pow(lod, 0.35)`), so depth
  decides who is on top identically from every side. Sink the underpainting mesh 4 cm so it never covers a dab.
  Gotcha: a skip-test hash or salt that differs from the parent's descent step doubles or drops dabs.

## 8. Shade: whole-dab static shadow, per-pixel glaze for movers

When: stylised shadows on instanced marks. Cost: one 4096x2560 depth render at boot; a 256x256 map per frame.
- **Still world**: render proxies (trunks + icosphere crown lobes, not 570k leaves) once into an ortho `DepthTexture`,
  `compareFunction = THREE.LessEqualCompare` + `LinearFilter` (free 2x2 PCF via `sampler2DShadow`). Sample at the
  dab centre: a shadow edge is a ragged line of whole dabs that never crawls. Procedural dapple outside the map.
- **Moving caster**: a small map following the hero (layer 1, `overrideMaterial`). Ground dabs (`glaze = 1`) carry
  shadow coords per corner and darken per pixel toward a tinted glaze, nudged by the brush streak:
```glsl
float lit = figSunSoft(vGlaze.xyz + vec3((t.b - 0.5) * 0.012, (t.r - 0.5) * 0.012, 0.0));   // 5 taps
col = mix(col * vec3(0.5, 0.38, 0.46) + vec3(0.03, 0.02, 0.06), col, lit);   // gotcha: per-DAB here flicks dabs
```

## 9. Mist per dab, sun in the mist per pixel

When: god rays without TAA. Cost: 22 x (1 PCF + up to 5 taps)/px, the `quality=low` cut. In the finish pass, rebuild
world position from resolved depth and march 22 steps (to 85 m) against `sunAt`; mist itself is per dab (5).
```glsl
float jit = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))); // IGN, NO time term
for (float i = 0.0; i < 22.0; i++) { float t = (i + jit) / 22.0, w = exp(-t * reach * 0.022);
  lit += sunAt(uEye + ray * t * reach) * w; wsum += w; }
col += glow * (lit / wsum - 0.34) * thick * streak;   // shaded air goes slightly darker than plain mist
```
Gotcha: a frame-varying jitter needs TAA to hide it, and TAA smears the marks. Shafts read only static + slow maps.

## 10. Finish pass: the canvas, not a filter

One fullscreen pass: linen weave in **screen pixels** (sines x noise), embossed by the impasto's upper-left light at
2.2%, screen-fixed on purpose (the canvas is the screen); shoulder `min(c, 0.8) + o / (1 + 5o)`; varnish S-curve 22%.

## 11. Draw order and stable stacking

`renderOrder` (sky -10/-9 no depth, underpaint 0, ground 2, bark 3, leaves 4, figure 5, airborne 6) only helps
early-z; depth decides. Card dabs step eye-ward along the view ray by a per-dab random amount of their own size:
```glsl
float lift = d.lift * max(half_.x, half_.y) * (0.6 + 0.8 * r.y);  vc.xyz *= 1.0 - min(lift / dist, 0.3);
// scaling about the eye keeps the pixel, moves depth nearer: clears its surface, fixed stacking, no z-fight
```
Negative lift (-0.2) sends dark inner leaves back. Underpaintings (land, trunks, skinned body) fill the gaps between
dabs and are themselves quantised in world space (0.32 m ragged squares, bind-pose noise), so the gaps hold still.

## 12. Budget

~1.5M instances (ground ~885k, leaves ~570k), ~18 dab draws, no CPU culling: 4.6 ms at 1080p on an RTX 4090 (README,
only GPU measured). Pixel ratio <= 1.5; `compileAsync` + 5 fenced warm-up frames. Weaker GPUs: cut levels first.

## Stability checklist (any stylised look)

1. **Hash every choice from a world-stable ID** (cell, pin, prebuilt instance), never pixel, frame or instance slot.
   Snap moving grids to whole world cells.
2. **LOD is the same mark, larger**, never a swap; fade out before a grid edge recycles instances.
3. **Grow and shrink, never fade alpha**; thinning survivors scale by `1/sqrt(keep)` to hold coverage.
4. **Order-independent edges** (A2C on MSAA, or cutouts) and **fixed per-mark depth offsets**: no sorting.
5. **Clamp mark size in pixels**, both ends; degenerate orientations fall back to a per-mark constant.
6. **Light and fog once per mark** for static inputs, per pixel only for movers; static shadows baked in world space.
7. **Noise is time-less** (IGN, no frame term), so no TAA; the gaps between marks are world-quantised too.
8. **Measure it**: two still frames 1/3 s apart, PSNR over a fixed crop ("inf" = identical), as a regression test.

## Adapting to other styles

- **Toon/cel**: `paint3` with two or three picked bands; outlines from inverted-hull geometry, not an edge filter.
- **Hatching/ink**: ticks along a world tangent; tone = ticks past a hashed per-tick threshold, grown in by length.
- **Pixel art**: snap the camera to whole texels of a low-res target; the pixel clamp becomes a 1-texel minimum.
- **Watercolour**: soft pigment blots via coverage, granulation in the atlas, paper grain screen-fixed like the weave.
