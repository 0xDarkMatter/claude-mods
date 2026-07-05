# Color & palettes for generative art — OKLAB/OKLCH conversion (JS + GLSL), cosine & OKLCH palette generation, perceptual gradient interpolation, color cycling, harmony rules

Generative/procedural color techniques. For CSS color, accessibility, and design
tokens, see `color-ops`.

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
