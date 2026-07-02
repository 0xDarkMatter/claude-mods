# Game loops — fixed timestep, dt discipline, determinism

The loop is the spine of the app. Three decisions: how you schedule frames, how
you measure time, and whether simulation runs on render time or its own clock.

## 1. Scheduling: `renderer.setAnimationLoop`, not raw rAF

```javascript
renderer.setAnimationLoop(animate);   // start
renderer.setAnimationLoop(null);      // stop (teardown!)
```

Why over `requestAnimationFrame(animate)` recursion:

- **WebXR requires it** — in XR the browser's rAF is replaced by the XR
  session's frame callback; `setAnimationLoop` switches automatically.
- One call site to stop the loop (`null`) — critical for SPA teardown
  (see [scale-and-disposal.md](scale-and-disposal.md)).
- The callback receives a `DOMHighResTimeStamp` — use it; don't call
  `performance.now()` again inside the frame.

## 2. Delta time: measure, clamp, never trust

```javascript
let last = 0;
renderer.setAnimationLoop((now) => {
  const dt = Math.min((now - last) / 1000, 0.1);   // seconds, clamped
  last = now;
  update(dt);
  renderer.render(scene, camera);
});
```

- **Clamp dt** (50–100 ms max). Background tabs throttle rAF to ~1 Hz or stop
  it entirely; on return, dt is seconds-to-minutes and one frame of
  `position += velocity * dt` teleports everything through walls.
- Never assume 60 Hz. 120/144 Hz displays are common; uncapped `dt`-free code
  (`position.x += 0.01` per frame) runs 2.4× too fast there.
- `THREE.Timer` (core since r163) packages this: `timer.update()` +
  `timer.getDelta()`, and `timer.connect(document)` auto-handles the
  tab-switch spike by listening to visibility itself.

## 3. Fixed timestep + interpolation (the Gaffer pattern)

Physics and gameplay logic that must behave identically at 60 / 120 / 24 fps
run on a **fixed step**, decoupled from render rate; rendering interpolates
between the last two sim states:

```javascript
const FIXED = 1 / 60;
let acc = 0, last = 0;

renderer.setAnimationLoop((now) => {
  acc += Math.min((now - last) / 1000, 0.1);
  last = now;

  while (acc >= FIXED) {
    previousState.copy(currentState);       // snapshot for interpolation
    simulate(FIXED);                        // physics.step, AI, gameplay
    acc -= FIXED;
  }

  const alpha = acc / FIXED;                // 0..1 — how far into the next tick
  mesh.position.lerpVectors(previousState.position, currentState.position, alpha);
  mesh.quaternion.slerpQuaternions(previousState.quaternion, currentState.quaternion, alpha);

  mixer.update(dtRender);                   // animation runs on RENDER time — smoother
  renderer.render(scene, camera);
});
```

Notes:

- The `while` loop caps itself via the dt clamp — without the clamp, a long
  stall queues hundreds of sim ticks (the "spiral of death").
- Rapier: set `world.timestep = FIXED` once and call `world.step()` inside the
  while — never pass render dt to a physics step
  ([physics.md](physics.md)).
- Skipping interpolation is fine when FIXED ≥ display rate; at 60 Hz sim on a
  144 Hz display, uninterpolated motion visibly stutters.
- Cosmetic systems (animation mixers, particles, camera smoothing) stay on
  render dt; only *stateful simulation* needs the fixed clock.

## 4. Pause / visibility

rAF stops in hidden tabs but not in occluded or backgrounded *windows*
consistently across platforms — pause explicitly:

```javascript
document.addEventListener('visibilitychange', () => {
  paused = document.hidden;
  if (!paused) last = performance.now();    // swallow the away-time
});
```

- Resetting `last` on resume is the other half of the dt clamp — otherwise the
  first visible frame still sees the whole away period.
- Pause = stop **simulating**, keep rendering one last frame; also mute audio
  and suspend `AudioContext`.
- `THREE.Timer.connect(document)` implements exactly this for its delta.

## 5. Input sampling

DOM input events fire asynchronously, between frames — never mutate game state
in the handler. Handlers write to a state object; the loop reads it:

```javascript
const input = { keys: new Set(), pointer: new THREE.Vector2(), pointerDown: false };
addEventListener('keydown', (e) => { if (!e.repeat) input.keys.add(e.code); });
addEventListener('keyup',   (e) => input.keys.delete(e.code));
addEventListener('blur',    () => input.keys.clear());   // alt-tab = stuck keys otherwise

// inside the fixed tick:
const forward = input.keys.has('KeyW') ? 1 : 0;
```

- Use `e.code` (physical key — `KeyW` works on AZERTY), not `e.key`.
- The `blur` clear matters: without it, releasing a key while the window is
  unfocused leaves it "held" forever.
- One-shot presses (jump) need edge detection: track `justPressed` by diffing
  against the previous tick's set, or consume the key on read.
- Mouse-look wants the Pointer Lock API — drei's `<PointerLockControls>` or
  three's addon of the same name wrap it.
- Sampling input in the **fixed tick** (not per rAF) keeps replays/determinism
  intact (§7): the same tick always sees the same input snapshot.

## 6. Smoothing — frame-rate-independent damping

`value += (target - value) * 0.1` per frame is the classic bug: the smoothing
speed changes with the frame rate (2.4× stiffer at 144 Hz). The correct,
dt-aware form is exponential decay — built in as `THREE.MathUtils.damp`:

```javascript
// λ ≈ 1/seconds-to-close-63%-of-the-gap; bigger = snappier
camera.position.x = THREE.MathUtils.damp(camera.position.x, target.x, 4, dt);
```

The third-person follow camera in four lines:

```javascript
const behind = player.localToWorld(new THREE.Vector3(0, 2.5, -5)); // offset in player space
camera.position.lerp(behind, 1 - Math.exp(-4 * dt));               // same math as damp
camera.lookAt(player.position);
```

Use damping for cameras, UI-ish motion, and audio params; never for physics
bodies (the solver owns those — see [physics.md](physics.md)).

## 7. Determinism

Fixed timestep is necessary but not sufficient. For replays, lockstep
networking, or reproducible tests:

- **Seeded RNG** in sim code — never `Math.random()`. A 10-line mulberry32 is
  enough: same seed → same run.
- Keep sim state separate from render state (positions in your own structures
  or the physics world; meshes are a *view*).
- Iterate collections in deterministic order (arrays, not Set/Map insertion
  assumptions across saves).
- Float math is deterministic on one machine/build but NOT bit-identical
  across browsers/CPUs — cross-machine lockstep needs quantized state or
  accepting drift + correction.
- Rapier is deterministic given identical inputs, same-order world
  construction, and the same WASM build — one of the reasons it's the default
  ([physics.md](physics.md)).

## 8. Frame budget quick reference

At 60 fps the whole frame is **16.6 ms**; browsers need ~2 ms, leaving ~14 ms
for sim + render. Measure before optimizing:

```javascript
renderer.info.render;        // { calls, triangles, points, lines } — per frame
```

Draw calls, not triangles, are usually the ceiling — see
[scale-and-disposal.md](scale-and-disposal.md) for the budget playbook.
