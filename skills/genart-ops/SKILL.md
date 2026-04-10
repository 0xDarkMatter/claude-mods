---
name: genart-ops
description: "Generative art programming - three.js scenes, p5.js sketches, SVG generation, GLSL shaders, procedural algorithms, and color for creative coding. Use for: generative art, creative coding, three.js, p5.js, SVG, GLSL, shader, noise, perlin, simplex, flow field, particle system, SDF, ray marching, procedural, L-system, voronoi, delaunay, cellular automata, wave function collapse, instanced mesh, post-processing, bloom, WebGL, canvas, fragment shader, vertex shader, FBM, domain warping."
license: MIT
allowed-tools: "Read Write Bash"
metadata:
  author: claude-mods
  related-skills: color-ops, javascript-ops, typescript-ops
---

# Generative Art Operations

Practical patterns for creative coding and generative art. Covers three.js, p5.js, SVG generation, GLSL shaders, procedural algorithms, and color theory for computational aesthetics.

> Color-ops handles CSS color, accessibility, and design tokens. This skill focuses on generative/procedural color techniques (palette algorithms, shader color, gradient interpolation in perceptual space).

---

## 1. Three.js -- Scene Scaffolding (2026)

### Minimal Scene

```javascript
import * as THREE from 'three';

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(
  75,                                    // fov
  window.innerWidth / window.innerHeight, // aspect
  0.1,                                   // near
  1000                                   // far
);
camera.position.set(0, 2, 5);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(window.devicePixelRatio);
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.toneMapping = THREE.ACESFilmicToneMapping;
document.body.appendChild(renderer.domElement);

// --- Responsive ---
window.addEventListener('resize', () => {
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
});
```

### Animation Loop (Timer-based, 2026 pattern)

```javascript
const timer = new THREE.Timer();
timer.connect(document); // auto-pauses on tab switch

renderer.setAnimationLoop(() => {
  timer.update();
  const delta = timer.getDelta();
  const elapsed = timer.getElapsed();

  // animate objects using delta/elapsed
  mesh.rotation.y += delta;

  renderer.render(scene, camera);
});
```

### OrbitControls

```javascript
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.05;
controls.maxPolarAngle = Math.PI * 0.5;
controls.minDistance = 2;
controls.maxDistance = 20;

// Must call update in animation loop when damping enabled
renderer.setAnimationLoop(() => {
  controls.update();
  renderer.render(scene, camera);
});
```

### Lighting Rig (Three-point)

```javascript
// Key light
const key = new THREE.DirectionalLight(0xffffff, 1.5);
key.position.set(5, 5, 5);
scene.add(key);

// Fill light (softer, opposite side)
const fill = new THREE.DirectionalLight(0x8888ff, 0.5);
fill.position.set(-5, 3, -5);
scene.add(fill);

// Rim / back light
const rim = new THREE.DirectionalLight(0xffffff, 0.8);
rim.position.set(0, 5, -10);
scene.add(rim);

// Ambient baseline
scene.add(new THREE.AmbientLight(0x404040, 0.5));
```

### Post-Processing Pipeline (Bloom)

```javascript
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';

const composer = new EffectComposer(renderer);
composer.addPass(new RenderPass(scene, camera));

const bloomPass = new UnrealBloomPass(
  new THREE.Vector2(window.innerWidth, window.innerHeight),
  1.5,  // strength
  0.4,  // radius
  0.85  // threshold
);
composer.addPass(bloomPass);
composer.addPass(new OutputPass()); // always last -- handles tone mapping

// In animation loop: composer.render() instead of renderer.render()
// On resize: composer.setSize(width, height)
```

### InstancedMesh (Particle Systems / Mass Geometry)

```javascript
const geometry = new THREE.SphereGeometry(0.05, 8, 8);
const material = new THREE.MeshStandardMaterial({ color: 0xff6600 });
const COUNT = 10000;

const mesh = new THREE.InstancedMesh(geometry, material, COUNT);
scene.add(mesh);

const dummy = new THREE.Object3D();
const matrix = new THREE.Matrix4();

for (let i = 0; i < COUNT; i++) {
  dummy.position.set(
    (Math.random() - 0.5) * 40,
    (Math.random() - 0.5) * 40,
    (Math.random() - 0.5) * 40
  );
  dummy.updateMatrix();
  mesh.setMatrixAt(i, dummy.matrix);
}
mesh.instanceMatrix.needsUpdate = true;

// Per-instance color
const color = new THREE.Color();
for (let i = 0; i < COUNT; i++) {
  color.setHSL(Math.random(), 0.8, 0.6);
  mesh.setColorAt(i, color);
}
mesh.instanceColor.needsUpdate = true;

// Animate instances
function animateInstances(elapsed) {
  for (let i = 0; i < COUNT; i++) {
    mesh.getMatrixAt(i, matrix);
    matrix.decompose(dummy.position, dummy.quaternion, dummy.scale);
    dummy.position.y += Math.sin(elapsed + i * 0.1) * 0.001;
    dummy.updateMatrix();
    mesh.setMatrixAt(i, dummy.matrix);
  }
  mesh.instanceMatrix.needsUpdate = true;
}
```

### Custom ShaderMaterial

```javascript
const shaderMaterial = new THREE.ShaderMaterial({
  uniforms: {
    uTime: { value: 0 },
    uResolution: { value: new THREE.Vector2(window.innerWidth, window.innerHeight) },
    uMouse: { value: new THREE.Vector2(0, 0) },
    uColor: { value: new THREE.Color(0x3b82f6) },
  },
  vertexShader: /* glsl */ `
    varying vec2 vUv;
    varying vec3 vPosition;
    uniform float uTime;

    void main() {
      vUv = uv;
      vPosition = position;
      vec3 pos = position;
      pos.z += sin(pos.x * 3.0 + uTime) * 0.2;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(pos, 1.0);
    }
  `,
  fragmentShader: /* glsl */ `
    uniform float uTime;
    uniform vec2 uResolution;
    uniform vec3 uColor;
    varying vec2 vUv;

    void main() {
      vec3 col = uColor * (0.5 + 0.5 * sin(vUv.x * 10.0 + uTime));
      gl_FragColor = vec4(col, 1.0);
    }
  `,
  side: THREE.DoubleSide,
});

// Update in animation loop:
shaderMaterial.uniforms.uTime.value = elapsed;
```

---

## 2. p5.js -- Sketch Patterns (2026)

### Global Mode (Quick Sketching)

```javascript
function setup() {
  createCanvas(800, 800);
  colorMode(HSB, 360, 100, 100, 100);
  noStroke();
}

function draw() {
  background(0, 0, 10);
  for (let i = 0; i < 100; i++) {
    let x = random(width);
    let y = random(height);
    fill(random(360), 80, 90, 50);
    circle(x, y, random(5, 30));
  }
}
```

### Instance Mode (Multiple Sketches / Modules)

