---
name: threejs-ops
description: "Application/game-scale three.js: ES modules, GLTF pipeline (DRACO/KTX2/meshopt), AnimationMixer, physics (rapier/cannon-es), react-three-fiber, and performance at scale (InstancedMesh, LOD, draw calls). Triggers on: three.js, GLTFLoader, r3f, game loop, WebGL memory leak, boids."
license: MIT
compatibility: "Web three.js r150+ (ES modules only — UMD builds removed in r160). check-three-facts.py is stdlib-only Python 3.10+."
metadata:
  author: claude-mods
  related-skills: "genart-ops, mapbox-ops, react-ops, javascript-ops, perf-ops"
---

# Three.js — application & game scale

Patterns for building three.js **applications and games**: module setup, asset
pipelines, animation, simulation loops, physics, the React ecosystem, and staying
fast (and leak-free) as scene complexity grows.

**Scope split with sibling skills** — do not duplicate them:

| Concern | Owner |
|---|---|
| Creative/generative three.js — scene scaffolding, GLSL shaders, particles, post-processing | [genart-ops](../genart-ops/SKILL.md) |
| three.js inside a Mapbox GL custom layer (`CustomLayerInterface`, threebox) | [mapbox-ops](../mapbox-ops/SKILL.md) |
| App/game-scale three.js — modules, assets, animation, loops, physics, R3F, scale | **this skill** |

---

## 1. ES-module reality (read this before writing any `<script>` tag)

three.js is **ES-modules only**. The legacy patterns are dead and will 404 or
silently break on any modern release:

| Dead pattern | Removed | Use instead |
|---|---|---|
| `examples/js/*` non-module loaders (`js/loaders/GLTFLoader.js`, `THREE.OrbitControls` globals) | **r148** | `three/addons/` module imports |
| `build/three.js` + `build/three.min.js` UMD builds (`<script src=…>` + global `THREE`) | **r160** | `build/three.module.js` via import map or bundler |

Versioning: npm publishes `0.<release>.<patch>` — `three@0.185.1` **is** r185.
Releases land monthly; pin exact versions.

### No-bundler setup (import map)

Copy [assets/importmap-starter.html](assets/importmap-starter.html) — a complete,
runnable starter (import map + addons + resize + `setAnimationLoop`). The core:

```html
<script type="importmap">
{
  "imports": {
    "three": "https://cdn.jsdelivr.net/npm/three@0.185.1/build/three.module.js",
    "three/addons/": "https://cdn.jsdelivr.net/npm/three@0.185.1/examples/jsm/"
  }
}
</script>
<script type="module">
  import * as THREE from 'three';
  import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
</script>
```

Gotchas: both entries MUST pin the **same version** (mixed versions =
`instanceof` failures across module copies); the `three/addons/` key needs the
trailing slash; import maps must appear **before** the first `type="module"`
script.

### Bundler vs no-bundler

| Situation | Choice |
|---|---|
| Real app/game, npm deps, physics WASM, R3F | **Vite** (`npm create vite@latest`) — default answer |
| Demo, CodePen, teaching, drop-in page on an existing site | **Import map** — zero build |
| `@dimforge/rapier3d` (WASM-bindgen) | Needs a bundler; use `rapier3d-compat` without one (§5) |

With a bundler, `import { X } from 'three/addons/…'` resolves via the package's
`exports` map — same specifier both worlds.

### WebGPU (know it exists; default to WebGL)

Since **r167** three ships a parallel build: `import { WebGPURenderer } from
'three/webgpu'` plus the TSL node-shader language from `three/tsl` (import-map
users: point the `"three"` key at `build/three.webgpu.js` **instead of**
`three.module.js` — it re-exports core; never load both). `WebGPURenderer`
falls back to WebGL2 automatically and initializes async (`await
renderer.init()`, or let `setAnimationLoop` defer for you). Default for
app/game work remains `WebGLRenderer` — reach for WebGPU when you need compute
(GPU crowds, particle sims) or TSL materials. Shader-level TSL/GLSL work is
[genart-ops](../genart-ops/SKILL.md) territory.

