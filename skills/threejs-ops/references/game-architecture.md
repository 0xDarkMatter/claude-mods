# Game architecture - a complete, robust, agent-buildable browser game

How to structure a full three.js game so it boots, degrades instead of dying, and verifies itself.
Source: the reference build in SKILL.md section 9, a three.js
r180 single-file FPS Claude one-shot as an artifact. Scheduling, dt clamping, fixed timestep,
visibility pause and damping live in [game-loop.md](game-loop.md); not repeated here.

## Contents

1. Module contract, stub table, boot loading
2. Event bus - the only inter-module link
3. Fault-isolated update loop
4. Self-verification: showcase harness and headless hooks
5. Repainting boot bar and shader warm-up
6. State machine: title -> intro -> playing -> paused / dead / complete
7. Input fallback ladder
8. Feel
9. Gameplay systems
10. DOM HUD driven from 3D state
11. Fully procedural audio
12. Validated, versioned settings
13. What one-shot got right vs what the human pass added

## 1. Module contract, stub table, boot loading

When: more than ~3 subsystems, and always when agents build modules in parallel. One context
`G = { THREE, params, events, rng, time, quality }`; every module (~15) has the same shape:
```js
export function create(G) { return { update(dt) {}, dispose() {} }; }   // build + subscribe
export function showcase(G) {}                                         // run alone: ?show=name
const STUBS = { audio: () => ({ play() {}, setIntensity() {}, update() {} }) /* one per module */ };
async function load(name, mod, required = false) {
  try { G[name] = await mod.create(G); }
  catch (e) { console.error(`[boot] ${name} failed`, e);
    if (required || !STUBS[name]) throw e;
    G[name] = STUBS[name](); }                 // degrade: a silent game beats a dead one
}
```
Gotchas: only `render` and `level` are required. Write STUBS first: they are the contract, and a
stub missing one method crashes its caller. Cross-module calls use a guard
`call(obj, 'method', ...args)` that no-ops when absent. Prefix logs per module (`[audio]`).

## 2. Event bus - the only inter-module link

When: always. Modules publish facts (`weapon:fire`, `enemy:killed`, `game:state { state, prev }`)
and never import each other; per-frame state (player pose) is read, never written, off `G`.
```js
const subs = new Map();
const bus = { on: (t, fn) => (subs.get(t) ?? subs.set(t, new Set()).get(t)).add(fn),
  emit: (t, d) => { for (const fn of subs.get(t) ?? []) try { fn(d); } catch (e) { console.error(`[events] ${t}`, e); } } };
```
Gotchas: the try/catch keeps one bad listener local. ~45 `domain:verb` topics carried a full FPS.

## 3. Fault-isolated update loop

When: long sessions where one subsystem bug must not freeze the frame.
```js
const errs = {}, run = (k, dt) => { try { return G[k]?.update?.(dt); }
  catch (e) { if (!errs[k]) { errs[k] = 1; console.error(`[loop] ${k}.update`, e); } } };  // first error only
renderer.setAnimationLoop(() => {
  const dt = frameDt(); run('input', dt);                 // frameDt: section 4
  if (run('game', dt) === true) for (const k of ['player', 'weapon', 'enemies']) run(k, dt);
  if (G.game.state !== 'paused') for (const k of ['fx', 'level']) run(k, dt);
  run('audio', dt); run('hud', dt);                       // alive while paused
  try { G.render.frame(dt); } catch (e) { console.error('[loop] render', e); }
  G.input.endFrame?.(); if (++window.__frames === 2) window.__ready = true;
});
```
Gotchas: `game.update` returns whether gameplay simulates, so player and enemies know nothing of
states. Logging every throw at 60 fps floods the console and tanks the frame. Input runs first,
HUD after what it reads. The reference build used clamped variable dt (50 ms); use the fixed step from
[game-loop.md](game-loop.md) when physics needs determinism.

## 4. Self-verification: showcase harness and headless hooks

When: any game an agent builds or CI captures. This is how the agent checks its own build.
```js
const P = Object.fromEntries(new URLSearchParams(location.search));
Object.assign(window, { __ready: false, __frames: 0, __errors: [] });   // also push 'error' events
const ce = console.error; console.error = (...a) => { __errors.push(a.join(' ').slice(0, 400)); ce(...a); };
window.__stats = () => ({ fps: 1 / avgDt, calls: renderer.info.render.calls, quality: G.quality });
const frameDt = () => (P.dt ? +P.dt : Math.min(rawDt(), 0.05));   // ?step: skip frame unless __step-- > 0
```
Params: `?show=<module>` (showcase on a stub floor), `?seed=` (shared seeded RNG), `?dt=0.0166`,
`?step`, `?cam=x,y,z,lx,ly,lz`, `?q=low..ultra`, `?autostart`, `?noaudio` (forces the stub),
`?bench` (30 s flythrough: avg/p99 ms, GPU, errors). Agent loop: open `?seed=1&dt=0.0166&autostart&noaudio`,
wait for `__ready` (frame 2; frame 1 compiles), assert `__errors` is empty, screenshot, then
`?show=` each module. A failed required module shows a selectable `#fatal` panel, never a native dialog.

