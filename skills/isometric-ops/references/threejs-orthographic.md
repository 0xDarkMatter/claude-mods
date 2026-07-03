# Three.js Orthographic — the isometric delta

This file owns **only what is isometric-specific** about three.js: the orthographic
camera rig, the two iso idioms, frustum sizing and its resize gotcha, pixel-perfect
sprite export, constraining `OrbitControls` to keep the iso feel, iso-consistent
lighting/shadows, and baking 8-direction sprites from a scene.

**Boundary — cross-link, do not duplicate:**
- General three.js scaffolding (minimal scene, animation loop, `OrbitControls` basics,
  three-point lighting, `InstancedMesh`, post-processing/bloom, custom `ShaderMaterial`)
  lives in the sibling **`genart-ops`** skill (§1 "Three.js — Scene Scaffolding"). This
  file assumes you already have a `renderer`, `scene`, and render loop from there.
- App/game-scale three.js (GLTF asset pipeline, react-three-fiber, `InstancedMesh` for
  large maps, draw-call budgeting) is the sibling **`threejs-ops`** skill's territory.
- Directional-light colour ramps and perceptual palette work belong to **`color-ops`**;
  the three-tone plane doctrine referenced here is codified in
  `references/style-guide.md`.
- The projection constants (35.264°, 81.65 %, √(3/2), the rig-angle table) are derived in
  `references/projection-math.md` — this file cites them, it does not re-derive them.

> **Terminology.** "Isometric" here means the **true isometric projection** (all three
> cube faces equal). Where a rig instead produces the **2:1 dimetric** look (commonly
> called isometric in games — top face twice as wide as tall), it is labelled
> **2:1 dimetric** explicitly. See `references/projection-math.md`.

---

## 1. Why orthographic, and the projection decision first

An isometric image has **no perspective foreshortening**: distant geometry is drawn at
the same scale as near geometry, parallel world lines stay parallel on screen. A
`PerspectiveCamera` cannot do this — its whole job is foreshortening. So **step one of any
three.js iso scene is to use `THREE.OrthographicCamera`**, never `PerspectiveCamera`.

The second decision — made before you touch the rig — is *which projection*:

| Goal | Projection | Camera pitch (rotX) | Result |
|---|---|---|---|
| Web/vector "true iso" look, all faces equal | **True isometric** | **54.736°** | cube's three visible faces render identical |
| Game tiles, pixel art, "isometric" games | **2:1 dimetric** | **60°** | cube top renders exactly 2× wide as tall |

Both are correct three.js orthographic rigs; they are *different projections*. Picking the
wrong one is the most common iso-in-three.js mistake — a "true iso" 54.736° rig will make
your 64×32 game tiles fail to tile, and a 60° dimetric rig will not give the symmetric
all-faces-equal illustration look. Decide, then rig.

Source: SRC-A ch.2 (Three.js section); rig-angle table in `references/projection-math.md`.
OrthographicCamera reference: <https://threejs.org/docs/#api/en/cameras/OrthographicCamera>.

---

## 2. The two idioms — position/lookAt vs exact rotation

There are two ways to point an orthographic camera into iso. **Both are used in the wild;
they are not equivalent.** Prototype with the first, switch to the second when you need
mathematically exact iso.

### Idiom A — position/lookAt (the fast prototype)

Place the camera on the scene diagonal and aim it at the origin. Simple, forgiving, and
what most CodePen iso demos use.

```js
// genart-ops gives you renderer + scene; this is the iso camera on top of that.
const aspect = container.clientWidth / container.clientHeight;
const d = 60;                                   // half-height of the frustum in world units
const camera = new THREE.OrthographicCamera(
  -d * aspect, d * aspect,                       // left, right
   d,          -d,                               // top, bottom
   1, 2000                                        // near, far
);
camera.position.set(10, 10, 10);                 // equal on all three axes => iso diagonal
camera.lookAt(scene.position);                   // (0, 0, 0)
```

`position.set(10,10,10)` sits the camera on the (1,1,1) diagonal. Because the three
components are **equal**, the view direction is the iso diagonal — this yields a *true*
isometric view (all faces foreshortened equally). For a 2:1 dimetric look with this idiom,
raise the Y component relative to X/Z until the cube top renders 2× wide as tall (an
`(x, y, z)` with `y/√(x²+z²) = tan 30° = 0.577…`, e.g. `(10, 8.165, 10)`), or use Idiom B
with `rotX = 60°`, which is cleaner and exact.

