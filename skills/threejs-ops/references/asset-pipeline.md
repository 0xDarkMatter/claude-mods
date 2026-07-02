# GLTF asset pipeline

glTF 2.0 (`.glb` binary) is three.js's first-class asset format: PBR materials,
skeletal + morph animation, extensions for every compression scheme. Everything
else (FBX, OBJ) gets converted **to** glTF in the pipeline, not loaded at runtime.

## 1. Loader wiring — all three decoders, once

An optimized `.glb` may use any combination of DRACO (geometry), KTX2/BasisU
(textures), and meshopt (geometry + animation). Wire all three at startup so the
loader handles anything; unused decoders cost nothing until a file needs them.

```javascript
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { DRACOLoader } from 'three/addons/loaders/DRACOLoader.js';
import { KTX2Loader } from 'three/addons/loaders/KTX2Loader.js';
import { MeshoptDecoder } from 'three/addons/libs/meshopt_decoder.module.js';

export function makeGLTFLoader(renderer) {
  const draco = new DRACOLoader()
    // Google-hosted WASM decoder; or self-host three's copy from
    // node_modules/three/examples/jsm/libs/draco/gltf/
    .setDecoderPath('https://www.gstatic.com/draco/versioned/decoders/1.5.7/');

  const ktx2 = new KTX2Loader()
    .setTranscoderPath('https://cdn.jsdelivr.net/npm/three@0.185.1/examples/jsm/libs/basis/')
    .detectSupport(renderer);   // REQUIRED, and requires the real renderer:
                                // picks the GPU's compressed format (ASTC/BC7/ETC2)

  return new GLTFLoader()
    .setDRACOLoader(draco)
    .setKTX2Loader(ktx2)
    .setMeshoptDecoder(MeshoptDecoder);
}
```

Gotchas:

- `detectSupport(renderer)` **before** the first load, with the renderer you'll
  actually render with. Forgetting it = "KTX2Loader: no supported transcoder" at
  load time.
- Decoder paths must end with a trailing `/`.
- Self-hosting beats CDN for production (offline, CSP, version lock): copy
  `three/examples/jsm/libs/draco/gltf/` and `libs/basis/` into your static dir
  and point the paths there.
- `loadAsync` returns `{ scene, animations, cameras, asset, parser }` — the
  model is `gltf.scene`, clips are `gltf.animations` (they are NOT attached to
  the scene).

## 2. Instantiating characters — SkeletonUtils

`gltf.scene.clone()` on a skinned mesh produces clones whose bones still point
at the original skeleton — animations play on one and glitch on the rest. Use:

```javascript
import * as SkeletonUtils from 'three/addons/utils/SkeletonUtils.js';
const soldier2 = SkeletonUtils.clone(gltf.scene);   // deep clone incl. skeleton
```

Each clone needs its **own** `AnimationMixer` (see [animation.md](animation.md));
the `AnimationClip`s themselves are shared safely.

For **many** copies of a static (non-skinned) model, don't clone at all —
extract geometry + material and build an `InstancedMesh`
(see [scale-and-disposal.md](scale-and-disposal.md)).

## 3. Optimizing assets — do it offline, not at runtime

Two CLI tools; both read/write `.glb`. Run them in the asset build step, commit
the optimized output.

### gltf-transform (`@gltf-transform/cli`) — the scriptable toolbox

```bash
npm i -g @gltf-transform/cli

# The 90% command — resample animation, prune, dedupe, instance, compress:
gltf-transform optimize in.glb out.glb --compress draco --texture-compress ktx2

# Individual passes when you need control:
gltf-transform draco   in.glb out.glb                  # geometry → DRACO
gltf-transform meshopt in.glb out.glb                  # geometry+anim → meshopt
gltf-transform etc1s   in.glb out.glb                  # textures → KTX2 (small, lossy-ish)
gltf-transform uastc   in.glb out.glb --slots "{normalTexture}"  # normals need UASTC quality
gltf-transform resize  in.glb out.glb --width 1024 --height 1024
gltf-transform inspect in.glb                          # what's actually in this file
```

KTX2 encoding requires the KTX-Software `toktx` binary on PATH for some modes;
`etc1s`/`uastc` commands bundle an encoder. Rule of thumb: **ETC1S** for
color/albedo (4–8× smaller in GPU memory), **UASTC** for normal maps (ETC1S
artifacts wreck lighting).

### gltfpack (meshoptimizer) — the one-shot compressor

```bash
npm i -g gltfpack
gltfpack -i in.glb -o out.glb -cc -tc     # -cc meshopt compression, -tc KTX2 textures
```

Fastest path to a small file; meshopt decodes faster than DRACO at runtime.
Trade-off: DRACO usually wins on wire size for dense static meshes; meshopt
wins on decode speed and also compresses animation data. Either is a large win
over raw; don't ship uncompressed `.glb` above ~1 MB.

### Choosing

| Situation | Choice |
|---|---|
| Dense static scenery, wire size is king | DRACO |
| Characters/animation, decode speed matters, mobile | meshopt (gltfpack) |
| Texture-heavy anything | KTX2 always — GPU memory, not just download, shrinks |

## 4. CC0 / freely-licensed model sources

| Source | What | License |
|---|---|---|
| [Quaternius](https://quaternius.com) | Stylized low-poly packs — characters, animals, buildings, many **rigged + animated** | CC0 |
| [Kenney](https://kenney.nl/assets) | Huge coherent low-poly sets — city, nature, cars, UI | CC0 |
| [Poly Pizza](https://poly.pizza) | Searchable aggregator (incl. ex-Google Poly); filter CC0 | per-model (mostly CC0/CC-BY) |
| [Sketchfab](https://sketchfab.com) | Everything; filter "Downloadable" + CC0/CC-BY | per-model — check each |
| [ambientCG](https://ambientcg.com) | PBR **texture** sets (albedo/normal/roughness) | CC0 |
| [Mixamo](https://www.mixamo.com) | Auto-rigging + humanoid animation clips (FBX → convert to glb) | free with Adobe account, not CC0 |

Pipeline for game-ready ambient life: Quaternius rigged animal pack →
`gltf-transform optimize` → `SkeletonUtils.clone` per individual → mixer
crossfades ([animation.md](animation.md)) → steering
([actors-and-steering.md](actors-and-steering.md)).

## 5. Loading UX

- `loader.loadAsync(url)` + `Promise.all` for parallel loads; wrap in one
  `LoadingManager` for a progress bar (`manager.onProgress(url, n, total)`).
- Show the scene only after first render, not after load — compile shaders
  up front with `await renderer.compileAsync(scene, camera)` to avoid the
  first-frame hitch when a big material graph compiles mid-gameplay.
- Cache cross-page with normal HTTP caching; `THREE.Cache.enabled = true` only
  dedupes within a session and holds raw file data in memory — usually skip it.
