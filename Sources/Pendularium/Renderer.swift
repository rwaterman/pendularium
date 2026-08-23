import Metal
import MetalKit
import QuartzCore
import AppKit

/// Drives the whole thing: steps the simulation, accumulates trail geometry, measures per-frame
/// CPU and GPU work to gate growth, and renders the trail + live-arm line buffers additively.
final class Renderer: NSObject, MTKViewDelegate {
    enum Phase: String {
        case growing = "GROW", saturated = "SATURATE", frozen = "FREEZE (at limit)", paused = "PAUSED"
    }

    struct Stats {
        var active: Int
        var segments: Int
        var cpuMs: Double
        var gpuMs: Double
        var phase: Phase
        var twoD: Bool
        var colorMode: String
    }

    var camera: Camera
    var onStats: ((Stats) -> Void)?

    private let config: Config
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState        // additive lines → HDR
    private let tonemapPipeline: MTLRenderPipelineState // HDR → display
    private var hdrTexture: MTLTexture?
    private var hdrW = 0
    private var hdrH = 0

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
    private var emaCpuMs: Double = 0
    private var emaGpuMs: Double = 0
    private var phase: Phase = .growing

    private var twoD = false
    private var colorMode: ColorMode = .speed
    private var manualPaused = false

    // Screenshots
    private var pendingKeyShot = false
    private let autoshot: (time: Double, url: URL)?