*Source: CodePen `notjiam/EqyGOa` "Isometric Camera and Colors" (SRC-A). Matt DesLauriers'
Frontend Masters "Creative Coding with Canvas & WebGL" iso lesson uses the same
switch-Perspective-to-Orthographic move for the Monument Valley look (SRC-A).*

### Idiom B — exact rotation (mathematically true iso)

Set the tilt directly instead of trusting eyeballed positions. This is the
copy-paste-exact true-iso rig.

```js
const camera = new THREE.OrthographicCamera(
  -d * aspect, d * aspect, d, -d, 1, 2000
);
camera.rotation.order = 'YXZ';                   // yaw (Y) applied before pitch (X): order matters
camera.rotation.y = -Math.PI / 4;                // -45°  azimuth (spin around the diagonal)
camera.rotation.x = Math.atan(-1 / Math.sqrt(2));// -35.264°  the true-iso tilt
camera.position.set(0, 0, 0);
camera.translateZ(500);                          // pull the camera back along its own -Z
```

The two magic numbers:

- **`rotation.y = -π/4` (−45°)** — spins the camera so a world corner faces the viewer.
- **`rotation.x = atan(-1/√2) = −35.264389°`** — the **canonical true-iso tilt**. It is
  `−arctan(1/√2) = −arcsin(1/√3)`, the same 35.264° that appears everywhere in
  `references/projection-math.md` (cube-tilt angle; `cos 35.264° = √(2/3) = 0.81650`, the
  axonometric foreshortening). `rotation.order = 'YXZ'` is required so the −45° yaw is
  applied *before* the pitch; with the default `'XYZ'` order the axes compose in the wrong
  sequence and the tilt is off.

Verify numerically: `Math.atan(-1/Math.sqrt(2))` → `-0.6154797086703873` rad →
`-35.26439°`. And `90° − 35.264° = 54.736°`, which is the Blender `rotX` for true iso —
the two rigs describe the same projection from camera-space vs world-space (see
`references/blender-prerender.md`).

For **2:1 dimetric** with Idiom B, replace the pitch with the 30°-elevation value:
`camera.rotation.x = -Math.atan(1/2)` is **not** what you want (that is the
ground-line 26.565° angle) — the dimetric camera *pitch* is 60° from vertical / 30°
elevation, i.e. `camera.rotation.x = -(Math.PI/2 - Math.PI/6) = -Math.PI/3` (−60°). The
tell is the render: the cube top is exactly twice as wide as tall.

*Source: react-three-fiber discussion #895 (SRC-A) for the `atan(-1/√2)` rotation idiom.*

---

## 3. Frustum sizing and the resize-recompute gotcha

