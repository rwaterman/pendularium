import simd

/// One vertex in a line buffer. Laid out to match the Metal `TrailVertex` struct
/// (`packed_float3` + `uint`) so the same 16-byte stride is used on both sides.
struct TrailVertex {
    var x: Float
    var y: Float
    var z: Float
    var color: UInt32

    init(_ p: SIMD3<Float>, _ color: UInt32) {
        self.x = p.x
        self.y = p.y
        self.z = p.z
        self.color = color
    }
}

/// Per-frame shader uniforms. Must match the Metal `Uniforms` struct.
struct Uniforms {
    var mvp: simd_float4x4
}
