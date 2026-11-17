# Character locomotion - third-person characters that feel AAA

How to make a skinned three.js character walk, run, turn, jump and land without foot slide, plus the controller, camera, input and cloth that sell the feel.

Source: "Oil paint" by blendi, https://patch.gg/blendi/oil-paint (code MIT, art CC0; three.js 0.186, Rapier 0.21). Snippets adapted from blendi/oil-paint (MIT).
Prereqs live elsewhere: crossfades, one-shots and additive layers in [animation.md](animation.md); Rapier init and body types in [physics.md](physics.md); fixed step, `damp()` and input sampling in [game-loop.md](game-loop.md). Below, `damp(a, b, rate, dt) = b + (a - b) * Math.exp(-rate * dt)`.

## Contents

1. In-place clips, travel kept as data
2. The mixer as a pose evaluator
3. Speed and strafe blend spaces with distance-synced phase
4. Locomotion states and pose-matched entry
5. Foot-sliding toolkit and procedural passes
6. Rapier kinematic controller tuning
7. Third-person orbit camera
8. Input
9. Verlet cloak on bone capsules
10. Attaching things to a skinned mesh
11. Gaps worth adding
12. Tuning constants

## 1. In-place clips, travel kept as data

**When:** library clips (UAL, Mixamo, mocap) carry root travel but the game owns position.
```js
const v = root.values, n = v.length;                  // root.position track
motion.velocity.set(v[n-3] - v[0], 0, v[n-1] - v[2]).divideScalar(clip.duration);
const d = q1.multiply(q0.invert()); motion.yaw = 2 * Math.atan2(d.y, d.w); // root.quaternion last*first^-1
raw[name] = clip;                                      // keep for one-shots (section 4)
clips[name] = new THREE.AnimationClip(name, clip.duration,
  clip.tracks.filter((t) => !t.name.startsWith('root.')));
```
- `stride = motion.velocity.length() * clip.duration` (metres per cycle) sets playback rate later. Gotcha: valid only when root's parent is the armature (character space, +Z forward); divide out any scale above it.
- Measure every clip once at load on a `SkeletonUtils.clone` rig at 30 samples/s: feet relative to root, feet in world, pelvis height. Sections 3-4 read these tables.

## 2. The mixer as a pose evaluator

**When:** phase-synced blends, or two layers playing one clip at different times (outgoing and incoming run during a stop).
```js
const a = mixer.clipAction(slot ? clip.clone() : clip); // 3 slots; clipAction caches by clip, so clone
a.play(); a.setEffectiveWeight(0); a.timeScale = 0;
// per frame, from each layer's sample() -> [{clip, time, w}], weights normalised:
a.setEffectiveWeight(w); a.time = time;   // zero every unused action
mixer.update(0);                          // evaluate, never advance
```
- `enter(state, fade)` pushes a layer at weight 0; the newest rises by `dt / fade`, the rest fall; evict the oldest when all 3 slots are busy.
- Gotcha: a fading-out loco layer must freeze the speed it last had. The stop's first frame reports speed 0, which turns the fading run into idle for a frame and snaps the knee straight.

## 3. Speed and strafe blend spaces with distance-synced phase

**When:** blending walk/run/sprint by speed, or 8-way strafes.
- Free move: 1D anchors `[[0, idle], [1.45, Walk], [5.3, Run], [7.0, Sprint]]` m/s, lerp between the two neighbours. Strafe: a walk ring and a jog ring of 8 clips at 0/45/.../315 deg. `walkW = v / 1.45`, `jogT = (v - 1.45) / (3.6 - 1.45)`; within a ring, split weight between the two entries either side of the move angle.
- Phase 0 = measured left heel strike: start of the longest run of slow left-foot frames (slow = 40th-percentile foot speed * 1.05 + 0.05 m/s). Store it as `offset`.
```js
let stride = 0, sw = 0;
for (const o of list) if (o.synced) { stride += info[o.clip].stride * o.w; sw += o.w; }
if (sw > 0) phase = wrap(phase + (stride / sw > 0.05 ? v / (stride / sw) : 0) * dt);
o.time = o.synced ? wrap(phase + info[o.clip].offset) * info[o.clip].duration
                  : idleClock % info[o.clip].duration;   // idles run on their own clock
```
- Gotchas: `v` is the speed the capsule really moved, not the requested one, or feet slide against walls. No backward jog clips means capping backward speed (walk * 1.15).