## 5. Repainting boot bar and shader warm-up

When: heavy procedural generation at startup. Put the bar in static HTML so it paints before a
1 MB script parses. Each labelled phase sets label and width, then `await new Promise((r) =>
setTimeout(r, 0))`; without that yield between synchronous phases the bar never moves. Last phase:
`await renderer.compileAsync(scene, camera)` for every lighting variant (swap the env map, compile
again), then a ~3.5 s settle window before dynamic resolution reacts. Flavour labels sell the wait.

## 6. State machine: title -> intro -> playing -> paused / dead / complete

When: any game with menus. One `switch` in `game.update`, a time-in-state counter, and
`setState(s)` emitting `game:state` for audio and menus.
- **Title is the live level**: `CatmullRomCurve3` flythrough on a level-authored path, smoothstep
  ease, sine drift, 0.006 rad roll, FOV 50, fade at the seam; scrim one side only. Reused by `?bench`.
- **Intro**: location card at 0.25 s, radio at 0.9 s, play at 2.4 s (retry 1.1 s). **Dead /
  complete**: damp saturation to 0.12 and dim, card after 1.5 s / 3.3 s.
- **Auto-pause** on pointer-lock loss and `visibilitychange`; debounce resume 0.35 s so the Esc
  that released the lock does not resume. Menus: one element, `data-screen` picks the section in CSS.

## 7. Input fallback ladder

When: always, doubly inside iframes (artifacts, itch embeds) where pointer lock can be refused.
Actions are live only while `setGameplay(true)`, except `pause`, so a menu click never fires.
- **Mouse**: rejection, `pointerlockerror`, or no lock within 1.2 s -> drag mode: movement still
  turns, the cursor in the outer 12% x / 10% y turns at a rate scaled by depth into the margin,
  arrows/IJKL turn, Enter fires, a HUD line explains. Drop deltas over 400 px (lock-acquire spikes).
- **Touch**: first `touchstart` (capture) flips mode and builds the overlay lazily. Left 45%:
  floating stick (58 px) spawns under the thumb; right: drag-look. Fire tracks its own touch
  identifier, so dragging it aims while shooting. Ignore mouse events < 800 ms after a touch.
- **Gamepad**: poll `getGamepads()`, prefer `mapping === 'standard'`.
  ```js
  function curve(x, y, dz = 0.14) {               // radial deadzone, rescaled, then 0.25n + 0.75n^3
    const r = Math.hypot(x, y); if (r < dz) return [0, 0];
    const n = Math.min(1, (r - dz) / (1 - dz)), k = (0.25 * n + 0.75 * n ** 3) / r; return [x * k, y * k]; }
  ```
  Vertical 0.62x; turn ramps to 1.75x after > 0.92 held 0.45 s; look scale 0.55 while the reticle
  is on a visible enemy. Device switches re-render prompts ("Hold E" / "Hold X" / "Hold USE").

## 8. Feel

When: any first-person or platforming controller.
```js
coyote = onGround ? 0.12 : Math.max(0, coyote - dt);
buffer = input.pressed('jump') ? 0.13 : Math.max(0, buffer - dt);
if (buffer > 0 && coyote > 0) { vel.y = Math.sqrt(2 * GRAVITY * JUMP_H); buffer = coyote = 0; }
trauma = Math.max(0, trauma - SHAKE_DECAY * dt); const s = trauma * trauma;  // squared: small hits subtle
pitchOff = s * MAX_PITCH * (Math.sin(t * 43.1) + 0.6 * Math.sin(t * 71.7 + 1.3));  // incommensurate sines
```
Recoil splits into a kept and a recovering part. Footsteps fire when stride phase crosses an
integer, so audio follows the bob. Draw the weapon on a second camera at a fixed 54 deg FOV.
**Known gap**: The reference build's reduced-motion only zeroed CSS. When `matchMedia('(prefers-reduced-motion:
reduce)')` matches, also zero camera shake and head bob, and hold the title camera still.

## 9. Gameplay systems

