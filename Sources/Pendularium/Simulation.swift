import Foundation
import simd

/// Field of planar chaotic double pendulums. State is stored as raw parallel arrays (SoA)
/// so the per-pendulum integration can run lock-free across CPU cores via `concurrentPerform`.
/// Each pendulum swings in a plane parallel to world XY; its pivot's Z places it in a depth layer.
final class Simulation {
    let capacity: Int
    private let config: Config
    private let baseSeed: UInt64

    private(set) var active: Int = 0

    // State
    private let t1, t2, w1, w2: UnsafeMutablePointer<Float>
    // Parameters
    private let l1, l2, m1, m2: UnsafeMutablePointer<Float>
    private let pivX, pivY, pivZ: UnsafeMutablePointer<Float>
    private let e0: UnsafeMutablePointer<Float>
    // Derived (updated each step)
    private let b1X, b1Y: UnsafeMutablePointer<Float>       // world bob-1 (z = pivZ)
    private let b2X, b2Y: UnsafeMutablePointer<Float>       // world bob-2 / tip
    private let prevB2X, prevB2Y: UnsafeMutablePointer<Float> // last appended tip
    private let speed: UnsafeMutablePointer<Float>          // |v| of bob-2

    init(config: Config, seed: UInt64) {
        self.config = config
        self.capacity = config.maxPendulums
        self.baseSeed = seed
        let cap = config.maxPendulums
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: cap)
            p.initialize(repeating: 0, count: cap)
            return p
        }
        t1 = alloc(); t2 = alloc(); w1 = alloc(); w2 = alloc()
        l1 = alloc(); l2 = alloc(); m1 = alloc(); m2 = alloc()
        pivX = alloc(); pivY = alloc(); pivZ = alloc(); e0 = alloc()
        b1X = alloc(); b1Y = alloc(); b2X = alloc(); b2Y = alloc()
        prevB2X = alloc(); prevB2Y = alloc(); speed = alloc()
    }

    deinit {
        for p in [t1, t2, w1, w2, l1, l2, m1, m2, pivX, pivY, pivZ, e0,
                  b1X, b1Y, b2X, b2Y, prevB2X, prevB2Y, speed] {
            p.deallocate()
        }
    }

    /// Activate pendulums up to `target`, deterministically from the seed + index.
    func spawn(upTo target: Int) {
        let limit = min(target, capacity)
        guard limit > active else { return }
        let g = config.gravity
        for i in active..<limit {
            var r = SplitMix64(seed: pendulumSeed(base: baseSeed, index: i))
            let len1 = config.armBase * (1 + r.float(-config.armJitter, config.armJitter))
            let len2 = config.armBase * (1 + r.float(-config.armJitter, config.armJitter))
            let mass1 = 1 + r.float(-config.massJitter, config.massJitter)
            let mass2 = 1 + r.float(-config.massJitter, config.massJitter)
            // Difference of two uniforms → triangular distribution: dense core, soft edges,
            // so the field reads as an organic cloud rather than a hard-edged box.
            let px = (r.float01() - r.float01()) * config.spreadX
            let py = (r.float01() - r.float01()) * config.spreadY
            let pz = (r.float01() - r.float01()) * config.spreadZ
            let a1 = r.float(-.pi, .pi)
            let a2 = r.float(-.pi, .pi)

            t1[i] = a1; t2[i] = a2; w1[i] = 0; w2[i] = 0
            l1[i] = len1; l2[i] = len2; m1[i] = mass1; m2[i] = mass2
            pivX[i] = px; pivY[i] = py; pivZ[i] = pz
            e0[i] = Simulation.energy(a1, a2, 0, 0, mass1, mass2, len1, len2, g)

            let bx1 = px + len1 * sin(a1)
            let by1 = py - len1 * cos(a1)
            let bx2 = bx1 + len2 * sin(a2)
            let by2 = by1 - len2 * cos(a2)
            b1X[i] = bx1; b1Y[i] = by1
            b2X[i] = bx2; b2Y[i] = by2
            prevB2X[i] = bx2; prevB2Y[i] = by2
            speed[i] = 0
        }
        active = limit
    }

    /// Advance every active pendulum by one frame (subSteps × subDt), in parallel.
    func step() {
        let n = active
        guard n > 0 else { return }
        let g = config.gravity
        let dt = config.subDt
        let steps = config.subSteps
        let speedScale = config.speedScale

        let t1 = self.t1, t2 = self.t2, w1 = self.w1, w2 = self.w2
        let l1 = self.l1, l2 = self.l2, m1 = self.m1, m2 = self.m2
        let pivX = self.pivX, pivY = self.pivY, e0 = self.e0
        let b1X = self.b1X, b1Y = self.b1Y, b2X = self.b2X, b2Y = self.b2Y
        let speed = self.speed

        DispatchQueue.concurrentPerform(iterations: n) { i in
            var a1 = t1[i], a2 = t2[i], v1 = w1[i], v2 = w2[i]
            let La = l1[i], Lb = l2[i], Ma = m1[i], Mb = m2[i]

            for _ in 0..<steps {
                // RK4 on (θ1, θ2, ω1, ω2)
                let (k1a, k1b) = Simulation.accel(a1, a2, v1, v2, Ma, Mb, La, Lb, g)
                let (k2a, k2b) = Simulation.accel(a1 + 0.5 * dt * v1, a2 + 0.5 * dt * v2,
                                                  v1 + 0.5 * dt * k1a, v2 + 0.5 * dt * k1b, Ma, Mb, La, Lb, g)
                let v1b = v1 + 0.5 * dt * k1a, v2b = v2 + 0.5 * dt * k1b
                let (k3a, k3b) = Simulation.accel(a1 + 0.5 * dt * v1b, a2 + 0.5 * dt * v2b,
                                                  v1 + 0.5 * dt * k2a, v2 + 0.5 * dt * k2b, Ma, Mb, La, Lb, g)
                let v1c = v1 + 0.5 * dt * k2a, v2c = v2 + 0.5 * dt * k2b
                let (k4a, k4b) = Simulation.accel(a1 + dt * v1c, a2 + dt * v2c,
                                                  v1 + dt * k3a, v2 + dt * k3b, Ma, Mb, La, Lb, g)

                a1 += dt / 6 * (v1 + 2 * v1b + 2 * v1c + (v1 + dt * k3a))
                a2 += dt / 6 * (v2 + 2 * v2b + 2 * v2c + (v2 + dt * k3b))
                v1 += dt / 6 * (k1a + 2 * k2a + 2 * k3a + k4a)
                v2 += dt / 6 * (k1b + 2 * k2b + 2 * k3b + k4b)

                // Energy renormalization: project velocities back onto the initial energy
                // surface so RK4 drift can't wash the color palette out over long runs.
                let pe = g * (Ma * (-La * cos(a1)) + Mb * (-La * cos(a1) - Lb * cos(a2)))
                let keTarget = e0[i] - pe
                let keNow = Simulation.kinetic(a1, a2, v1, v2, Ma, Mb, La, Lb)
                if keNow > 1e-3 && keTarget > 1e-3 {
                    let s = (keTarget / keNow).squareRoot()
                    v1 *= s; v2 *= s
                }
            }

            t1[i] = a1; t2[i] = a2; w1[i] = v1; w2[i] = v2

            let bx1 = pivX[i] + La * sin(a1)
            let by1 = pivY[i] - La * cos(a1)
            let bx2 = bx1 + Lb * sin(a2)
            let by2 = by1 - Lb * cos(a2)
            b1X[i] = bx1; b1Y[i] = by1
            b2X[i] = bx2; b2Y[i] = by2

            // Instantaneous bob-2 world speed (drives color — varies wildly under chaos).
            let v2sq = (La * v1) * (La * v1) + (Lb * v2) * (Lb * v2)
                + 2 * La * Lb * v1 * v2 * cos(a1 - a2)
            speed[i] = max(0, v2sq).squareRoot() / speedScale
        }
    }

    /// Append one trail segment (previous tip → new tip) per active pendulum, then refresh
    /// the live-arm buffer (pivot→bob1, bob1→bob2). Both written serially; cheap at v1 scale.
    func emitGeometry(into trails: TrailBuffer, arms: UnsafeMutablePointer<TrailVertex>,
                      trailAlpha: Float, armAlpha: Float, allowTrailGrowth: Bool) {
        let n = active
        for i in 0..<n {
            let z = pivZ[i]
            let s = speed[i]
            let p2 = SIMD3<Float>(b2X[i], b2Y[i], z)

            if allowTrailGrowth {
                let c = Colormap.packed(s, alpha: trailAlpha)
                trails.appendSegment(SIMD3<Float>(prevB2X[i], prevB2Y[i], z), p2, color: c)
            }
            prevB2X[i] = p2.x; prevB2Y[i] = p2.y

            let ca = Colormap.packed(s, alpha: armAlpha)
            let piv = SIMD3<Float>(pivX[i], pivY[i], z)
            let b1 = SIMD3<Float>(b1X[i], b1Y[i], z)
            let base = i * 4
            arms[base + 0] = TrailVertex(piv, ca)
            arms[base + 1] = TrailVertex(b1, ca)
            arms[base + 2] = TrailVertex(b1, ca)
            arms[base + 3] = TrailVertex(p2, ca)
        }
    }

    // MARK: - Double pendulum physics (standard planar equations)

    /// Angular accelerations (α1, α2) for a planar double pendulum.
    @inline(__always)
    static func accel(_ a1: Float, _ a2: Float, _ v1: Float, _ v2: Float,
                      _ m1: Float, _ m2: Float, _ L1: Float, _ L2: Float, _ g: Float) -> (Float, Float) {
        let d = a1 - a2
        let sd = sin(d)
        let cd = cos(d)
        let denom = 2 * m1 + m2 - m2 * cos(2 * a1 - 2 * a2)
        let a1n = (-g * (2 * m1 + m2) * sin(a1)
                   - m2 * g * sin(a1 - 2 * a2)
                   - 2 * sd * m2 * (v2 * v2 * L2 + v1 * v1 * L1 * cd)) / (L1 * denom)
        let a2n = (2 * sd * (v1 * v1 * L1 * (m1 + m2)
                   + g * (m1 + m2) * cos(a1)
                   + v2 * v2 * L2 * m2 * cd)) / (L2 * denom)
        return (a1n, a2n)
    }

    @inline(__always)
    static func kinetic(_ a1: Float, _ a2: Float, _ v1: Float, _ v2: Float,
                        _ m1: Float, _ m2: Float, _ L1: Float, _ L2: Float) -> Float {
        let v1sq = (L1 * v1) * (L1 * v1)
        let v2sq = (L1 * v1) * (L1 * v1) + (L2 * v2) * (L2 * v2)
            + 2 * L1 * L2 * v1 * v2 * cos(a1 - a2)
        return 0.5 * m1 * v1sq + 0.5 * m2 * v2sq
    }

    @inline(__always)
    static func energy(_ a1: Float, _ a2: Float, _ v1: Float, _ v2: Float,
                       _ m1: Float, _ m2: Float, _ L1: Float, _ L2: Float, _ g: Float) -> Float {
        let pe = g * (m1 * (-L1 * cos(a1)) + m2 * (-L1 * cos(a1) - L2 * cos(a2)))
        return kinetic(a1, a2, v1, v2, m1, m2, L1, L2) + pe
    }
}
