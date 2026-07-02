# react-three-fiber + drei

R3F expresses the three.js scene graph as React components. It is **not a
wrapper library** — every three.js class is available as a lowercase JSX
element (`<mesh>`, `<boxGeometry>`), constructor args via `args`, properties as
props. Version reality: **R3F v9 (`@react-three/fiber`) requires React 19**
(v8 ↔ React 18); drei v10 (`@react-three/drei`) pairs with R3F v9; `three`
peer is `>=0.156`.

## 1. When R3F, when vanilla

| Signal | Choice |
|---|---|
| Page is already a React app; 3D is a feature within it | **R3F** |
| Heavy HTML UI ↔ scene interplay (state, routing, forms) | **R3F** |
| You want the pmndrs stack (drei, @react-three/rapier, postprocessing, xr) | **R3F** |
| No React on the page; a widget/embed; minimal bundle | **vanilla** |
| Engine-style control, custom render pipeline, non-React team | **vanilla** |
| Generative art sketch | vanilla ([genart-ops](../../genart-ops/SKILL.md)) |

R3F renders outside React's reconciler per frame — the framework overhead is at
mount/update time, not per frame. Performance is not the deciding axis until
you're re-rendering the React tree needlessly (see pitfalls).

## 2. Core model

```jsx
import { Canvas, useFrame, useThree } from '@react-three/fiber';

function SpinningBox(props) {
  const ref = useRef();
  useFrame((state, delta) => { ref.current.rotation.y += delta; });  // the game loop
  return (
    <mesh ref={ref} {...props}>
      <boxGeometry args={[1, 1, 1]} />          {/* args = constructor arguments */}
      <meshStandardMaterial color="tomato" />
    </mesh>
  );
}

export default () => (
  <Canvas camera={{ position: [0, 2, 5], fov: 60 }} shadows>
    <ambientLight intensity={0.4} />
    <directionalLight position={[5, 10, 5]} castShadow />
    <SpinningBox position={[0, 1, 0]} />
  </Canvas>
);
```

- `<Canvas>` owns renderer/scene/camera/loop; it fills its parent — **size the
  parent** (`<div style={{height:'100vh'}}>`), the eternal "blank canvas" bug.
- Dashed props set nested properties: `position-y={2}`,
  `rotation-x={Math.PI/2}`, `material-color="hotpink"`.
- `useThree()` exposes `{ gl, scene, camera, size, ... }` inside the Canvas.
- Loading: `const { scene, animations } = useGLTF('/model.glb')` (drei) —
  Suspense-based, wrap in `<Suspense fallback={...}>`.

## 3. The pitfalls that actually bite

1. **Never `setState` per frame.** `useFrame` + mutate refs. React state is for
   discrete changes (mode, selection), not continuous motion. Per-frame
   `setState` re-renders the tree at 60 Hz and craters.
2. **No `new THREE.X()` in render without memo.** Inline `new Vector3()` in
   JSX props allocates every render; hoist or `useMemo`. Prop shorthand
   (`position={[0,1,0]}`) is fine — arrays are diffed.
3. **Disposal is automatic — mostly.** Unmounting disposes objects R3F created
   from JSX. Objects you created imperatively (`useMemo(() => new
   Texture(...))`) or loaded manually are yours to dispose
   ([scale-and-disposal.md](scale-and-disposal.md)). `useGLTF` caches globally
   — cached assets survive unmount by design.
4. **`useLoader`/`useGLTF` cache by URL.** Two components loading the same URL
   share one instance — mutate a material in one and both change. Clone (or
   drei's `<Clone>`) for independent copies; skinned characters still need
   `SkeletonUtils.clone` semantics (drei `useGLTF` + `<Clone>` handles it).
5. **Events are built in** — `<mesh onClick={e => ...} onPointerOver={...}>`
   does raycasting for you; `e.stopPropagation()` respects occlusion. Don't
   hand-roll a `Raycaster` in R3F.
6. **Frameloop control:** static scenes set `<Canvas frameloop="demand">` +
   `invalidate()` on change — stops burning battery at idle.

## 4. drei shortlist (the ones worth knowing exist)

| Helper | Replaces hand-rolling |
|---|---|
| `<OrbitControls makeDefault />` | controls wiring + camera event plumbing |
| `useGLTF` / `useTexture` / `useKTX2` | loader + Suspense + caching (incl. DRACO/KTX2 paths) |
| `<Environment preset="sunset" />` | HDRI IBL lighting setup |
| `<Instances>` / `<Merged>` | InstancedMesh bookkeeping as JSX children |
| `<Html>` | DOM elements tracking 3D positions (labels, health bars) |
| `<Text>` (troika SDF) | crisp 3D text without geometry fonts |
| `<KeyboardControls>` | input state map for games |
| `<PerspectiveCamera makeDefault>` | camera-as-component, animatable |
| `<ContactShadows>` / `<AccumulativeShadows>` | cheap grounded-look shadows |
| `<Stats>` / `<Perf>` (r3f-perf) | fps/draw-call HUD |
| `<Detailed distances={[0,10,20]}>` | THREE.LOD as JSX |
| `<Bvh>` | three-mesh-bvh accelerated raycasting for big scenes |

## 5. Ecosystem for games

- **`@react-three/rapier`** — declarative rapier
  ([physics.md](physics.md)): `<Physics>` + `<RigidBody type="dynamic">`
  around meshes; `<Debug />` renders colliders. Runs the fixed-step loop for
  you.
- **`@react-three/postprocessing`** — effect composer as components.
- **`ecctrl`** (pmndrs) — ready-made character controller on
  @react-three/rapier: capsule + camera rig + WASD.
- **zustand** — the pmndrs state library; game state lives outside React,
  `useFrame` reads it via `getState()` without subscribing (no re-renders).

Vanilla knowledge transfers 1:1 — R3F components are the same objects; a ref
gives you the real `THREE.Mesh`, and everything in the other references
(animation mixers, fixed timestep, disposal) applies unchanged inside
`useFrame`/`useEffect`.