---

## 2. GLTF asset pipeline

glTF (`.glb`) is the format. Wire **all three decoders** once at startup so any
optimized asset loads; full setup, optimization CLI recipes (`gltf-transform`,
`gltfpack`), and CC0 model sources (Quaternius, Kenney, Poly Pizza) in
[references/asset-pipeline.md](references/asset-pipeline.md).

```javascript
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js';
import { KTX2Loader } from 'three/addons/loaders/KTX2Loader.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';

const draco = new DRACOLoader().setDecoderPath(
  'https://www.gstatic.com/draco/versioned/decoders/1.5.7/');
const ktx2 = new KTX2Loader()
  .setTranscoderPath('https://cdn.jsdelivr.net/npm/three@0.185.1/examples/jsm/libs/basis/')
  .detectSupport(renderer);              // MUST pass the live renderer

const loader = new GLTFLoader()
  .setDRACOLoader(draco).setKTX2Loader(ktx2).setMeshoptDecoder(MeshoptDecoder);

const { scene: model, animations } = await loader.loadAsync('hero.glb');
```

Cloning a skinned character for multiple instances needs
`SkeletonUtils.clone()` — a plain `.clone()` shares (and corrupts) the skeleton.

---

## 3. Animation system

`AnimationMixer` drives everything (skeletal + morph targets). One mixer per
model root; `mixer.update(dt)` every frame. Crossfades, blending weights,
one-shot clips, additive layers, and morph-target patterns in
[references/animation.md](references/animation.md).

```javascript
const mixer = new THREE.AnimationMixer(model);
const idle = mixer.clipAction(THREE.AnimationClip.findByName(animations, 'Idle'));
const run  = mixer.clipAction(THREE.AnimationClip.findByName(animations, 'Run'));
idle.play();
// smooth transition — never .stop() + .play()
run.reset().play();
idle.crossFadeTo(run, 0.3, /*warp*/ true);
```

---

## 4. Game loops

Render on rAF; simulate on a **fixed timestep** when gameplay/physics needs
determinism. Full accumulator pattern (with render interpolation), dt clamping,
tab-hidden handling, input sampling, and frame-rate-independent damping
(`MathUtils.damp`, follow cameras) in
[references/game-loop.md](references/game-loop.md).

```javascript
const FIXED = 1 / 60;
let acc = 0, last = performance.now();
renderer.setAnimationLoop((now) => {
  acc += Math.min((now - last) / 1000, 0.1);  // clamp: tab-switch dt spike
  last = now;
  while (acc >= FIXED) { simulate(FIXED); acc -= FIXED; }
  render(acc / FIXED);                         // interpolation alpha
});
```

Rules: use `renderer.setAnimationLoop` (not raw rAF — required for WebXR, and
it pauses cleanly); **clamp dt** or the first frame after a background tab
teleports everything; pause simulation on `document.hidden`
(`visibilitychange`); determinism = fixed step + seeded RNG + no per-frame
`Math.random()` in sim code.

---

## 5. Physics

**Default: `@dimforge/rapier3d`** (Rust/WASM — fast, deterministic, actively
developed, built-in kinematic character controller). `cannon-es` remains the
pure-JS fallback for zero-WASM constraints. Decision table, init patterns,
body/mesh sync, and character controllers in
[references/physics.md](references/physics.md).

The package-name trap:

| Package | When |
|---|---|
| `@dimforge/rapier3d` | Bundler with WASM support (Vite: works out of the box) |
| `@dimforge/rapier3d-compat` | No bundler / import map — WASM inlined as base64; `await RAPIER.init()` first |

```javascript
import RAPIER from '@dimforge/rapier3d-compat';
await RAPIER.init();
const world = new RAPIER.World({ x: 0, y: -9.81, z: 0 });
// step inside the FIXED loop (§4), then copy body → mesh:
world.timestep = FIXED; world.step();
mesh.position.copy(body.translation());
mesh.quaternion.copy(body.rotation());
```

---

## 6. react-three-fiber + drei

