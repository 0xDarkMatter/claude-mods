# Procedural generation algorithms — noise (Perlin/simplex/FBM/ridged), domain warping, flow fields, Poisson disk, L-systems, cellular automata, Voronoi/Delaunay, wave function collapse, terrain, seamless tiling

CPU-side procedural recipes in JavaScript. For the GLSL equivalents (shaders),
see [glsl-shaders.md](glsl-shaders.md). For colorizing the output, see
[color-and-palettes.md](color-and-palettes.md).

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
