# SVG generation — programmatic construction, path commands, generative patterns, filters, animation, SVGO optimization

Resolution-independent vector output for plotter-ready, print, and crisp web
art. Build paths programmatically; serialize with `XMLSerializer`.

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
