---
name: genart-ops
description: "Generative art programming - three.js scenes, p5.js sketches, SVG generation, GLSL shaders, procedural algorithms, and color for creative coding. Use for: generative art, creative coding, three.js, p5.js, SVG, GLSL, shader, noise, perlin, simplex, flow field, particle system, SDF, ray marching, procedural, L-system, voronoi, delaunay, cellular automata, wave function collapse, instanced mesh, post-processing, bloom, WebGL, canvas, fragment shader, vertex shader, FBM, domain warping."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: color-ops, javascript-ops, typescript-ops, mapbox-ops, threejs-ops
---

# Generative Art Operations

Practical patterns for creative coding and generative art. Covers three.js, p5.js, SVG generation, GLSL shaders, procedural algorithms, and color theory for computational aesthetics.

> Color-ops handles CSS color, accessibility, and design tokens. This skill focuses on generative/procedural color techniques (palette algorithms, shader color, gradient interpolation in perceptual space).
>
> Application/game-scale three.js — GLTF asset pipelines, AnimationMixer, fixed-timestep game loops, physics (rapier/cannon-es), react-three-fiber, instancing/disposal at scale — is [threejs-ops](../threejs-ops/SKILL.md). This skill owns the creative/shader side of three.js.

The detailed code, technique walkthroughs, and parameter tables live in the
references below. This body holds the decisions: which surface, which algorithm,
which color space, in what order.

## Workflow & tool selection

Pick the **rendering surface** first — it determines everything downstream:

| Goal | Surface | Reference |
|---|---|---|
| 2D sketches, fast iteration, teaching | p5.js (Canvas2D or WebGL) | [p5-sketches](references/p5-sketches.md) |
| 3D scenes, camera, lighting, post-processing | three.js | [threejs-scenes](references/threejs-scenes.md) |
| Per-pixel fields, full-screen shaders, ray marching | raw GLSL / WebGL fragment | [glsl-shaders](references/glsl-shaders.md) |
| Resolution-independent vectors, plotter/print | SVG | [svg-generation](references/svg-generation.md) |

Then **generate content** (CPU) and **colorize** it (perceptual space):

| Need | Algorithm family | Reference |
|---|---|---|
| Organic texture, terrain, marble | noise (value/simplex/FBM/domain-warp) | [procedural-algorithms](references/procedural-algorithms.md) |
| Even point distribution | Poisson disk | [procedural-algorithms](references/procedural-algorithms.md) |
| Trees, fractals, self-similar curves | L-systems | [procedural-algorithms](references/procedural-algorithms.md) |
| Emergent motion/patterns | flow fields / cellular automata | [procedural-algorithms](references/procedural-algorithms.md) |
| Space partitioning | Voronoi / Delaunay (d3-delaunay) | [procedural-algorithms](references/procedural-algorithms.md) |
| Tile worlds with adjacency rules | wave function collapse | [procedural-algorithms](references/procedural-algorithms.md) |
| Palettes, gradients, harmonies | OKLAB / OKLCH | [color-and-palettes](references/color-and-palettes.md) |

**Order of operations:** surface → generators → color. Determinism = seeded RNG
(`alea`) + no per-frame `Math.random()` inside the field/particle loop.

## 1. Three.js scenes

Creative/shader-side scaffolding: minimal scene + camera + renderer (ACES tone
mapping, responsive resize), the 2026 `THREE.Timer` animation loop (auto-pauses
on tab switch), `OrbitControls` (damping requires `update()` per frame), a
three-point lighting rig (key/fill/rim + ambient), bloom via `EffectComposer`
(`OutputPass` always last — it owns tone mapping), `InstancedMesh` for 10k+
particle/mass-geometry systems with per-instance color, and a custom
`ShaderMaterial` template (uTime/uResolution/uMouse uniforms). Full code in
[references/threejs-scenes.md](references/threejs-scenes.md).

## 2. p5.js sketches

Mode selection drives everything: **global** (one sketch, fastest path to
pixels), **instance** (multiple sketches per page, module isolation), **WebGL**
(3D, lights, `orbitControl`). Plus custom GLSL via `createShader`,
`loadPixels`/`updatePixels` per-pixel manipulation, and recording/export — PNG
frame sequences, SVG output (p5.js-svg), and `canvas-sketch` for high-res
Canvas2D + MP4 streaming. Full code in
[references/p5-sketches.md](references/p5-sketches.md).

## 3. SVG generation

Resolution-independent vector output. Programmatic construction
(`createElementNS` + `XMLSerializer`), the full path-command reference
(M/L/H/V/C/S/Q/T/A/Z, absolute + relative), generative patterns (organic blobs
via smooth closed cubic paths, line hatching), generative SVG filters
(`feTurbulence` / `feDisplacementMap` / `feDiffuseLighting`), SMIL + CSS
animation, and SVGO optimization (preserve viewBox, drop dimensions for
responsive output). Full code in
[references/svg-generation.md](references/svg-generation.md).

## 4. GLSL shaders