- **Hold-to-interact with decay** (When: interruptible objectives): in range (2.2 m) and facing
  (dot > 0.45) `p = Math.min(1, p + dt / 2.4)`, else `p = Math.max(0, p - dt * 1.6)`. The object
  exposes `userData.setState('live' | 'cutting' | 'cut')` so the level animates it, not the game.
- **Attack tokens** (When: many ranged enemies): only N (2-5 by difficulty) may shoot at once,
  grants spaced by `tokenGap`, alternating types. The main fairness lever.
- **Spawn scoring** (When: waves): `(d < 18 ? -Infinity : 0) + (seesPlayer ? 0 : 2.5) -
  (usedWithin6s ? 3 : 0) + jitter`; take the max, announce the mean bearing ("Contact - SOUTH-WEST").
- **Difficulty as snapshot + overlay** (When: presets): `DEFAULTS = structuredClone(TUNE)` once;
  on change, deep-restore DEFAULTS then deep-merge the preset, so presets never compound.

## 10. DOM HUD driven from 3D state

When: any HUD. DOM over the canvas (`pointer-events: none`, `aria-hidden`), built once, moved
with `translate3d` only. Write-on-change: keep `last[key]` of the rounded value (tape x to 0.5 px,
heading to 1 deg, opacity to 0.05) and skip the DOM write when unchanged.
- **Compass tape**: 4 px/deg, ticks pre-rendered for -90..450 deg so it never wraps, edges faded
  by `mask-image`; markers clamped to the half-width: `rel = ((brg - hdg) % 360 + 540) % 360 - 180`.
- **World markers**: `project(camera)`; behind (`z > 1`) negate x, y; `k = max(|x| / 0.9, |y| / 0.82)`;
  if `k > 1` or behind, divide by `max(k, 1e-3)` and add `offscreen`; hide within 3 m and when
  aiming. Crosshair gap = `tan(spread) / tan(fov / 2) * h / 2 + 4`, matching the real cone.
- **Typewriter radio**: queue `{ text, secs }`, 58 chars/s, hold, advance. The reference build types into its
  `aria-live="polite"` node; better: write the full line once to a visually hidden live node and
  type into an `aria-hidden` twin, so screen readers get one announcement.

## 11. Fully procedural audio

When: zero-download games. Each of ~60 sounds is a generator that fills a buffer and `yield`s
every few thousand samples; a pump calls `next()` for 6 ms, then `setTimeout(pump, 12)`.
- Render boot-critical sounds synchronously; a late request jumps the queue and is dropped when
  over 2.5 s stale. 44.1 kHz guns, 22.05 kHz music; synthesize the reverb impulse responses too.
- **Voice pools** per bus (world 22 HRTF `PannerNode`s, inverse, ref 3 m, rolloff 0.6; gun 18;
  music 3): full -> steal lowest priority, then oldest. Per-sound max; 3.5% pitch, 8% gain jitter.
- Buses -> lowpass (interior) -> compressor -> soft-clip WaveShaper -> output. **Duck** ambience
  and music under gunfire via `setTargetAtTime`: 12 ms attack, 85 ms hold, 100 ms release.
- **Stems**: 7 loops whose gains are smoothstep ranges of one intensity (0.15 calm, 0.6 alert,
  1.0 combat); stingers on bar lines (96 bpm = 2.5 s). Resume the `AudioContext` on first input.

## 12. Validated, versioned settings

When: anything persisted. One versioned key; every storage call in try/catch (sandboxed iframes
and private mode throw); each field clamped or whitelisted, so a stale blob cannot break boot:
```js
const SCHEMA = { sens: [0.2, 3, 1], fov: [60, 95, 75], quality: [['auto', 'low', 'high'], 'auto'] };
let raw = {}; try { raw = JSON.parse(localStorage.getItem('game.settings.v1')) || {}; } catch {}
const fix = (v, [a, b, d]) => (Array.isArray(a) ? (a.includes(v) ? v : b) : Number.isFinite(v) ? Math.min(b, Math.max(a, v)) : d);
const settings = Object.fromEntries(Object.entries(SCHEMA).map(([k, s]) => [k, fix(raw[k], s)]));
```
Apply live through one `applySettings(field)`; save on every input event.

## 13. What one-shot got right vs what the human pass added

The one-shot already had the module contract and stubs, the pointer-lock ladder, touch, gamepad,
HRTF audio, `compileAsync` warm-up, dynamic resolution, versioned settings and attack tokens. Two
human hours added content (wave mode, difficulty presets, sidearm, explosives, music stingers, pad
menu navigation), no structure. Lesson for prompting: name the skeleton in the brief (shared
context, `create`/`showcase` + stubs, bus, guarded loop, test hooks and URL params) and the host
(an iframe: pointer lock may be refused). The agent verifies its own build; humans tune feel.