```javascript
const sketch = (p) => {
  let particles = [];

  p.setup = () => {
    p.createCanvas(800, 800);
    p.colorMode(p.HSB, 360, 100, 100, 100);
    for (let i = 0; i < 200; i++) {
      particles.push({
        x: p.random(p.width),
        y: p.random(p.height),
        vx: p.random(-1, 1),
        vy: p.random(-1, 1),
        hue: p.random(360),
      });
    }
  };

  p.draw = () => {
    p.background(0, 0, 5, 10); // trailing fade
    for (let pt of particles) {
      pt.x += pt.vx;
      pt.y += pt.vy;
      if (pt.x < 0 || pt.x > p.width) pt.vx *= -1;
      if (pt.y < 0 || pt.y > p.height) pt.vy *= -1;
      p.fill(pt.hue, 80, 90, 60);
      p.noStroke();
      p.circle(pt.x, pt.y, 6);
    }
  };
};

new p5(sketch, document.getElementById('canvas-container'));
```

### WebGL Mode

```javascript
function setup() {
  createCanvas(800, 800, WEBGL);
}

function draw() {
  background(0);
  orbitControl();
  ambientLight(60);
  directionalLight(255, 255, 255, 0.5, -1, -0.5);

  push();
  rotateX(frameCount * 0.01);
  rotateY(frameCount * 0.013);
  normalMaterial();
  torus(150, 50, 24, 16);
  pop();
}
```

### Custom Shaders in p5.js

```javascript
let myShader;

const vertSrc = `
  precision highp float;
  uniform mat4 uModelViewMatrix;
  uniform mat4 uProjectionMatrix;
  attribute vec3 aPosition;
  attribute vec2 aTexCoord;
  varying vec2 vTexCoord;

  void main() {
    vTexCoord = aTexCoord;
    vec4 positionVec4 = vec4(aPosition, 1.0);
    gl_Position = uProjectionMatrix * uModelViewMatrix * positionVec4;
  }
`;

const fragSrc = `
  precision highp float;
  uniform float uTime;
  uniform vec2 uResolution;
  varying vec2 vTexCoord;

  void main() {
    vec2 uv = vTexCoord;
    vec3 col = 0.5 + 0.5 * cos(uTime + uv.xyx + vec3(0, 2, 4));
    gl_FragColor = vec4(col, 1.0);
  }
`;

function setup() {
  createCanvas(800, 800, WEBGL);
  myShader = createShader(vertSrc, fragSrc);
}

function draw() {
  shader(myShader);
  myShader.setUniform('uTime', millis() / 1000.0);
  myShader.setUniform('uResolution', [width, height]);
  rect(0, 0, width, height);
}
```

### Pixel Manipulation

```javascript
function draw() {
  loadPixels();
  for (let x = 0; x < width; x++) {
    for (let y = 0; y < height; y++) {
      let idx = (x + y * width) * 4;
      let n = noise(x * 0.01, y * 0.01, frameCount * 0.01);
      pixels[idx]     = n * 255;     // R
      pixels[idx + 1] = n * 128;     // G
      pixels[idx + 2] = 255 - n*255; // B
      pixels[idx + 3] = 255;         // A
    }
  }
  updatePixels();
}
```

### Recording / Export

```javascript
// Frame export (PNG sequence)
function draw() {
  // ... drawing code ...
  if (frameCount <= 300) {
    saveCanvas('frame-' + nf(frameCount, 4), 'png');
  }
}

// SVG export (requires p5.js-svg library)
function setup() {
  createCanvas(800, 800, SVG);
}
function draw() {
  // ... vector drawing ...
  save('artwork.svg');
  noLoop();
}

// With canvas-sketch (standalone, not p5)
// npm install canvas-sketch canvas-sketch-cli -g
const canvasSketch = require('canvas-sketch');

const settings = {
  dimensions: [2048, 2048],
  animate: true,
  fps: 30,
  duration: 5,
  suffix: '-artwork',
};

const sketch = () => {
  return ({ context, width, height, time }) => {
    const ctx = context;
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, width, height);
    // ... drawing with Canvas 2D API ...
  };
};

canvasSketch(sketch, settings);
// Export: Ctrl+Shift+S for PNG, or --stream flag for MP4
```

---

## 3. SVG Generation

### Programmatic SVG in JavaScript

```javascript
function createSVG(width, height) {
  const NS = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(NS, 'svg');
  svg.setAttribute('viewBox', `0 0 ${width} ${height}`);
  svg.setAttribute('xmlns', NS);
  return svg;
}

function addPath(svg, d, attrs = {}) {
  const NS = 'http://www.w3.org/2000/svg';
  const path = document.createElementNS(NS, 'path');
  path.setAttribute('d', d);
  for (const [k, v] of Object.entries(attrs)) {
    path.setAttribute(k, v);
  }
  svg.appendChild(path);
  return path;
}

// Serialize to string
function svgToString(svg) {
  return new XMLSerializer().serializeToString(svg);
}
```

### SVG Path Commands Reference

| Command | Name | Syntax | Notes |
|---------|------|--------|-------|
| `M x y` | Move to | Absolute | Start new subpath |
| `m dx dy` | Move to | Relative | |
| `L x y` | Line to | Absolute | Straight line |
| `l dx dy` | Line to | Relative | |
| `H x` | Horizontal line | Absolute | |
| `h dx` | Horizontal line | Relative | |
| `V y` | Vertical line | Absolute | |
| `v dy` | Vertical line | Relative | |
| `C x1 y1 x2 y2 x y` | Cubic bezier | 2 control points + endpoint |
| `c dx1 dy1 dx2 dy2 dx dy` | Cubic bezier | Relative |
| `S x2 y2 x y` | Smooth cubic | Reflects previous control point |
| `Q x1 y1 x y` | Quadratic bezier | 1 control point + endpoint |
| `T x y` | Smooth quadratic | Reflects previous control point |
| `A rx ry rot large-arc sweep x y` | Arc | Elliptical arc |
| `Z` | Close path | Back to subpath start |

### Generative SVG Patterns

