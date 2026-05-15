import Foundation
import Combine
import CoreGraphics

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
    private var tickAccumulator: Double = 0

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
        tickAccumulator = 0
    }

    // MARK: - Config → World synchronisieren

    private func syncConfigToWorld() {
        // Nahrung und Population skalieren mit der Wurzel der Weltfläche relativ zur Referenzgröße (800×600).
        // Wurzel statt linearer Skala: doppelte Fläche → ~1.4× mehr Kapazität (nicht 2×).
        let area      = Double(world.size.width * world.size.height)
        let refArea   = 800.0 * 600.0
        let scale     = sqrt(area / refArea)
        world.maxFood          = Int(Double(config.foodCapacity) * scale)
        world.maxPopulation    = Int(300.0 * scale)
        world.foodGrowthRate   = config.foodGrowthRate
        world.mutationRate     = config.mutationRate
        world.mutationStrength = config.mutationStrength
        world.seasonEnabled    = config.seasonEnabled
        world.seasonLength     = config.seasonLength
        world.seasonAmplitude  = config.seasonAmplitude
    }

    // MARK: - Loop

    private func startTimer() {
        tickAccumulator = 0
        // Immer mit Display-Rate (60 fps) feuern — Simulations-Ticks werden pro Frame gebatcht.
        timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func tick() {
        guard !isPaused else { return }
        // Wie viele Simulations-Ticks in diesem Frame fällig sind
        tickAccumulator += 30.0 * speedMultiplier / 60.0
        let n = Int(tickAccumulator)
        tickAccumulator -= Double(n)
        for _ in 0..<n {
            world.tick()
            tracker.update(world: world)
        }
        guard n > 0 else { return }
        scene.update(world: world)
        updateStats()
    }

    private func updateStats() {
        let creatures       = world.creatures
        stats.tickCount     = world.tickCount
        stats.generation    = world.generation
        stats.population    = creatures.count
        stats.herbivores    = creatures.filter { $0.dna.aggression <= 0.45 }.count
        stats.carnivores    = creatures.filter { $0.dna.aggression  > 0.45 }.count
        stats.totalBirths   = world.totalBirths
        stats.plantCount    = world.plantCount
        stats.corpseCount   = world.foodSources.filter { $0.type == .corpse }.count
        stats.oldestAge     = creatures.map { $0.age }.max() ?? 0
        let energies        = creatures.map { Double($0.energy / $0.maxEnergy) }
        stats.averageEnergy = energies.isEmpty ? 0 : energies.reduce(0, +) / Double(energies.count)
        stats.currentSeason = world.currentSeasonName
        stats.seasonFactor  = world.currentSeasonFactor

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

    // Jahreszeiten (sofort wirksam)
    var seasonEnabled:   Bool  = false
    var seasonLength:    Int   = 3000   // Ticks pro Jahr
    var seasonAmplitude: Float = 0.70   // 0 = kein Effekt, 1 = Winter → 0% Wachstum

    // Erst beim Neustart wirksam
    var worldWidth:       Int = 2400
    var worldHeight:      Int = 1800
    var initialCreatures: Int = 80
    var initialFood:      Int = 250
}

// MARK: - Kreatur-Snapshot (für Inspektion)

struct CreatureSnapshot {
    let age:              Int
    let maxAge:           Int
    let energyRatio:      Float
    let bodyMassRatio:    Float   // bodyMass / maxBodyMass
    let senescence:       Float   // [0,1] — 0 = jung, >0 = Altersabbau aktiv
    let isHerbivore:      Bool
    // DNA
    let size:             Float
    let speed:            Float
    let aggression:       Float
    let sightRadiusGene:  Float   // Rohwert [0,1]
    let sightRadiusPx:    Float   // berechneter Radius in Pixeln (inkl. Seneszenz)
    let maxAgeGene:       Float   // [0,1] — zeigt Lebensstrategien-Pol
    let reproThreshold:   Float
    let litterSize:       Int
    let brainSize:        Float
    let hiddenCount:      Int
    // Aktuelles NN-Verhalten
    let actionSpeed:      Float
    let actionReproduce:  Float
    let actionAttack:     Float

    init(_ c: Creature) {
        age           = c.age
        maxAge        = c.dna.maxAge
        energyRatio   = max(0, min(c.energy / c.maxEnergy, 1))
        let maxBM     = c.dna.size * 60 + 20
        bodyMassRatio = maxBM > 0 ? max(0, min(c.bodyMass / maxBM, 1)) : 0
        senescence    = c.senescence
        isHerbivore   = c.dna.aggression <= 0.45
        size          = c.dna.size
        speed         = c.dna.speed
        aggression    = c.dna.aggression
        sightRadiusGene = c.dna.sightRadius
        sightRadiusPx   = Float(c.sightRadius)
        maxAgeGene    = c.dna.genes[4]
        reproThreshold = c.dna.reproductionThreshold
        litterSize    = c.dna.litterSize
        brainSize     = c.dna.brainSize
        hiddenCount   = c.hiddenCount
        actionSpeed   = c.lastAction?.speed             ?? 0
        actionReproduce = c.lastAction?.wantsToReproduce ?? 0
        actionAttack  = c.lastAction?.wantsToAttack     ?? 0
    }
}

// MARK: - Statistiken

struct SimulationStats {
    var tickCount:     Int    = 0
    var generation:    Int    = 0
    var population:    Int    = 0
    var herbivores:    Int    = 0
    var carnivores:    Int    = 0
    var totalBirths:   Int    = 0
    var plantCount:    Int    = 0
    var corpseCount:   Int    = 0
    var oldestAge:     Int    = 0
    var averageEnergy: Double = 0
    var currentSeason: String = "–"
    var seasonFactor:  Double = 1.0
}
