# Pendularium

A native macOS generative-art engine that paints a zoomed-out, fractal-like image from a field
of **chaotic double pendulums** swinging in 3D. Every run is seeded differently, so no two images
are alike. Built in Swift + Metal, runnable straight from the terminal.

## Demo

![Ten seconds of a run: the 3D field grows, hits the trail memory cap, then recolors live by identity and phase](docs/media/demo.gif)

[Watch the 25-second demo (MP4)](https://github.com/rwaterman/pendularium/releases/latest/download/pendularium-demo.mp4)
— it continues into 2D mode, where the head-on view reveals the coherent seeding field.

<!-- Inline player: drag pendularium-demo.mp4 into this file in GitHub's web editor and paste
     the user-attachments URL it inserts on its own line here. -->

Both are rendered from code: a scripted run "presses" the live controls on a schedule, every
frame is rendered offscreen, and the HUD is composited in. No screen recording, no ffmpeg.

```sh
swift run -c release Pendularium --seed 42 --gif demo.gif
swift run -c release Pendularium --seed 42 --record demo.mp4
```

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

![A finished 3D painting](docs/example.png)

## Requirements

- macOS 14 or later
- Xcode 16 or later (Swift 6 toolchain), including the command line tools
- A Mac with Metal; Apple Silicon recommended (the simulation is CPU-bound)

## Build and run

```sh
swift run -c release Pendularium
```

`-c release` is strongly recommended — the optimized build reaches many more pendulums before
saturating. A debug build works, it just saturates early.

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

```text
--seed <uint64>          reproduce a run's initial conditions
--2d                     start in 2D mode
--color <speed|identity|phase>   start color mode
--mem-mb <int>           trail-memory cap in MB (default 192)
--autoshot <sec> <path>  render headless for <sec> seconds, save a PNG, then quit
--record <path.mp4>      render the scripted demo to an H.264 video, then quit
--gif <path.gif>         render the scripted demo to a looping GIF, then quit
--seconds <n>            demo length for --record (default 25) / --gif (default 10)
```

Example — deterministic capture in 2D phase mode:

```sh
swift run -c release Pendularium --seed 42 --2d --color phase --autoshot 12 out.png
```

The headless modes (`--autoshot`, `--record`, `--gif`) render to an **offscreen** texture and
never show a window, so they work in scripts and even when the display is asleep.

Note on reproducibility: `--seed` fixes the smooth seeding field and the order in which pendulums
spawn, so the same seed on the same machine produces essentially the same image. The final density
still depends on machine performance, because growth is gated on real frame timing (the headless
modes have no GPU timing to gate on, so they grow at the maximum rate).

## Test

```sh
swift test
```

Tests cover the simulation (determinism, energy renormalization, 2D flattening), vertex packing,
the PRNG, projection math, and the camera. None of them need a GPU, so they run on CI.

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
| `main.swift` | AppKit bootstrap, window, input, HUD, CLI, headless entry points |
| `Renderer.swift` | HDR line pipeline + tone-map pass, growth controller, 2D/3D + pause, offscreen rendering |
| `Simulation.swift` | double-pendulum RK4 + energy renormalization, coherent field seeding (SoA, parallel) |
| `TrailBuffer.swift` | persistent append-only vertex buffer |
| `Shaders.swift` | Metal source (runtime-compiled): line shader (per-vertex color modes) + tone-map |
| `Recorder.swift` | scripted demo capture: H.264 via `AVAssetWriter`, GIF via ImageIO, HUD composite |
| `Screenshot.swift` | texture readback to `CGImage` / PNG |
| `Camera.swift`, `Matrix.swift`, `Random.swift`, `Config.swift`, `Types.swift` | support |
| `Tests/PendulariumTests` | simulation, packing, PRNG, matrix, and camera tests |

CI runs `swift build` and `swift test` on macOS, plus gitleaks, markdownlint, and a link check.

## License

MIT.