```javascript
// Generative organic blob
function blob(cx, cy, radius, points = 8, variance = 0.3) {
  const pts = [];
  for (let i = 0; i < points; i++) {
    const angle = (i / points) * Math.PI * 2;
    const r = radius * (1 + (Math.random() - 0.5) * variance);
    pts.push([
      cx + Math.cos(angle) * r,
      cy + Math.sin(angle) * r,
    ]);
  }
  return smoothClosedPath(pts);
}

// Convert points to smooth cubic bezier closed path
function smoothClosedPath(points) {
  const n = points.length;
  let d = `M ${points[0][0]} ${points[0][1]}`;
  for (let i = 0; i < n; i++) {
    const curr = points[i];
    const next = points[(i + 1) % n];
    const prev = points[(i - 1 + n) % n];
    const next2 = points[(i + 2) % n];

    const cp1x = curr[0] + (next[0] - prev[0]) / 6;
    const cp1y = curr[1] + (next[1] - prev[1]) / 6;
    const cp2x = next[0] - (next2[0] - curr[0]) / 6;
    const cp2y = next[1] - (next2[1] - curr[1]) / 6;

    d += ` C ${cp1x} ${cp1y}, ${cp2x} ${cp2y}, ${next[0]} ${next[1]}`;
  }
  return d + ' Z';
}

// Generative line hatching
function hatchRect(x, y, w, h, angle, spacing) {
  const paths = [];
  const cos = Math.cos(angle);
  const sin = Math.sin(angle);
  const diag = Math.sqrt(w * w + h * h);

  for (let d = -diag; d < diag; d += spacing) {
    const x1 = x + d * cos - diag * sin;
    const y1 = y + d * sin + diag * cos;
    const x2 = x + d * cos + diag * sin;
    const y2 = y + d * sin - diag * cos;
    // Clip to rect bounds and add to paths
    paths.push(`M ${x1} ${y1} L ${x2} ${y2}`);
  }
  return paths.join(' ');
}
```

### SVG Filters for Generative Effects

```xml
<!-- Organic texture -->
<filter id="organic">
  <feTurbulence type="fractalNoise" baseFrequency="0.02"
    numOctaves="4" seed="42" result="noise"/>
  <feDisplacementMap in="SourceGraphic" in2="noise"
    scale="20" xChannelSelector="R" yChannelSelector="G"/>
</filter>

<!-- Glow effect -->
<filter id="glow">
  <feGaussianBlur stdDeviation="4" result="blur"/>
  <feMerge>
    <feMergeNode in="blur"/>
    <feMergeNode in="SourceGraphic"/>
  </feMerge>
</filter>

<!-- Paper texture -->
<filter id="paper">
  <feTurbulence type="fractalNoise" baseFrequency="0.04"
    numOctaves="5" result="noise"/>
  <feDiffuseLighting in="noise" lighting-color="white"
    surfaceScale="2" result="lit">
    <feDistantLight azimuth="45" elevation="60"/>
  </feDiffuseLighting>
  <feComposite in="SourceGraphic" in2="lit"
    operator="multiply"/>
</filter>

<!-- Eroded / distressed edges -->
<filter id="eroded">
  <feTurbulence type="turbulence" baseFrequency="0.05"
    numOctaves="2" result="noise"/>
  <feDisplacementMap in="SourceGraphic" in2="noise"
    scale="6" xChannelSelector="R" yChannelSelector="G"
    result="displaced"/>
  <feGaussianBlur in="displaced" stdDeviation="0.5"/>
</filter>

<!-- Usage -->
<path d="..." filter="url(#organic)" fill="oklch(0.7 0.15 200)"/>
```

### SVG Animation

```xml
<!-- SMIL animation (native SVG) -->
<circle cx="50" cy="50" r="20" fill="oklch(0.7 0.2 250)">
  <animate attributeName="r" from="20" to="40"
    dur="2s" repeatCount="indefinite"
    values="20;40;20" keyTimes="0;0.5;1"/>
  <animate attributeName="fill-opacity" from="1" to="0.3"
    dur="2s" repeatCount="indefinite"/>
</circle>

<!-- Morph path -->
<path fill="oklch(0.6 0.18 150)">
  <animate attributeName="d" dur="4s" repeatCount="indefinite"
    values="M10,80 Q52,10 95,80 T180,80;
            M10,80 Q52,50 95,20 T180,80;
            M10,80 Q52,10 95,80 T180,80"/>
</path>

<!-- CSS animation on SVG -->
<style>
  @keyframes dash {
    to { stroke-dashoffset: 0; }
  }
  .draw-in {
    stroke-dasharray: 1000;
    stroke-dashoffset: 1000;
    animation: dash 3s ease-in-out forwards;
  }
</style>
<path class="draw-in" d="..." stroke="#000" fill="none"/>
```

### SVG Optimization (SVGO)

```bash
# Install
npm install -g svgo

# Optimize single file
svgo input.svg -o output.svg

# Batch optimize
svgo -f ./input-dir -o ./output-dir

# Preserve viewBox, remove dimensions (responsive)
svgo input.svg -o output.svg --config='{ "plugins": [
  { "name": "removeDimensions" },
  { "name": "removeViewBox", "active": false }
]}'
```

---

## 4. GLSL Shaders

### Shader Boilerplate (Standalone WebGL)

```glsl
// --- Vertex Shader ---
attribute vec2 aPosition;
varying vec2 vUv;

void main() {
  vUv = aPosition * 0.5 + 0.5;
  gl_Position = vec4(aPosition, 0.0, 1.0);
}

// --- Fragment Shader ---
precision highp float;
uniform float uTime;
uniform vec2 uResolution;
uniform vec2 uMouse;
varying vec2 vUv;

void main() {
  vec2 uv = gl_FragCoord.xy / uResolution;
  // ... shader logic ...
  gl_FragColor = vec4(col, 1.0);
}
```

### Common Uniforms

```glsl
uniform float uTime;        // seconds elapsed
uniform vec2 uResolution;   // canvas pixel dimensions
uniform vec2 uMouse;        // mouse position (normalized or pixels)
uniform float uFrame;       // frame counter
uniform sampler2D uTexture;  // texture input
```

### Hash / Random Functions

```glsl
// 1D hash
float hash(float n) {
  return fract(sin(n) * 43758.5453123);
}

// 2D hash
float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// 2D -> 2D hash
vec2 hash2(vec2 p) {
  p = vec2(dot(p, vec2(127.1, 311.7)),
           dot(p, vec2(269.5, 183.3)));
  return fract(sin(p) * 43758.5453123);
}
```

### Value Noise

```glsl
float valueNoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f); // smoothstep

  return mix(
    mix(hash(i + vec2(0, 0)), hash(i + vec2(1, 0)), u.x),
    mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x),
    u.y
  );
}
```

### Simplex Noise (2D)

```glsl
// Credit: Stefan Gustavson, Ian McEwan (MIT)
vec3 mod289(vec3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec2 mod289(vec2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
vec3 permute(vec3 x) { return mod289(((x * 34.0) + 1.0) * x); }

float snoise(vec2 v) {
  const vec4 C = vec4(
    0.211324865405187,   // (3.0-sqrt(3.0))/6.0
    0.366025403784439,   // 0.5*(sqrt(3.0)-1.0)
   -0.577350269189626,   // -1.0 + 2.0 * C.x
    0.024390243902439);  // 1.0 / 41.0

  vec2 i  = floor(v + dot(v, C.yy));
  vec2 x0 = v - i + dot(i, C.xx);

  vec2 i1 = (x0.x > x0.y) ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
  vec4 x12 = x0.xyxy + C.xxzz;
  x12.xy -= i1;

  i = mod289(i);
  vec3 p = permute(permute(i.y + vec3(0.0, i1.y, 1.0))
                          + i.x + vec3(0.0, i1.x, 1.0));

  vec3 m = max(0.5 - vec3(
    dot(x0, x0),
    dot(x12.xy, x12.xy),
    dot(x12.zw, x12.zw)
  ), 0.0);
  m = m * m;
  m = m * m;

  vec3 x = 2.0 * fract(p * C.www) - 1.0;
  vec3 h = abs(x) - 0.5;
  vec3 ox = floor(x + 0.5);
  vec3 a0 = x - ox;

  m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);

  vec3 g;
  g.x = a0.x * x0.x + h.x * x0.y;
  g.yz = a0.yz * x12.xz + h.yz * x12.yw;

  return 130.0 * dot(m, g);
}
```