## 4. Locomotion states and pose-matched entry

**When:** starts, stops, pivots and jumps should look authored, not blended.

| Mode | Enter | Clip window, rate, fade |
|---|---|---|
| start | idle, input within 0.9 rad of facing | Idle_To_Walk 0.06-0.62 @1.15, fade 0.2; Idle_To_Run 0.03-0.72, fade 0.15 |
| stop | input released, speed > 0.9 after > 0.6 s moving | Walk/Run/Sprint_To_Idle by speed (2.4 / 5.7), entered at the matching frame, fade 0.22 |
| turn | idle, asked direction > 2.2 rad behind | Turn90/180_L/R, 0.08-0.78/0.8 @1.35/1.45, fade 0.2 |
| jump / air / land | jump edge; > 0.2 s airborne; grounded | Jump_Start from measured launch @1.25; Jump_Loop; Jump_Land to 0.7 (0.9 if fall > 7 m/s) |
| idleExtra | 9 s still | LookAround, fade 0.6; Idle_Tired after > 1.5 s sprint, eased in over ~1 s |

```js
const from = match(stopClip, currentFeet(), 0, 0.3);       // best feet match in first 30%
phase = wrap(match(loopClip, currentFeet()) - info[loopClip].offset); // re-enter mid-stride
// one-shots move the capsule by their raw root delta, through the KCC (walls still stop them)
const d = rootAt(raw, u * dur).sub(rootAt(raw, prevU * dur)).applyAxisAngle(UP, yaw);
```
- `match` = argmin over sampled frames of `|lFoot - l|^2 + |rFoot - r|^2`, feet relative to root.
- Turn in place lands on the exact angle: `scale = asked / covered` (covered = root yaw over the trimmed window; use the full turn if under 0.3 rad), then `yaw += angleWrap(y1 - y0) * scale` per frame.
- Jump launch = frame where the hips rise fastest, minus 3 frames, so the clip starts at take-off.
- Gotchas: on a one-shot's first frame `prevU === u`, so keep the current pace or he halts for a frame. Allow early exits: turn after 70% when input arrives; start aborts on a gait or > 0.6 rad direction change.

## 5. Foot-sliding toolkit and procedural passes

**When:** after `mixer.update(0)`, in this order. Passes read bones in world space, so `updateMatrixWorld(true)` after each write. Stride sync (section 3) and pose-matched entry (section 4) already remove most slide.
- **Sharp-turn slow-down:** `speed *= off < 1 ? 1 : clamp(1.45 - off / 2.2, 0.4, 1)` (off = angle to wanted heading).
- **Wall stall:** after 3 frames moving under 60% of commanded speed, drop speed to what he really moves.
- **Foot lock with a leash:** planted when ankle < 0.125 m and ball < 0.055 m above the clip floor. Pin where it landed; if the pin drifts > 0.2 m from the animated foot, lerp it at `12 * dt` (never snap); after lift, decay the offset by `exp(-16 * dt)`.
- **Two-bone leg IK:** law-of-cosines knee in the animated hip-knee-ankle plane, with the pole blended toward character-forward as the animated knee turns away, so legs never invert on high steps. Drop the pelvis for the lower foot (damp 12), feet damp 18, tilt planted feet to the ground normal (halved above ~41 deg), keep the foot's world rotation.
- **Spine and lean:** spread spine rotation evenly over spine_01..03; remove extra clip lean toward 4/6/11/14 deg at 0/1.45/5.3/7 m/s (run clips lean 23-29 deg).
- **Turn and accel lean:** roll `clamp(-turnRate * speed * 0.035, +/-0.22)` damp 6; pitch `clamp(accel * 0.012, -0.08, 0.1)` damp 5.
- **Head look:** yaw toward camera forward, clamped +/-1 rad, split spine_03/neck/head 0.2/0.35/0.45; face front when the camera is > 1.9 rad behind; fade out above 1.5 m/s. **Arm clearance:** keep elbows at least 86% of the rest shoulder half-width from the centre line.
- **Visual root:** the mesh follows a ground ray under the capsule, rising at damp 14 and falling at damp 20. Hides autostep pops.

## 6. Rapier kinematic controller tuning

