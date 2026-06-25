import simd

/// Dual-mode camera. In 3D it orbits the volume (auto-orbit + drag/zoom). In 2D it is a fixed
/// head-on orthographic view of the z=0 plane (drag pans, zoom scales). No auto-orbit in 2D.
struct Camera {
    var orthographic = false
    var target = SIMD3<Float>(0, 0, 0)

    // 3D orbit
    var radius: Float
    var azimuth: Float = 0.6
    var elevation: Float = 0.22
    var fovY: Float = 50 * .pi / 180

    // 2D orthographic
    var orthoHalfHeight: Float

    init(radius: Float, orthoHalfHeight: Float) {
        self.radius = radius
        self.orthoHalfHeight = orthoHalfHeight
    }

    mutating func advance(dt: Float, rate: Float) {
        guard !orthographic else { return }
        azimuth += dt * rate
    }

    mutating func drag(dx: Float, dy: Float) {
        if orthographic {
            let s = orthoHalfHeight / 400
            target.x -= dx * s
            target.y += dy * s
        } else {
            azimuth -= dx * 0.005
            elevation = max(-1.45, min(1.45, elevation + dy * 0.005))
        }
    }

    mutating func zoom(_ delta: Float) {
        if orthographic {
            orthoHalfHeight = max(4, min(400, orthoHalfHeight * (1 - delta * 0.04)))
        } else {
            radius = max(15, min(900, radius * (1 - delta * 0.04)))
        }
    }

    /// Switch projection mode and re-frame to defaults (called on 2D/3D toggle).
    mutating func configure(twoD: Bool, defaultRadius: Float, defaultOrtho: Float) {
        orthographic = twoD
        target = SIMD3<Float>(0, 0, 0)
        if twoD {
            orthoHalfHeight = defaultOrtho
        } else {
            radius = defaultRadius
            azimuth = 0.6
            elevation = 0.22
        }
    }

    private var eye: SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth), sa = sin(azimuth)
        return target + radius * SIMD3<Float>(ce * sa, se, ce * ca)
    }

    func viewProjection(aspect: Float) -> simd_float4x4 {
        let a = max(0.01, aspect)
        if orthographic {
            let view = makeLookAt(eye: target + SIMD3<Float>(0, 0, 1000), center: target,
                                  up: SIMD3<Float>(0, 1, 0))
            let proj = makeOrthographic(halfWidth: orthoHalfHeight * a, halfHeight: orthoHalfHeight,
                                        near: 0.5, far: 3000)
            return proj * view
        } else {
            let view = makeLookAt(eye: eye, center: target, up: SIMD3<Float>(0, 1, 0))
            let proj = makePerspective(fovYRadians: fovY, aspect: a, near: 0.5, far: 3000)
            return proj * view
        }
    }
}