### FBM (Fractal Brownian Motion)

```glsl
float fbm(vec2 p, int octaves) {
  float value = 0.0;
  float amplitude = 0.5;
  float frequency = 1.0;

  for (int i = 0; i < 8; i++) { // max octaves = 8
    if (i >= octaves) break;
    value += amplitude * snoise(p * frequency);
    frequency *= 2.0;   // lacunarity
    amplitude *= 0.5;   // gain / persistence
  }
  return value;
}
```

### Domain Warping

```glsl
// Single warp
float warpedNoise(vec2 p) {
  vec2 q = vec2(
    fbm(p + vec2(0.0, 0.0), 4),
    fbm(p + vec2(5.2, 1.3), 4)
  );
  return fbm(p + 4.0 * q, 4);
}

// Double warp (Inigo Quilez technique)
float doubleWarp(vec2 p) {
  vec2 q = vec2(
    fbm(p + vec2(0.0, 0.0), 4),
    fbm(p + vec2(5.2, 1.3), 4)
  );
  vec2 r = vec2(
    fbm(p + 4.0 * q + vec2(1.7, 9.2), 4),
    fbm(p + 4.0 * q + vec2(8.3, 2.8), 4)
  );
  return fbm(p + 4.0 * r, 4);
}
```

### Worley / Cellular Noise

```glsl
float worley(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  float minDist = 1.0;

  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec2 neighbor = vec2(float(x), float(y));
      vec2 point = hash2(i + neighbor);
      vec2 diff = neighbor + point - f;
      float dist = length(diff);
      minDist = min(minDist, dist);
    }
  }
  return minDist;
}

// F2 - F1 for cell edges
float worleyEdge(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  float f1 = 1.0, f2 = 1.0;

  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec2 neighbor = vec2(float(x), float(y));
      vec2 point = hash2(i + neighbor);
      float dist = length(neighbor + point - f);
      if (dist < f1) { f2 = f1; f1 = dist; }
      else if (dist < f2) { f2 = dist; }
    }
  }
  return f2 - f1;
}
```

### 2D SDF Primitives

```glsl
float sdCircle(vec2 p, float r) {
  return length(p) - r;
}

float sdBox(vec2 p, vec2 b) {
  vec2 d = abs(p) - b;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

float sdSegment(vec2 p, vec2 a, vec2 b) {
  vec2 pa = p - a, ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h);
}

float sdEquilateralTriangle(vec2 p, float r) {
  const float k = sqrt(3.0);
  p.x = abs(p.x) - r;
  p.y = p.y + r / k;
  if (p.x + k * p.y > 0.0) p = vec2(p.x - k*p.y, -k*p.x - p.y) / 2.0;
  p.x -= clamp(p.x, -2.0*r, 0.0);
  return -length(p) * sign(p.y);
}
```

### 3D SDF Primitives

```glsl
float sdSphere(vec3 p, float r) { return length(p) - r; }

float sdBox(vec3 p, vec3 b) {
  vec3 q = abs(p) - b;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sdTorus(vec3 p, vec2 t) {
  vec2 q = vec2(length(p.xz) - t.x, p.y);
  return length(q) - t.y;
}

float sdCapsule(vec3 p, vec3 a, vec3 b, float r) {
  vec3 pa = p - a, ba = b - a;
  float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
  return length(pa - ba * h) - r;
}

float sdRoundBox(vec3 p, vec3 b, float r) {
  vec3 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r;
}

float sdOctahedron(vec3 p, float s) {
  p = abs(p);
  float m = p.x + p.y + p.z - s;
  vec3 q;
       if (3.0*p.x < m) q = p.xyz;
  else if (3.0*p.y < m) q = p.yzx;
  else if (3.0*p.z < m) q = p.zxy;
  else return m * 0.57735027;
  float k = clamp(0.5*(q.z - q.y + s), 0.0, s);
  return length(vec3(q.x, q.y - s + k, q.z - k));
}
```

### SDF Operations

```glsl
// Boolean
float opUnion(float a, float b) { return min(a, b); }
float opSubtract(float a, float b) { return max(-a, b); }
float opIntersect(float a, float b) { return max(a, b); }

// Smooth boolean
float opSmoothUnion(float a, float b, float k) {
  k *= 4.0;
  float h = max(k - abs(a - b), 0.0);
  return min(a, b) - h*h*0.25/k;
}

float opSmoothSubtract(float a, float b, float k) {
  return -opSmoothUnion(a, -b, k);
}

// Transform
float opRound(float d, float r) { return d - r; }
float opOnion(float d, float t) { return abs(d) - t; }

// Repetition
vec3 opRepeat(vec3 p, vec3 s) { return p - s * round(p / s); }
vec3 opRepeatLimited(vec3 p, float s, vec3 lim) {
  return p - s * clamp(round(p / s), -lim, lim);
}

// Twist
vec3 opTwist(vec3 p, float k) {
  float c = cos(k * p.y);
  float s = sin(k * p.y);
  mat2 m = mat2(c, -s, s, c);
  return vec3(m * p.xz, p.y);
}
```

### Ray Marching Template

```glsl
#define MAX_STEPS 100
#define MAX_DIST 100.0
#define SURF_DIST 0.001

float map(vec3 p) {
  float sphere = sdSphere(p - vec3(0, 1, 0), 1.0);
  float plane = p.y;
  return opSmoothUnion(sphere, plane, 0.5);
}

float rayMarch(vec3 ro, vec3 rd) {
  float d = 0.0;
  for (int i = 0; i < MAX_STEPS; i++) {
    vec3 p = ro + rd * d;
    float ds = map(p);
    d += ds;
    if (d > MAX_DIST || ds < SURF_DIST) break;
  }
  return d;
}

vec3 getNormal(vec3 p) {
  vec2 e = vec2(0.001, 0.0);
  return normalize(vec3(
    map(p + e.xyy) - map(p - e.xyy),
    map(p + e.yxy) - map(p - e.yxy),
    map(p + e.yyx) - map(p - e.yyx)
  ));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;

  // Camera
  vec3 ro = vec3(0, 2, -5);  // ray origin
  vec3 rd = normalize(vec3(uv, 1.0));  // ray direction

  float d = rayMarch(ro, rd);

  vec3 col = vec3(0.0);
  if (d < MAX_DIST) {
    vec3 p = ro + rd * d;
    vec3 n = getNormal(p);
    vec3 lightDir = normalize(vec3(1, 2, -1));
    float diff = max(dot(n, lightDir), 0.0);
    col = vec3(1.0, 0.8, 0.6) * diff;
  }

  fragColor = vec4(col, 1.0);
}
```

