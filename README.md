# Pendularium

A native macOS generative-art engine that paints a zoomed-out, fractal-like image from a field
of **chaotic double pendulums** swinging in 3D. Every run is seeded differently, so no two images
are alike. Built in Swift + Metal, runnable straight from the terminal.

![example](docs/example.png)

## What it does

- Spawns thousands of planar **double pendulums** (the classic chaotic system), integrated on the
  CPU with **RK4** plus per-step **energy renormalization** so the motion stays lively indefinitely.
- **Coherent seeding**: neighboring pendulums start from a randomized *smooth field* of initial
  angles, so the field begins ordered and chaos shatters it over time — sensitive dependence on
  initial conditions, made visible. Every run uses a different field, so no two images are alike.
- Each bob's tip leaves a **persistent, accumulating trail** blended additively into an **HDR
  buffer**, then tone-mapped to the screen. The high dynamic range keeps the dense core from
  clipping to white, so structure and color survive everywhere.
- **Two views**: a **3D** volume with a slow auto-orbit, and a flat head-on **2D** plane
  (orthographic) where all trails overlap into one dense image. Toggle live with `D`.
- **Three color modes**, cycled live with `C` (recolors the whole painting instantly):
  - **speed** — cool→hot by instantaneous bob speed (the chaotic energy distribution),
  - **identity** — a per-pendulum hue that tracks each trajectory (divergence / mixing),
  - **phase** — hue by swing angle (who is in / out of sync).
- The population **grows to the machine's performance budget**, then trails accumulate to a memory
  cap and it **pauses at the limit** — the final painting holds while you drag/zoom/recolor it.
  The graceful end of "until it can't draw any more."

## Run

Requires macOS 14+, Xcode/Swift toolchain, Apple Silicon recommended.

```sh
swift run -c release Pendularium
```

(`-c release` is strongly recommended — the simulation is CPU-bound, so the optimized build reaches
many more pendulums before saturating.)

### Controls

| Input    | Action                                            |
| -------- | ------------------------------------------------- |
| drag     | orbit (3D) / pan (2D)                             |
| scroll   | zoom                                              |
| `D`      | toggle 2D / 3D (restarts the painting)            |
| `C`      | cycle color mode (speed → identity → phase)       |
| `Space`  | pause / resume growth                             |
| `S`      | save a PNG screenshot to the working dir          |
| `Q`      | quit                                              |

### Flags

```
--seed <uint64>          reproduce a run's initial conditions
--autoshot <sec> <path>  render headless for <sec> seconds, save a PNG, then quit
--mem-mb <int>           trail-memory cap in MB (default 192)
--2d                     start in 2D mode
--color <speed|identity|phase>   start color mode
```

Example — deterministic capture in 2D phase mode:

```sh
swift run -c release Pendularium --seed 42 --2d --color phase --autoshot 12 out.png
```

`--autoshot` renders to an **offscreen** texture and is independent of the display, so it works
in scripts/CI and even when the screen is asleep.

Note on reproducibility: `--seed` fixes the smooth seeding field and the order in which pendulums
spawn, so the same seed on the same machine produces essentially the same image. The final density
still depends on machine performance, because growth is gated on real frame timing.

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
| `main.swift` | AppKit bootstrap, window, input, HUD, CLI, offscreen autoshot driver |
| `Renderer.swift` | HDR line pipeline + tone-map pass, growth controller, 2D/3D + pause, screenshots |
| `Simulation.swift` | double-pendulum RK4 + energy renormalization, coherent field seeding (SoA, parallel) |
| `TrailBuffer.swift` | persistent append-only vertex buffer |
| `Shaders.swift` | Metal source (runtime-compiled): line shader (per-vertex color modes) + tone-map |
| `Camera.swift`, `Matrix.swift`, `Random.swift`, `Config.swift`, `Types.swift` | support |
