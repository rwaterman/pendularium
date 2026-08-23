import AppKit
import MetalKit

setbuf(stdout, nil)

// MARK: - CLI

struct LaunchOptions {
    var seed: UInt64
    var seedWasGiven: Bool
    var autoshot: (time: Double, url: URL)?
    var trailMemoryMB: Int?
    var twoD: Bool
    var colorMode: ColorMode
    var record: Recorder.Output?
    var seconds: Double?
    var report: URL?
    var exportPLY: URL?
}

func parseOptions() -> LaunchOptions {
    var seed = UInt64.random(in: UInt64.min...UInt64.max)
    var seedGiven = false
    var autoshot: (time: Double, url: URL)?
    var memMB: Int?
    var twoD = false
    var colorMode: ColorMode = .speed
    var record: Recorder.Output?
    var seconds: Double?
    var report: URL?
    var exportPLY: URL?

    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--seed":
            if i + 1 < args.count, let v = UInt64(args[i + 1]) { seed = v; seedGiven = true; i += 1 }
        case "--autoshot":
            if i + 2 < args.count, let t = Double(args[i + 1]) {
                autoshot = (t, URL(fileURLWithPath: args[i + 2])); i += 2
            }
        case "--record":
            if i + 1 < args.count { record = .video(URL(fileURLWithPath: args[i + 1])); i += 1 }
        case "--gif":
            if i + 1 < args.count { record = .gif(URL(fileURLWithPath: args[i + 1])); i += 1 }
        case "--seconds":
            if i + 1 < args.count, let v = Double(args[i + 1]) { seconds = v; i += 1 }
        case "--report":
            if i + 1 < args.count { report = URL(fileURLWithPath: args[i + 1]); i += 1 }
        case "--export-ply":
            if i + 1 < args.count { exportPLY = URL(fileURLWithPath: args[i + 1]); i += 1 }
        case "--mem-mb":
            if i + 1 < args.count, let v = Int(args[i + 1]) { memMB = v; i += 1 }
        case "--2d":
            twoD = true
        case "--color":
            if i + 1 < args.count {
                switch args[i + 1] {
                case "speed": colorMode = .speed
                case "identity": colorMode = .identity
                case "phase": colorMode = .phase
                default: break
                }
                i += 1
            }
        case "--help", "-h":
            print("""
            pendularium — a field of chaotic double pendulums painting a fractal-like image.
              --seed <uint64>          reproduce a run's initial conditions
              --autoshot <sec> <path>  render for <sec>, save a PNG, then quit
              --record <path.mp4>      render the scripted demo to an H.264 video, then quit
              --gif <path.gif>         render the scripted demo to a looping GIF, then quit
              --seconds <n>            demo length for --record (default 25) / --gif (default 10)
              --report <path.json>     write the run report (measurements + seed) on exit
              --export-ply <path.ply>  write the trail segments as a colored PLY on exit
              --mem-mb <int>           trail memory cap (default 192)
              --2d                     start in 2D mode
              --color <speed|identity|phase>   start color mode
            Controls: drag/scroll = move, D = 2D/3D, C = color mode, Space = pause,
                      S = screenshot, R = report, P = PLY export, Q = quit.
                      Pauses automatically once at the limit.
            """)
            exit(0)
        default:
            break
        }
        i += 1
    }
    return LaunchOptions(seed: seed, seedWasGiven: seedGiven, autoshot: autoshot,
                         trailMemoryMB: memMB, twoD: twoD, colorMode: colorMode,
                         record: record, seconds: seconds, report: report, exportPLY: exportPLY)
}

// MARK: - View (input + Metal surface)

final class PendulumView: MTKView {
    weak var renderer: Renderer?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": renderer?.requestScreenshot()
        case "r": _ = renderer?.writeReport(to: URL(fileURLWithPath: "pendularium-\(Int(Date().timeIntervalSince1970)).json"))
        case "p": _ = renderer?.exportPLY(to: URL(fileURLWithPath: "pendularium-\(Int(Date().timeIntervalSince1970)).ply"))
        case "q": NSApp.terminate(nil)
        case "d": renderer?.toggleDimension()
        case "c": renderer?.cycleColorMode()
        case " ": renderer?.togglePause()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        renderer?.camera.drag(dx: Float(event.deltaX), dy: Float(event.deltaY))
    }

    override func scrollWheel(with event: NSEvent) {
        renderer?.camera.zoom(Float(event.scrollingDeltaY))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var view: PendulumView!
    private var renderer: Renderer!
    private var hud: NSTextField!
    private let options: LaunchOptions

    init(options: LaunchOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }

        var config = Config()
        if let mem = options.trailMemoryMB { config.trailMemoryMB = mem }

        let frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        view = PendulumView(frame: frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.012, green: 0.012, blue: 0.022, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false   // allow screenshot readback

        renderer = Renderer(view: view, config: config, seed: options.seed, autoshot: options.autoshot,
                            startTwoD: options.twoD, startColor: options.colorMode)
        view.delegate = renderer
        view.renderer = renderer

        print("[pendularium] seed = \(options.seed)\(options.seedWasGiven ? " (given)" : " (random)")")

        hud = NSTextField(labelWithString: "")
        hud.frame = NSRect(x: 12, y: frame.height - 58, width: 960, height: 46)
        hud.autoresizingMask = [.maxXMargin, .minYMargin]
        hud.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        hud.textColor = NSColor(white: 0.85, alpha: 0.9)
        hud.maximumNumberOfLines = 2
        view.addSubview(hud)

        let seed = options.seed
        renderer.onStats = { [weak self] s in
            self?.hud.stringValue = String(
                format: "[%@]  color:%@   pendulums %d   segments %d   cpu %.1fms gpu %.1fms   %@\ndrag/scroll=move  D=2D/3D  C=color  Space=pause  S=shot  R=report  P=ply  Q=quit   seed %llu",
                s.twoD ? "2D" : "3D", s.colorMode, s.active, s.segments,
                s.cpuMs, s.gpuMs, s.phase.rawValue, seed)
        }

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Pendularium"
        window.contentView = view
        window.center()

        // Headless capture: drive rendering ourselves into an offscreen texture rather than relying
        // on the display-link/drawable (which stall when the display sleeps). No window is shown.
        let headless = options.autoshot != nil || options.record != nil
        if headless {
            view.isPaused = true
            view.enableSetNeedsDisplay = false
        } else {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            NSApp.activate(ignoringOtherApps: true)
        }

        if options.autoshot != nil {
            DispatchQueue.main.async { self.renderer.runAutoshotAndExit(width: 1600, height: 1000) }
        } else if let output = options.record {
            DispatchQueue.main.async { self.runRecordingAndExit(output) }
        }
    }

    private func runRecordingAndExit(_ output: Recorder.Output) {
        let seconds: Double
        let width: Int, height: Int
        let url: URL
        switch output {
        case .video(let u): seconds = options.seconds ?? 25; width = 1280; height = 800; url = u
        case .gif(let u): seconds = options.seconds ?? 10; width = 640; height = 400; url = u
        }
        let ok = Recorder.run(renderer: renderer, output: output, seconds: seconds, width: width, height: height)
        print("[pendularium] demo \(ok ? "saved" : "FAILED"): \(url.path)")
        if !ok { exit(1) }
        NSApp.terminate(nil)
    }

    /// `--report` / `--export-ply` apply to whatever the run accumulated, in every mode.
    func applicationWillTerminate(_ notification: Notification) {
        if let url = options.report, !renderer.writeReport(to: url) { exit(1) }
        if let url = options.exportPLY, !renderer.exportPLY(to: url) { exit(1) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let options = parseOptions()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