### Color Blending in Shaders

```glsl
// Palette function (Inigo Quilez)
vec3 palette(float t, vec3 a, vec3 b, vec3 c, vec3 d) {
  return a + b * cos(6.28318 * (c * t + d));
}

// Common palettes:
// Rainbow:  palette(t, vec3(0.5), vec3(0.5), vec3(1.0), vec3(0.0, 0.33, 0.67))
// Sunset:   palette(t, vec3(0.5), vec3(0.5), vec3(1.0), vec3(0.0, 0.1, 0.2))
// Ocean:    palette(t, vec3(0.5), vec3(0.5), vec3(1.0, 1.0, 0.5), vec3(0.8, 0.9, 0.3))
// Fire:     palette(t, vec3(0.5,0.5,0.3), vec3(0.5,0.5,0.3), vec3(1.0), vec3(0.0,0.1,0.2))

// OKLAB blending in GLSL (see color section below for conversion functions)
vec3 blendOklab(vec3 rgb1, vec3 rgb2, float t) {
  vec3 lab1 = linearSRGBToOklab(rgb1);
  vec3 lab2 = linearSRGBToOklab(rgb2);
  vec3 mixed = mix(lab1, lab2, t);
  return oklabToLinearSRGB(mixed);
}
```

---

## 5. Procedural Generation Algorithms

### Perlin / Simplex Noise (JavaScript)

```javascript
// Use a library: npm install simplex-noise
import { createNoise2D, createNoise3D, createNoise4D } from 'simplex-noise';

const noise2D = createNoise2D();  // returns -1..1
const noise3D = createNoise3D();
const noise4D = createNoise4D();

// With seeded random
import { createNoise2D } from 'simplex-noise';
import alea from 'alea';

const prng = alea('my-seed');
const noise2D = createNoise2D(prng);
```

### FBM (JavaScript)

```javascript
function fbm(x, y, octaves = 6, lacunarity = 2.0, gain = 0.5) {
  let value = 0;
  let amplitude = 1.0;
  let frequency = 1.0;
  let maxValue = 0;

  for (let i = 0; i < octaves; i++) {
    value += amplitude * noise2D(x * frequency, y * frequency);
    maxValue += amplitude;
    frequency *= lacunarity;
    amplitude *= gain;
  }

  return value / maxValue; // normalize to -1..1
}
```

### Domain Warping (JavaScript)

```javascript
function domainWarp(x, y, scale = 0.005, warpStrength = 100) {
  const qx = fbm(x * scale, y * scale, 4);
  const qy = fbm(x * scale + 5.2, y * scale + 1.3, 4);

  return fbm(
    (x + warpStrength * qx) * scale,
    (y + warpStrength * qy) * scale,
    4
  );
}

// Double warp for more organic patterns
function doubleWarp(x, y, scale = 0.005) {
  const q = [
    fbm(x * scale, y * scale, 4),
    fbm(x * scale + 5.2, y * scale + 1.3, 4),
  ];
  const r = [
    fbm((x + 100 * q[0]) * scale + 1.7, (y + 100 * q[1]) * scale + 9.2, 4),
    fbm((x + 100 * q[0]) * scale + 8.3, (y + 100 * q[1]) * scale + 2.8, 4),
  ];
  return fbm(
    (x + 100 * r[0]) * scale,
    (y + 100 * r[1]) * scale,
    4
  );
}
```

### Ridged Noise

```javascript
function ridgedNoise(x, y, octaves = 6) {
  let value = 0;
  let amplitude = 1.0;
  let frequency = 1.0;
  let weight = 1.0;

  for (let i = 0; i < octaves; i++) {
    let signal = noise2D(x * frequency, y * frequency);
    signal = 1.0 - Math.abs(signal); // create ridges
    signal *= signal;                 // sharpen
    signal *= weight;
    weight = Math.min(1.0, Math.max(0.0, signal * 2.0));

    value += signal * amplitude;
    frequency *= 2.0;
    amplitude *= 0.5;
  }
  return value;
}
```

### Flow Fields

```javascript
class FlowField {
  constructor(cols, rows, noiseScale = 0.1) {
    this.cols = cols;
    this.rows = rows;
    this.field = new Float32Array(cols * rows);
    this.noiseScale = noiseScale;
  }

  update(time = 0) {
    for (let y = 0; y < this.rows; y++) {
      for (let x = 0; x < this.cols; x++) {
        const angle = noise2D(
          x * this.noiseScale,
          y * this.noiseScale + time * 0.2
        ) * Math.PI * 2;
        this.field[y * this.cols + x] = angle;
      }
    }
  }

  getAngle(x, y) {
    const col = Math.floor(x) % this.cols;
    const row = Math.floor(y) % this.rows;
    return this.field[row * this.cols + col];
  }
}

class Particle {
  constructor(x, y) {
    this.x = x;
    this.y = y;
    this.prevX = x;
    this.prevY = y;
    this.speed = 2;
  }

  follow(field) {
    this.prevX = this.x;
    this.prevY = this.y;
    const angle = field.getAngle(this.x, this.y);
    this.x += Math.cos(angle) * this.speed;
    this.y += Math.sin(angle) * this.speed;
  }

  edges(w, h) {
    if (this.x < 0 || this.x > w || this.y < 0 || this.y > h) {
      this.x = Math.random() * w;
      this.y = Math.random() * h;
      this.prevX = this.x;
      this.prevY = this.y;
    }
  }
}

// p5.js usage
const field = new FlowField(80, 80, 0.05);
const particles = Array.from({ length: 1000 },
  () => new Particle(random(width), random(height))
);

function draw() {
  field.update(frameCount * 0.01);
  for (const p of particles) {
    p.follow(field);
    p.edges(width, height);
    stroke(255, 20);
    line(p.prevX, p.prevY, p.x, p.y);
  }
}
```

### Poisson Disk Sampling

