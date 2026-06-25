import simd

/// Orbit camera framing the whole field. Auto-orbits slowly; mouse drag and scroll override.
struct Camera {
    var target = SIMD3<Float>(0, 0, 0)
    var radius: Float = 130
    var azimuth: Float = 0.6
    var elevation: Float = 0.22
    var fovY: Float = 50 * .pi / 180

    mutating func advance(dt: Float, rate: Float) {
        azimuth += dt * rate
    }

    mutating func drag(dx: Float, dy: Float) {
        azimuth -= dx * 0.005
        elevation = max(-1.45, min(1.45, elevation + dy * 0.005))
    }

    mutating func zoom(_ delta: Float) {
        radius = max(15, min(900, radius * (1 - delta * 0.04)))
    }

    private var eye: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth), sa = sin(azimuth)
        return target + radius * SIMD3<Float>(ce * sa, se, ce * ca)
    }

    func viewProjection(aspect: Float) -> simd_float4x4 {
        let view = makeLookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
        let proj = makePerspective(fovYRadians: fovY, aspect: max(0.01, aspect), near: 0.5, far: 3000)
        return proj * view
    }
}
