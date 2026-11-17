# Verification harness - an agent checks its own browser game, headless

The test side of self-verification: the in-game test API, then the Playwright tools that measure stills, frame time, stability, cold start, film and host protocol.
Source: "Oil paint" by blendi, https://patch.gg/blendi/oil-paint (three.js 0.186, MIT); code adapted from blendi/oil-paint (MIT).
The game-side hooks (`__ready`, `__frames`, `__errors`, `__stats`, `?seed`, `?dt`, `?show`) are in [game-architecture.md](game-architecture.md) section 4; not repeated here.

## Contents

1. The in-game test API: `window.lab`
2. GPU-fenced warm-up before `ready`
3. Harness base: test the build, launch, guard the cursor
4. Named stills from a pose table
5. Frame time: two methods
6. Temporal stability: PSNR between two standing frames
7. Cold start under throttling, with a hitch detector
8. Deterministic MP4 capture
9. Host-protocol smoke test
10. Budgets that fail the build

## 1. The in-game test API: `window.lab`

When: any game a tool must drive. One object, built next to the loop, so tools never reach into modules.
```js
const q = new URLSearchParams(location.search), capture = q.has('capture');
window.lab = {
  ready: false, timings, counts,                       // timings: per-phase ms from lap('shaders') etc.
  step(dt = 1 / 60, n = 1) { for (let i = 0; i < n; i++) tick(dt); },   // the only clock under ?capture
  setInput(fn) { input.override = fn; },               // fn(dt) -> whole input state; null = real devices
  teleport(x, z, fx, fz) { /* place on ground facing (fx, fz), zero velocity, reset animator, tick(1/60) */ },
  view(eye, target) { camera.fixed = eye && { eye, target }; },        // view(null) = follow again
  renderer, player, follow,                            // read-only handles for tools
};
if (!capture) renderer.setAnimationLoop(loop);         // capture: time moves only when a tool steps it
```
| Flag | Effect |
|---|---|
| `?capture` | no animation loop, pixel ratio 1, skip warm-up; `lab.step` is the clock |
| `?nopad` | gamepads off: headless Chrome reports the host's real pad, so stick drift leaks into tests |
| `?clean` | remove hint and overlay DOM so stills and fps runs see only the scene |
| `?quality=low` | the low tier; wins over any platform performance setting |
Gotchas: `setInput` replaces the whole state (`move`, `look`, `jump`, `sprint`, `zoom`, `device`), so return every field. Clamp `dt` in `tick` (oil paint: 1/20) so a stalled tool cannot explode physics. Teleport must reset velocity and animation state, or the first frame shows a skid.

## 2. GPU-fenced warm-up before `ready`

When: any harness or platform that waits on "ready". JavaScript finishing is not the GPU finishing.
```js
function gpuDone(gl = renderer.getContext()) {
  const sync = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0); gl.flush();
  return new Promise((ok) => (function poll() {
    if (gl.clientWaitSync(sync, 0, 0) === gl.TIMEOUT_EXPIRED) return void setTimeout(poll, 4);
    gl.deleteSync(sync); ok(); })());
}
await renderer.compileAsync(scene, camera); lap('shaders');
for (let i = 0; i < 5; i++) { tick(1 / 60); await gpuDone(); }   // real frames: lazy programs, uploads
lap('first frame'); lab.ready = true;
```
Gotchas: poll with timeout 0; a blocking `clientWaitSync` stalls the main thread. Under `?capture` the source skips all of this, so the first `step` compiles synchronously: never time the first frames of a capture run. WebGL2 only (`fenceSync`).

## 3. Harness base: test the build, launch, guard the cursor

When: every tool below. Serve `dist/`, not the dev server: that is what ships.
```js
import { chromium } from 'playwright-core';
import { guard } from './no-pointer-lock.mjs';
guard(chromium);                                  // every context gets the fake pointer lock
const server = createServer(serveDist).listen(PORT, '127.0.0.1');   // no-store, 404 outside dist
const browser = await chromium.launch({ executablePath: process.env.CHROME, headless: true,
  args: ['--mute-audio', '--ignore-gpu-blocklist', '--use-angle=d3d11', '--enable-gpu'] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
const errors = []; page.on('pageerror', (e) => errors.push(e.message));
await page.goto(`http://127.0.0.1:${PORT}/?capture&nopad`);
await page.waitForFunction(() => window.lab?.ready, null, { timeout: 120_000 });
```
The fake pointer lock: a game calling `requestPointerLock` in a Playwright browser on Windows locks the real OS cursor to the hidden window. Fake it in an init script so the game still sees the lock:
```js
export function fakePointerLock() {
  let locked = null; const fire = () => document.dispatchEvent(new Event('pointerlockchange'));
  Element.prototype.requestPointerLock = function () { locked = this; queueMicrotask(fire); return Promise.resolve(); };
  Document.prototype.exitPointerLock = function () { locked = null; queueMicrotask(fire); };
  Object.defineProperty(Document.prototype, 'pointerLockElement', { configurable: true, get: () => locked });
}
```
`guard(browserType)` wraps `launch`, `connectOverCDP` and `launchPersistentContext` so each new context gets `addInitScript(fakePointerLock)` (`newPage` goes through `newContext`). Gotchas: `CHROME` from env, never a hard-coded path; fail on `errors.length` at the end; in the game, still catch the refusal: `el.requestPointerLock?.()?.catch?.(() => {})`.

## 4. Named stills from a pose table

When: a regression set you re-shoot after every visual change.
```js
// name: [x, z, lookX, lookZ, { run: s of running first, pitch, dist, yaw, view: [eye, target] }]
export const VIEWS = { start: [0, 78, -2, 50, { run: 0 }], running: [-6, 58, 3, 32, { run: 2.2 }],
  high: [0, 70, -2, 50, { view: [[3, 15, 78], [-2, 0, 38]] }] };