```javascript
function poissonDisk(width, height, minDist, maxAttempts = 30) {
  const cellSize = minDist / Math.SQRT2;
  const gridW = Math.ceil(width / cellSize);
  const gridH = Math.ceil(height / cellSize);
  const grid = new Array(gridW * gridH).fill(null);
  const points = [];
  const active = [];

  function gridIndex(x, y) {
    return Math.floor(x / cellSize) + Math.floor(y / cellSize) * gridW;
  }

  // Seed point
  const p0 = { x: width / 2, y: height / 2 };
  points.push(p0);
  active.push(p0);
  grid[gridIndex(p0.x, p0.y)] = p0;

  while (active.length > 0) {
    const idx = Math.floor(Math.random() * active.length);
    const point = active[idx];
    let found = false;

    for (let n = 0; n < maxAttempts; n++) {
      const angle = Math.random() * Math.PI * 2;
      const dist = minDist + Math.random() * minDist;
      const candidate = {
        x: point.x + Math.cos(angle) * dist,
        y: point.y + Math.sin(angle) * dist,
      };

      if (candidate.x < 0 || candidate.x >= width ||
          candidate.y < 0 || candidate.y >= height) continue;

      const gi = gridIndex(candidate.x, candidate.y);
      let ok = true;

      // Check neighboring cells
      const gx = Math.floor(candidate.x / cellSize);
      const gy = Math.floor(candidate.y / cellSize);
      for (let dy = -2; dy <= 2 && ok; dy++) {
        for (let dx = -2; dx <= 2 && ok; dx++) {
          const nx = gx + dx, ny = gy + dy;
          if (nx < 0 || nx >= gridW || ny < 0 || ny >= gridH) continue;
          const neighbor = grid[nx + ny * gridW];
          if (neighbor) {
            const d = Math.hypot(candidate.x - neighbor.x,
                                 candidate.y - neighbor.y);
            if (d < minDist) ok = false;
          }
        }
      }

      if (ok) {
        points.push(candidate);
        active.push(candidate);
        grid[gi] = candidate;
        found = true;
        break;
      }
    }

    if (!found) active.splice(idx, 1);
  }

  return points;
}
```

### L-Systems

```javascript
class LSystem {
  constructor(axiom, rules, angle = 25) {
    this.axiom = axiom;
    this.rules = rules; // { 'F': 'FF+[+F-F-F]-[-F+F+F]' }
    this.angle = angle * (Math.PI / 180);
    this.sentence = axiom;
  }

  generate(iterations) {
    this.sentence = this.axiom;
    for (let i = 0; i < iterations; i++) {
      let next = '';
      for (const ch of this.sentence) {
        next += this.rules[ch] || ch;
      }
      this.sentence = next;
    }
    return this.sentence;
  }

  // Returns array of line segments [{x1,y1,x2,y2}]
  interpret(startX, startY, stepLen) {
    const lines = [];
    const stack = [];
    let x = startX, y = startY;
    let angle = -Math.PI / 2; // start pointing up

    for (const ch of this.sentence) {
      switch (ch) {
        case 'F': {
          const nx = x + Math.cos(angle) * stepLen;
          const ny = y + Math.sin(angle) * stepLen;
          lines.push({ x1: x, y1: y, x2: nx, y2: ny });
          x = nx; y = ny;
          break;
        }
        case '+': angle += this.angle; break;
        case '-': angle -= this.angle; break;
        case '[': stack.push({ x, y, angle }); break;
        case ']': {
          const state = stack.pop();
          x = state.x; y = state.y; angle = state.angle;
          break;
        }
      }
    }
    return lines;
  }
}

// Classic trees
const tree = new LSystem('F', { 'F': 'FF+[+F-F-F]-[-F+F+F]' }, 22.5);
tree.generate(4);

// Koch curve
const koch = new LSystem('F', { 'F': 'F+F-F-F+F' }, 90);

// Sierpinski triangle
const sierpinski = new LSystem('F-G-G', {
  'F': 'F-G+F+G-F',
  'G': 'GG'
}, 120);

// Dragon curve
const dragon = new LSystem('FX', {
  'X': 'X+YF+',
  'Y': '-FX-Y'
}, 90);
```

### Cellular Automata (Game of Life)

```javascript
class CellularAutomata {
  constructor(width, height) {
    this.w = width;
    this.h = height;
    this.grid = new Uint8Array(width * height);
    this.next = new Uint8Array(width * height);
  }

  randomize(density = 0.3) {
    for (let i = 0; i < this.grid.length; i++) {
      this.grid[i] = Math.random() < density ? 1 : 0;
    }
  }

  step() {
    for (let y = 0; y < this.h; y++) {
      for (let x = 0; x < this.w; x++) {
        const neighbors = this.countNeighbors(x, y);
        const idx = y * this.w + x;
        const alive = this.grid[idx];

        // Conway's Game of Life rules
        if (alive && (neighbors < 2 || neighbors > 3)) {
          this.next[idx] = 0;
        } else if (!alive && neighbors === 3) {
          this.next[idx] = 1;
        } else {
          this.next[idx] = this.grid[idx];
        }
      }
    }
    [this.grid, this.next] = [this.next, this.grid];
  }

  countNeighbors(x, y) {
    let count = 0;
    for (let dy = -1; dy <= 1; dy++) {
      for (let dx = -1; dx <= 1; dx++) {
        if (dx === 0 && dy === 0) continue;
        const nx = (x + dx + this.w) % this.w;
        const ny = (y + dy + this.h) % this.h;
        count += this.grid[ny * this.w + nx];
      }
    }
    return count;
  }
}
```

### Voronoi Diagram (Fortune's Algorithm Alternative -- Brute Force)

```javascript
// For production use: npm install d3-delaunay
import { Delaunay } from 'd3-delaunay';

// Generate Voronoi from random points
const points = Array.from({ length: 50 }, () => [
  Math.random() * width,
  Math.random() * height,
]);

const delaunay = Delaunay.from(points);
const voronoi = delaunay.voronoi([0, 0, width, height]);

// Iterate cells
for (let i = 0; i < points.length; i++) {
  const cell = voronoi.cellPolygon(i);
  if (!cell) continue;
  // cell is array of [x,y] vertices (closed polygon)
  // Draw with canvas, SVG, etc.
}

// Delaunay triangles
for (let i = 0; i < delaunay.triangles.length; i += 3) {
  const p0 = points[delaunay.triangles[i]];
  const p1 = points[delaunay.triangles[i + 1]];
  const p2 = points[delaunay.triangles[i + 2]];
  // Draw triangle
}

// Lloyd relaxation (makes cells more even)
function lloydRelax(points, bounds, iterations = 3) {
  let pts = [...points];
  for (let i = 0; i < iterations; i++) {
    const d = Delaunay.from(pts);
    const v = d.voronoi(bounds);
    pts = pts.map((_, j) => {
      const cell = v.cellPolygon(j);
      if (!cell) return pts[j];
      // Centroid of polygon
      let cx = 0, cy = 0;
      for (let k = 0; k < cell.length - 1; k++) {
        cx += cell[k][0];
        cy += cell[k][1];
      }
      return [cx / (cell.length - 1), cy / (cell.length - 1)];
    });
  }
  return pts;
}
```

### Wave Function Collapse (Simple Tiled)

