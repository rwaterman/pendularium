import Foundation

/// Collects the run's measurements while it plays and writes them as JSON: the numbers behind
/// the three color modes (speed histogram, phase sync, probe divergence), a Lyapunov estimate
/// from the probe twins, and the seed + seeding field so the run can be reproduced.
final class RunReport {
    struct Sample: Codable {
        let t: Float                       // simulated seconds
        let pendulums: Int
        let sync: Float                    // Kuramoto order parameter of θ2
        let meanLogSeparation: Float?      // probe twins, ln(radians)
    }

    struct Document: Codable {
        let seed: UInt64
        let mode: String
        let colorMode: String
        let simSeconds: Float
        let pendulums: Int
        let segments: Int
        let field: Simulation.Field
        let speedHistogram: [Int]          // 16 bins over normalized speed [0, 1]
        let sync: Float
        let probePairs: Int
        let probePerturbation: Float
        let lyapunovPerSecond: Float?      // slope of meanLogSeparation before it saturates
        let samples: [Sample]
    }

    static let sampleEveryFrames = 30
    private(set) var samples: [Sample] = []

    func reset() { samples.removeAll() }

    func sample(_ sim: Simulation, frame: Int) {
        samples.append(Sample(t: Float(frame) / 60, pendulums: sim.active, sync: sim.syncOrder(),
                              meanLogSeparation: sim.meanLogProbeSeparation()))
    }

    func document(sim: Simulation, config: Config, seed: UInt64, frame: Int, segments: Int,
                  twoD: Bool, colorMode: ColorMode) -> Document {
        Document(seed: seed, mode: twoD ? "2D" : "3D", colorMode: colorMode.label,
                 simSeconds: Float(frame) / 60, pendulums: sim.active, segments: segments,
                 field: sim.field, speedHistogram: sim.speedHistogram(bins: 16), sync: sim.syncOrder(),
                 probePairs: config.probePairs, probePerturbation: config.probePerturbation,
                 lyapunovPerSecond: RunReport.lyapunov(samples), samples: samples)
    }

    /// Least-squares slope of mean log separation vs time over the pre-saturation samples
    /// (separation under ~0.5 rad). Needs at least three such samples.
    static func lyapunov(_ samples: [Sample]) -> Float? {
        let pts = samples.compactMap { s -> (Float, Float)? in
            guard let v = s.meanLogSeparation, v < log(0.5) else { return nil }
            return (s.t, v)
        }
        guard pts.count >= 3 else { return nil }
        let n = Float(pts.count)
        let mx = pts.reduce(0) { $0 + $1.0 } / n
        let my = pts.reduce(0) { $0 + $1.1 } / n
        var sxy: Float = 0, sxx: Float = 0
        for (x, y) in pts { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx) }
        return sxx > 0 ? sxy / sxx : nil
    }

    static func write(_ doc: Document, to url: URL) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(doc) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
