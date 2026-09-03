import Foundation
import Combine
import CoreGraphics

final class SimulationEngine: ObservableObject {

    // MARK: - Public properties

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

    // The simulation runs on its own thread, leaving main free for UI and rendering
    private let simQueue = DispatchQueue(label: "swiftolution.simulation", qos: .userInteractive)
    private var simBusy  = false

    // MARK: - Lifecycle

    init() {
        syncConfigToWorld()
        world.populate(creatures: config.initialCreatures, food: world.maxFood)
        scene.setup(world: world)
        scene.onCreatureSelected = { [weak self] id in self?.selectCreature(id: id) }
        startTimer()
    }

    // MARK: - Control

    func togglePause() {
        isPaused.toggle()
    }

    func restart() {
        timer?.cancel()
        world = World(size: CGSize(width: config.worldWidth, height: config.worldHeight))
        syncConfigToWorld()
        world.populate(creatures: config.initialCreatures, food: world.maxFood)
        scene.reset(world: world)
        stats = SimulationStats()
        tracker.reset()
        selectCreature(id: nil)
        startTimer()
    }

    func selectCreature(id: UUID?) {
        selectedCreatureID       = id
        scene.selectedCreatureID = id
        // Do not touch world.creatures while simQueue is running — updateStats() catches up later
        guard !simBusy else { return }
        refreshInspection()
    }

    private func refreshInspection() {
        if let id = selectedCreatureID,
           let creature = world.creatures.first(where: { $0.id == id }) {
            let biome = world.biomesEnabled ? world.biome(at: creature.position) : nil
            inspectedCreature = CreatureSnapshot(creature, biome: biome)
        } else if selectedCreatureID != nil {
            inspectedCreature = nil
            selectedCreatureID = nil
            scene.selectedCreatureID = nil
        }
    }

    func setSpeed(_ multiplier: Double) {
        speedMultiplier = multiplier
        tickAccumulator = 0
    }

    // MARK: - Syncing config into the world

    private func syncConfigToWorld() {
        // Food and population scale with the square root of the world area relative to the
        // reference size (800x600). Square root rather than linear: twice the area gives ~1.4x
        // the capacity, not 2x.
        let area      = Double(world.size.width * world.size.height)
        let refArea   = 800.0 * 600.0
        let scale     = sqrt(area / refArea)
        world.maxFood          = Int(Double(config.foodCapacity) * scale)
        // The population ceiling scales with world size but never falls below the starting count
        world.maxPopulation    = max(Int(300.0 * scale), config.initialCreatures)
        world.foodGrowthRate   = config.foodGrowthRate
        world.mutationRate     = config.mutationRate
        world.mutationStrength = config.mutationStrength
        world.seasonEnabled    = config.seasonEnabled
        world.seasonLength     = config.seasonLength
        world.seasonAmplitude  = config.seasonAmplitude
        world.minSpawnEnabled        = config.minSpawnEnabled
        world.minSpawnThreshold      = config.minSpawnThreshold
        world.latitudeGradientEnabled = config.latitudeGradientEnabled
        world.speciationEnabled      = config.speciationEnabled
        world.speciationThreshold    = config.speciationThreshold
        world.plantToxinFactor       = config.plantToxinEnabled ? config.plantToxinFactor : 0
        world.plantToxinThreshold    = config.plantToxinThreshold
        world.biomesEnabled          = config.biomesEnabled
    }

    // MARK: - Loop

