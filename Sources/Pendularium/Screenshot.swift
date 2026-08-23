import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reads a BGRA8 Metal texture back to the CPU as a `CGImage` or PNG. Used by the `S` key,
/// `--autoshot`, and the demo recorder. Requires a readable source texture
/// (MTKView `framebufferOnly = false`, or a `.shared` offscreen target).
enum Screenshot {
    static let bitmapInfo = CGBitmapInfo(rawValue:
        CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

    static func cgImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
        bgra.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    static func writePNG(from texture: MTLTexture, to url: URL) -> Bool {
        guard let cgImage = cgImage(from: texture),
              let dest = CGImageDestinationCreateWithURL(
                  url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cgImage, nil)
        return CGImageDestinationFinalize(dest)
    }
}
