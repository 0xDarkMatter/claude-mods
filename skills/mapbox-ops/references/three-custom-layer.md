# three.js inside Mapbox GL — custom layer integration

Animated 3D objects (vehicles, wildlife, ambient life) living *in* the map: a
`CustomLayerInterface` layer hosting a three.js scene that shares Mapbox's WebGL
context. Distilled from a production ambient-vessels layer and from reviewing
[Threebox](https://github.com/jscastro76/threebox) v2.2.7 internals (`CameraSync.js`,
`Threebox.js`) — the de-facto mapbox↔three bridge library.

## Decide the architecture FIRST — two incompatible approaches

| | A. Baked matrix (Mapbox docs pattern) | B. Reconstructed camera (Threebox `CameraSync`) |
|---|---|---|
| How | Bake everything into `camera.projectionMatrix` from the `render(gl, matrix)` arg | Rebuild a *real* camera each `move`: true `projectionMatrix` + true `matrixWorld`; a `world` group carries zoom/pan |
| Code | ~30 lines, no deps | ~300 lines, or adopt Threebox |
| Rendering | ✅ correct (terrain occlusion, fog) | ✅ correct |
| Raycast picking / drag / hover | ❌ **impossible** — camera pose is fake | ✅ `raycaster.setFromCamera` works |
| CSS2D labels / tooltips synced to 3D | ❌ | ✅ |
| API surface used | public only | **private** `map.transform` internals (`_fov`, `_pitch`, `angle`, `_camera.position`, `elevation`, `_horizonShift`) — version-gated, breaks across GL JS majors |

**Decision rule:** ambient/display-only objects → A. Users must click/drag/hover the
3D objects → B (and seriously consider just using Threebox rather than hand-rolling —
but pin its version; it vendors its own patched legacy three.js build, so check
compatibility before mixing with a modern three from CDN).

Threebox's own comment (CameraSync.js): applying the transform directly to the
projection matrix "will work OK but break raycasting" — that's the whole fork.

## Recipe A — minimal baked-matrix layer (display-only actors)

Scene space = **local ENU metres** around an origin anchor (avoids float32 precision
loss at global mercator scale). After the matrix chain below: x=east, y=up, z=south.

```js
const ORIGIN = [144.85, -38.15];                       // anchor near your actors
function ll2m(p){ const d = Math.PI/180, R = 6378137;  // [lng,lat] → ENU metres
  return [ (p[0]-ORIGIN[0])*d*R*Math.cos(ORIGIN[1]*d), (p[1]-ORIGIN[1])*d*R ]; }

const layer = {
  id: "actors", type: "custom", renderingMode: "3d",   // "3d" → shares depth buffer
  onAdd(map, gl){
    this.renderer = new THREE.WebGLRenderer({ canvas: map.getCanvas(), context: gl, antialias: true });
    this.renderer.autoClear = false;                   // never clear Mapbox's frame
  },
  render(gl, matrix){
    stepActors();                                      // your animation tick
    const mc = mapboxgl.MercatorCoordinate.fromLngLat({lng: ORIGIN[0], lat: ORIGIN[1]}, 0);
    const s  = mc.meterInMercatorCoordinateUnits();
    camera.projectionMatrix = new THREE.Matrix4().fromArray(matrix)
      .multiply(new THREE.Matrix4().makeTranslation(mc.x, mc.y, mc.z))
      .multiply(new THREE.Matrix4().makeScale(s, -s, s))          // mercator y grows south
      .multiply(new THREE.Matrix4().makeRotationX(Math.PI/2));    // z-up → three's y-up
    this.renderer.resetState();                        // Mapbox left GL state dirty
    this.renderer.render(scene, camera);
    map.triggerRepaint();                              // ONLY while animating
  }
};
```

- Place an actor at ENU `(e, n)`: `obj.position.set(e, alt, -n)` (note the `-n`).
- Heading: model your object facing −z (north); then `rotation.y = -bearingRad`.
- `camera = new THREE.Camera()` — a bare camera; the matrix chain is the whole pose.
- Roll/heel about the forward axis: nest an inner group (`inner.rotation.z`) inside
  the yawed outer group — don't fight Euler order on one object.

