# Animation system — AnimationMixer, crossfades, blending

The three.js animation system is player (`AnimationMixer`) + clips
(`AnimationClip`) + per-clip playback state (`AnimationAction`). It drives both
**skeletal** animation (bones/skinning) and **morph targets** (blend shapes)
through the same API.

## 1. Setup — one mixer per model root

```javascript
const mixer = new THREE.AnimationMixer(model);          // model = gltf.scene (or a clone)
const actions = {};
for (const clip of gltf.animations) {
  actions[clip.name] = mixer.clipAction(clip);          // cached — same clip returns same action
}
actions.Idle.play();
```

Every frame (from the game loop — see [game-loop.md](game-loop.md)):

```javascript
mixer.update(dt);      // dt in SECONDS. Forgetting this = frozen model, no error.
```

Rules:

- **One mixer per animated model instance.** Clips are shared; mixers and
  actions are not. Cloned characters (`SkeletonUtils.clone`) each get their own
  mixer.
- Clip lookup by name: `THREE.AnimationClip.findByName(gltf.animations, 'Run')`.
  Names come from the DCC tool/Mixamo — `gltf.animations.map(c => c.name)` to
  see what you actually have.
- Mixer time scales globally: `mixer.timeScale = 0` is a clean pause;
  `action.timeScale` scales one clip (negative plays it backwards).

## 2. Crossfading — the state-transition workhorse

Never `.stop()` one action and `.play()` the next — that pops. Fade:

```javascript
function fadeTo(next, duration = 0.3) {
  if (next === current) return;
  next.enabled = true;
  next.reset().play();                       // reset: re-entering a faded-out action
  current.crossFadeTo(next, duration, true); // true = warp (sync time scales)
  current = next;
}
```

- `reset()` matters: a previously faded-out action has `weight = 0` and a stale
  time; without reset the "fade in" shows nothing.
- **Warp** (`true`) time-stretches the outgoing clip to match the incoming one's
  pace during the fade — use it for locomotion (walk↔run keeps footfalls
  aligned); skip it for unrelated transitions (idle → jump).
- For locomotion trees, keep walk and run cycles authored at the same phase
  (both start on left foot) or the crossfade will slide feet regardless.

## 3. One-shot clips (jump, attack, death)

```javascript
const jump = actions.Jump;
jump.setLoop(THREE.LoopOnce, 1);
jump.clampWhenFinished = true;               // hold last frame instead of snapping to T-pose
jump.reset().play();

mixer.addEventListener('finished', (e) => {
  if (e.action === jump) fadeTo(actions.Idle, 0.2);
});
```

`clampWhenFinished` without the `finished` handler is how characters get stuck
mid-air: the clip holds its final pose forever. Always pair them.

## 4. Manual blend weights (locomotion blending)

Crossfade is A→B. For continuous blends (idle/walk/run by speed), run all
actions at once and drive weights yourself:

```javascript
for (const a of [idle, walk, run]) { a.play(); a.setEffectiveWeight(0); }

function setLocomotion(speed01) {            // 0 = idle, 0.5 = walk, 1 = run
  idle.setEffectiveWeight(Math.max(0, 1 - speed01 * 2));
  walk.setEffectiveWeight(1 - Math.abs(speed01 - 0.5) * 2);
  run.setEffectiveWeight(Math.max(0, speed01 * 2 - 1));
  // keep cycles in phase: scale run's timeScale toward walk's cadence as weight shifts
}
```

Weights are normalized by the mixer per property track — they don't need to sum
to 1, but keeping them roughly normalized avoids under/over-shooting poses.

## 5. Additive layers (breathing, recoil, look-at on top of locomotion)

```javascript
const additiveClip = THREE.AnimationUtils.makeClipAdditive(gltf2.animations[0].clone());
const layer = mixer.clipAction(additiveClip);
layer.blendMode = THREE.AdditiveAnimationBlendMode;
layer.play();                                 // plays ON TOP of whatever else runs
```

`makeClipAdditive` mutates the clip (subtracts the first frame as reference
pose) — clone first if the original is also used normally.

## 6. Morph targets (blend shapes — faces, corrective shapes)

Morph influences live on the mesh, indexed via `morphTargetDictionary`:

```javascript
const face = model.getObjectByName('Head');
const i = face.morphTargetDictionary['mouthSmile'];
face.morphTargetInfluences[i] = 0.8;          // 0..1, animate directly per frame
```

- glTF exports morph names when the exporter enables it (Blender: shape keys
  export automatically); if `morphTargetDictionary` is missing names you get
  numeric indices only.
- Animation clips can drive influences too (exported blend-shape animation
  plays through the mixer like any other clip) — manual driving and mixer
  driving fight over the same array; pick one per target.
- Lip-sync/ARKit-style pipelines are just 52 named influences set per frame.

## 7. Skeletal specifics

- Bones are plain `Object3D`s in the hierarchy — grab one to attach props:
  `model.getObjectByName('mixamorigRightHand').add(sword)`.
- Procedural bone control (head look-at) must run **after** `mixer.update(dt)`
  in the frame, or the mixer overwrites it. Set `bone.quaternion`
  post-update, and call `bone.updateMatrixWorld(true)` if you read it back.
- Retargeting clips between skeletons: `SkeletonUtils.retargetClip` exists but
  is finicky about rest poses — prefer authoring/converting via Mixamo or
  Blender so all characters share one rig.

## 8. Root motion vs in-place

Game locomotion normally uses **in-place** clips (Mixamo checkbox: "In Place")
with movement applied by code/physics ([physics.md](physics.md)). If a clip has
baked root motion and you move the character too, it double-translates. Either
strip the root track:

```javascript
clip.tracks = clip.tracks.filter(t => !t.name.startsWith('mixamorigHips.position'));
```

…or don't move the object while that clip plays. Rotation-only root tracks are
usually fine to keep.