    private func startTimer() {
        tickAccumulator = 0
        // Always fire at the display rate (60 fps); simulation ticks are batched per frame.
        timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    // Ceiling on the backlog that can be caught up (~2 frames at 10x). Without it, a genuinely
    // overloaded run would grow the backlog without bound, make the batches ever larger and
    // freeze the UI — better that the multiplier simply stays out of reach.
    private static let maxTickBacklog: Double = 10

    private func tick() {
        guard !isPaused else { return }
        // Accumulate the budget even while the simulation is still computing: otherwise the
        // tick budget of every frame with simBusy set is lost, and the simulation idles between
        // batches instead of working — which made it run persistently slower than the
        // configured multiplier.
        tickAccumulator += 30.0 * speedMultiplier / 60.0
        tickAccumulator = min(tickAccumulator, SimulationEngine.maxTickBacklog)
        guard !simBusy else { return }
        let n = Int(tickAccumulator)
        tickAccumulator -= Double(n)
        guard n > 0 else { return }

        simBusy = true
        simQueue.async { [weak self] in
            guard let self else { return }
            for _ in 0..<n { self.world.tick() }
            DispatchQueue.main.async {
                self.tracker.update(world: self.world)
                self.scene.update(world: self.world)
                self.updateStats()
                self.simBusy = false
            }
        }
    }

    private func updateStats() {
        let creatures = world.creatures
        let n         = Double(creatures.count)

        // A single pass over all creatures instead of 8 filter/map traversals
        var herbivores = 0, omnivores = 0, carnivores = 0
        var aggressionSum = 0.0, ageSum = 0.0, energySum = 0.0
        var oldestAge = 0
        for c in creatures {
            let aggression = c.dna.aggression
            if aggression <= 0.33      { herbivores += 1 }
            else if aggression <= 0.67 { omnivores  += 1 }
            else                       { carnivores += 1 }
            aggressionSum += Double(aggression)
            ageSum        += Double(c.age)
            energySum     += Double(c.energy / c.maxEnergy)
            if c.age > oldestAge { oldestAge = c.age }
        }

        // Build locally and assign once, so @Published fires only a single time per frame
        var s = SimulationStats()
        s.tickCount     = world.tickCount
        s.generation    = world.generation
        s.population    = creatures.count
        s.herbivores    = herbivores
        s.omnivores     = omnivores
        s.carnivores    = carnivores
        s.avgAggression = n > 0 ? aggressionSum / n : 0
        s.totalBirths   = world.totalBirths
        s.totalDeaths   = world.totalDeaths
        s.plantCount    = world.plantCount
        s.maxFood       = world.maxFood
        s.corpseCount   = world.corpseCount
        s.oldestAge     = oldestAge
        s.averageAge    = n > 0 ? ageSum / n : 0
        s.averageEnergy = n > 0 ? energySum / n : 0
        s.currentSeason = world.currentSeasonName
        s.seasonFactor  = world.currentSeasonFactor
        s.speciesCount  = world.speciationEnabled ? world.countSpecies(threshold: world.speciationThreshold) : 0
        stats = s
        refreshInspection()
    }
}

// MARK: - Configuration

struct SimulationConfig {
    // Takes effect immediately (live)
    // Reference for 800x600; scales with sqrt(world area). Defaults to the top of the slider's
    // range on purpose: this is the bootstrap phase of the intended workflow — establish a
    // population at maximum food, then turn it down to raise selection pressure. Measured
    // headlessly on the default world, a starting population survives 4000 ticks in 6 of 6 runs
    // at 3000 and in 0 of 4 at 1500, so a lower default would mostly show the user an extinction.
    var foodCapacity:     Int    = 3000
    var foodGrowthRate:   Double = 0.05
    var mutationRate:     Float  = 0.05
    var mutationStrength: Float  = 0.10
    var minSpawnEnabled:         Bool  = false
    var minSpawnThreshold:       Int   = 5
    var latitudeGradientEnabled: Bool  = false

    // Assortative mating / speciation
    var speciationEnabled:   Bool  = true
    var speciationThreshold: Float = 0.45

    // Plant toxin: the incentive for carnivores to specialize away from plants. Only above the
    // threshold does a carnivore take on a toxin load when eating plants; the carrion stepping
    // stone for omnivores below it is left untouched.
    var plantToxinEnabled:   Bool  = true
    var plantToxinFactor:    Float = 0.60   // toxin strength; 0 = off. At 0.6 a pure carnivore loses energy on plants
    var plantToxinThreshold: Float = 0.50   // the aggression above which the toxin load applies

