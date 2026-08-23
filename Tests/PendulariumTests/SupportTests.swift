import Testing
import simd
@testable import Pendularium

@Suite("Vertex packing")
struct PackingTests {
    @Test("Scalars land in their bytes, clamped to [0, 1]")
    func packs() {
        #expect(packAttribs(speed: 1, hue: 0, angle: 0, alpha: 0) == 255)
        #expect(packAttribs(speed: 0, hue: 1, angle: 0, alpha: 0) == 255 << 8)
        #expect(packAttribs(speed: 0, hue: 0, angle: 1, alpha: 0) == 255 << 16)
        #expect(packAttribs(speed: 0, hue: 0, angle: 0, alpha: 1) == 255 << 24)
        #expect(packAttribs(speed: 7, hue: -3, angle: 0, alpha: 0) == 255)
    }

    @Test("Vertex stride matches the Metal layout (packed_float3 + uint)")
    func stride() {
        #expect(MemoryLayout<TrailVertex>.stride == 16)
    }
}

@Suite("Random")
struct RandomTests {
    @Test("SplitMix64 is deterministic and float01 stays in [0, 1)")
    func splitMix() {
        var a = SplitMix64(seed: 123), b = SplitMix64(seed: 123)
        for _ in 0..<100 {
            let x = a.float01()
            #expect(x == b.float01())
            #expect(x >= 0 && x < 1)
        }
    }

    @Test("Per-index seeds are stable and distinct")
    func pendulumSeeds() {
        #expect(pendulumSeed(base: 5, index: 10) == pendulumSeed(base: 5, index: 10))
        #expect(pendulumSeed(base: 5, index: 10) != pendulumSeed(base: 5, index: 11))
        #expect(pendulumSeed(base: 5, index: 10) != pendulumSeed(base: 6, index: 10))
    }
}

@Suite("Matrix")
struct MatrixTests {
    private func approx(_ a: Float, _ b: Float, _ tol: Float = 1e-4) -> Bool { abs(a - b) <= tol }

    @Test("Perspective keeps the axis point centered and clips z to [0, 1]")
    func perspective() {
        let p = makePerspective(fovYRadians: .pi / 3, aspect: 1.6, near: 0.5, far: 100)
        let c = p * SIMD4<Float>(0, 0, -5, 1)
        #expect(approx(c.x / c.w, 0) && approx(c.y / c.w, 0))
        let n = p * SIMD4<Float>(0, 0, -0.5, 1)
        let f = p * SIMD4<Float>(0, 0, -100, 1)
        #expect(approx(n.z / n.w, 0) && approx(f.z / f.w, 1))
    }

    @Test("Orthographic maps the half extents to the clip edges")
    func orthographic() {
        let o = makeOrthographic(halfWidth: 20, halfHeight: 10, near: 0.5, far: 100)
        let e = o * SIMD4<Float>(20, 10, -1, 1)
        #expect(approx(e.x, 1) && approx(e.y, 1))
    }

    @Test("Look-at puts the center straight down -z")
    func lookAt() {
        let v = makeLookAt(eye: SIMD3(3, 4, 5), center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let c = v * SIMD4<Float>(0, 0, 0, 1)
        #expect(approx(c.x, 0) && approx(c.y, 0))
        #expect(approx(c.z, -simd_length(SIMD3<Float>(3, 4, 5))))
    }
}

@Suite("Camera")
struct CameraTests {
    @Test("Zoom is clamped in both modes")
    func zoomClamps() {
        var cam = Camera(radius: 130, orthoHalfHeight: 42)
        for _ in 0..<200 { cam.zoom(10) }
        #expect(cam.radius == 15)
        cam.configure(twoD: true, defaultRadius: 130, defaultOrtho: 42)
        for _ in 0..<200 { cam.zoom(-10) }
        #expect(cam.orthoHalfHeight == 400)
    }

    @Test("Auto-orbit only runs in 3D")
    func orbit() {
        var cam = Camera(radius: 130, orthoHalfHeight: 42)
        let start = cam.azimuth
        cam.advance(dt: 1, rate: 0.5)
        #expect(cam.azimuth == start + 0.5)
        cam.configure(twoD: true, defaultRadius: 130, defaultOrtho: 42)
        let flat = cam.azimuth
        cam.advance(dt: 1, rate: 0.5)
        #expect(cam.azimuth == flat)
    }
}
