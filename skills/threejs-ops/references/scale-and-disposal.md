# Scale patterns — draw calls, instancing, LOD, and disposal discipline

Two failure modes as scenes grow: **frame time** (too many draw calls) and
**memory** (GPU resources never freed). Both are measurable — never optimize
blind.

## 1. The meter: `renderer.info`

```javascript
renderer.info.render;   // { calls, triangles, points, lines }  — resets per frame
renderer.info.memory;   // { geometries, textures }             — live GPU allocations
```

- **Draw calls** are the usual ceiling, not triangles. A modern GPU eats
  millions of triangles; a thousand `drawElements` calls of CPU overhead is
  what drops frames. Budget order-of-magnitude: **≤ ~200 calls mobile,
  ≤ ~1000 desktop** — then measure.
- `info.memory` is the leak detector: after any teardown (level unload, route
  change), `geometries`/`textures` must return to baseline. If they climb per
  reload, you have a disposal bug (§5).

Each visible `Mesh` = ≥1 draw call (×N for multi-material). The scale toolkit
below is all about collapsing that count.

## 2. InstancedMesh — same geometry × N in one draw call

The single highest-leverage tool. Threshold: **~50+ copies** of the same
geometry+material → instance them; at 1,000+ it's not optional.

```javascript
const mesh = new THREE.InstancedMesh(geometry, material, COUNT);
mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);   // if updated per frame

const m = new THREE.Matrix4(), p = new THREE.Vector3(),
      q = new THREE.Quaternion(), s = new THREE.Vector3(1, 1, 1);
for (let i = 0; i < COUNT; i++) {
  p.set(rand(), 0, rand());
  q.setFromAxisAngle(UP, rand() * Math.PI * 2);
  mesh.setMatrixAt(i, m.compose(p, q, s));
}
mesh.instanceMatrix.needsUpdate = true;                 // after ANY setMatrixAt batch
scene.add(mesh);
```

- Forgetting `instanceMatrix.needsUpdate = true` = nothing moves, no error.
- Per-instance color: `setColorAt(i, color)` + `instanceColor.needsUpdate`
  (material color must be white to show through).
- Frustum culling is all-or-nothing per InstancedMesh: three culls the whole
  batch by its bounding sphere. Compute it (`mesh.computeBoundingSphere()`)
  after placing instances, or set `frustumCulled = false` if instances span
  the whole world.
- "Remove" an instance by scaling its matrix to 0 or compacting
  `count` (draw first N only: `mesh.count = liveCount`).
- Raycasting works (`intersection.instanceId`); at large counts add
  three-mesh-bvh.
- Skinned meshes can't be instanced this way — crowds of characters use a few
  LOD tiers of real clones, or vertex-animation-texture techniques.

Related: `BufferGeometryUtils.mergeGeometries([...])` bakes *different static*
geometries sharing one material into one draw call (loses per-object
visibility/movement — right for scenery, wrong for actors).

## 3. LOD

```javascript
const lod = new THREE.LOD();
lod.addLevel(highMesh, 0);       // used when distance < 25
lod.addLevel(midMesh, 25);
lod.addLevel(lowMesh, 60);
lod.addLevel(new THREE.Object3D(), 150);   // empty = culled beyond 150
scene.add(lod);                  // lod.update(camera) is automatic in the renderer
```

- Generate levels offline: `gltf-transform simplify` (meshoptimizer under the
  hood) at ~50% / ~15% ratios ([asset-pipeline.md](asset-pipeline.md)).
- LOD multiplies draw calls per object (only one level renders, but each LOD
  object is still its own call) — combine with instancing by keeping one
  InstancedMesh **per LOD tier** and re-bucketing instances by camera distance
  every few hundred ms, not per frame.
- Texture LOD is free (mipmaps); geometry LOD is what you manage.

## 4. Culling

- **Frustum culling is on by default** per object (`frustumCulled = true`),
  tested against `geometry.boundingSphere`. Objects whose vertices move in a
  shader (GPU wind, displacement) pop out at screen edges — their CPU-side
  bounds are stale; fix bounds or disable culling for those.
- **Occlusion culling does not exist built-in.** Options, in effort order:
  don't need it (most games) → cells/rooms you toggle by player zone →
  distance fog + far-plane pull-in → `WebGLRenderer` occlusion queries via
  raycast heuristics or three-mesh-bvh visibility checks. If genuinely
  occlusion-bound indoors, structure the level into portals/zones manually.
- Shadows have their own scene walk: set `castShadow`/`receiveShadow`
  deliberately, keep the shadow camera tight, and give distant scenery
  `castShadow = false` — shadow draw calls count double.

## 5. Disposal discipline — GPU memory is manual

**`scene.remove(obj)` frees nothing.** JS GC cannot see GPU buffers; three
holds them until you call `.dispose()`. The contract:

| Resource | Free with |
|---|---|
| `BufferGeometry` | `geometry.dispose()` |
| `Material` | `material.dispose()` — does **not** dispose its textures |
| `Texture` (every map: `map`, `normalMap`, `envMap`, …) | `texture.dispose()` |
| Render targets | `renderTarget.dispose()` |
| Skeletons (skinned) | `mesh.skeleton.dispose()` (frees boneTexture) |
| The renderer itself | `renderer.dispose()` + `renderer.setAnimationLoop(null)` |

The traversal that gets all of it:

```javascript
function disposeObject(root) {
  root.traverse((o) => {
    o.geometry?.dispose();
    o.skeleton?.dispose?.();
    const mats = Array.isArray(o.material) ? o.material : [o.material];
    for (const m of mats) {
      if (!m) continue;
      for (const v of Object.values(m)) v?.isTexture && v.dispose();
      m.dispose();
    }
  });
  root.removeFromParent();
}
```

- **Shared resources**: dispose only when the *last* user goes away — either
  refcount, or (simpler) treat shared assets as app-lifetime and dispose only
  per-level objects.
- **SPA teardown** (React/Vue route unmount) is the classic leak: the full
  sequence is stop loop → `disposeObject(scene)` → `renderer.dispose()` →
  remove canvas → drop all references. Verify with `renderer.info.memory`
  before/after. Losing the WebGL context entirely:
  `renderer.forceContextLoss()` as the nuclear last step.
- Materials replaced at runtime (`mesh.material = newMat`) leak the old one —
  dispose what you swap out.
- R3F: JSX-created objects auto-dispose on unmount; anything you `new` or load
  imperatively is still yours ([r3f-drei.md](r3f-drei.md)).

## 6. Texture memory (the other half of "why is GPU memory huge")

- A 4096² RGBA texture is **64 MB+ with mipmaps** — before compression.
  KTX2/BasisU stays compressed *on the GPU* (4–8× less)
  ([asset-pipeline.md](asset-pipeline.md)); PNG/JPG decompress to full size.
- Cap sizes: 1024² covers most game props; 2048² for hero assets.
- `renderer.capabilities.maxTextureSize` on mobile can be 4096 — larger inputs
  get silently downscaled (slow) or fail.

## 7. Scaling checklist (in order)

1. Measure: `renderer.info.render.calls` + a frame profiler.
2. Instance repeated meshes; merge static same-material scenery.
3. Compress textures to KTX2; cap resolutions.
4. LOD (or delete) distant detail; pull in the far plane + fog.
5. Tighten shadows (map size, camera bounds, who casts).
6. `frameloop="demand"` / render-on-change for non-game scenes.
7. Only then: material/shader-level work (see
   [genart-ops](../../genart-ops/SKILL.md) for the shader side).