### Constant screen-size actors (the "game token" pattern)

Real-scale objects vanish at low zoom. Scale per frame so actors read like symbols
(Threebox ships this as `fixedZoom`/`setObjectScale`, recomputed on `zoom`):

```js
const mPerPx = 40075016.686 * Math.cos(map.getCenter().lat * Math.PI/180)
             / (512 * 2 ** map.getZoom());
obj.scale.setScalar(Math.max(TARGET_PX * mPerPx, MIN_METERS) / MODEL_LEN_METERS);
```

### Terrain

- Water/sea-level actors: altitude 0 is correct even with terrain + exaggeration.
- Land actors: sample `map.queryTerrainElevation(lngLat, {exaggerated: true})` and
  feed it into `position.y` — the custom layer matrix does NOT lift objects onto
  terrain for you.

## Recipe B — the CameraSync math worth stealing (when you need picking)

From Threebox `CameraSync.js`; rebuild on every map `move` + `resize`:

- `cameraToCenterDistance = 0.5 / tan(fov/2) * transform.height`
- **Camera world matrix** (kept separate from projection — merging them is what
  breaks raycasting): `rotZ(t.angle) · rotX(t._pitch) · translateZ(cameraToCenterDistance)`
- **World group matrix** (zoom/pan live here, not on the camera):
  `translate(-t.point.x, t.point.y, 0) · scale(t.scale·TILE/WORLD) · translateCenter(WORLD/2, -WORLD/2) · rotZ(π)`
- **Far plane must be horizon-aware** or content clips at high pitch (GL JS ≥ 2):
  `fovAboveCenter = fov·(0.5 + centerOffset.y/height)`;
  `camToSea = (t._camera.position[2]·worldSize − minElevBelowMSL·pxPerM) / cos(pitch)`;
  `farZ = min(furthest·1.01, camToSea / t._horizonShift)`.
  Near plane: `nearZ = max((height/50)·cos(π/2 − pitch), height/50)`.
- **Terrain**: when `t.elevation` exists, override camera height:
  `cameraWorldMatrix.elements[14] = t._camera.position[2] * worldSize`.
- **Reset `camera.aspect` on map resize or raycasting silently breaks** (their own
  bug-fix comment — easy to miss because rendering still looks fine).
- Picking = normalize mouse to NDC, `raycaster.setFromCamera(ndc, camera)`,
  `intersectObjects(world.children, true)`.

## Lifecycle & hygiene (either recipe)

- **`setStyle` wipes custom layers** (see [lifecycle.md](lifecycle.md)): re-add via one
  idempotent installer called on `load` AND `style.load`. Keep the *scene* as
  module state so actors survive the swap; only the layer registration and the
  renderer (rebuilt in `onAdd`) are per-style. Threebox goes further: it wraps
  `setStyle` to dispose and rebuild its whole world.
- **One layer, one scene, many actors.** N custom layers = N render passes + N
  renderer state resets. Threebox's `multiLayer` option exists precisely to route
  everything through a single driver layer that calls one `update()`.
- **Renderer parity**: `setPixelRatio(devicePixelRatio)` and sRGB output
  (`renderer.outputColorSpace = THREE.SRGBColorSpace`, older three:
  `outputEncoding = sRGBEncoding`) — otherwise your objects look softer/washed-out
  next to Mapbox's own rendering.
- `triggerRepaint()` only while something animates; clamp `dt` (`min(0.1, …)`) so a
  backgrounded tab doesn't teleport actors on resume.
- Respect `prefers-reduced-motion` for ambient animation (default it off).
- Teardown: dispose geometries/materials/renderer — the page WebGL-context cap
  (~16) is shared with the map itself.

## Extras Threebox ships that pair well

- **Real sun lighting**: bundled suncalc → sun azimuth/altitude from date + lngLat
  drives a `DirectionalLight` (+ shadow camera). Pairs with map `lightPreset`/fog
  time-of-day so 3D objects and basemap agree on lighting.
- **`BuildingShadows`** — a shader patch over `fill-extrusion` so Mapbox buildings
  receive shadows from three.js objects. Niche, but nothing else does it.
