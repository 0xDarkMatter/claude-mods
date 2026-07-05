# p5.js sketch patterns — global/instance/WebGL modes, custom shaders, pixel manipulation, recording & export

p5.js is the fastest path from idea to pixels for 2D creative coding. Pick the
mode by how many sketches share a page and whether you need the GPU.

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
