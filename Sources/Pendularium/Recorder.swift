import AVFoundation
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Headless demo capture for the README: a scripted run "presses" the live controls on a
/// schedule while every frame is rendered offscreen with the HUD composited in, then written
/// as H.264 (`--record`) or a looping GIF (`--gif`). Needs no screen-recording permission
/// and no ffmpeg.
enum Recorder {
    enum Output {
        case video(URL)
        case gif(URL)
    }

    /// What the demo does and when (seconds into the run). The caption is shown for a moment
    /// after each cue so the viewer can see which control was used.
    struct Cue {
        let time: Double
        let caption: String
        let action: (Renderer) -> Void
    }

    static let script: [Cue] = [
        Cue(time: 0, caption: "3D field grows to the frame budget, then to the trail memory cap",
            action: { $0.camera.zoom(9) }),
        Cue(time: 4.5, caption: "C  color -> identity (per-pendulum hue: divergence / mixing)",
            action: { $0.cycleColorMode() }),
        Cue(time: 8.5, caption: "C  color -> phase (hue by swing angle: in / out of sync)",
            action: { $0.cycleColorMode() }),
        Cue(time: 12.5, caption: "D  2D mode: same seed, head-on, painting restarts",
            action: { $0.toggleDimension() }),
        Cue(time: 17, caption: "C  color -> speed (cool to hot by bob speed)",
            action: { $0.cycleColorMode() }),
        Cue(time: 21, caption: "C  color -> identity",
            action: { $0.cycleColorMode() }),
    ]

    private static let captionSeconds = 3.5

    static func run(renderer: Renderer, output: Output, seconds: Double, width: Int, height: Int) -> Bool {
        let fps: Int
        let sink: FrameSink?
        let frameCount: Int
        switch output {
        case .video(let url):
            fps = 30
            frameCount = max(1, Int(seconds * Double(fps)))
            sink = VideoSink(url: url, width: width, height: height, fps: fps)
        case .gif(let url):
            fps = 10
            frameCount = max(1, Int(seconds * Double(fps)))
            sink = GIFSink(url: url, frameCount: frameCount, fps: fps)
        }
        guard let sink, let target = renderer.makeOffscreenTarget(width: width, height: height) else {
            log("[pendularium] record FAILED: could not open output or offscreen target")
            return false
        }
        let simStepsPerFrame = 60 / fps

        var nextCue = 0
        var caption = ""
        var captionUntil = -1.0
        for frame in 0..<frameCount {
            let t = Double(frame) / Double(fps)
            while nextCue < script.count, script[nextCue].time <= t {
                script[nextCue].action(renderer)
                caption = script[nextCue].caption
                captionUntil = t + captionSeconds
                nextCue += 1
            }
            guard renderer.renderOffscreen(into: target, steps: simStepsPerFrame),
                  let raw = Screenshot.cgImage(from: target) else { return false }
            let captionAlpha = max(0, min(1, (captionUntil - t) / 0.5))
            let image = compose(raw, hud: hudLine(renderer.stats), caption: caption, captionAlpha: captionAlpha)
            guard sink.append(image, frame: frame) else { return false }
            if frame % fps == 0 { log("[pendularium] recording \(Int(t))s / \(Int(seconds))s") }
        }
        return sink.finish()
    }

    private static func hudLine(_ s: Renderer.Stats) -> String {
        let segments = Double(s.segments) / 1_000_000
        return String(format: "%@   color: %@   %@ pendulums   %.1fM segments   %@",
                      s.twoD ? "2D" : "3D", s.colorMode, grouped(s.active), segments, s.phase.rawValue)
    }

    private static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Draw the frame with the HUD line top-left and the (fading) cue caption under it.
    private static func compose(_ image: CGImage, hud: String, caption: String, captionAlpha: Double) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: Screenshot.bitmapInfo.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let size = CGFloat(h) / 34
        let pad = size
        drawText(hud, in: ctx, x: pad, y: CGFloat(h) - pad - size, size: size, alpha: 0.9)
        if captionAlpha > 0 {
            drawText(caption, in: ctx, x: pad, y: CGFloat(h) - pad - size * 2.6, size: size * 0.95,
                     alpha: CGFloat(captionAlpha) * 0.95)
        }
        return ctx.makeImage() ?? image
    }

    private static func drawText(_ text: String, in ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, alpha: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 0.93, alpha: alpha),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: size * 0.5, color: NSColor(white: 0, alpha: alpha).cgColor)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

private protocol FrameSink {
    func append(_ image: CGImage, frame: Int) -> Bool
    func finish() -> Bool
}

/// H.264 MP4 via AVAssetWriter, one pixel buffer per frame.
private final class VideoSink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int

    init?(url: URL, width: Int, height: Int, fps: Int) {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.fps = fps
    }

    func append(_ image: CGImage, frame: Int) -> Bool {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        guard let pool = adaptor.pixelBufferPool else { return false }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                               width: image.width, height: image.height, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: Screenshot.bitmapInfo.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        return adaptor.append(buffer, withPresentationTime: time)
    }

    func finish() -> Bool {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if let error = writer.error { log("[pendularium] video FAILED: \(error)") }
        return writer.status == .completed
    }
}

/// Looping GIF via ImageIO.
private final class GIFSink: FrameSink {
    private let destination: CGImageDestination
    private let delay: Double

    init?(url: URL, frameCount: Int, fps: Int) {
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else { return nil }
        let loopForever = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loopForever as CFDictionary)
        self.destination = destination
        self.delay = 1 / Double(fps)
    }

    func append(_ image: CGImage, frame: Int) -> Bool {
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        CGImageDestinationAddImage(destination, image, frameProps as CFDictionary)
        return true
    }

    func finish() -> Bool { CGImageDestinationFinalize(destination) }
}
