# Three.js scene scaffolding — minimal scene/camera/renderer, Timer-based animation loop, OrbitControls, three-point lighting, bloom post-processing, InstancedMesh particle systems, custom ShaderMaterial

Creative/shader-side three.js setup patterns (2026). App/game-scale three.js
(GLTF pipelines, AnimationMixer, fixed-timestep loops, physics, R3F, disposal at
scale) is [threejs-ops](../../threejs-ops/SKILL.md).

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