```
Per view: `view(null)`, `teleport`, set pitch and distance, script "run forward", `step(max(run, 0.5) * 60)`, optional yaw swing or fixed `view`, screenshot, and log `{at, mode, speed}` beside the PNG so a bad shot can be told from a bad pose. Add `--view "x,z,fx,fz,..." --name n` for one-offs. Gotcha: dedupe console errors and print them once at the end.

## 5. Frame time: two methods

**Stepped, GPU-synced** (When: comparing a shader change, any machine). A 1-pixel `readPixels` forces the GPU to finish each frame, so the number is CPU plus GPU without vsync:
```js
const ms = await page.evaluate(() => { const L = lab, gl = L.renderer.getContext(), px = new Uint8Array(4);
  L.step(1 / 60, 30); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);       // settle first
  const t = performance.now(); for (let i = 0; i < 240; i++) { L.step(1 / 60); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); }
  return (performance.now() - t) / 240; });
```
**Real loop, uncapped** (When: a performance claim in a README or release note). Drop `?capture`, add `?clean`, launch with `--disable-gpu-vsync --disable-frame-rate-limit`, script movement, wait 1.5 s, then collect rAF deltas in the page for 8 s and return sorted `{ frames, fps: 1000 / mean, median, p99, worst }`.
Gotchas: the readPixels method stalls the pipeline, so it reads slower than real play; quote it only relative to itself. Benchmark on a quiet GPU (the author serialised runs behind a lock); anything else drawing ruins both numbers.

## 6. Temporal stability: PSNR between two standing frames

When: a world-anchored effect must not shimmer while nothing moves (paint dabs, dither, TAA, impostors, shadow acne).
```js
const input = (y) => page.evaluate((y) => lab.setInput(() => ({ move: { x: 0, y }, look: { x: 0, y: 0 },
  walk: true, sprint: false, strafe: false, jump: false, zoom: 0, device: 'keyboard' })), y);
await page.evaluate(() => { lab.teleport(4, 30, 10, 6); lab.follow.pitch = 0.2; });
await input(0); await page.evaluate(() => lab.step(1 / 60, 90));        // settle the camera
await page.screenshot({ path: 'a.png' }); await page.evaluate(() => lab.step(1 / 60, 20));
await page.screenshot({ path: 'b.png' });
const crop = 'crop=900:420:400:620';                                    // ground round the feet only
const r = spawnSync('ffmpeg', ['-hide_banner', '-i', 'a.png', '-i', 'b.png', '-lavfi',
  `[0]${crop}[x];[1]${crop}[y];[x][y]psnr`, '-f', 'null', '-'], { encoding: 'utf8' });
const psnr = Number(/average:(inf|[\d.]+)/.exec(r.stderr)?.[1].replace('inf', 'Infinity'));
spawnSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', 'a.png', '-i', 'b.png', '-lavfi',
  `[0]${crop}[x];[1]${crop}[y];[x][y]blend=all_mode=difference,eq=contrast=3`, 'diff.png']);