```javascript
class WFC {
  constructor(tiles, adjacency, width, height) {
    this.tiles = tiles;        // array of tile IDs
    this.adj = adjacency;      // { tileId: { up: [...], down: [...], left: [...], right: [...] } }
    this.w = width;
    this.h = height;
    // Each cell starts with all tiles possible
    this.grid = Array.from({ length: width * height },
      () => new Set(tiles)
    );
  }

  entropy(idx) {
    return this.grid[idx].size;
  }

  // Find cell with lowest entropy > 1
  findLowestEntropy() {
    let minE = Infinity, minIdx = -1;
    for (let i = 0; i < this.grid.length; i++) {
      const e = this.grid[i].size;
      if (e > 1 && e < minE) {
        minE = e;
        minIdx = i;
      }
    }
    return minIdx;
  }

  collapse(idx) {
    const options = [...this.grid[idx]];
    const chosen = options[Math.floor(Math.random() * options.length)];
    this.grid[idx] = new Set([chosen]);
    return chosen;
  }

  propagate(idx) {
    const stack = [idx];
    while (stack.length > 0) {
      const current = stack.pop();
      const x = current % this.w;
      const y = Math.floor(current / this.w);
      const currentTiles = this.grid[current];

      const neighbors = [
        { dx: 0, dy: -1, dir: 'up', opp: 'down' },
        { dx: 0, dy: 1, dir: 'down', opp: 'up' },
        { dx: -1, dy: 0, dir: 'left', opp: 'right' },
        { dx: 1, dy: 0, dir: 'right', opp: 'left' },
      ];

      for (const { dx, dy, dir } of neighbors) {
        const nx = x + dx, ny = y + dy;
        if (nx < 0 || nx >= this.w || ny < 0 || ny >= this.h) continue;
        const ni = ny * this.w + nx;
        const neighborPossible = this.grid[ni];
        const prevSize = neighborPossible.size;

        // Compute allowed tiles for neighbor
        const allowed = new Set();
        for (const t of currentTiles) {
          for (const a of (this.adj[t]?.[dir] || [])) {
            allowed.add(a);
          }
        }

        // Intersect
        for (const t of neighborPossible) {
          if (!allowed.has(t)) neighborPossible.delete(t);
        }

        if (neighborPossible.size < prevSize) {
          stack.push(ni);
        }
      }
    }
  }

  solve() {
    while (true) {
      const idx = this.findLowestEntropy();
      if (idx === -1) break; // all collapsed
      this.collapse(idx);
      this.propagate(idx);
    }
    return this.grid.map(s => [...s][0]);
  }
}
```

### Terrain with Noise Octaves

```javascript
function generateTerrain(width, height, options = {}) {
  const {
    octaves = 6,
    lacunarity = 2.0,
    gain = 0.5,
    scale = 0.005,
    exponent = 1.5,  // redistribution power
    seed = 'terrain',
  } = options;

  const prng = alea(seed);
  const noise = createNoise2D(prng);
  const data = new Float32Array(width * height);

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const nx = x * scale - 0.5;
      const ny = y * scale - 0.5;

      let e = 0, amplitude = 1, frequency = 1, maxAmp = 0;
      for (let i = 0; i < octaves; i++) {
        e += amplitude * noise(nx * frequency, ny * frequency);
        maxAmp += amplitude;
        frequency *= lacunarity;
        amplitude *= gain;
      }
      e = (e / maxAmp + 1) * 0.5; // normalize to 0..1
      e = Math.pow(e, exponent);   // redistribute

      data[y * width + x] = e;
    }
  }
  return data;
}

// Biome from elevation + moisture
function biome(e, m) {
  if (e < 0.1) return 'DEEP_WATER';
  if (e < 0.15) return 'WATER';
  if (e < 0.18) return 'BEACH';
  if (e > 0.8) {
    if (m < 0.2) return 'SCORCHED';
    if (m < 0.5) return 'BARE';
    return 'SNOW';
  }
  if (e > 0.6) {
    if (m < 0.33) return 'SHRUBLAND';
    return 'FOREST';
  }
  if (m < 0.16) return 'DESERT';
  if (m < 0.5) return 'GRASSLAND';
  return 'RAINFOREST';
}
```

### Seamless Tiling (Cylindrical / Toroidal Noise)

```javascript
// Wrap noise seamlessly by mapping to higher dimensions
function torusNoise(nx, ny, noise4D) {
  const TAU = Math.PI * 2;
  return noise4D(
    Math.cos(TAU * nx) / TAU,
    Math.sin(TAU * nx) / TAU,
    Math.cos(TAU * ny) / TAU,
    Math.sin(TAU * ny) / TAU
  );
}

// Scale output by sqrt(2) to compensate for 4D range narrowing
```

---

## 6. Color Theory for Generative Art

> For CSS color, accessibility, design tokens, and gamut details, see `color-ops`.

### OKLAB / OKLCH Conversion (JavaScript)

```javascript
function linearSRGBToOklab(r, g, b) {
  const l = 0.4122214708*r + 0.5363325363*g + 0.0514459929*b;
  const m = 0.2119034982*r + 0.6806995451*g + 0.1073969566*b;
  const s = 0.0883024619*r + 0.2817188376*g + 0.6299787005*b;
  const l_ = Math.cbrt(l), m_ = Math.cbrt(m), s_ = Math.cbrt(s);
  return {
    L: 0.2104542553*l_ + 0.7936177850*m_ - 0.0040720468*s_,
    a: 1.9779984951*l_ - 2.4285922050*m_ + 0.4505937099*s_,
    b: 0.0259040371*l_ + 0.7827717662*m_ - 0.8086757660*s_,
  };
}

function oklabToLinearSRGB(L, a, b) {
  const l_ = L + 0.3963377774*a + 0.2158037573*b;
  const m_ = L - 0.1055613458*a - 0.0638541728*b;
  const s_ = L - 0.0894841775*a - 1.2914855480*b;
  return {
    r: +4.0767416621*l_**3 - 3.3077115913*m_**3 + 0.2309699292*s_**3,
    g: -1.2684380046*l_**3 + 2.6097574011*m_**3 - 0.3413193965*s_**3,
    b: -0.0041960863*l_**3 - 0.7034186147*m_**3 + 1.7076147010*s_**3,
  };
}

function oklabToOklch({ L, a, b }) {
  return { L, C: Math.hypot(a, b), h: Math.atan2(b, a) * 180 / Math.PI };
}

function oklchToOklab({ L, C, h }) {
  const rad = h * Math.PI / 180;
  return { L, a: C * Math.cos(rad), b: C * Math.sin(rad) };
}
```

### OKLAB / OKLCH Conversion (GLSL)

