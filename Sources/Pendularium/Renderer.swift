import Metal
import MetalKit
import QuartzCore
import AppKit

/// Drives the whole thing: steps the simulation, accumulates trail geometry, measures per-frame
/// CPU and GPU work to gate growth, and renders the trail + live-arm line buffers additively.
final class Renderer: NSObject, MTKViewDelegate {
    enum Phase: String { case growing = "GROW", saturated = "SATURATE", frozen = "FREEZE" }

    struct Stats {
        var active: Int
        var segments: Int
        var cpuMs: Double
        var gpuMs: Double
        var phase: Phase
        var trailFull: Bool
    }

    var camera: Camera
    var onStats: ((Stats) -> Void)?

    private let config: Config
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private let sim: Simulation
    private let trails: TrailBuffer

    private static let maxFramesInFlight = 3
    private let inFlight = DispatchSemaphore(value: maxFramesInFlight)
    private var frameRing = 0
    private let armsBuffers: [MTLBuffer]
    private let armsPtrs: [UnsafeMutablePointer<TrailVertex>]
    private let uniformBuffers: [MTLBuffer]
    private let armsCapacityVerts: Int

    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var elapsed: CFTimeInterval = 0
    private var emaCpuMs: Double = 0
    private var emaGpuMs: Double = 0
    private var phase: Phase = .growing

    // Screenshots
    private var pendingKeyShot = false
    private let autoshot: (time: Double, url: URL)?
    private var autoshotDone = false

    init(view: MTKView, config: Config, seed: UInt64, autoshot: (time: Double, url: URL)?) {
        guard let device = view.device else { fatalError("MTKView has no device") }
        guard let queue = device.makeCommandQueue() else { fatalError("No command queue") }
        self.device = device
        self.queue = queue
        self.config = config
        self.autoshot = autoshot
        self.camera = Camera(radius: config.cameraRadius)

        // Pipeline (runtime-compiled shader, additive premultiplied blending).
        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "line_vertex")
            desc.fragmentFunction = library.makeFunction(name: "line_fragment")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = view.colorPixelFormat
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .one
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            fatalError("Pipeline build failed: \(error)")
        }

        sim = Simulation(config: config, seed: seed)
        trails = TrailBuffer(device: device, capacity: config.trailVertexCapacity)

        armsCapacityVerts = config.maxPendulums * 4
        var ab: [MTLBuffer] = []
        var ap: [UnsafeMutablePointer<TrailVertex>] = []
        var ub: [MTLBuffer] = []
        for _ in 0..<Renderer.maxFramesInFlight {
            let armsBuf = device.makeBuffer(length: armsCapacityVerts * MemoryLayout<TrailVertex>.stride,
                                            options: .storageModeShared)!
            ab.append(armsBuf)
            ap.append(armsBuf.contents().bindMemory(to: TrailVertex.self, capacity: armsCapacityVerts))
            ub.append(device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)!)
        }
        armsBuffers = ab
        armsPtrs = ap
        uniformBuffers = ub

        super.init()

        sim.spawn(upTo: config.spawnPerFrame)
        print("[pendularium] seed in use; field initialized — growing toward the frame budget")
    }

    func requestScreenshot() { pendingKeyShot = true }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        inFlight.wait()
        frameRing = (frameRing + 1) % Renderer.maxFramesInFlight

        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now
        elapsed += Double(dt)
        camera.advance(dt: dt, rate: config.orbitRateRadPerSec)

        // Phase / growth decision from the previous frame's measured cost.
        if trails.isFull {
            phase = .frozen
        } else if emaCpuMs + emaGpuMs >= config.frameBudgetMs {
            phase = .saturated
        } else {
            phase = .growing
            sim.spawn(upTo: sim.active + config.spawnPerFrame)
        }

        // CPU work (the real cost, measured directly — vsync would mask it).
        let cpuStart = CACurrentMediaTime()
        sim.step()
        let allowGrowth = !trails.isFull
        sim.emitGeometry(into: trails, arms: armsPtrs[frameRing],
                         trailAlpha: config.trailAlpha, armAlpha: config.armAlpha,
                         allowTrailGrowth: allowGrowth)
        let cpuMs = (CACurrentMediaTime() - cpuStart) * 1000
        emaCpuMs += 0.12 * (cpuMs - emaCpuMs)

        let aspect = Float(view.drawableSize.width / max(1, view.drawableSize.height))
        uniformBuffers[frameRing].contents()
            .bindMemory(to: Uniforms.self, capacity: 1)
            .pointee = Uniforms(mvp: camera.viewProjection(aspect: aspect))

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else {
            inFlight.signal()
            return
        }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(uniformBuffers[frameRing], offset: 0, index: 1)

        if trails.count > 0 {
            enc.setVertexBuffer(trails.buffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: trails.count)
        }
        let armVerts = sim.active * 4
        if armVerts > 0 {
            enc.setVertexBuffer(armsBuffers[frameRing], offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: armVerts)
        }
        enc.endEncoding()

        let wantKeyShot = pendingKeyShot
        pendingKeyShot = false
        let wantAutoShot = !autoshotDone && (autoshot.map { elapsed >= $0.time } ?? false)
        if wantAutoShot { autoshotDone = true }

        cmd.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let gpuMs = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            if gpuMs > 0 { self.emaGpuMs += 0.12 * (gpuMs - self.emaGpuMs) }

            if wantKeyShot {
                let url = URL(fileURLWithPath: "pendularium-\(Int(Date().timeIntervalSince1970)).png")
                if Screenshot.writePNG(from: drawable.texture, to: url) {
                    print("[pendularium] screenshot saved: \(url.path)")
                }
            }
            if wantAutoShot, let shot = self.autoshot {
                let ok = Screenshot.writePNG(from: drawable.texture, to: shot.url)
                print("[pendularium] autoshot \(ok ? "saved" : "FAILED"): \(shot.url.path) " +
                      "(active=\(self.sim.active), segments=\(self.trails.count / 2))")
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            self.inFlight.signal()
        }

        cmd.present(drawable)
        cmd.commit()

        onStats?(Stats(active: sim.active, segments: trails.count / 2,
                       cpuMs: emaCpuMs, gpuMs: emaGpuMs, phase: phase, trailFull: trails.isFull))
    }
}