The GPU fragment-shader toolbox: standalone WebGL boilerplate (fullscreen
quad), common uniforms, hash/random functions, value / simplex / Worley noise,
FBM, domain warping (single + double, Inigo Quilez), 2D & 3D SDF primitives,
boolean / smooth / transform SDF operations, a full ray-marching template
(normal estimation + lighting), and cosine-palette color blending. Full code in
[references/glsl-shaders.md](references/glsl-shaders.md). Several of these
(noise, FBM, domain warping) have CPU/JS counterparts in
[procedural-algorithms](references/procedural-algorithms.md) — pick the surface,
then reuse the math.

## 5. Procedural generation algorithms

CPU-side recipes in JavaScript: Perlin/simplex noise (`simplex-noise` + `alea`
seeding), FBM, domain warping, ridged noise, flow fields (with particle
drivers), Poisson disk sampling, L-systems (trees / Koch / Sierpinski / dragon),
Conway's Game of Life, Voronoi/Delaunay via `d3-delaunay` (+ Lloyd relaxation),
wave function collapse (simple tiled), terrain from noise octaves (+ biome
classification), and seamless toroidal tiling. Full code in
[references/procedural-algorithms.md](references/procedural-algorithms.md).

## 6. Color & palettes

OKLAB/OKLCH conversion (both JS and GLSL — the perceptually-uniform basis for
everything here), cosine palettes (Quilez presets), OKLCH palette generators
(even-hue, analogous, warm/cool), gradient interpolation in perceptual space
(OKLCH with shortest-hue path, multi-stop), color cycling (phase-shifted per
element), and harmony rules (complementary / analogous / triadic /
split-complementary / tetradic). Full code in
[references/color-and-palettes.md](references/color-and-palettes.md).

## Quick Reference: Noise Algorithm Comparison

| Algorithm | Dimension | Character | Cost | Use Case |
|-----------|-----------|-----------|------|----------|
| Value noise | Any | Blocky, grid artifacts | Cheap | Quick prototypes |
| Perlin (gradient) | Any | Smooth, directional | Medium | Classic terrain, clouds |
| Simplex | Any | Smooth, isotropic | Medium | Default choice, fewer artifacts than Perlin |
| Worley (cellular) | Any | Cell-like, organic | Expensive | Stone, water, cells |
| FBM | Any | Fractal detail | N * base | Terrain, clouds, organic shapes |
| Ridged FBM | Any | Sharp mountain ridges | N * base | Mountains, lightning |
| Domain warping | 2D+ | Swirling, marble-like | 3-9x base | Marble, smoke, alien landscapes |

## Quick Reference: Libraries

| Task | Library | Install |
|------|---------|---------|
| Noise | `simplex-noise` | `npm install simplex-noise` |
| Seeded random | `alea` | `npm install alea` |
| Voronoi/Delaunay | `d3-delaunay` | `npm install d3-delaunay` |
| 3D engine | `three` | `npm install three` |
| 2D canvas | `p5` | `npm install p5` |
| Canvas export | `canvas-sketch` | `npm install canvas-sketch` |
| Video export | `ccapture.js` | `npm install ccapture.js` |
| SVG optimize | `svgo` | `npm install -g svgo` |
| Color | `culori` | `npm install culori` |
| Shader library | LYGIA | `#include` from lygia.xyz |

## Bundled references

| Reference | Load when |
|---|---|
| [threejs-scenes.md](references/threejs-scenes.md) | Scaffolding a creative three.js scene — scene/camera/renderer, Timer loop, controls, lighting, bloom, InstancedMesh, ShaderMaterial |
| [p5-sketches.md](references/p5-sketches.md) | p5.js global/instance/WebGL modes, custom shaders, pixel manipulation, recording/export |
| [svg-generation.md](references/svg-generation.md) | Programmatic SVG, path commands, generative patterns, filters, animation, SVGO |
| [glsl-shaders.md](references/glsl-shaders.md) | GLSL boilerplate, hash/noise, FBM, domain warping, SDFs, ray marching, palette blending |
| [procedural-algorithms.md](references/procedural-algorithms.md) | JS procedural recipes — noise, flow fields, Poisson disk, L-systems, CA, Voronoi, WFC, terrain, tiling |
| [color-and-palettes.md](references/color-and-palettes.md) | OKLAB/OKLCH conversion (JS+GLSL), palette generation, perceptual gradients, cycling, harmonies |

## See Also

- `color-ops` - CSS color, accessibility, design tokens, palette scripts
- `javascript-ops` - JS async patterns, modules, ES2024+ features
- [Book of Shaders](https://thebookofshaders.com/) - GLSL fundamentals
- [Shadertoy](https://www.shadertoy.com/) - Live shader playground
- [Inigo Quilez articles](https://iquilezles.org/articles/) - SDF, noise, ray marching
- [LYGIA](https://lygia.xyz/) - Cross-platform shader library
- [Red Blob Games](https://www.redblobgames.com/) - Procedural generation algorithms
