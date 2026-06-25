import simd

/// Right-handed perspective projection with a [0, 1] depth range (Metal convention).
func makePerspective(fovYRadians: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let ys = 1 / tan(fovYRadians * 0.5)
    let xs = ys / aspect
    let zs = far / (near - far)
    return simd_float4x4(columns: (
        SIMD4<Float>(xs, 0, 0, 0),
        SIMD4<Float>(0, ys, 0, 0),
        SIMD4<Float>(0, 0, zs, -1),
        SIMD4<Float>(0, 0, zs * near, 0)
    ))
}

/// Right-handed orthographic projection (centered) with a [0, 1] depth range (Metal convention).
func makeOrthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> simd_float4x4 {
    let sx = 1 / halfWidth
    let sy = 1 / halfHeight
    let sz = 1 / (near - far)
    return simd_float4x4(columns: (
        SIMD4<Float>(sx, 0, 0, 0),
        SIMD4<Float>(0, sy, 0, 0),
        SIMD4<Float>(0, 0, sz, 0),
        SIMD4<Float>(0, 0, near * sz, 1)
    ))
}

/// Right-handed look-at view matrix.
func makeLookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let z = normalize(eye - center)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    return simd_float4x4(columns: (
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
    ))
}
