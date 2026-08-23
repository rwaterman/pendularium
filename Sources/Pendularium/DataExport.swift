import Foundation

/// The run as tables: a `pendulums` dimension (one row per pendulum, fixed at spawn) and a
/// `samples` fact (one row per pendulum per sampled frame). Written as CSV files, or streamed
/// as JSON lines on stdout for a pipeline to pick up. The rows are what the run report's
/// metrics are computed from, so the same numbers can be reproduced in SQL.
final class DataExport {
    enum Sink {
        case csv(directory: URL)
        case jsonl(FileHandle)
    }

    static let pendulumColumns = ["id", "spawn_frame", "pivot_x", "pivot_y", "pivot_z", "l1", "l2", "m1", "m2",
                                  "theta1_0", "theta2_0", "hue", "energy", "twin_of"]
    static let sampleColumns = ["t", "frame", "id", "theta1", "theta2", "omega1", "omega2", "speed", "x", "y", "z"]

    let every: Int
    private let sink: Sink
    private var samples: FileHandle?
    private var emittedPendulums = 0
    private(set) var rowsWritten = 0

    init?(sink: Sink, every: Int) {
        self.sink = sink
        self.every = max(1, every)
        if case .csv(let dir) = sink {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("samples.csv")
                try Data((DataExport.sampleColumns.joined(separator: ",") + "\n").utf8).write(to: url)
                samples = try FileHandle(forWritingTo: url)
                samples?.seekToEndOfFile()
            } catch {
                log("[pendularium] export FAILED: \(error)")
                return nil
            }
        }
    }

    /// Called every simulated frame; emits a row per active pendulum every `every` frames.
    /// New pendulums are announced first on the stream so facts never precede their dimension.
    func sample(_ sim: Simulation, frame: Int) {
        guard frame % every == 0, sim.active > 0 else { return }
        var out = ""
        out.reserveCapacity(sim.active * 96)
        if case .jsonl = sink, sim.active > emittedPendulums {
            for i in emittedPendulums..<sim.active { out += jsonLine(kind: "pendulum", DataExport.pendulumValues(sim.pendulumRecord(i))) }
            emittedPendulums = sim.active
        }
        let t = Float(frame) / 60
        for i in 0..<sim.active {
            let values = DataExport.sampleValues(sim.stateRecord(i), t: t, frame: frame)
            switch sink {
            case .csv: out += values.joined(separator: ","); out += "\n"
            case .jsonl: out += jsonLine(kind: "sample", values)
            }
        }
        rowsWritten += sim.active
        write(out)
    }

    /// Write the dimension table (CSV) and close files.
    func finish(_ sim: Simulation) -> Bool {
        switch sink {
        case .csv(let dir):
            var out = DataExport.pendulumColumns.joined(separator: ",") + "\n"
            for i in 0..<sim.active { out += DataExport.pendulumValues(sim.pendulumRecord(i)).joined(separator: ",") + "\n" }
            let url = dir.appendingPathComponent("pendulums.csv")
            try? samples?.close()
            do { try Data(out.utf8).write(to: url) } catch { log("[pendularium] export FAILED: \(error)"); return false }
            log("[pendularium] export saved: \(dir.path) (pendulums=\(sim.active), sample rows=\(rowsWritten))")
        case .jsonl:
            sample(sim, frame: 0)   // flush any pendulums spawned since the last sample
        }
        return true
    }

    static func pendulumValues(_ r: PendulumRecord) -> [String] {
        [String(r.id), String(r.spawnFrame), f(r.pivot.x), f(r.pivot.y), f(r.pivot.z), f(r.l1), f(r.l2), f(r.m1), f(r.m2),
         f(r.theta1_0), f(r.theta2_0), f(r.hue), f(r.energy), r.twinOf.map(String.init) ?? ""]
    }

    static func sampleValues(_ r: StateRecord, t: Float, frame: Int) -> [String] {
        [f(t), String(frame), String(r.id), f(r.theta1), f(r.theta2), f(r.omega1), f(r.omega2), f(r.speed),
         f(r.tip.x), f(r.tip.y), f(r.tip.z)]
    }

    private static func f(_ v: Float) -> String { v.isFinite ? "\(v)" : "" }

    private func jsonLine(kind: String, _ values: [String]) -> String {
        let columns = kind == "pendulum" ? DataExport.pendulumColumns : DataExport.sampleColumns
        var fields = ["\"kind\":\"\(kind)\""]
        for (name, value) in zip(columns, values) { fields.append("\"\(name)\":\(value.isEmpty ? "null" : value)") }
        return "{" + fields.joined(separator: ",") + "}\n"
    }

    private func write(_ text: String) {
        switch sink {
        case .csv: samples?.write(Data(text.utf8))
        case .jsonl(let handle): handle.write(Data(text.utf8))
        }
    }
}
