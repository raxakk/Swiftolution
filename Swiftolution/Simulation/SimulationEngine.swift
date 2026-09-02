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

    // Simulation läuft auf einem eigenen Thread — Main bleibt für UI/Rendering frei
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

    // MARK: - Steuerung

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
        // Kein Zugriff auf world.creatures während simQueue läuft — updateStats() holt es nach
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

    // MARK: - Config → World synchronisieren

    private func syncConfigToWorld() {
        // Nahrung und Population skalieren mit der Wurzel der Weltfläche relativ zur Referenzgröße (800×600).
        // Wurzel statt linearer Skala: doppelte Fläche → ~1.4× mehr Kapazität (nicht 2×).
        let area      = Double(world.size.width * world.size.height)
        let refArea   = 800.0 * 600.0
        let scale     = sqrt(area / refArea)
        world.maxFood          = Int(Double(config.foodCapacity) * scale)
        // Populationsgrenze skaliert mit Weltgröße, ist aber mindestens so groß wie die Startzahl
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
        // Immer mit Display-Rate (60 fps) feuern — Simulations-Ticks werden pro Frame gebatcht.
        timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    // Deckel für den aufholbaren Rückstand (≈2 Frames bei 10×). Ohne Deckel würde der
    // Rückstand bei echter Überlast unbegrenzt wachsen, die Batches immer größer werden
    // und die UI einfrieren — der Multiplikator bleibt dann eben unerreichbar.
    private static let maxTickBacklog: Double = 10

    private func tick() {
        guard !isPaused else { return }
        // Budget auch dann akkumulieren, wenn die Sim noch rechnet: sonst geht das
        // Tick-Budget jedes Frames verloren, in dem simBusy gesetzt war, und die Sim
        // legt zwischen den Batches Pausen ein statt zu rechnen — sie lief dadurch
        // dauerhaft langsamer als der eingestellte Multiplikator.
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

        // Ein Pass über alle Kreaturen statt 8 filter/map-Durchläufe
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

        // Lokal aufbauen, einmal zuweisen — @Published feuert so nur 1× pro Frame
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

// MARK: - Konfiguration

struct SimulationConfig {
    // Sofort wirksam (live)
    var foodCapacity:     Int    = 500     // Referenz für 800×600; skaliert mit √(Weltfläche)
    var foodGrowthRate:   Double = 0.05
    var mutationRate:     Float  = 0.05
    var mutationStrength: Float  = 0.10
    var minSpawnEnabled:         Bool  = false
    var minSpawnThreshold:       Int   = 5
    var latitudeGradientEnabled: Bool  = false

    // Assortative Paarung / Artbildung
    var speciationEnabled:   Bool  = true
    var speciationThreshold: Float = 0.45

    // Pflanzengift: Anreiz für Fleischfresser, sich von Pflanzen zu spezialisieren.
    // Erst oberhalb der Schwelle zahlt ein Fleischfresser eine Giftlast beim Pflanzenfressen
    // (das Aas-Trittstein für Allesfresser darunter bleibt unberührt).
    var plantToxinEnabled:   Bool  = true
    var plantToxinFactor:    Float = 0.60   // Giftstärke; 0 = aus. 0.6 → reiner Carnivore verliert an Pflanzen
    var plantToxinThreshold: Float = 0.50   // ab dieser aggression greift die Giftlast

    // Jahreszeiten (sofort wirksam)
    var seasonEnabled:   Bool  = false
    var seasonLength:    Int   = 3000   // Ticks pro Jahr
    var seasonAmplitude: Float = 0.70   // 0 = kein Effekt, 1 = Winter → 0% Wachstum

    // Biome: Terrain wird bei Welterzeugung generiert → voller Effekt (Karte, Spawns,
    // Darstellung) erst nach Neustart. Bei aktiver Karte formen Wasserzonen Barrieren.
    var biomesEnabled: Bool = false

    // Erst beim Neustart wirksam
    var worldWidth:       Int = 2400
    var worldHeight:      Int = 1800
    var initialCreatures: Int = 80
    // Startnahrung = immer world.maxFood — Welt startet vollständig bepflanzt
}

// MARK: - Kreatur-Snapshot (für Inspektion)

struct CreatureSnapshot {
    let age:              Int
    let maxAge:           Int
    let energyRatio:      Float
    let bodyMassRatio:    Float   // bodyMass / maxBodyMass
    let senescence:       Float   // [0,1] — 0 = jung, >0 = Altersabbau aktiv
    let isHerbivore:      Bool
    let biomeName:        String?  // aktuelles Biom (nil wenn Biome deaktiviert)
    // DNA
    let size:             Float
    let speed:            Float
    let aggression:       Float
    let sightRadiusGene:  Float   // Rohwert [0,1]
    let sightRadiusPx:    Float   // berechneter Radius in Pixeln (inkl. Seneszenz)
    let sightAngleGene:   Float   // Rohwert [0,1]
    let sightAngleDeg:    Int     // berechneter Winkel in Grad
    let turnRateGene:     Float   // Rohwert [0,1]
    let turnRateDeg:      Float   // berechneter Wert in Grad/Tick
    let maxAgeGene:       Float   // [0,1] — zeigt Lebensstrategien-Pol
    let reproThreshold:   Float
    let litterSize:       Int
    let brainSize:        Float
    let hiddenCount:      Int
    let olfaction:        Float   // Geruchssinn-Gen [0,1]
    // Aktuelles NN-Verhalten
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

// MARK: - Statistiken

struct SimulationStats {
    var tickCount:     Int    = 0
    var generation:    Int    = 0
    var population:    Int    = 0
    // Drei-Klassen-Einteilung nach Aggression (kontinuierlich, keine harte Grenze)
    var herbivores:    Int    = 0   // aggression ≤ 0.33
    var omnivores:     Int    = 0   // 0.33 < aggression ≤ 0.67
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
    var currentSeason: String = "–"
    var seasonFactor:  Double = 1.0
    var speciesCount:  Int    = 0   // distinkte Arten (0 = Speziation aus)
}
