import AppKit
import MetalKit

setbuf(stdout, nil)

// MARK: - CLI

struct LaunchOptions {
    var seed: UInt64
    var seedWasGiven: Bool
    var autoshot: (time: Double, url: URL)?
    var trailMemoryMB: Int?
}

func parseOptions() -> LaunchOptions {
    var seed = UInt64.random(in: UInt64.min...UInt64.max)
    var seedGiven = false
    var autoshot: (time: Double, url: URL)?
    var memMB: Int?

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
        case "--mem-mb":
            if i + 1 < args.count, let v = Int(args[i + 1]) { memMB = v; i += 1 }
        case "--help", "-h":
            print("""
            pendularium — a field of chaotic double pendulums painting a fractal-like image.
              --seed <uint64>          reproduce a run's initial conditions
              --autoshot <sec> <path>  render for <sec>, save a PNG, then quit
              --mem-mb <int>           trail memory cap (default 192)
            Controls: drag = orbit, scroll = zoom, S = screenshot, Q = quit.
            """)
            exit(0)
        default:
            break
        }
        i += 1
    }
    return LaunchOptions(seed: seed, seedWasGiven: seedGiven, autoshot: autoshot, trailMemoryMB: memMB)
}

// MARK: - View (input + Metal surface)

final class PendulumView: MTKView {
    weak var renderer: Renderer?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "s": renderer?.requestScreenshot()
        case "q": NSApp.terminate(nil)
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

        renderer = Renderer(view: view, config: config, seed: options.seed, autoshot: options.autoshot)
        view.delegate = renderer
        view.renderer = renderer

        print("[pendularium] seed = \(options.seed)\(options.seedWasGiven ? " (given)" : " (random)")")

        hud = NSTextField(labelWithString: "")
        hud.frame = NSRect(x: 12, y: frame.height - 58, width: 760, height: 46)
        hud.autoresizingMask = [.maxXMargin, .minYMargin]
        hud.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        hud.textColor = NSColor(white: 0.85, alpha: 0.9)
        hud.maximumNumberOfLines = 2
        view.addSubview(hud)

        let seed = options.seed
        renderer.onStats = { [weak self] s in
            self?.hud.stringValue = String(
                format: "pendulums %d   segments %d   cpu %.1fms   gpu %.1fms   %@%@\nseed %llu   drag=orbit scroll=zoom  S=shot  Q=quit",
                s.active, s.segments, s.cpuMs, s.gpuMs, s.phase.rawValue,
                s.trailFull ? " (trail full)" : "", seed)
        }

        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Pendularium"
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let options = parseOptions()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
