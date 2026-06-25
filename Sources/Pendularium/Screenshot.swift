import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reads a BGRA8 Metal texture back to CPU and writes it as a PNG. Used by the `S` key and
/// `--autoshot`. Requires the source texture to be readable (MTKView `framebufferOnly = false`).
enum Screenshot {
    static func writePNG(from texture: MTLTexture, to url: URL) -> Bool {
        let width = texture.width
        let height = texture.height
        guard width > 0, height > 0 else { return false }

        let bytesPerRow = width * 4
        var bgra = [UInt8](repeating: 0, count: bytesPerRow * height)
        bgra.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                                    provider: provider, decode: nil, shouldInterpolate: false,
                                    intent: .defaultIntent)
        else { return false }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cgImage, nil)
        return CGImageDestinationFinalize(dest)
    }
}