if (!(psnr >= PSNR_FLOOR)) { console.error(`shimmer: PSNR ${psnr} < ${PSNR_FLOOR}`); process.exit(1); }
```
Gotchas: ffmpeg prints PSNR on stderr. Crop away anything that legitimately moves (falling leaves, water, UI); wind still advances between A and B, so "inf" is not expected. Keep the boosted diff image: it shows where it shimmers, for a human or for a vision check.

## 7. Cold start under throttling, with a hitch detector

When: before publishing, against the real hosted URL as well as `dist`.
```js
for (let run = 1; run <= RUNS; run++) {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.CHROME,
    args: ['--mute-audio', '--ignore-gpu-blocklist', '--use-angle=d3d11'] });
  const context = await browser.newContext({ viewport: { width: 1280, height: 720 } });   // empty caches
  const page = await context.newPage();
  await page.addInitScript(() => {                         // before any page script runs
    Element.prototype.requestPointerLock = function () { return Promise.resolve(); };
    const f = (window.__hitch = { last: 0, slow: [] });
    const tick = (now) => { if (f.last && now - f.last > 50) f.slow.push(`${Math.round(now - f.last)}@${(now / 1000).toFixed(2)}`);
      f.last = now; requestAnimationFrame(tick); };
    requestAnimationFrame(tick);
  });
  const cdp = await context.newCDPSession(page);
  await cdp.send('Network.enable');
  await cdp.send('Network.emulateNetworkConditions', { offline: false, latency: 40,
    downloadThroughput: 30e6 / 8, uploadThroughput: 10e6 / 8 });
  await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 });
  const t0 = Date.now(); await page.goto(URL);
  await page.waitForFunction(() => window.__block?.ready, null, { timeout: 180_000, polling: 50 });
  const take = () => page.evaluate(() => window.__hitch.slow.splice(0));
  const ready = (Date.now() - t0) / 1000, loading = (await take()).filter((s) => parseInt(s) > 300);
  await page.waitForTimeout(2500); const standing = await take();
  await page.mouse.click(640, 360); await page.keyboard.down('KeyW');   // real input, not setInput
  await page.waitForTimeout(2500); await page.keyboard.up('KeyW'); const walking = await take();
  console.log(JSON.stringify({ run, ready, loading, standing, walking, laps: await page.evaluate(() => window.__block.timings) }));
  await browser.close();
}
```
Gotchas: a new browser per run, or the shader and HTTP caches lie. Loading gaps under 300 ms are noise; after ready, any gap over 50 ms is a finding. Expose a plain global (`window.__block = { ready, timings }`) for tools that cannot assume `lab`. GPU load from other apps slows compiling a lot: record what else was running.

## 8. Deterministic MP4 capture

When: a hover clip, release film or before/after comparison. The stepped clock keeps it smooth however slow each screenshot is, and two runs give the same frames.
- Path-following camera through `setInput`: find the nearest path point, aim 9 points ahead, turn by `-turn * Math.min(1, dt * 1.6)` (slow chase), stand still for the first 1.2 s and stop near the end.
- Per output frame: `lab.step(1 / 60, 2)` (two sim ticks = 30 fps of real time), then `screenshot({ type: 'jpeg', quality: 93 })` to `f0000.jpg`...
- Assemble: `ffmpeg -framerate 30 -i f%04d.jpg -c:v libx264 -pix_fmt yuv420p -crf 23 -movflags +faststart out.mp4`.
Gotchas: `yuv420p` or many players show nothing; `+faststart` so the web can play it before the download ends; frames go to an ignored work folder.

## 9. Host-protocol smoke test

When: the game ships inside a host page (Patch blocks, itch or artifact iframes). Oil paint's recipe declares `{ "mode": "browser", "test": { "move_keys": ["KeyW"] } }`; Patch's harness is internal, so rebuild its checks:
1. Embed `dist` in a parent page; post `{ channel: 'patch-block', type: 'hello' }`; expect `ready` then `state`.
2. Post junk messages (wrong channel, unknown type, `set` before ready); expect no `pageerror`.
3. Post `visible: false`, then `true`; expect `stats` about every second while visible.
4. Click the canvas, screenshot, hold each `move_keys` key for 1.5 s with real `keyboard.down`, screenshot; assert the frames differ (PSNR below a ceiling, reusing section 6).
Gotchas: step 4 needs real keyboard input working without pointer lock and without a pad, which is why the guard and `?nopad` exist. A game with nothing to move leaves `move_keys` empty.

## 10. Budgets that fail the build

The source only prints its size (`dist: 26 MB`); nothing fails. Make each number a gate in `check`:
| Budget | Check | Fail when |
|---|---|---|
| Download | walk `dist/`, sum bytes | `bytes > BUDGET_MB * 1048576`; print the top 5 files |
| Frame time | section 5 stepped method at a fixed size and `?quality` | median ms over budget, against a baseline from the same machine |
| Stability | section 6 PSNR on each named crop | PSNR below the floor (set it from a known-good build, minus a margin) |
| Cold start | section 7, 3 runs, take the median | `ready` over budget, or any post-ready gap over 100 ms |
| Errors | every tool | any `pageerror` or console error |
Gotchas: frame-time and cold-start gates are machine-bound; store baselines per machine name and skip, not pass, when there is none.

Keep these servers throwaway: each tool binds its port, serves only `dist/`, and closes the server when the run ends.
