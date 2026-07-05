# GLSL shaders — boilerplate, uniforms, hash/noise (value/simplex/Worley), FBM, domain warping, 2D/3D SDFs, SDF operations, ray marching, palette blending

The GPU toolbox for fragment-shader art. Reach for shaders when you need
per-pixel field evaluation (noise fields, SDF ray marching) that would be too
slow on the CPU.

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
