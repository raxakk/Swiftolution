import Foundation
import Combine

final class SimulationEngine: ObservableObject {

    // MARK: - Öffentliche Properties

    @Published var stats              = SimulationStats()
    @Published var config             = SimulationConfig() { didSet { syncConfigToWorld() } }
    @Published var inspectedCreature: CreatureSnapshot?
    let scene   = GameScene()
    let tracker = StatisticsTracker()

    private var selectedCreatureID: UUID?

    // MARK: - Private Properties

    private var world  = World(size: CGSize(width: 2400, height: 1800))
    private var timer: AnyCancellable?
    private(set) var isPaused = false
    private var speedMultiplier: Double = 1.0

    // MARK: - Lifecycle

    init() {
        syncConfigToWorld()
        world.populate(creatures: config.initialCreatures, food: config.initialFood)
        scene.setup(world: world)
        scene.onCreatureSelected = { [weak self] id in self?.selectCreature(id: id) }
        startTimer()
    }

    // MARK: - Steuerung

    func togglePause() {
        isPaused.toggle()
    }

    func restart() {
        timer?.cancel()
        world = World(size: CGSize(width: config.worldWidth, height: config.worldHeight))
        syncConfigToWorld()
        world.populate(creatures: config.initialCreatures, food: config.initialFood)
        scene.reset(world: world)
        stats = SimulationStats()
        tracker.reset()
        selectCreature(id: nil)
        startTimer()
    }

    func selectCreature(id: UUID?) {
        selectedCreatureID       = id
        scene.selectedCreatureID = id
        if let id, let creature = world.creatures.first(where: { $0.id == id }) {
            inspectedCreature = CreatureSnapshot(creature)
        } else {
            inspectedCreature = nil
        }
    }

    func setSpeed(_ multiplier: Double) {
        speedMultiplier = multiplier
        timer?.cancel()
        startTimer()
    }

    // MARK: - Config → World synchronisieren

    private func syncConfigToWorld() {
        // Nahrung und Population skalieren mit der Wurzel der Weltfläche relativ zur Referenzgröße (800×600).
        // Wurzel statt linearer Skala: doppelte Fläche → ~1.4× mehr Kapazität (nicht 2×).
        let area      = Double(world.size.width * world.size.height)
        let refArea   = 800.0 * 600.0
        let scale     = sqrt(area / refArea)
        world.maxFood         = Int(Double(config.foodCapacity) * scale)
        world.maxPopulation   = Int(300.0 * scale)
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
        tracker.update(world: world)
    }

    private func updateStats() {
        let creatures       = world.creatures
        stats.generation    = world.generation
        stats.population    = creatures.count
        stats.herbivores    = creatures.filter { $0.dna.aggression <= 0.45 }.count
        stats.carnivores    = creatures.filter { $0.dna.aggression  > 0.45 }.count
        stats.totalBirths   = world.totalBirths
        stats.foodCount     = world.foodSources.filter { $0.type == .plant }.count
        stats.oldestAge     = creatures.map { $0.age }.max() ?? 0
        let energies        = creatures.map { Double($0.energy / $0.maxEnergy) }
        stats.averageEnergy = energies.isEmpty ? 0 : energies.reduce(0, +) / Double(energies.count)

        if let id = selectedCreatureID,
           let creature = creatures.first(where: { $0.id == id }) {
            inspectedCreature = CreatureSnapshot(creature)
        } else if selectedCreatureID != nil {
            selectCreature(id: nil)   // Kreatur gestorben
        }
    }
}

// MARK: - Konfiguration

struct SimulationConfig {
    // Sofort wirksam (live)
    var foodCapacity:     Int    = 250
    var foodGrowthRate:   Double = 0.03
    var mutationRate:     Float  = 0.05
    var mutationStrength: Float  = 0.10

    // Erst beim Neustart wirksam
    var worldWidth:       Int = 2400
    var worldHeight:      Int = 1800
    var initialCreatures: Int = 80
    var initialFood:      Int = 250
}

// MARK: - Kreatur-Snapshot (für Inspektion)

struct CreatureSnapshot {
    let age:                  Int
    let maxAge:               Int
    let energyRatio:          Float
    let isHerbivore:          Bool
    // DNA
    let size:                 Float
    let speed:                Float
    let aggression:           Float
    let sightRadius:          Float
    let reproThreshold:       Float
    let habitatPreference:    Float
    let brainSize:            Float
    let hiddenCount:          Int
    // Aktuelles NN-Verhalten
    let actionSpeed:          Float
    let actionReproduce:      Float
    let actionAttack:         Float

    init(_ c: Creature) {
        age            = c.age
        maxAge         = c.dna.maxAge
        energyRatio    = max(0, min(c.energy / c.maxEnergy, 1))
        isHerbivore    = c.dna.aggression <= 0.45
        size           = c.dna.size
        speed          = c.dna.speed
        aggression     = c.dna.aggression
        sightRadius    = c.dna.sightRadius
        reproThreshold    = c.dna.reproductionThreshold
        habitatPreference = c.dna.habitatPreference
        brainSize         = c.dna.brainSize
        hiddenCount    = c.hiddenCount
        actionSpeed    = c.lastAction?.speed          ?? 0
        actionReproduce = c.lastAction?.wantsToReproduce ?? 0
        actionAttack   = c.lastAction?.wantsToAttack  ?? 0
    }
}

// MARK: - Statistiken

struct SimulationStats {
    var generation:    Int    = 0
    var population:    Int    = 0
    var herbivores:    Int    = 0
    var carnivores:    Int    = 0
    var totalBirths:   Int    = 0
    var foodCount:     Int    = 0
    var oldestAge:     Int    = 0
    var averageEnergy: Double = 0
}
