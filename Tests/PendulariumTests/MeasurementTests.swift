import Foundation
import Testing
import simd
@testable import Pendularium

@Suite("Measurements")
struct MeasurementTests {
    private func makeSim(seed: UInt64, count: Int = 256) -> Simulation {
        var config = Config()
        config.maxPendulums = 256
        let sim = Simulation(config: config, seed: seed)
        sim.spawn(upTo: count)
        return sim
    }

    @Test("Probe twins start a perturbation apart and diverge exponentially")
    func probesDiverge() {
        let sim = makeSim(seed: 42)
        let start = sim.meanLogProbeSeparation()!
        #expect(abs(start - log(1e-4)) < 0.05)
        #expect(simd_distance(sim.tip(0), sim.tip(1)) < 1e-3)
        for _ in 0..<180 { sim.step() }
        let later = sim.meanLogProbeSeparation()!
        #expect(later > start + 1)
    }

    @Test("Sync order is a normalized magnitude and the histogram counts every pendulum")
    func syncAndHistogram() {
        let sim = makeSim(seed: 5)
        for _ in 0..<30 { sim.step() }
        let r = sim.syncOrder()
        #expect(r >= 0 && r <= 1)
        #expect(sim.speedHistogram(bins: 16).reduce(0, +) == sim.active)
        #expect(sim.speedHistogram(bins: 4).count == 4)
    }

    @Test("Lyapunov fit recovers the slope of pre-saturation samples")
    func lyapunovFit() {
        let samples = (0..<8).map {
            RunReport.Sample(t: Float($0) * 0.5, pendulums: 1, sync: 0, meanLogSeparation: -9 + 2 * Float($0) * 0.5)
        }
        #expect(abs(RunReport.lyapunov(samples)! - 2) < 1e-4)
        #expect(RunReport.lyapunov(Array(samples.prefix(2))) == nil)
        let saturated = samples.map { RunReport.Sample(t: $0.t, pendulums: 1, sync: 0, meanLogSeparation: 1) }
        #expect(RunReport.lyapunov(saturated) == nil)
    }

    @Test("Report round-trips through JSON")
    func reportJSON() throws {
        let sim = makeSim(seed: 9)
        let report = RunReport()
        report.sample(sim, frame: 0)
        let doc = report.document(sim: sim, config: Config(), seed: 9, frame: 0, segments: 0, twoD: false, colorMode: .phase)
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(RunReport.Document.self, from: data)
        #expect(back.seed == 9 && back.colorMode == "phase" && back.samples.count == 1)
        #expect(back.field.amp == sim.field.amp)
    }
}

@Suite("Export")
struct ExportTests {
    private func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 0.02 }

    @Test("Color ramps match the shader endpoints")
    func colors() {
        #expect(near(ModeColor.coolHot(0), SIMD3(0.10, 0.12, 0.48)))
        #expect(near(ModeColor.coolHot(1), SIMD3(1.00, 0.22, 0.16)))
        #expect(near(ModeColor.coolHot(2), SIMD3(1.00, 0.22, 0.16)))
        #expect(near(ModeColor.hsv(0, 1, 1), SIMD3(1, 0, 0)))
        #expect(near(ModeColor.hsv(1.0 / 3.0, 1, 1), SIMD3(0, 1, 0)))
        #expect(near(ModeColor.rgb(attribs: packAttribs(speed: 1, hue: 0, angle: 0, alpha: 1), mode: .speed),
                     ModeColor.coolHot(1)))
    }

    @Test("PLY has a correct header, size, and little-endian payload")
    func ply() throws {
        let verts = [
            TrailVertex(SIMD3(1, 2, 3), attribs: packAttribs(speed: 0, hue: 0, angle: 0, alpha: 1)),
            TrailVertex(SIMD3(4, 5, 6), attribs: packAttribs(speed: 0, hue: 0, angle: 0, alpha: 1)),
            TrailVertex(SIMD3(7, 8, 9), attribs: packAttribs(speed: 1, hue: 0, angle: 0, alpha: 1)),
            TrailVertex(SIMD3(1, 1, 1), attribs: packAttribs(speed: 1, hue: 0, angle: 0, alpha: 1)),
        ]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pendularium-test-\(UUID()).ply")
        defer { try? FileManager.default.removeItem(at: url) }
        let ok = verts.withUnsafeBufferPointer { PLYExport.write(vertices: $0.baseAddress!, count: 4, mode: .speed, to: url) }
        #expect(ok)
        let data = try Data(contentsOf: url)
        let header = Data(PLYExport.header(vertexCount: 4, mode: .speed).utf8)
        #expect(data.prefix(header.count) == header)
        #expect(data.count == header.count + 4 * PLYExport.vertexBytes + 2 * PLYExport.edgeBytes)
        let x = data[header.count..<header.count + 4].withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        #expect(x == 1)
        let lastEdge = data.suffix(4).withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) }
        #expect(lastEdge == 3)
    }
}
