import Foundation
import simd

/// CPU mirror of the shader's color functions, so exports carry the same colors the screen shows.
enum ModeColor {
    /// Cool→hot gradient (deep blue → cyan → green → yellow → orange → red).
    static func coolHot(_ t: Float) -> SIMD3<Float> {
        let t = max(0, min(1, t))
        let ts: [Float] = [0, 0.25, 0.5, 0.7, 0.85, 1]
        let cs: [SIMD3<Float>] = [
            SIMD3(0.10, 0.12, 0.48), SIMD3(0.10, 0.55, 0.85), SIMD3(0.12, 0.80, 0.42),
            SIMD3(0.95, 0.90, 0.20), SIMD3(1.00, 0.55, 0.10), SIMD3(1.00, 0.22, 0.16),
        ]
        for i in 1..<ts.count where t <= ts[i] {
            let f = (t - ts[i - 1]) / max(1e-5, ts[i] - ts[i - 1])
            return simd_mix(cs[i - 1], cs[i], SIMD3(repeating: f))
        }
        return cs[cs.count - 1]
    }

    /// Full-wheel HSV (hue in [0, 1]).
    static func hsv(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let q = h + SIMD3<Float>(0, 2.0 / 3.0, 1.0 / 3.0)
        let p = abs((q - q.rounded(.down)) * 6 - 3)
        let c = simd_clamp(p - 1, SIMD3(repeating: 0), SIMD3(repeating: 1))
        return v * simd_mix(SIMD3(repeating: 1), c, SIMD3(repeating: s))
    }

    /// Color of a vertex under `mode`, from its packed attributes.
    static func rgb(attribs: UInt32, mode: ColorMode) -> SIMD3<Float> {
        let speed = Float(attribs & 0xFF) / 255
        let hue = Float((attribs >> 8) & 0xFF) / 255
        let angle = Float((attribs >> 16) & 0xFF) / 255
        switch mode {
        case .speed: return coolHot(speed)
        case .identity: return hsv(hue, 0.85, 1)
        case .phase: return hsv(angle, 0.85, 1)
        }
    }
}

/// Writes the accumulated trail segments as a binary little-endian PLY: colored vertices plus an
/// edge per segment. Opens in Blender, MeshLab, and CloudCompare as a colored line cloud.
enum PLYExport {
    static let vertexBytes = 3 * 4 + 3
    static let edgeBytes = 2 * 4

    static func header(vertexCount: Int, mode: ColorMode) -> String {
        """
        ply
        format binary_little_endian 1.0
        comment Pendularium trail segments, colors baked for color mode \(mode.label)
        element vertex \(vertexCount)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        element edge \(vertexCount / 2)
        property int vertex1
        property int vertex2
        end_header

        """
    }

    static func write(vertices: UnsafePointer<TrailVertex>, count: Int, mode: ColorMode, to url: URL) -> Bool {
        let count = count - count % 2
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? file.close() }
        do {
            try file.write(contentsOf: Data(header(vertexCount: count, mode: mode).utf8))
            let chunk = 1 << 20
            var start = 0
            while start < count {
                let n = min(chunk, count - start)
                var bytes = [UInt8]()
                bytes.reserveCapacity(n * vertexBytes)
                for i in start..<(start + n) {
                    let v = vertices[i]
                    appendLE(v.x.bitPattern, to: &bytes)
                    appendLE(v.y.bitPattern, to: &bytes)
                    appendLE(v.z.bitPattern, to: &bytes)
                    let c = ModeColor.rgb(attribs: v.attribs, mode: mode)
                    bytes.append(UInt8(c.x * 255 + 0.5))
                    bytes.append(UInt8(c.y * 255 + 0.5))
                    bytes.append(UInt8(c.z * 255 + 0.5))
                }
                try file.write(contentsOf: Data(bytes))
                start += n
            }
            start = 0
            while start < count {
                let n = min(chunk, count - start)
                var bytes = [UInt8]()
                bytes.reserveCapacity(n / 2 * edgeBytes)
                var i = start
                while i < start + n {
                    appendLE(UInt32(i), to: &bytes)
                    appendLE(UInt32(i + 1), to: &bytes)
                    i += 2
                }
                try file.write(contentsOf: Data(bytes))
                start += n
            }
        } catch {
            print("[pendularium] PLY write failed: \(error)")
            return false
        }
        return true
    }

    @inline(__always)
    private static func appendLE(_ v: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
        bytes.append(UInt8((v >> 16) & 0xFF))
        bytes.append(UInt8((v >> 24) & 0xFF))
    }
}
