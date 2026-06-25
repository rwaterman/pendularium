import simd

/// Maps a normalized scalar (speed/energy proxy) to a cool→hot color and packs it to RGBA8.
/// Control points run deep-blue → cyan → green → yellow → orange → red, linearly interpolated.
enum Colormap {
    private static let stops: [(t: Float, c: SIMD3<Float>)] = [
        (0.00, SIMD3(0.10, 0.12, 0.48)),
        (0.25, SIMD3(0.10, 0.55, 0.85)),
        (0.50, SIMD3(0.12, 0.80, 0.42)),
        (0.70, SIMD3(0.95, 0.90, 0.20)),
        (0.85, SIMD3(1.00, 0.55, 0.10)),
        (1.00, SIMD3(1.00, 0.22, 0.16)),
    ]

    static func color(_ x: Float) -> SIMD3<Float> {
        let t = max(0, min(1, x))
        var lo = stops[0]
        for stop in stops {
            if stop.t >= t {
                if stop.t == lo.t { return stop.c }
                let f = (t - lo.t) / (stop.t - lo.t)
                return mix(lo.c, stop.c, t: f)
            }
            lo = stop
        }
        return stops[stops.count - 1].c
    }

    /// Pack RGBA into a little-endian UInt32 so byte0=R … byte3=A, matching the Metal
    /// `unpack_unorm4x8_to_float` byte order.
    static func packed(_ x: Float, alpha: Float) -> UInt32 {
        let c = color(x)
        let r = UInt32(max(0, min(255, c.x * 255)))
        let g = UInt32(max(0, min(255, c.y * 255)))
        let b = UInt32(max(0, min(255, c.z * 255)))
        let a = UInt32(max(0, min(255, alpha * 255)))
        return r | (g << 8) | (b << 16) | (a << 24)
    }
}
