# Camera & animation

Camera control, cinematic fly-throughs, and animated data. How-to first, with the
footguns that bite flagged inline.

## Table of contents
- [Camera methods](#camera-methods)
- [fitBounds & cameraForBounds](#fitbounds--cameraforbounds)
- [The `essential` / reduced-motion gotcha](#the-essential--reduced-motion-gotcha)
- [freeCameraOptions — full 3D control](#freecameraoptions--full-3d-control)
- [Animate a point along a line](#animate-a-point-along-a-line)
- [Draw-in a line (progressive reveal)](#draw-in-a-line-progressive-reveal)
- [Animated data & paint transitions](#animated-data--paint-transitions)
- [Spinning globe](#spinning-globe)

## Camera methods

| Method | Use |
|---|---|
| `jumpTo(opts)` | Instant, no animation |
| `easeTo(opts)` | Animated, constant-feel — short hops, pitch/bearing changes |
| `flyTo(opts)` | Zoom-out-arc "flight" — best for long distances |
| `panTo` / `panBy` / `rotateTo` / `snapToNorth` | Single-axis moves |

All take `{center, zoom, bearing, pitch, padding, duration}`. `flyTo` adds the flight
controls: **`curve`** (default 1.42 — higher = bigger zoom-out arc), `speed`,
`screenSpeed`, `minZoom`, `maxDuration`.

```js
map.flyTo({ center:[146.9,-36.1], zoom:14, pitch:55, bearing:-20, curve:1.6, speed:0.8,
            essential:true });
```

## fitBounds & cameraForBounds

```js
map.fitBounds(bounds, { padding:{top:40,bottom:40,left:320,right:40}, maxZoom:15,
                        pitch: map.getPitch(), bearing: map.getBearing() });
```

- **`padding` as an object** is essential when a sidebar/legend/controls overlay the map
  — otherwise the fitted content tucks *under* your UI. Per-edge padding offsets it clear.
- Preserve a 3D camera across fits by passing the current `pitch`/`bearing` (a bare
  `fitBounds` resets them to 0/north).
- **`cameraForBounds(bounds, opts)`** returns the computed `{center, zoom, …}` *without
  moving* — compute it, tweak it (nudge zoom, add pitch), then `easeTo` the result.

## The `essential` / reduced-motion gotcha

Any camera animation is **cancelled immediately** (jumps to the end) for users with
`prefers-reduced-motion: reduce` — **unless you pass `{essential: true}`**. A "fly to the
selected result" that mysteriously *jumps* for some users and animates for others is
almost always this. Pass `essential:true` when the motion conveys meaning; otherwise
honour the preference deliberately. (User scroll/drag also interrupts animations — usually
desired; `essential` doesn't change that.)

## freeCameraOptions — full 3D control

When `flyTo`/`easeTo` can't express the shot (orbit a point, drone pass over terrain, a
camera at a specific altitude looking at a target), drive the camera directly:

```js
const cam = map.getFreeCameraOptions();
const target = [146.9, -36.1];
// position the camera at an altitude, then aim it at the target
cam.position = mapboxgl.MercatorCoordinate.fromLngLat([146.85, -36.15], 4000); // 4 km up
cam.lookAtPoint(target);
map.setFreeCameraOptions(cam);
```

- `MercatorCoordinate.fromLngLat([lng,lat], altitudeMetres)` — the 3rd arg is **metres**.
- To move by real-world distance, scale with
  `MercatorCoordinate.fromLngLat(c).meterInMercatorCoordinateUnits()`.
- Orbit: in a RAF loop, advance an angle and recompute `position` on a circle around the
  target, `lookAtPoint(target)` each frame.
- With terrain on, the camera **collides** with the DEM (won't sink below ground); for low
  passes set an altitude safely above the terrain.

## Flight / first-person camera (drone, fly-through, sim)

Continuous first-person movement — a flight sim, drone pass, or walkthrough — drives the
camera every frame from a `{lng, lat, alt, heading, pitch, speed}` state.

- **Native camera:** Mapbox GL JS has **no camera roll** — only `bearing` + `pitch`.
  "Banked" turns are choreography: sweep `bearing` through the turn while easing `pitch`
  up a few degrees; the combined motion reads as a bank even though the horizon stays
  level. Per-frame `jumpTo` is instant (no easing lag):

```js
const s = { lng:146.9, lat:-36.1, alt:1500, heading:0, pitch:75, speed:0 };
function fly() {
  // advance along heading by speed (deg/frame ≈ metres → deg)
  const rad = s.heading * Math.PI/180, d = s.speed * 1e-5;
  s.lat += Math.cos(rad) * d; s.lng += Math.sin(rad) * d;
  map.jumpTo({ center:[s.lng,s.lat], bearing:s.heading, pitch:s.pitch });
  requestAnimationFrame(fly);
}
fly();   // A/D → s.heading, W/S → s.pitch, R/F → s.speed (key handlers)
```

- **Full positional control** (camera at an exact altitude, aimed at a target): use
  `freeCameraOptions` — set `position = MercatorCoordinate.fromLngLat([lng,lat], alt)`
  and orientation each frame. This does **not** unlock roll either: the orientation
  quaternion "must be representable using only pitch and bearing" (per the
  FreeCameraOptions docs — a non-conforming orientation is discarded). freeCamera buys
  position freedom, not a rolled horizon.
- **Need true roll?** Switch libraries — MapLibre GL JS v5 added first-class camera roll
  (`easeTo`/`flyTo({roll})`, `map.setRoll`) plus pitch beyond 90°. Mapbox GL JS has no
  equivalent on any camera API.
- Cap pitch near 85° — the native camera's hard maximum (`maxPitch`); a nose-down or
  looking-up shot past that is likewise MapLibre-v5-only territory.

## Animated day–night cycle

- **Discrete (Standard style):** step `setConfigProperty("basemap","lightPreset", …)`
  through `dawn→day→dusk→night` on a timer — snaps between four looks (cheap, no reload).
- **Smooth (3D lights):** drive the v3 lights API and move the sun — animate the
  directional light's direction by clock for a continuous sweep:

```js
map.setLights([
  { id:"ambient", type:"ambient", properties:{ intensity:0.5 } },
  { id:"sun", type:"directional",
    properties:{ direction:[azimuthDeg, polarDeg], intensity:0.8, "cast-shadows":true } }
]);
// in a slow loop, advance azimuth/polar to sweep the sun → moving shadows, warm→cool light
```

## HUD synced to camera state

A telemetry overlay (speed, heading, altitude) is absolutely-positioned DOM updated from
the camera. Read state on `"move"`/`"render"` (not a free-running RAF) so it idles cheaply:

```js
map.on("render", () => {
  hud.heading.textContent = Math.round(map.getBearing());
  hud.pitch.textContent   = Math.round(map.getPitch());
  hud.alt.textContent     = Math.round(map.getFreeCameraOptions().position.toAltitude());
});
```

`getFreeCameraOptions().position.toAltitude()` is the live camera altitude in metres —
the only way to read it (there's no `map.getAltitude()`).

## Animate a point along a line

`requestAnimationFrame` loop advancing a distance; get the point with Turf
(`@turf/along`) or manual segment interpolation; `setData` a one-point source. Rotate an
icon with `@turf/bearing`.

```js
let phase = 0, raf;
const line = trail.features[0], total = turf.length(line);   // km
function frame() {
  phase = (phase + 0.02) % total;
  const pt = turf.along(line, phase);
  map.getSource("mover").setData(pt);
  raf = requestAnimationFrame(frame);
}
frame();
// cancelAnimationFrame(raf) on teardown — see lifecycle.md (leaked RAF loops survive map.remove)
```

## Draw-in a line (progressive reveal)

Two options:
- **Cheap:** one `line-gradient` over `["line-progress"]` and animate a single colour
  stop from 0→1 (no geometry churn). Needs `lineMetrics:true` (see
  [lines-and-trails.md](lines-and-trails.md)).
- **Simple:** slice the coordinates up to `phase` and `setData` each frame (more work,
  but lets you also drop a moving "head" marker).

## Animated data & paint transitions

**Paint** properties transition smoothly on change (layout properties do not). Set the
transition then update the value:

```js
map.setPaintProperty("choro", "fill-color-transition", { duration: 600, delay: 0 });
map.setPaintProperty("choro", "fill-color", nextRamp);   // animates over 600 ms
```

For continuous data updates, `setData` on a RAF/interval — but batch and throttle; every
`setData` re-tiles the source (see [interaction-and-performance.md](interaction-and-performance.md)).

## Spinning globe

```js
function spin() {
  if (userInteracting || map.getZoom() > 5) return;
  const c = map.getCenter(); c.lng -= 2;
  map.easeTo({ center: c, duration: 1000, easing: t => t });   // linear, seamless loop
}
map.on("moveend", spin);   // chain each ease into the next; pause on user interaction
```
