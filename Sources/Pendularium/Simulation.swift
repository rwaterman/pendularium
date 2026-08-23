import Foundation
import simd

/// Field of planar chaotic double pendulums. State is stored as raw parallel arrays (SoA)
/// so the per-pendulum integration can run lock-free across CPU cores via `concurrentPerform`.
/// Each pendulum swings in a plane parallel to world XY; its pivot's Z places it in a depth layer.
final class Simulation {
    /// Per-run smooth field that seeds initial conditions coherently: neighboring pendulums start
    /// from nearly the same angle, so the field begins ordered and chaos shatters it over time.
    struct Field: Codable {
        var k1: SIMD3<Float>; var phi1: Float   // spatial frequency + phase for θ1
        var k2: SIMD3<Float>; var phi2: Float   // …for θ2
        var amp: Float                          // angle amplitude
        var kh: SIMD3<Float>; var phih: Float   // …for identity hue
        var noise: Float                        // per-pendulum jitter on top of the field
    }

    let capacity: Int
    private let config: Config
    private let baseSeed: UInt64
    let field: Field

    private(set) var active: Int = 0
    /// 2D mode flattens every pendulum into the z=0 plane.
    private(set) var twoD: Bool = false

    // State
    private let t1, t2, w1, w2: UnsafeMutablePointer<Float>
    private let t1_0, t2_0: UnsafeMutablePointer<Float>   // angles at spawn (probe twins)
    private let spawnFrame: UnsafeMutablePointer<Int32>
    // Parameters
    private let l1, l2, m1, m2: UnsafeMutablePointer<Float>
    private let pivX, pivY, pivZ: UnsafeMutablePointer<Float>
    private let e0: UnsafeMutablePointer<Float>
    // Derived (updated each step)
    private let b1X, b1Y: UnsafeMutablePointer<Float>       // world bob-1 (z = pivZ)
    private let b2X, b2Y: UnsafeMutablePointer<Float>       // world bob-2 / tip
    private let prevB2X, prevB2Y: UnsafeMutablePointer<Float> // last appended tip
    private let speed: UnsafeMutablePointer<Float>          // |v| of bob-2 (normalized)
    private let hue: UnsafeMutablePointer<Float>            // per-pendulum random hue [0,1)