**When:** any walking character on terrain plus obstacles. Extends the KCC basics in [physics.md](physics.md).
```js
const kcc = world.createCharacterController(0.02);
kcc.enableAutostep(0.3, 0.12, false); kcc.enableSnapToGround(0.45); // no stepping onto dynamic bodies
kcc.setMaxSlopeClimbAngle(46 * DEG); kcc.setMinSlopeSlideAngle(52 * DEG); kcc.setSlideEnabled(true);
// capsule r 0.28, half-height 0.62 (1.8 m tall), friction 0
if (grounded) vel.y = -0.1;             // light push: snap works, autostep isn't defeated
else vel.y = Math.max(vel.y - (vel.y < 0 ? 25 : 19) * dt, -40);
```
- Jump `vel.y = Math.sqrt(2 * 19 * 0.8)` = 5.51 m/s; keep ground momentum; air control 2.5 m/s^2, air turn 2.5 rad/s. Ignore `computedGrounded()` for 150 ms after take-off, or the launch frame lands instantly. Head bump: `if (vel.y > 0 && mv.y < d.y * 0.5) vel.y = 0`.
- Linear accel per gait (walk 6, run 9, sprint 7, decel 12 m/s^2), rate-limited turning (9 / 7.5 / 5.2 rad/s). Lower sprint accel and turn rate is what gives sprint its weight.
- Gotcha: the demo calls `world.step()` once per render frame (Rapier integrates at its default 1/60
  `timestep`) while the KCC moves by frame dt. Fine for one kinematic body; with dynamic props, use the fixed step in [game-loop.md](game-loop.md).

## 7. Third-person orbit camera

**When:** a free-orbit camera in clutter (trees, pillars).
```js
pivot.x = damp(pivot.x, feet.x, 10, dt); pivot.z = damp(pivot.z, feet.z, 10, dt);
pivot.y = damp(pivot.y, feet.y + 1.35, 5, dt);          // softer on y: steps don't bob
const from = pivot.clone().addScaledVector(right, 0.95 * k); // k = min(1, want / 6.4)
const hit = castRay(from, back, want + 0.4);             // exclude the player collider
const free = hit == null ? want : Math.max(0.8, hit - 0.3);
dist = free < dist ? damp(dist, free, 18, dt) : damp(dist, free, 2.5, dt);
cam.position.copy(from).addScaledVector(back, dist);
cam.position.y = Math.max(cam.position.y, groundAt(cam.position) + 0.45);
```
- Pull in fast (18), ease out slow (2.5): the asymmetry is the whole trick. Pitch -0.75..1.2 rad, zoom 2.8-13 m at 0.5 per wheel step.
- Rotation comes straight from input, unsmoothed; movement is camera-relative. Shoulder offset and aim lift (0.85 * k) shrink as you zoom in.

## 8. Input

**When:** keyboard, mouse and pad, read once per frame into one plain state object.
```js
el.requestPointerLock?.()?.catch?.(() => {});    // refusal (e.g. right after ESC) rejects
if (document.pointerLockElement === el || mouse.right) { mx += e.movementX; my += e.movementY; }
const dz = (v) => (Math.abs(v) < 0.15 ? 0 : Math.sign(v) * (Math.abs(v) - 0.15) / 0.85);
look.x += rx * Math.abs(rx) * 3.2 * dt;          // squared stick: fine aim near centre
speed = mag < 0.6 ? walk * (mag / 0.6) : lerp(walk, run, (mag - 0.6) / 0.4);
```
- RMB-drag look is the fallback when lock is refused or unavailable (iframes, embeds, headless). Mouse 0.0022 rad/px; pad pitch 2.2 rad/s. L3 toggles sprint and clears when the stick drops under 0.2.
- Gotchas: clear keys on `blur`; `preventDefault` Space/arrows/Tab/Alt; the wheel listener needs `passive: false`; disable pads in headless tests (real pads leak in).

## 9. Verlet cloak on bone capsules

