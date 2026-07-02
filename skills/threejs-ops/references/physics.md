# Physics — rapier (default) vs cannon-es

three.js has no physics; you bolt on an engine and mirror its bodies into
meshes. Two realistic choices in 2026:

| | `@dimforge/rapier3d` | `cannon-es` |
|---|---|---|
| Implementation | Rust → WASM | Pure JS |
| Performance | Fast; hundreds of dynamic bodies | OK for dozens |
| Determinism | Yes (same inputs + build) | No guarantee |
| Character controller | **Built-in kinematic controller** | Roll your own |
| Trimesh/convex support | Strong (colliders from any mesh) | Weak trimesh; prefer primitives |
| Setup | WASM init step | `import` and go |
| Maintenance | Active (Dimforge) | Community fork of dead cannon.js; low activity |
| R3F wrapper | `@react-three/rapier` | `@react-three/cannon` |

**Default to rapier.** Pick cannon-es only when WASM is genuinely unacceptable
(exotic CSP, some embedded webviews) or the sim is trivial (a few boxes).

## 1. Rapier init — the package-name trap

Two npm packages, same API, different WASM delivery:

```javascript
// A) Bundler (Vite/webpack) — WASM as a real .wasm file, streamed + cached:
import RAPIER from '@dimforge/rapier3d';

// B) No bundler / import map / CDN — WASM inlined as base64 (bigger, simpler):
import RAPIER from '@dimforge/rapier3d-compat';
await RAPIER.init();                      // compat REQUIRES this before any use
```

Vite handles (A) out of the box. If a bundler chokes on the wasm import,
(B) works everywhere at ~1.5× the download. Symptom of forgetting
`RAPIER.init()`: `undefined` errors deep inside the first `new RAPIER.World`.

## 2. World + stepping (inside the fixed loop)

```javascript
const world = new RAPIER.World({ x: 0, y: -9.81, z: 0 });
world.timestep = FIXED;                   // match the fixed step — set once

// inside the fixed-timestep while-loop (see game-loop.md):
world.step();
```

Never step with render dt: rapier tuning (CCD, solver iterations) assumes a
stable timestep, and variable stepping breaks determinism.

## 3. Body types — which one for what

| Type | Moves by | Pushed by others? | Use for |
|---|---|---|---|
| `fixed` | never | no | Ground, walls, static scenery |
| `dynamic` | solver (forces/impulses) | yes | Crates, ragdolls, projectiles, debris |
| `kinematicPositionBased` | you set next position | no (it pushes *them*) | Player characters, moving platforms, elevators |
| `kinematicVelocityBased` | you set velocity | no | Conveyor-ish movers where velocity is the natural control |

The classic mistake is a **dynamic player capsule**: it trips on edges, gets
shoved by props, and fights the controller. Player characters are kinematic;
the environment reacts dynamically.

```javascript
// dynamic crate
const body = world.createRigidBody(
  RAPIER.RigidBodyDesc.dynamic().setTranslation(0, 5, 0));
world.createCollider(RAPIER.ColliderDesc.cuboid(0.5, 0.5, 0.5), body);

// fixed ground
world.createCollider(RAPIER.ColliderDesc.cuboid(50, 0.1, 50),
  world.createRigidBody(RAPIER.RigidBodyDesc.fixed()));
```

Colliders from loaded models: `ColliderDesc.trimesh(vertices, indices)` for
static scenery (never for dynamic bodies — use `convexHull(vertices)` or
primitive approximations there).

## 4. Syncing bodies → meshes

The physics world is the source of truth; meshes are the view:

```javascript
// after world.step(), for each (body, mesh) pair:
mesh.position.copy(body.translation());
mesh.quaternion.copy(body.rotation());
```

- Keep an explicit `pairs: Array<{body, mesh}>` — don't hang references off
  `mesh.userData` and traverse the scene per frame.
- With interpolation (fixed step < render rate), copy into `currentState`
  instead and lerp in the render pass ([game-loop.md](game-loop.md)).
- Scale is NOT synced — physics has no scale; bake scale into collider sizes
  at creation.

## 5. Character controller (rapier's built-in)

Kinematic body + `KinematicCharacterController` = walking, slopes, steps, and
sliding along walls without hand-rolled raycasts:

```javascript
const controller = world.createCharacterController(0.01);  // skin offset
controller.enableAutostep(0.4, 0.2, true);    // max step height, min width, dynamic-ok
controller.enableSnapToGround(0.4);           // stick to ramps when walking down
controller.setMaxSlopeClimbAngle(50 * Math.PI / 180);

// per fixed tick:
const desired = inputDirection.multiplyScalar(speed * FIXED);
desired.y = verticalVelocity * FIXED;          // integrate your own gravity/jump
controller.computeColliderMovement(collider, desired);
const corrected = controller.computedMovement();           // slid along obstacles
const p = body.translation();
body.setNextKinematicTranslation({
  x: p.x + corrected.x, y: p.y + corrected.y, z: p.z + corrected.z });

const grounded = controller.computedGrounded();            // gate jumping on this
```

You own gravity and jump velocity (kinematic bodies ignore world gravity):
`verticalVelocity -= 9.81 * FIXED` each tick, zero it when `computedGrounded()`.

## 6. cannon-es essentials (when you must)

```javascript
import * as CANNON from 'cannon-es';
const world = new CANNON.World({ gravity: new CANNON.Vec3(0, -9.82, 0) });
const body = new CANNON.Body({ mass: 1, shape: new CANNON.Box(new CANNON.Vec3(.5, .5, .5)) });
world.addBody(body);
// fixed tick:
world.fixedStep();                       // internal 1/60 accumulator
mesh.position.copy(body.position);
mesh.quaternion.copy(body.quaternion);
```

Stick to primitive shapes (Box/Sphere/Cylinder) and compound bodies;
`Trimesh` in cannon-es only reliably collides against spheres/planes. No
character controller — kinematic body + manual raycast for ground checks.

## 7. Debugging

Render the physics world, not your assumptions:

- Rapier: `world.debugRender()` returns line vertices/colors — feed a
  `LineSegments` with `BufferGeometry` each frame (or use
  `@react-three/rapier`'s `<Debug />`).
- Mismatched visuals ↔ colliders are 90% of "physics is broken": check
  half-extents (rapier cuboids take **half** sizes), baked scale, and center
  offsets.
- Bodies falling asleep: `RigidBodyDesc.setCanSleep(false)` while debugging,
  re-enable for perf.
