import Foundation
import Combine

final class SimulationEngine: ObservableObject {

    // MARK: - Öffentliche Properties

    @Published var stats  = SimulationStats()
    @Published var config = SimulationConfig() {
        didSet { syncConfigToWorld() }
    }
    let scene = GameScene()

    // MARK: - Private Properties

    private var world  = World()
    private var timer: AnyCancellable?
    private(set) var isPaused = false
    private var speedMultiplier: Double = 1.0

    // MARK: - Lifecycle

    init() {
        syncConfigToWorld()
        world.populate(creatures: config.initialCreatures, food: config.initialFood)
        scene.setup(world: world)
        startTimer()
    }

    // MARK: - Steuerung

    func togglePause() {
        isPaused.toggle()
    }

    func restart() {
        timer?.cancel()
        world = World()
        syncConfigToWorld()
        world.populate(creatures: config.initialCreatures, food: config.initialFood)
        scene.reset(world: world)
        stats = SimulationStats()
        startTimer()
    }

    func setSpeed(_ multiplier: Double) {
        speedMultiplier = multiplier
        timer?.cancel()
        startTimer()
    }

    // MARK: - Config → World synchronisieren

    private func syncConfigToWorld() {
        world.maxFood         = config.foodCapacity
        world.foodGrowthRate  = config.foodGrowthRate
        world.mutationRate    = config.mutationRate
        world.mutationStrength = config.mutationStrength
    }

    // MARK: - Loop

    private func startTimer() {
        let interval = 1.0 / (30.0 * speedMultiplier)
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard !isPaused else { return }
        world.tick()
        scene.update(world: world)
        updateStats()
    }

    private func updateStats() {
        stats.generation    = world.generation
        stats.population    = world.creatures.count
        stats.totalBirths   = world.totalBirths
        stats.foodCount     = world.foodSources.count
        stats.oldestAge     = world.creatures.map { $0.age }.max() ?? 0
        let energies        = world.creatures.map { Double($0.energy / $0.maxEnergy) }
        stats.averageEnergy = energies.isEmpty ? 0 : energies.reduce(0, +) / Double(energies.count)
    }
}

// MARK: - Konfiguration

struct SimulationConfig {
    // Sofort wirksam (live)
    var foodCapacity:     Int    = 250    // maximale Nahrungsmenge in der Welt
    var foodGrowthRate:   Double = 0.03   // logistische Wachstumsrate pro Tick
    var mutationRate:     Float  = 0.05   // Wahrscheinlichkeit einer Gen-Mutation
    var mutationStrength: Float  = 0.10   // maximale Stärke einer Mutation

    // Erst beim Neustart wirksam
    var initialCreatures: Int = 50
    var initialFood:      Int = 150
}

// MARK: - Statistiken

struct SimulationStats {
    var generation:    Int    = 0
    var population:    Int    = 0
    var totalBirths:   Int    = 0
    var foodCount:     Int    = 0
    var oldestAge:     Int    = 0
    var averageEnergy: Double = 0
}