**When:** a cape, cloak or scarf without a cloth engine.
- Grid 19 x 14 (266 points, row 0 pinned to a collar built from shoulder bones), 0.088 m per row, rest lengths cut from a cone flaring 6% per row.
- 1,433 links: structural 1.0, shear 0.6, bend (skip-one) 0.25. Compression stiffness x0.12: threads pull, barely push, so cloth folds instead of springing.
- Fixed 1/120 s step, accumulator capped at 0.05 s, max 6 substeps, damping 0.992, 7 constraint iterations, collide on passes 0/2/4/6 plus once after.
- 12 capsules from bone pairs (torso 0.165, arms 0.075/0.06, thighs 0.105, calves 0.075, +0.022 skin). Lerp pins and capsules from last frame's pose to this one by substep fraction `u = (s + 1) / steps`, or fast limbs tunnel.
```js
const rx = wind.x - vx / STEP, ry = wind.y - vy / STEP, rz = wind.z - vz / STEP; // relative air
const flutter = Math.sin(t * 11 - row * 0.85 + col * 0.7) * 0.45 * Math.hypot(rx, ry, rz) * (row / ROWS);
ax = nx * flutter + rx * 1.45; ay = -9.8 + ny * flutter + ry * 0.5; az = nz * flutter + rz * 1.45;
```
- Relative-air drag alone lifts the cloak behind a runner; the hem-growing sine supplies the ripples. Re-hang the cloth if pins jump > 2 m in a frame (respawn/teleport). Ground clamp at height + 0.04.
- Cost (estimated, not measured): ~10k link solves and ~15k capsule tests per substep, ~50k small ops per frame at 60 fps in plain `Float32Array` JS. Main thread copes at this size.

## 10. Attaching things to a skinned mesh

**When:** a few hundred decals, strokes or particles that must ride the skin.
```js
a.copy(pin.p); mesh.applyBoneTransform(pin.vertex, a); a.applyMatrix4(mesh.matrixWorld);
b.copy(pin.p).addScaledVector(pin.n, 0.03); mesh.applyBoneTransform(pin.vertex, b); b.applyMatrix4(mesh.matrixWorld);
normal.subVectors(b, a);  // finite-difference normal bends with the skin
```
- `applyBoneTransform(index, v)` uses vertex `index`'s skin weights, so snap each sample to a vertex (area-weighted triangle pick, seeded RNG for stable placement).
- Run it after all procedural passes: it reads the bones' `matrixWorld`. Morph targets are not applied. 870 pins x 3 points per frame is cheap; beyond a few thousand, skin in the shader. Rigid props (a hat): place in bind pose, then `bone.attach(prop)`.

## 11. Gaps worth adding

- **Coyote time:** `coyote = grounded ? 0.12 : coyote - dt`; allow a jump while `coyote > 0`.
- **Jump buffer:** `buffer = jumpPressed ? 0.15 : buffer - dt`; jump on landing if `buffer > 0`, then zero both.
- **Camera look-ahead:** add `lead = damp(lead, velXZ * 0.25 (max 1.5 m), 3, dt)` to the pivot.

## 12. Tuning constants

| Constant | Value |
|---|---|
| Gait anchors walk / run / sprint; strafe walk / jog | 1.45 / 5.3 / 7.0; 1.45 / 3.6 m/s |
| Strafe caps forward / back | run x 0.82 / walk x 1.15 |
| Accel walk / run / sprint, decel | 6 / 9 / 7, 12 m/s^2 linear |
| Turn rate walk / run / sprint; strafe body | 9 / 7.5 / 5.2; 12 (8 in air) rad/s |
| Capsule, skin, autostep, snap; slope climb / slide | r 0.28 h 1.8; 0.02; 0.3 m (min width 0.12); 0.45 m; 46 / 52 deg |
| Gravity up / down, terminal; jump; dt clamp | 19 / 25 m/s^2, -40 m/s; 0.8 m apex (5.51 m/s); 1/20 s |
| Foot lock ankle / ball / leash | 0.125 / 0.055 m; 0.2 m at 12/s; release 16/s |
| IK damp feet / pelvis; visual root up / down | 18 / 12; 14 / 20 |
| Camera distance default, range; pivot damp xz / y | 6.4, 2.8-13; 10 / 5 |
| Camera occlusion in / out; min; floor | 18 / 2.5; 0.8 m; +0.45 m |
| Pad deadzone; look yaw / pitch | 0.15; 3.2 / 2.2 rad/s squared |
| Cloak | 19 x 14, 1/120 s, <= 6 substeps, 7 iters, drag xz 1.45 y 0.5 |