R3F v9 (React 19) renders the three.js scene graph declaratively;
[drei](https://github.com/pmndrs/drei) is its helper library. **When**: React
app, UI-heavy, want the pmndrs ecosystem (`@react-three/rapier`,
postprocessing). **When not**: no React on the page, engine-style tight control,
minimal bundle. Hooks, pitfalls (per-frame `setState` kills you — mutate refs in
`useFrame`), and the drei shortlist in
[references/r3f-drei.md](references/r3f-drei.md).

---

## 7. Scale patterns — staying fast, staying leak-free

Draw calls are the budget; GPU memory leaks are the debt. `renderer.info` is the
meter for both. InstancedMesh at count, LOD, culling, and the **full disposal
discipline** in [references/scale-and-disposal.md](references/scale-and-disposal.md).

Quick rules:

- **Same mesh × N ≥ ~50 → `InstancedMesh`** (one draw call). Set matrices via
  `setMatrixAt(i, m)`, then `instanceMatrix.needsUpdate = true`.
- Watch `renderer.info.render.calls` per frame — hundreds is fine, thousands is
  the problem. `renderer.info.memory.{geometries,textures}` must return to
  baseline after teardown.
- **Removing from the scene frees nothing.** GPU memory needs explicit
  `geometry.dispose()`, `material.dispose()`, **every texture** `.dispose()`,
  and `renderer.dispose()` on full teardown (SPA route change = the classic leak).

```javascript
function disposeObject(root) {
  root.traverse((o) => {
    o.geometry?.dispose();
    for (const m of Array.isArray(o.material) ? o.material : [o.material]) {
      if (!m) continue;
      for (const v of Object.values(m)) v?.isTexture && v.dispose();
      m.dispose();
    }
  });
  root.removeFromParent();
}
```

---

## 8. Ambient life — boids, steering, waypoints

Crowd/wildlife/NPC motion is steering forces + a spatial hash, driven from the
fixed loop and rendered via InstancedMesh. Seek/arrive/wander, the three boids
rules, waypoint drivers, and library options in
[references/actors-and-steering.md](references/actors-and-steering.md). For
structured game-state building blocks (actor motion controllers, waypoint
drivers, camera rigs) see
[xt4d/GameBlocks](https://github.com/xt4d/GameBlocks) — agent-oriented,
self-explanatory reference implementations.

---

## Bundled resources

| Resource | Load when |
|---|---|
| [references/asset-pipeline.md](references/asset-pipeline.md) | Loading/optimizing GLTF, decoder wiring, sourcing CC0 models |
| [references/animation.md](references/animation.md) | Crossfades, blend weights, one-shots, morph targets |
| [references/game-loop.md](references/game-loop.md) | Fixed timestep, interpolation, pause/visibility, input sampling, damping/follow-cam, determinism |
| [references/physics.md](references/physics.md) | rapier vs cannon-es, init, sync, character controllers |
| [references/r3f-drei.md](references/r3f-drei.md) | React Three Fiber apps, drei helpers, R3F pitfalls |
| [references/scale-and-disposal.md](references/scale-and-disposal.md) | Instancing, LOD, culling, draw-call budgets, disposal/leaks |
| [references/actors-and-steering.md](references/actors-and-steering.md) | Boids, steering, waypoint actors, ambient life |
| [assets/importmap-starter.html](assets/importmap-starter.html) | Starting a no-bundler project — copy and edit |
| [assets/three-facts.json](assets/three-facts.json) | Canonical version gates + package facts (verifier input) |

**Staleness verifier** — this skill encodes fast-moving facts (three version
gates, npm package names/versions). Check internal consistency (CI) or live
drift against the npm registry:

```bash
python3 skills/threejs-ops/scripts/check-three-facts.py --offline   # structural, no network — PR CI
python3 skills/threejs-ops/scripts/check-three-facts.py --live      # npm registry probe — exit 10 drift, 7 unreachable
python3 skills/threejs-ops/scripts/check-three-facts.py --offline --json | jq '.data[] | select(.status!="ok")'
```