    init(config: Config, seed: UInt64) {
        self.config = config
        self.capacity = config.maxPendulums
        self.baseSeed = seed

        var fr = SplitMix64(seed: seed ^ 0x5EED_F1E1_D000_0001)
        func freq() -> SIMD3<Float> {
            SIMD3(fr.float(-0.12, 0.12), fr.float(-0.12, 0.12), fr.float(-0.12, 0.12))
        }
        self.field = Field(k1: freq(), phi1: fr.float(0, 2 * .pi),
                           k2: freq(), phi2: fr.float(0, 2 * .pi),
                           amp: .pi,
                           kh: freq() * 1.4, phih: fr.float(0, 1),
                           noise: 0.06)

        let cap = config.maxPendulums
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: cap)
            p.initialize(repeating: 0, count: cap)
            return p
        }
        t1 = alloc(); t2 = alloc(); w1 = alloc(); w2 = alloc()
        t1_0 = alloc(); t2_0 = alloc()
        spawnFrame = UnsafeMutablePointer<Int32>.allocate(capacity: cap)
        spawnFrame.initialize(repeating: 0, count: cap)
        l1 = alloc(); l2 = alloc(); m1 = alloc(); m2 = alloc()
        pivX = alloc(); pivY = alloc(); pivZ = alloc(); e0 = alloc()
        b1X = alloc(); b1Y = alloc(); b2X = alloc(); b2Y = alloc()
        prevB2X = alloc(); prevB2Y = alloc(); speed = alloc(); hue = alloc()
    }

    deinit {
        for p in [t1, t2, w1, w2, t1_0, t2_0, l1, l2, m1, m2, pivX, pivY, pivZ, e0,
                  b1X, b1Y, b2X, b2Y, prevB2X, prevB2Y, speed, hue] {
            p.deallocate()
        }
        spawnFrame.deallocate()
    }

    /// Clear the field and switch dimension. Pendulums re-initialize deterministically (same
    /// per-index seeds) on the next `spawn`, laid out for the chosen mode.
    func reset(twoD: Bool) {
        active = 0
        self.twoD = twoD
    }

    /// Activate pendulums up to `target`, deterministically from the seed + index.
    func spawn(upTo target: Int, frame: Int = 0) {
        let limit = min(target, capacity)
        guard limit > active else { return }
        let g = config.gravity
        for i in active..<limit {
            var r = SplitMix64(seed: pendulumSeed(base: baseSeed, index: i))
            var len1 = config.armBase * (1 + r.float(-config.armJitter, config.armJitter))
            var len2 = config.armBase * (1 + r.float(-config.armJitter, config.armJitter))
            var mass1 = 1 + r.float(-config.massJitter, config.massJitter)
            var mass2 = 1 + r.float(-config.massJitter, config.massJitter)
            // Difference of two uniforms → triangular distribution: dense core, soft edges,
            // so the field reads as an organic cloud rather than a hard-edged box.
            let px = (r.float01() - r.float01()) * config.spreadX
            let py = (r.float01() - r.float01()) * config.spreadY
            var pz = twoD ? 0 : (r.float01() - r.float01()) * config.spreadZ
            var p = SIMD3<Float>(px, py, pz)

            // Coherent seeding: initial angles are a smooth function of position + tiny noise, so
            // neighbors start nearly identical and chaos amplifies the differences over time.
            var a1 = field.amp * sin(simd_dot(field.k1, p) + field.phi1) + r.float(-field.noise, field.noise)
            var a2 = field.amp * sin(simd_dot(field.k2, p) + field.phi2) + r.float(-field.noise, field.noise)

            // Probe pairs: the first `probePairs` odd indices are twins of the even index before
            // them, identical except for a tiny angle perturbation. Their separation over time is
            // the Lyapunov measurement in the run report; they are too few to show in the image.
            if i % 2 == 1, i / 2 < config.probePairs {
                let twin = i - 1
                p = SIMD3(pivX[twin], pivY[twin], pivZ[twin])
                pz = p.z
                len1 = l1[twin]; len2 = l2[twin]; mass1 = m1[twin]; mass2 = m2[twin]
                a1 = t1_0[twin] + config.probePerturbation
                a2 = t2_0[twin]
            }
            let hueRaw = simd_dot(field.kh, p) + field.phih
            let hueVal = hueRaw - floor(hueRaw)

            t1[i] = a1; t2[i] = a2; w1[i] = 0; w2[i] = 0
            t1_0[i] = a1; t2_0[i] = a2
            spawnFrame[i] = Int32(frame)
            l1[i] = len1; l2[i] = len2; m1[i] = mass1; m2[i] = mass2
            pivX[i] = p.x; pivY[i] = p.y; pivZ[i] = pz
            hue[i] = hueVal
            e0[i] = Simulation.energy(a1, a2, 0, 0, mass1, mass2, len1, len2, g)

            let bx1 = p.x + len1 * sin(a1)
            let by1 = p.y - len1 * cos(a1)
            let bx2 = bx1 + len2 * sin(a2)
            let by2 = by1 - len2 * cos(a2)
            b1X[i] = bx1; b1Y[i] = by1
            b2X[i] = bx2; b2Y[i] = by2
            prevB2X[i] = bx2; prevB2Y[i] = by2
            speed[i] = 0
        }
        active = limit
    }

    // MARK: - Rows for data export

    /// Index of the pendulum this one is a probe twin of, if any.
    func twinOf(_ i: Int) -> Int? { i % 2 == 1 && i / 2 < config.probePairs ? i - 1 : nil }

    /// Per-pendulum constants (the dimension table).
    func pendulumRecord(_ i: Int) -> PendulumRecord {
        PendulumRecord(id: i, spawnFrame: Int(spawnFrame[i]), pivot: SIMD3(pivX[i], pivY[i], pivZ[i]),
                       l1: l1[i], l2: l2[i], m1: m1[i], m2: m2[i], theta1_0: t1_0[i], theta2_0: t2_0[i],
                       hue: hue[i], energy: e0[i], twinOf: twinOf(i))
    }

    /// Per-pendulum state right now (the fact table).
    func stateRecord(_ i: Int) -> StateRecord {
        StateRecord(id: i, theta1: t1[i], theta2: t2[i], omega1: w1[i], omega2: w2[i],
                    speed: speed[i], tip: SIMD3(b2X[i], b2Y[i], pivZ[i]))
    }

    // MARK: - Measurements (what the three color modes show, as numbers)

    /// Histogram of normalized bob-2 speed over [0, 1] — the distribution the `speed` color mode
    /// paints. Speeds above the scale land in the last bin.
    func speedHistogram(bins: Int) -> [Int] {
        var counts = [Int](repeating: 0, count: bins)
        for i in 0..<active {
            counts[min(bins - 1, Int(max(0, speed[i]) * Float(bins)))] += 1
        }
        return counts
    }

    /// Kuramoto order parameter of the bob-2 swing angles: 1 when every pendulum is in phase,
    /// near 0 when the phases are spread uniformly — the `phase` color mode as one number.
    func syncOrder() -> Float {
        guard active > 0 else { return 0 }
        var c: Float = 0, s: Float = 0
        for i in 0..<active { c += cos(t2[i]); s += sin(t2[i]) }
        return (c * c + s * s).squareRoot() / Float(active)
    }

    /// Mean natural log of the angular separation between each probe pendulum and its twin.
    /// Grows linearly in time at the Lyapunov rate until it saturates — the divergence the
    /// `identity` color mode makes visible. `nil` until the probes exist.
    func meanLogProbeSeparation() -> Float? {
        let pairs = min(config.probePairs, active / 2)
        guard pairs > 0 else { return nil }
        var sum: Float = 0
        for k in 0..<pairs {
            let a = 2 * k, b = a + 1
            let d1 = (t1[a] - t1[b]).remainder(dividingBy: 2 * .pi)
            let d2 = (t2[a] - t2[b]).remainder(dividingBy: 2 * .pi)
            sum += log(max(1e-9, (d1 * d1 + d2 * d2).squareRoot()))
        }
        return sum / Float(pairs)
    }

    /// World position of pendulum `i`'s tip (bob 2).
    func tip(_ i: Int) -> SIMD3<Float> { SIMD3(b2X[i], b2Y[i], pivZ[i]) }

    /// Relative drift of pendulum `i`'s total energy from its initial energy. Energy
    /// renormalization in `step` keeps this near zero for arbitrarily long runs.
    func energyDrift(_ i: Int) -> Float {
        let e = Simulation.energy(t1[i], t2[i], w1[i], w2[i], m1[i], m2[i], l1[i], l2[i], config.gravity)
        return abs(e - e0[i]) / max(1e-3, abs(e0[i]))
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
        let inv2pi = Float(1.0 / (2.0 * Double.pi))
        for i in 0..<n {
            let z = pivZ[i]
            let s = speed[i]
            let h = hue[i]
            let angRaw = t2[i] * inv2pi
            let ang = angRaw - floor(angRaw)   // swing angle wrapped to [0,1)
            let p2 = SIMD3<Float>(b2X[i], b2Y[i], z)

            if allowTrailGrowth {
                let a = packAttribs(speed: s, hue: h, angle: ang, alpha: trailAlpha)
                trails.appendSegment(SIMD3<Float>(prevB2X[i], prevB2Y[i], z), p2, attribs: a)
            }
            prevB2X[i] = p2.x; prevB2Y[i] = p2.y

            let aa = packAttribs(speed: s, hue: h, angle: ang, alpha: armAlpha)
            let piv = SIMD3<Float>(pivX[i], pivY[i], z)
            let b1 = SIMD3<Float>(b1X[i], b1Y[i], z)
            let base = i * 4
            arms[base + 0] = TrailVertex(piv, attribs: aa)
            arms[base + 1] = TrailVertex(b1, attribs: aa)
            arms[base + 2] = TrailVertex(b1, attribs: aa)
            arms[base + 3] = TrailVertex(p2, attribs: aa)
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