An `OrthographicCamera`'s `left/right/top/bottom` define a **fixed-size viewing box** in
world units. Unlike a perspective camera (where you just update `.aspect`), an ortho
camera has *no* aspect field — the aspect ratio is baked into the left/right vs top/bottom
spread. **If you don't recompute the frustum on resize, the scene stretches.** This is the
single most common iso-three.js bug (three.js forum #37894, cited in SRC-A).

Pick a **`viewSize`** (the world-unit half-height the frustum should always show) and drive
left/right from the container aspect:

```js
const viewSize = 60;                             // world units visible top-to-bottom (half)

function resizeIsoCamera(camera, renderer, container) {
  const w = container.clientWidth;
  const h = container.clientHeight;
  const aspect = w / h;

  camera.left   = -viewSize * aspect;
  camera.right  =  viewSize * aspect;
  camera.top    =  viewSize;
  camera.bottom = -viewSize;
  camera.updateProjectionMatrix();               // MANDATORY after touching frustum bounds

  renderer.setSize(w, h);
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
}

const ro = new ResizeObserver(() => resizeIsoCamera(camera, renderer, container));
ro.observe(container);
resizeIsoCamera(camera, renderer, container);    // run once on init
```

Rules:

- **Always call `camera.updateProjectionMatrix()`** after mutating `left/right/top/bottom`.
  Forgetting it is why "I changed the frustum but nothing happened."
- Anchor on **half-height** (`top = viewSize`, `bottom = -viewSize`) and let width follow
  aspect, so the vertical scale of your iso content is stable across window sizes — content
  reveals/hides horizontally instead of scaling.
- `renderer.setPixelRatio(Math.min(devicePixelRatio, 2))` caps HiDPI cost; for
  pixel-perfect sprite work (§4) you often force `1` instead.

---

## 4. Pixel-perfect ortho — mapping world units to CSS px, and sprite export

For crisp sprite export (baking iso tiles/objects to PNG), you want an **exact,
integer** relationship between world units and output pixels — otherwise edges land on
fractional pixels and blur.

### 4.1 Exact world→pixel scale

Because ortho has no depth-scaling, the mapping is a single constant:

```
pixelsPerWorldUnit = outputHeightPx / (2 * viewSize)      // frustum is 2*viewSize tall
```

To make one world unit equal exactly *N* device pixels, invert it — choose `viewSize` from
the desired output height:

```js
// Want a 512px-tall render where 1 world unit == 8 px?  viewSize = 512 / (2*8) = 32.
const targetPx = 512;
const pxPerUnit = 8;
const viewSize = targetPx / (2 * pxPerUnit);     // = 32
```

Then render at `renderer.setPixelRatio(1)` and a canvas whose height is `targetPx`, and
disable any anti-aliasing you don't want smearing sprite edges
(`new THREE.WebGLRenderer({ antialias: false })`; set
`texture.magFilter = THREE.NearestFilter` on pixel-art textures — see
`references/pixel-art-workflow.md`).

### 4.2 Render-to-target and export at 1×/2×/4×

Bake to an offscreen `WebGLRenderTarget` (transparent background), read it back, and emit
PNG data at multiple scales for @1x/@2x/@4x asset sets:

```js
function bakeSprite(renderer, scene, camera, sizePx, scale = 1) {
  const px = sizePx * scale;
  const rt = new THREE.WebGLRenderTarget(px, px, {
    minFilter: THREE.NearestFilter,
    magFilter: THREE.NearestFilter,
    format: THREE.RGBAFormat,                     // alpha => transparent background
  });

  const prevClear = renderer.getClearAlpha();
  renderer.setClearColor(0x000000, 0);            // fully transparent
  renderer.setRenderTarget(rt);
  renderer.clear();
  renderer.render(scene, camera);

  const buf = new Uint8Array(px * px * 4);
  renderer.readRenderTargetPixels(rt, 0, 0, px, px, buf);
  renderer.setRenderTarget(null);
  renderer.setClearAlpha(prevClear);

  // WebGL origin is bottom-left; flip rows to top-left for image/PNG conventions.
  return flipRowsRGBA(buf, px, px);               // Uint8ClampedArray -> ImageData -> canvas -> toBlob
}
```

Two export paths:

- **`renderer.domElement.toDataURL('image/png')` / `.toBlob()`** — simplest: render to the
  on-screen canvas with `preserveDrawingBuffer: true`, then grab a data URL/blob. Good for
  one-off exports; `preserveDrawingBuffer` has a small perf cost, so gate it behind an
  export flag rather than leaving it on.
- **RenderTarget + `readRenderTargetPixels`** (above) — the robust path: transparent
  background, exact size independent of the visible canvas, and you can loop scales/directions
  without disturbing the live view. WebGL's pixel origin is **bottom-left**, so flip rows
  before handing bytes to a top-left `ImageData`/PNG encoder.

For power-of-two/padded packing of the resulting frames into a spritesheet + atlas, hand the
PNGs to `scripts/sheet-pack.py`.

*Source: SRC-A ch.2 (Three.js OrthographicCamera as the web-native sprite-baking route,
the alternative to Blender in `references/blender-prerender.md`).*

---

## 5. Constraining OrbitControls to keep the iso feel

`OrbitControls` (general setup is in `genart-ops` §1) will happily let the user drag the
camera out of iso and re-introduce perspective-looking angles. To let users *orbit* while
preserving the isometric character, **lock the polar angle** and (optionally) **snap the
azimuth to 45° steps** — the four/eight canonical iso viewpoints.

```js
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const controls = new OrbitControls(camera, renderer.domElement);
controls.enablePan     = true;
controls.enableZoom    = true;                    // ortho zoom = camera.zoom, not dolly
controls.enableRotate  = true;

// Freeze the tilt to the true-iso polar angle so faces stay equal:
const isoPolar = Math.acos(1 / Math.sqrt(3));     // = 54.7356°  (complement of 35.264°)
controls.minPolarAngle = isoPolar;
controls.maxPolarAngle = isoPolar;                // min == max => tilt is locked

// Optional: allow only the 4 iso corners by snapping azimuth on change.
controls.addEventListener('change', () => {
  const step = Math.PI / 2;                        // 90° corners; use Math.PI/4 for 8 directions
  const snapped = Math.round(controls.getAzimuthalAngle() / step) * step;
  if (Math.abs(controls.getAzimuthalAngle() - snapped) > 1e-4) {
    controls.setAzimuthalAngle(snapped);           // three r132+
  }
});
```

Notes:

- **Ortho "zoom" is `camera.zoom`**, not a dolly — `OrbitControls` drives `camera.zoom` and
  calls `updateProjectionMatrix()` for you. Set `controls.minZoom` / `controls.maxZoom` to
  bound it. Physically moving the camera closer does nothing for an ortho camera (no
  foreshortening), which is exactly the property that makes iso work.
- **`minPolarAngle === maxPolarAngle`** freezes the tilt. Use the true-iso polar angle
  `acos(1/√3) = 54.7356°` (that is `90° − 35.264°`, the angle down from the world +Y axis).
  For a locked 2:1 dimetric feel use `acos` of the dimetric elevation instead (30°
  elevation → polar `60°`).
- **y-up convention.** three.js is **Y-up**; build your iso ground on the **XZ plane** and
  treat +Y as elevation/height. This matches the Blender rigs (which are Z-up) once the
  camera is placed, and keeps `screenY` growing "down the diamond" as tile `(x+z)`
  increases. Keep this consistent with the coordinate math in
  `references/coordinates-depth.md`.

---

## 6. Lighting and shadows for isometric

Iso illustration lives or dies on **one consistent light direction across the entire asset
set** (the three-tone plane doctrine — top lightest, one side mid, one side dark — is
codified in `references/style-guide.md`). In three.js that means a single
**`DirectionalLight`** whose angle is fixed and matches the projection, plus fill so the
dark face never goes black.

```js
// Key light: fixed 45° azimuth, ~45-55° elevation => a top face + two clearly separated
// side tones, consistent with the three-tone doctrine.
const key = new THREE.DirectionalLight(0xffffff, 2.2);
key.position.set(-6, 10, -6);                     // upper-back-left in XZ-ground space
key.castShadow = true;

const fill = new THREE.HemisphereLight(0xbfd4ff, 0x30303a, 0.6); // sky/ground fill
const ambient = new THREE.AmbientLight(0xffffff, 0.25);          // lift the dark face off black
scene.add(key, fill, ambient);
```

Shadow rig for iso (the shadow camera is itself orthographic — tighten it to the scene):

```js
key.shadow.mapSize.set(2048, 2048);
const sc = key.shadow.camera;                     // an OrthographicCamera
sc.left = -40; sc.right = 40; sc.top = 40; sc.bottom = -40;   // wrap the whole map footprint
sc.near = 0.5; sc.far = 200;
sc.updateProjectionMatrix();
key.shadow.bias = -0.0005;                        // kill shadow acne on flat iso planes
renderer.shadowMap.enabled = true;
renderer.shadowMap.type = THREE.PCFSoftShadowMap; // soft long iso shadows
```

Doctrine points:

- **One light direction, whole set.** If you bake sprites per-direction (§7), keep the light
  in **world space fixed** and rotate the *subject*, so every direction is lit identically —
  do **not** rotate the camera+light together, or each facing gets a different shadow logic.
- **Soft, long shadows along the plane angles.** `PCFSoftShadowMap` + a low-angle key gives
  the characteristic long iso shadow; cast onto a large receiver plane, or bake a separate
  shadow sprite.
- **Tighten the shadow ortho camera** to the map footprint — a loose shadow frustum wastes
  resolution and produces chunky shadow edges on the flat iso faces.
- Directional-light *colour* (warm key / cool fill temperature ramps) is a `color-ops`
  concern — cross-link, don't tune colour science here.

---

## 7. Baking 8-direction sprites from a three.js scene

The web-native alternative to the Blender 8-direction rig
(`references/blender-prerender.md`): rotate the **subject** (not the camera) through 8
yaw steps and export each with the §4 sprite-bake, giving `name_dir_variant.png` frames
for engines/tilesets.

```js
// Parent the model to a pivot; rotate the PIVOT, keep camera + light fixed in world space.
const pivot = new THREE.Group();
pivot.add(model);
scene.add(pivot);

const DIRECTIONS = 8;                              // N, NE, E, SE, S, SW, W, NW
const names = ['n','ne','e','se','s','sw','w','nw'];
const frames = [];

for (let i = 0; i < DIRECTIONS; i++) {
  pivot.rotation.y = (i / DIRECTIONS) * Math.PI * 2;   // 45° per step
  const png = bakeSprite(renderer, scene, camera, 128, 1);  // §4.2
  frames.push({ name: `hero_${names[i]}`, png });
}
// -> write frames to disk, then pack with scripts/sheet-pack.py into a sheet + atlas.
```

Why rotate the subject and not the camera:

- The **light and shadow stay fixed** in world space, so all 8 facings share identical
  three-tone shading — a hard requirement for a coherent sprite set (§6).
- The camera frustum, zoom, and pixel-per-unit calibration (§4) never change, so every
  frame lands on the same pixel grid — no per-direction re-alignment.
- For 4-direction sets use `DIRECTIONS = 4` (90° steps); mirror-symmetric subjects can bake
  5 and flip in-engine (`flipX`) to save frames — the `flipX` field exists in the
  iso-studio app's `scene-schema.json` for exactly this.

Anchor/pivot: keep the model's **visual feet at the pivot origin** so every baked frame
shares the feet-anchor the depth sort expects (`references/coordinates-depth.md`), and the
atlas pivot maps cleanly into Godot/Unity (`references/engine-integration.md`).

*Source: SRC-A ch.2 (Three.js as the programmatic 3D→iso route) and the Blender
8-direction parented-empty rig it parallels.*

---

## 8. Gotcha recap (three.js iso-specific)

| Gotcha | Fix |
|---|---|
| Used `PerspectiveCamera` → things get smaller with distance | Use `OrthographicCamera`; iso requires zero foreshortening (§1). |
| Chose the wrong rig → game tiles don't tile / illustration not symmetric | Decide **true iso (54.736° pitch)** vs **2:1 dimetric (60° pitch)** first (§1). |
| `rotation.x` tilt looks wrong | Set `rotation.order = 'YXZ'` before `y=-π/4; x=atan(-1/√2)` (§2 Idiom B). |
| Scene stretches on window resize | Recompute `left/right/top/bottom` from aspect **and** call `updateProjectionMatrix()` (§3). |
| Sprite edges blur on export | Force `pixelRatio = 1`, integer `pixelsPerWorldUnit`, `antialias:false` + `NearestFilter` (§4). |
| Exported PNG is upside-down | WebGL pixel origin is bottom-left; flip rows before `ImageData` (§4.2). |
| Ortho "dolly" does nothing | Ortho zoom is `camera.zoom` (bound with `min/maxZoom`), not camera distance (§5). |
| OrbitControls breaks the iso angle | Lock `min/maxPolarAngle` to `acos(1/√3)=54.736°`; optionally snap azimuth (§5). |
| Each baked direction lit differently | Rotate the **subject**, keep camera+light fixed in world space (§6, §7). |
| Shadow edges chunky / shadow acne | Tighten the shadow ortho frustum to the footprint; `shadow.bias = -0.0005` (§6). |

---

## Related skills & references

- **`genart-ops`** — general three.js scene scaffolding (renderer, loop, controls, lighting,
  InstancedMesh, post-processing). Start there; this file is the iso overlay.
- **`threejs-ops`** — app/game-scale three.js (GLTF pipeline, react-three-fiber,
  InstancedMesh at map scale).
- **`color-ops`** — light/palette colour science; directional-light temperature ramps.
- `references/projection-math.md` — where 35.264°, 54.736°, 81.65 %, √(3/2) are derived.
- `references/blender-prerender.md` — the Blender counterpart to §7's sprite bake (both rigs).
- `references/coordinates-depth.md` — feet-anchor + depth-sort the baked frames feed into.
- `references/engine-integration.md` — importing the packed sheet/atlas into Godot/Unity.
- `references/pixel-art-workflow.md` — `NearestFilter` and pixel-neat stepping for §4 exports.
- `references/style-guide.md` — the three-tone plane doctrine §6's lighting serves.

### Source citations

- SRC-A (compass artifact, ch.2 "Programmatic / Code-Based Generation", Three.js section):
  OrthographicCamera as the base primitive; the position/lookAt vs exact-rotation idioms;
  the resize-frustum gotcha; three.js as the web-native sprite-baking route.
- three.js `OrthographicCamera`: <https://threejs.org/docs/#api/en/cameras/OrthographicCamera>
- CodePen `notjiam/EqyGOa` "Isometric Camera and Colors" — position/lookAt idiom.
- react-three-fiber discussion #895 — the `camera.rotation.x = Math.atan(-1/Math.sqrt(2))`
  true-iso tilt.
- three.js forum thread #37894 — the OrthographicCamera resize distortion.
- Matt DesLauriers, Frontend Masters "Creative Coding with Canvas & WebGL", isometric lesson
  — Perspective→Orthographic for the Monument Valley look.
- OrbitControls: <https://threejs.org/docs/#examples/en/controls/OrbitControls>

*Numeric anchors (verify against `references/projection-math.md`): true-iso tilt
`atan(1/√2) = 35.26439°`; camera pitch complement `54.73561°`; `cos 35.264° = √(2/3) =
0.81650`; undo-foreshorten factor `√(3/2) = 1.22474`; 2:1 dimetric camera pitch `60°`
(30° elevation, `sin 30° = 0.5`).*