```glsl
vec3 linearSRGBToOklab(vec3 c) {
  vec3 lms = vec3(
    dot(c, vec3(0.4122214708, 0.5363325363, 0.0514459929)),
    dot(c, vec3(0.2119034982, 0.6806995451, 0.1073969566)),
    dot(c, vec3(0.0883024619, 0.2817188376, 0.6299787005))
  );
  lms = sign(lms) * pow(abs(lms), vec3(1.0/3.0));
  return vec3(
    dot(lms, vec3(0.2104542553, 0.7936177850, -0.0040720468)),
    dot(lms, vec3(1.9779984951, -2.4285922050, 0.4505937099)),
    dot(lms, vec3(0.0259040371, 0.7827717662, -0.8086757660))
  );
}

vec3 oklabToLinearSRGB(vec3 lab) {
  vec3 lms = vec3(
    lab.x + 0.3963377774*lab.y + 0.2158037573*lab.z,
    lab.x - 0.1055613458*lab.y - 0.0638541728*lab.z,
    lab.x - 0.0894841775*lab.y - 1.2914855480*lab.z
  );
  return vec3(
    dot(lms*lms*lms, vec3(4.0767416621, -3.3077115913, 0.2309699292)),
    dot(lms*lms*lms, vec3(-1.2684380046, 2.6097574011, -0.3413193965)),
    dot(lms*lms*lms, vec3(-0.0041960863, -0.7034186147, 1.7076147010))
  );
}
```

### Palette Generation Algorithms

```javascript
// Cosine palette (port of Inigo Quilez technique)
function cosinePalette(t, a, b, c, d) {
  return [
    a[0] + b[0] * Math.cos(Math.PI * 2 * (c[0] * t + d[0])),
    a[1] + b[1] * Math.cos(Math.PI * 2 * (c[1] * t + d[1])),
    a[2] + b[2] * Math.cos(Math.PI * 2 * (c[2] * t + d[2])),
  ];
}

// Presets (a, b, c, d)
const PALETTES = {
  rainbow:  [[0.5,0.5,0.5], [0.5,0.5,0.5], [1,1,1],       [0, 0.33, 0.67]],
  sunset:   [[0.5,0.5,0.5], [0.5,0.5,0.5], [1,1,1],       [0, 0.1, 0.2]],
  ocean:    [[0.5,0.5,0.5], [0.5,0.5,0.5], [1,1,0.5],     [0.8, 0.9, 0.3]],
  fire:     [[0.5,0.5,0.3], [0.5,0.5,0.3], [1,1,1],       [0, 0.1, 0.2]],
  electric: [[0.5,0.5,0.5], [0.5,0.5,0.5], [2,1,0],       [0.5, 0.2, 0.25]],
  forest:   [[0.5,0.5,0.5], [0.5,0.5,0.5], [1,0.7,0.4],   [0, 0.15, 0.2]],
};

// Usage: get color at position t (0..1) along palette
const [r, g, b] = cosinePalette(0.5, ...PALETTES.sunset);
```

### OKLCH Palette Generation

```javascript
// Perceptually uniform palette with fixed lightness
function oklchPalette(count, L = 0.7, C = 0.15, hueOffset = 0) {
  return Array.from({ length: count }, (_, i) => {
    const h = (hueOffset + (i / count) * 360) % 360;
    return { L, C, h };
  });
}

// Analogous palette (clustered hues)
function analogousPalette(baseHue, count = 5, spread = 30, L = 0.7, C = 0.15) {
  return Array.from({ length: count }, (_, i) => {
    const t = i / (count - 1) - 0.5; // -0.5 to 0.5
    return { L, C, h: (baseHue + t * spread + 360) % 360 };
  });
}

// Warm/cool palette
function warmCoolPalette(count = 6) {
  return Array.from({ length: count }, (_, i) => {
    const t = i / (count - 1);
    return {
      L: 0.5 + t * 0.3,
      C: 0.12 + Math.sin(t * Math.PI) * 0.06,
      h: 20 + t * 220,  // warm orange -> cool blue
    };
  });
}
```

### Gradient Interpolation in Perceptual Space

```javascript
// Interpolate in OKLAB (no hue discontinuity issues)
function lerpOklab(lab1, lab2, t) {
  return {
    L: lab1.L + (lab2.L - lab1.L) * t,
    a: lab1.a + (lab2.a - lab1.a) * t,
    b: lab1.b + (lab2.b - lab1.b) * t,
  };
}

// Interpolate in OKLCH with shortest hue path
function lerpOklch(lch1, lch2, t) {
  let dh = lch2.h - lch1.h;
  if (dh > 180) dh -= 360;
  if (dh < -180) dh += 360;

  return {
    L: lch1.L + (lch2.L - lch1.L) * t,
    C: lch1.C + (lch2.C - lch1.C) * t,
    h: (lch1.h + dh * t + 360) % 360,
  };
}

// Multi-stop gradient
function multiStopGradient(stops, t) {
  // stops: [{pos: 0, color: {L,C,h}}, {pos: 0.5, ...}, {pos: 1, ...}]
  if (t <= stops[0].pos) return stops[0].color;
  if (t >= stops[stops.length - 1].pos) return stops[stops.length - 1].color;

  for (let i = 0; i < stops.length - 1; i++) {
    if (t >= stops[i].pos && t <= stops[i + 1].pos) {
      const localT = (t - stops[i].pos) / (stops[i + 1].pos - stops[i].pos);
      return lerpOklch(stops[i].color, stops[i + 1].color, localT);
    }
  }
}
```

### Color Cycling

```javascript
// Smooth cycling through a palette
function cyclePalette(palette, t, speed = 1.0) {
  const idx = (t * speed) % palette.length;
  const i = Math.floor(idx);
  const frac = idx - i;
  const c1 = palette[i % palette.length];
  const c2 = palette[(i + 1) % palette.length];
  return lerpOklch(c1, c2, frac);
}

// Phase-shifted cycling (each element gets different phase)
function phasedColor(palette, t, elementIndex, phaseSpread = 0.1) {
  return cyclePalette(palette, t + elementIndex * phaseSpread);
}
```

### Harmony Rules in OKLCH

```javascript
function colorHarmonies(baseHue, L = 0.65, C = 0.15) {
  const h = baseHue;
  return {
    complementary:   [{ L, C, h }, { L, C, h: (h + 180) % 360 }],
    analogous:       [{ L, C, h: (h - 30 + 360) % 360 }, { L, C, h }, { L, C, h: (h + 30) % 360 }],
    triadic:         [{ L, C, h }, { L, C, h: (h + 120) % 360 }, { L, C, h: (h + 240) % 360 }],
    splitComplementary: [{ L, C, h }, { L, C, h: (h + 150) % 360 }, { L, C, h: (h + 210) % 360 }],
    tetradic:        [{ L, C, h }, { L, C, h: (h + 90) % 360 }, { L, C, h: (h + 180) % 360 }, { L, C, h: (h + 270) % 360 }],
  };
}
```

---

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

## See Also

- `color-ops` - CSS color, accessibility, design tokens, palette scripts
- `javascript-ops` - JS async patterns, modules, ES2024+ features
- [Book of Shaders](https://thebookofshaders.com/) - GLSL fundamentals
- [Shadertoy](https://www.shadertoy.com/) - Live shader playground
- [Inigo Quilez articles](https://iquilezles.org/articles/) - SDF, noise, ray marching
- [LYGIA](https://lygia.xyz/) - Cross-platform shader library
- [Red Blob Games](https://www.redblobgames.com/) - Procedural generation algorithms