    // Seasons (take effect immediately)
    var seasonEnabled:   Bool  = false
    var seasonLength:    Int   = 3000   // ticks per year
    var seasonAmplitude: Float = 0.70   // 0 = no effect, 1 = winter halts growth entirely

    // Biomes: terrain is generated when the world is created, so the full effect (map, spawns,
    // rendering) only appears after a restart. With a map in place, water forms barriers.
    var biomesEnabled: Bool = false

    // Only takes effect on restart
    var worldWidth:       Int = 2400
    var worldHeight:      Int = 1800
    var initialCreatures: Int = 80
    // Starting food is always world.maxFood — the world begins fully planted
}

// MARK: - Creature snapshot (for the inspector)

struct CreatureSnapshot {
    let age:              Int
    let maxAge:           Int
    let energyRatio:      Float
    let bodyMassRatio:    Float   // bodyMass / maxBodyMass
    let senescence:       Float   // [0,1] — 0 = young, >0 = age-related decline has set in
    let isHerbivore:      Bool
    let biomeName:        String?  // the current biome (nil when biomes are disabled)
    // DNA
    let size:             Float
    let speed:            Float
    let aggression:       Float
    let sightRadiusGene:  Float   // raw value [0,1]
    let sightRadiusPx:    Float   // resulting radius in pixels (senescence included)
    let sightAngleGene:   Float   // raw value [0,1]
    let sightAngleDeg:    Int     // resulting angle in degrees
    let turnRateGene:     Float   // raw value [0,1]
    let turnRateDeg:      Float   // resulting value in degrees per tick
    let maxAgeGene:       Float   // [0,1] — shows which pole of the life strategy it sits on
    let reproThreshold:   Float
    let litterSize:       Int
    let brainSize:        Float
    let hiddenCount:      Int
    let olfaction:        Float   // the olfaction gene [0,1]
    // Current network behaviour
    let actionSpeed:      Float
    let actionReproduce:  Float
    let actionAttack:     Float
    let actionEatPlant:   Float
    let actionEatCorpse:  Float

    init(_ c: Creature, biome: Biome? = nil) {
        age           = c.age
        maxAge        = c.dna.maxAge
        biomeName     = biome?.name
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
        sightAngleGene  = c.dna.sightAngle
        sightAngleDeg   = Int((c.sightAngle * 180 / .pi).rounded())
        turnRateGene    = c.dna.turnRate
        turnRateDeg     = c.maxTurnRate * 180 / .pi
        maxAgeGene    = c.dna.genes[4]
        reproThreshold = c.dna.reproductionThreshold
        litterSize    = c.dna.litterSize
        brainSize     = c.dna.brainSize
        hiddenCount   = c.hiddenCount
        olfaction     = c.dna.olfaction
        actionSpeed     = c.lastAction?.speed             ?? 0
        actionReproduce = c.lastAction?.wantsToReproduce ?? 0
        actionAttack    = c.lastAction?.wantsToAttack    ?? 0
        actionEatPlant  = c.lastAction?.wantsToEatPlant  ?? 1
        actionEatCorpse = c.lastAction?.wantsToEatCorpse ?? 1
    }
}

// MARK: - Statistics

struct SimulationStats {
    var tickCount:     Int    = 0
    var generation:    Int    = 0
    var population:    Int    = 0
    // A three-way split by aggression (the trait itself is continuous, there is no hard line)
    var herbivores:    Int    = 0   // aggression <= 0.33
    var omnivores:     Int    = 0   // 0.33 < aggression <= 0.67
    var carnivores:    Int    = 0   // aggression > 0.67
    var avgAggression: Double = 0
    var totalBirths:   Int    = 0
    var totalDeaths:   Int    = 0
    var plantCount:    Int    = 0
    var maxFood:       Int    = 0
    var corpseCount:   Int    = 0
    var oldestAge:     Int    = 0
    var averageAge:    Double = 0
    var averageEnergy: Double = 0
    var currentSeason: String = "-"
    var seasonFactor:  Double = 1.0
    var speciesCount:  Int    = 0   // distinct species (0 = speciation is off)
}