    init(view: MTKView, config: Config, seed: UInt64, autoshot: (time: Double, url: URL)?,
         startTwoD: Bool, startColor: ColorMode) {
        guard let device = view.device else { fatalError("MTKView has no device") }
        guard let queue = device.makeCommandQueue() else { fatalError("No command queue") }
        self.device = device
        self.queue = queue
        self.config = config
        self.autoshot = autoshot
        self.camera = Camera(radius: config.cameraRadius, orthoHalfHeight: config.orthoHalfHeight)

        // Runtime-compiled shaders → two pipelines: additive lines into an HDR target, then a
        // fullscreen tone-mapping pass into the display/capture target.
        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)

            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "line_vertex")
            desc.fragmentFunction = library.makeFunction(name: "line_fragment")
            let att = desc.colorAttachments[0]!
            att.pixelFormat = .rgba16Float
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            att.sourceRGBBlendFactor = .one
            att.destinationRGBBlendFactor = .one
            att.sourceAlphaBlendFactor = .one
            att.destinationAlphaBlendFactor = .one
            pipeline = try device.makeRenderPipelineState(descriptor: desc)

            let tdesc = MTLRenderPipelineDescriptor()
            tdesc.vertexFunction = library.makeFunction(name: "fs_vertex")
            tdesc.fragmentFunction = library.makeFunction(name: "tonemap_fragment")
            tdesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            tonemapPipeline = try device.makeRenderPipelineState(descriptor: tdesc)
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

        colorMode = startColor
        if startTwoD {
            twoD = true
            sim.reset(twoD: true)
            camera.configure(twoD: true, defaultRadius: config.cameraRadius,
                             defaultOrtho: config.orthoHalfHeight)
        }
        sim.spawn(upTo: config.spawnPerFrame)
        print("[pendularium] field initialized (\(startTwoD ? "2D" : "3D"), color:\(startColor.label)) — growing")
    }

    func requestScreenshot() { pendingKeyShot = true }

    var stats: Stats {
        Stats(active: sim.active, segments: trails.count / 2, cpuMs: emaCpuMs, gpuMs: emaGpuMs,
              phase: phase, twoD: twoD, colorMode: colorMode.label)
    }

    /// Cycle the color distribution. Pure uniform change → recolors the whole painting live.
    func cycleColorMode() {
        let all = ColorMode.allCases
        colorMode = all[(colorMode.rawValue + 1) % all.count]
    }

    /// Manually pause/resume growth (no effect once the painting is final at the limit).
    func togglePause() { manualPaused.toggle() }

    /// Switch between 3D and 2D. The painting is mode-specific, so this restarts accumulation.
    func toggleDimension() {
        let next = !twoD
        // Drain in-flight frames so the GPU isn't reading buffers while we clear/reseed them.
        for _ in 0..<Renderer.maxFramesInFlight { inFlight.wait() }
        twoD = next
        trails.reset()
        sim.reset(twoD: next)
        sim.spawn(upTo: config.spawnPerFrame)
        camera.configure(twoD: next, defaultRadius: config.cameraRadius, defaultOrtho: config.orthoHalfHeight)
        manualPaused = false
        emaCpuMs = 0; emaGpuMs = 0
        phase = .growing
        for _ in 0..<Renderer.maxFramesInFlight { inFlight.signal() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: - Per-frame simulation step (shared by interactive and headless paths)

    /// Advance one frame: pause/grow decision, integrate, and emit trail + arm geometry.
    private func advance(dt: Float, ring: Int) {
        // "Pause once at limit": when the painting is full (or manually paused), stop the
        // simulation and auto-orbit, but keep rendering so drag/zoom/C/D stay live.
        let atLimit = trails.isFull
        let running = !manualPaused && !atLimit

        if running {
            camera.advance(dt: dt, rate: config.orbitRateRadPerSec)
            if emaCpuMs + emaGpuMs >= config.frameBudgetMs {
                phase = .saturated
            } else {
                phase = .growing
                sim.spawn(upTo: sim.active + config.spawnPerFrame)
            }
        } else {
            phase = atLimit ? .frozen : .paused
        }

        let cpuStart = CACurrentMediaTime()
        if running { sim.step() }
        sim.emitGeometry(into: trails, arms: armsPtrs[ring],
                         trailAlpha: config.trailAlpha, armAlpha: config.armAlpha,
                         allowTrailGrowth: running)
        if running {
            let cpuMs = (CACurrentMediaTime() - cpuStart) * 1000
            emaCpuMs += 0.12 * (cpuMs - emaCpuMs)
        }
    }

    private func writeUniforms(ring: Int, aspect: Float) {
        uniformBuffers[ring].contents()
            .bindMemory(to: Uniforms.self, capacity: 1)
            .pointee = Uniforms(mvp: camera.viewProjection(aspect: aspect),
                                modeParams: SIMD4<Float>(Float(colorMode.rawValue), 0, 0, 0))
    }

    /// Issue the trail + arm draw calls into an encoder (target-agnostic).
    private func encodeDraws(_ enc: MTLRenderCommandEncoder, ring: Int) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(uniformBuffers[ring], offset: 0, index: 1)
        if trails.count > 0 {
            enc.setVertexBuffer(trails.buffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: trails.count)
        }
        let armVerts = sim.active * 4
        if armVerts > 0 {
            enc.setVertexBuffer(armsBuffers[ring], offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: armVerts)
        }
        enc.endEncoding()
    }

    private func ensureHDR(width: Int, height: Int) {
        if hdrTexture != nil, hdrW == width, hdrH == height { return }
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: max(1, width), height: max(1, height), mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .private
        hdrTexture = device.makeTexture(descriptor: td)
        hdrW = width; hdrH = height
    }

    /// Two-pass render: additive lines into the HDR target, then tone-map into `finalRPD`.
    private func renderHDR(into finalRPD: MTLRenderPassDescriptor, cmd: MTLCommandBuffer,
                           ring: Int, width: Int, height: Int) {
        ensureHDR(width: width, height: height)
        writeUniforms(ring: ring, aspect: Float(width) / Float(max(1, height)))

        let hdrRPD = MTLRenderPassDescriptor()
        hdrRPD.colorAttachments[0].texture = hdrTexture
        hdrRPD.colorAttachments[0].loadAction = .clear
        hdrRPD.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        hdrRPD.colorAttachments[0].storeAction = .store
        if let e1 = cmd.makeRenderCommandEncoder(descriptor: hdrRPD) {
            encodeDraws(e1, ring: ring)
        }

        if let e2 = cmd.makeRenderCommandEncoder(descriptor: finalRPD) {
            e2.setRenderPipelineState(tonemapPipeline)
            e2.setFragmentTexture(hdrTexture, index: 0)
            var params = SIMD2<Float>(config.exposure, config.saturation)
            e2.setFragmentBytes(&params, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            e2.endEncoding()
        }
    }

    // MARK: - Interactive rendering (display-link driven; needs an awake display)

    func draw(in view: MTKView) {
        inFlight.wait()
        frameRing = (frameRing + 1) % Renderer.maxFramesInFlight

        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - lastTime))
        lastTime = now

        advance(dt: dt, ring: frameRing)

        let w = Int(view.drawableSize.width), h = Int(view.drawableSize.height)
        guard w > 0, h > 0,
              let drawable = view.currentDrawable,
              let finalRPD = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }

        renderHDR(into: finalRPD, cmd: cmd, ring: frameRing, width: w, height: h)

        let wantKeyShot = pendingKeyShot
        pendingKeyShot = false

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
            self.inFlight.signal()
        }

        cmd.present(drawable)
        cmd.commit()

        onStats?(stats)
    }

    // MARK: - Headless capture (offscreen; works regardless of display sleep)

    /// A CPU-readable BGRA8 render target for offscreen capture.
    func makeOffscreenTarget(width: Int, height: Int) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        return device.makeTexture(descriptor: td)
    }

    /// Step the simulation `steps` frames (1/60 s each) and render the painting into `target`,
    /// blocking until the GPU is done so the texture can be read back. Independent of the
    /// display link / drawable, so it works when the display is asleep or there is no window.
    func renderOffscreen(into target: MTLTexture, steps: Int) -> Bool {
        for _ in 0..<steps { advance(dt: 1.0 / 60.0, ring: 0) }
        guard let cmd = queue.makeCommandBuffer() else { return false }
        let finalRPD = MTLRenderPassDescriptor()
        finalRPD.colorAttachments[0].texture = target
        finalRPD.colorAttachments[0].loadAction = .dontCare
        finalRPD.colorAttachments[0].storeAction = .store
        renderHDR(into: finalRPD, cmd: cmd, ring: 0, width: target.width, height: target.height)
        cmd.commit()
        cmd.waitUntilCompleted()
        return true
    }

    /// Step the simulation forward `time` seconds of frames, render the accumulated painting once
    /// to an offscreen texture, write a PNG, and quit.
    func runAutoshotAndExit(width: Int, height: Int) {
        guard let shot = autoshot else { return }
        guard let tex = makeOffscreenTarget(width: width, height: height),
              renderOffscreen(into: tex, steps: max(1, Int(shot.time * 60))) else {
            print("[pendularium] autoshot FAILED: could not render offscreen")
            NSApp.terminate(nil); return
        }
        let ok = Screenshot.writePNG(from: tex, to: shot.url)
        print("[pendularium] autoshot \(ok ? "saved" : "FAILED") [offscreen]: \(shot.url.path) " +
              "(active=\(sim.active), segments=\(trails.count / 2))")
        NSApp.terminate(nil)
    }
}
