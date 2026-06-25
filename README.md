# Pendularium

A native macOS generative-art engine that paints a zoomed-out, fractal-like image from a field
of **chaotic double pendulums** swinging in 3D. Every run is seeded differently, so no two images
are alike. Built in Swift + Metal, runnable straight from the terminal.

![example](docs/example.png)

## What it does

- Spawns thousands of planar **double pendulums** (the classic chaotic system), each with random
  initial angles, distributed across a wide 3D volume as camera-parallel "sheets" layered in depth.
- Integrates each pendulum on the CPU with **RK4** plus per-step **energy renormalization**, so the
  motion stays lively and the color palette never washes out over long runs.
- Each bob's tip leaves a **persistent, accumulating trail**, colored by its instantaneous speed
  (cool = slow, hot = fast) and blended additively into a density glow.
- The population **grows to the machine's performance budget**: it keeps spawning pendulums while
  measured CPU + GPU frame work stays under budget, then stops. Trails keep accumulating until a
  memory cap, then the painting freezes while the live arms keep swinging — the graceful end of
  "until it can't draw any more."

## Run

Requires macOS 14+, Xcode/Swift toolchain, Apple Silicon recommended.

```sh
swift run -c release Pendularium
```

(`-c release` is strongly recommended — the simulation is CPU-bound, so the optimized build reaches
many more pendulums before saturating.)

### Controls

| Input            | Action            |
| ---------------- | ----------------- |
| drag             | orbit the camera  |
| scroll           | zoom              |
| `S`              | save a PNG screenshot to the working dir |
| `Q`              | quit              |

### Flags

```
--seed <uint64>          reproduce a run's initial conditions
--autoshot <sec> <path>  render headless for <sec> seconds, save a PNG, then quit
--mem-mb <int>           trail-memory cap in MB (default 192)
```

Example — deterministic capture:

```sh
swift run -c release Pendularium --seed 42 --autoshot 12 out.png
```

Note on reproducibility: `--seed` fixes the *initial conditions* and the order in which pendulums
are spawned, so the same seed on the same machine produces essentially the same image. The final
density still depends on machine performance, because growth is gated on real frame timing.

## How it scales (toward millions)

v1 integrates on the CPU (`DispatchQueue.concurrentPerform`), which comfortably reaches the
low tens of thousands of pendulums. The path to millions is a Metal **compute** rewrite: move RK4
integration to a compute shader over GPU state buffers, and move trail-append into a compute shader
with an atomic counter writing directly into the vertex buffer, drawn indirectly. That changes the
data flow (the CPU no longer touches per-pendulum state) — it is a real re-architecture, not a
drop-in swap.

## Layout

| File | Responsibility |
| ---- | -------------- |
| `main.swift` | AppKit bootstrap, window, input, HUD, CLI |
| `Renderer.swift` | Metal pipeline, per-frame loop, growth controller, screenshots |
| `Simulation.swift` | double-pendulum RK4 + energy renormalization (SoA, parallel) |
| `TrailBuffer.swift` | persistent append-only vertex buffer |
| `Shaders.swift` | Metal source (runtime-compiled) |
| `Camera.swift`, `Colormap.swift`, `Matrix.swift`, `Random.swift`, `Config.swift` | support |
