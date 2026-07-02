# Ambient life — boids, steering, waypoint actors

Birds, fish, crowds, traffic, grazing animals: autonomous agents that make a
scene feel inhabited. The recipe is always the same three layers:

1. **Steering forces** decide *where* each agent wants to go (this file).
2. **The fixed loop** integrates them deterministically
   ([game-loop.md](game-loop.md)).
3. **InstancedMesh** (or LOD'd clones for skinned characters) renders them
   ([scale-and-disposal.md](scale-and-disposal.md)).

For a structured, engine-flavored take on the same layers — actor motion
controllers, waypoint drivers, camera rigs as composable "blocks" — see
[xt4d/GameBlocks](https://github.com/xt4d/GameBlocks): concise, self-explanatory
building blocks written for agent-assisted prototyping; good reference
implementations to crib state-shape from.

## 1. The steering core (Reynolds)

Every behavior returns a desired-velocity correction; the agent sums, clamps,
integrates:

```javascript
class Agent {
  constructor() {
    this.position = new THREE.Vector3();
    this.velocity = new THREE.Vector3();
    this.maxSpeed = 4;         // m/s
    this.maxForce = 8;         // m/s² — lower = lazier turns
  }
  // steer toward a point at full speed
  seek(target, out) {
    out.subVectors(target, this.position).setLength(this.maxSpeed)
       .sub(this.velocity).clampLength(0, this.maxForce);
    return out;
  }
  // seek, but decelerate inside `slowRadius` (stops AT the target)
  arrive(target, slowRadius, out) {
    out.subVectors(target, this.position);
    const d = out.length();
    out.setLength(this.maxSpeed * Math.min(1, d / slowRadius))
       .sub(this.velocity).clampLength(0, this.maxForce);
    return out;
  }
  integrate(force, dt) {
    this.velocity.addScaledVector(force, dt).clampLength(0, this.maxSpeed);
    this.position.addScaledVector(this.velocity, dt);
  }
}
```

**Wander** (idle meandering): project a point ahead of the agent, jitter a
target around a small circle there, `seek` it. Deterministic if the jitter uses
the seeded RNG ([game-loop.md](game-loop.md) §7).

Facing: agents look along velocity —
`mesh.quaternion.setFromRotationMatrix(m.lookAt(ZERO, velocity, UP))`, slerped
for smoothness. For instanced rendering, compose this into the per-instance
matrix instead.

## 2. Boids — flocks, schools, herds

Three forces over neighbors within a radius:

| Rule | Force | Typical weight |
|---|---|---|
| **Separation** | away from too-close neighbors (1/d falloff) | 1.5 — highest, prevents clumping |
| **Alignment** | match average neighbor velocity | 1.0 |
| **Cohesion** | toward average neighbor position | 1.0 |

```javascript
// per agent, per fixed tick: sum weighted rules + bounds-return force
force.set(0, 0, 0)
  .addScaledVector(separation(agent, neighbors, 2.0), 1.5)
  .addScaledVector(alignment(agent, neighbors, 6.0), 1.0)
  .addScaledVector(cohesion(agent, neighbors, 6.0), 1.0)
  .addScaledVector(containment(agent, WORLD_BOUNDS), 2.0);
agent.integrate(force, FIXED);
```

**The O(N²) wall.** Naive neighbor search dies around ~500 agents. Spatial
hash — a `Map<cellKey, Agent[]>` rebuilt each tick, cell size = neighbor
radius — restores O(N·k):

```javascript
const CELL = 6.0;                                   // == largest neighbor radius
const key = (p) => `${(p.x / CELL) | 0},${(p.y / CELL) | 0},${(p.z / CELL) | 0}`;
// rebuild each tick (cheap); query = own cell + 26 neighbors
```

Tuning that reads as *life*: per-agent `maxSpeed` jitter (±15%), a small
species-specific vertical damping for birds/fish, and a rare "startle" impulse
propagating through neighbors.

## 3. Waypoint actors — patrols, traffic, grazing routes

State machine + `arrive`:

```javascript
const route = { points: [...Vector3], loop: true };
// states: TRAVELING → (reached, d < 0.5) → DWELLING(t) → next waypoint
```

- Use **`arrive`, not `seek`**, at each waypoint — seek orbits the point
  forever at max speed.
- Dwell timers (graze, look around) come from the seeded RNG so replays hold.
- Layer a small wander force on top of route-following so paths aren't
  rail-straight.
- Skinned actors: drive locomotion blend weight from `velocity.length()`
  ([animation.md](animation.md) §4) — walk/run/idle picks itself.
- Ground clamping on terrain: raycast down (or sample the heightfield) per
  tick; physics is overkill for ambient walkers — reserve real character
  controllers ([physics.md](physics.md) §5) for gameplay-relevant actors.

## 4. Scaling ambient life

| Population | Rendering | Simulation |
|---|---|---|
| ≤ ~50 skinned | `SkeletonUtils.clone` + own mixers | full steering per tick |
| ~50–500 | LOD tiers: skinned near, InstancedMesh imposters far | full steering, spatial hash |
| 500–10k (birds/fish/particles-with-brains) | one InstancedMesh, matrix per agent | spatial hash; consider half-rate ticks for far agents |
| beyond | GPU (compute in shader) | out of scope here — see [genart-ops](../../genart-ops/SKILL.md) particles |

Half-rate trick: agents beyond N meters tick every 2nd–4th fixed step (stagger
by `index % 4`) — invisible at distance, quarters the sim cost.

## 5. When to reach for a library

[yuka](https://mugen87.github.io/yuka/) (by a three.js maintainer) ships
steering, FSMs, pathfinding, fuzzy logic — engine-agnostic, you sync its
entities to meshes exactly like a physics world. Worth it once you need
pathfinding/navmesh (`three-pathfinding` for navmesh queries) or goal-driven
AI; below that, the ~100 lines above stay easier to tune and debug.
