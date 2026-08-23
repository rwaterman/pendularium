import Testing
import simd
@testable import Pendularium

@Suite("Simulation")
struct SimulationTests {
    private func makeSim(seed: UInt64, twoD: Bool = false, count: Int = 64) -> Simulation {
        var config = Config()
        config.maxPendulums = 256
        let sim = Simulation(config: config, seed: seed)
        sim.reset(twoD: twoD)
        sim.spawn(upTo: count)
        return sim
    }

    @Test("Same seed reproduces the same trajectories")
    func deterministic() {
        let a = makeSim(seed: 42), b = makeSim(seed: 42)
        for _ in 0..<120 { a.step(); b.step() }
        for i in 0..<a.active { #expect(a.tip(i) == b.tip(i)) }
    }

    @Test("Different seeds diverge")
    func seedsDiffer() {
        let a = makeSim(seed: 1), b = makeSim(seed: 2)
        #expect(a.tip(0) != b.tip(0))
    }

    @Test("Energy renormalization holds total energy over a long run")
    func energyConserved() {
        let sim = makeSim(seed: 7)
        for _ in 0..<600 { sim.step() }
        for i in 0..<sim.active { #expect(sim.energyDrift(i) < 1e-2, "pendulum \(i)") }
    }

    @Test("Tips move once stepped")
    func tipsMove() {
        let sim = makeSim(seed: 3, count: 8)
        let before = (0..<8).map { sim.tip($0) }
        for _ in 0..<60 { sim.step() }
        for i in 0..<8 { #expect(simd_distance(before[i], sim.tip(i)) > 1e-3) }
    }

    @Test("2D mode flattens every pivot onto z = 0")
    func twoDIsFlat() {
        let sim = makeSim(seed: 9, twoD: true)
        sim.step()
        for i in 0..<sim.active { #expect(sim.tip(i).z == 0) }
    }

    @Test("Spawning is capped at capacity")
    func spawnCapped() {
        let sim = makeSim(seed: 1, count: 10_000)
        #expect(sim.active == 256)
    }

    @Test("Hanging at rest stays at rest; a displaced arm is pulled back")
    func physics() {
        let (r1, r2) = Simulation.accel(0, 0, 0, 0, 1, 1, 1, 1, 9.81)
        #expect(abs(r1) < 1e-6 && abs(r2) < 1e-6)
        let (d1, _) = Simulation.accel(0.1, 0, 0, 0, 1, 1, 1, 1, 9.81)
        #expect(d1 < 0)
    }
}
