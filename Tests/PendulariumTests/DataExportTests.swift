import Foundation
import Testing
@testable import Pendularium

@Suite("Data export")
struct DataExportTests {
    private func makeSim(count: Int) -> Simulation {
        var config = Config()
        config.maxPendulums = 64
        let sim = Simulation(config: config, seed: 11)
        sim.spawn(upTo: count, frame: 7)
        return sim
    }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pendularium-export-\(UUID())")
    }

    @Test("Records carry spawn frame and twin links")
    func records() {
        let sim = makeSim(count: 8)
        #expect(sim.pendulumRecord(5).spawnFrame == 7)
        #expect(sim.pendulumRecord(1).twinOf == 0)
        #expect(sim.pendulumRecord(2).twinOf == nil)
        #expect(sim.pendulumRecord(1).pivot == sim.pendulumRecord(0).pivot)
        #expect(sim.stateRecord(3).tip == sim.tip(3))
    }

    @Test("CSV export writes both tables with one fact row per pendulum per sampled frame")
    func csv() throws {
        let sim = makeSim(count: 10)
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let export = try #require(DataExport(sink: .csv(directory: dir), every: 2))
        for frame in 0..<6 { export.sample(sim, frame: frame); sim.step() }
        #expect(export.finish(sim))

        let samples = try String(contentsOf: dir.appendingPathComponent("samples.csv"), encoding: .utf8)
            .split(separator: "\n")
        #expect(samples[0] == DataExport.sampleColumns.joined(separator: ","))
        #expect(samples.count == 1 + 3 * 10)
        #expect(samples[1].hasPrefix("0.0,0,0,"))
        #expect(samples[11].hasPrefix("0.033333335,2,0,"))

        let pendulums = try String(contentsOf: dir.appendingPathComponent("pendulums.csv"), encoding: .utf8)
            .split(separator: "\n")
        #expect(pendulums.count == 1 + 10)
        #expect(pendulums[1].hasSuffix(","))       // id 0: no twin
        #expect(pendulums[2].hasSuffix(",0"))      // id 1 is the twin of 0
    }

    @Test("JSONL stream announces pendulums before their samples")
    func jsonl() throws {
        let sim = makeSim(count: 4)
        let url = tempDir().appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        let export = try #require(DataExport(sink: .jsonl(handle), every: 1))
        export.sample(sim, frame: 0)
        sim.spawn(upTo: 6, frame: 1)
        export.sample(sim, frame: 1)
        try handle.close()

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 4 + 4 + 2 + 6)
        let kinds = try lines.map { line -> String in
            let obj = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try #require(obj["kind"] as? String)
        }
        #expect(kinds.prefix(4).allSatisfy { $0 == "pendulum" })
        #expect(kinds[4..<8].allSatisfy { $0 == "sample" })
        #expect(kinds[8..<10].allSatisfy { $0 == "pendulum" })
        let twin = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        #expect(twin["twin_of"] as? Int == 0)
    }
}
