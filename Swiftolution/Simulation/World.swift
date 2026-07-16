import Foundation
import CoreGraphics

// Warum eine Kreatur gestorben ist — für Diagnose der Populationsdynamik.
enum DeathCause: String {
    case starvation   // Energie ≤ 0 ohne Angreifer (Stoffwechsel/Hunger, Vergiftung)
    case predation    // Energie ≤ 0 nach Angriff in diesem Tick
    case oldAge       // Alters-Mortalität (Gompertz-Wurf) trotz vorhandener Energie
}

// Ein einzelnes Simulationsereignis für den optionalen Live-Stream (World.events).
struct SimEvent {
    enum Kind: String { case birth, death }
    let kind: Kind
    let tick: Int
    let x: Float
    let y: Float
    let aggression: Float
    let cause: DeathCause?   // nur bei .death
}

final class World {

    // MARK: - Eigenschaften

    let size: CGSize
    var creatures:   [Creature]   = []
    var foodSources: [FoodSource] = []
    var generation:  Int = 0
    var tickCount:   Int = 0
    var totalBirths: Int = 0

    var plantCount:  Int = 0  // Cache — vermeidet filter { .plant } jeden Tick
    var corpseCount: Int = 0  // Cache — vermeidet filter { .corpse } in updateStats
    var totalDeaths: Int = 0

    // Todesursachen (kumulativ) — welcher Faktor die Population wie stark drückt.
    var deathsByStarvation = 0
    var deathsByPredation  = 0
    var deathsByOldAge     = 0

    // Optionaler Live-Ereignisstrom (Geburten/Tode). Nur bei eventRecording befüllt;
    // ein Beobachter (z. B. der Headless-Runner) leert `events` nach jedem tick().
    var eventRecording = false
    var events: [SimEvent] = []

    // Speichert die Wahrnehmung jeder Kreatur pro Tick (Creature.lastSensors) — nur für
    // Trace/Diagnose. Aus, weil es sonst pro Tick population × 25 Floats kostet.
    var sensorRecording = false
    var foodGrowthRate:   Double = 0.03   // logistische Rate: Anteil der freien Kapazität pro Tick
    var maxFood:          Int    = 250    // Kapazitätsgrenze (konfigurierbar)
    var mutationRate:     Float  = 0.05
    var mutationStrength: Float  = 0.10
    var maxPopulation:    Int    = 300
    var minSpawnEnabled:   Bool = false
    var minSpawnThreshold: Int  = 5
    var latitudeGradientEnabled: Bool = false

    // Assortative Paarung: Kreaturen paaren sich nur mit genetisch ähnlichen Partnern.
    // Treibt reproduktive Isolation → sichtbare Artbildung statt eines verschwommenen Genpools.
    // Verträgt sich mit einer selbsttragenden Population (Verhaltenstest: hält die Kapazität
    // auch bei stufenweiser Nahrungsreduktion). Niedrigere Schwelle → mehr, engere Arten,
    // aber kleinerer Partnerpool; in einer knappen Population entsprechend vorsichtig senken.
    var speciationEnabled:   Bool  = true
    var speciationThreshold: Float = 0.45   // max. genetische Distanz für Paarung (Bereich der Distanz: [0, 2])

    // Pflanzengift: Fleischfresser (aggression > Schwelle) zahlen beim Pflanzenfressen eine Giftlast.
    // 0 = aus. Wird pro Fressvorgang an Creature.eat übergeben.
    var plantToxinFactor:    Float = 0.60
    var plantToxinThreshold: Float = 0.50

    // Biome: räumliche Nischen (Fruchtbarkeit, Deckung, Untergrund) + Wasserbarrieren.
    // Die Karte wird einmal pro Welt erzeugt; das Flag schaltet Wirkung, Spawns und Rendering.
    let biomeMap: BiomeMap
    var biomesEnabled: Bool = false

    // Biom an einer Position. Ausgeschaltet → überall neutrale Wiese (alle Faktoren 1.0, passierbar),
    // sodass sämtliche biomabhängigen Pfade ohne Sonderfall exakt das alte Verhalten liefern.
    @inline(__always)
    func biome(at point: CGPoint) -> Biome {
        biomesEnabled ? biomeMap.biome(at: point) : .grassland
    }

    // Jahreszeiten — Cosinus-Zyklus moduliert das Pflanzenwachstum
    var seasonEnabled:   Bool  = false
    var seasonLength:    Int   = 3000    // Ticks pro Jahr
    var seasonAmplitude: Float = 0.7    // 0 = kein Effekt, 1 = Winter bringt 0% Wachstum

    // Aktueller saisonaler Wachstumsfaktor [1-amplitude … 1.0]
    var currentSeasonFactor: Double {
        guard seasonEnabled, seasonLength > 0 else { return 1.0 }
        let t = Double(tickCount % seasonLength) / Double(seasonLength)   // [0, 1)
        return (1.0 - Double(seasonAmplitude))
             + Double(seasonAmplitude) * 0.5 * (1.0 + cos(2.0 * .pi * t))
    }

    var currentSeasonName: String {
        guard seasonEnabled, seasonLength > 0 else { return "–" }
        let t = Double(tickCount % seasonLength) / Double(seasonLength)
        switch t {
        case 0..<0.25:  return "Sommer"
        case 0.25..<0.5: return "Herbst"
        case 0.5..<0.75: return "Winter"
        default:         return "Frühling"
        }
    }

    private var grid: SpatialGrid

    func rebuildGrid() { grid.rebuild(creatures: creatures, food: foodSources) }

    init(size: CGSize = CGSize(width: 1200, height: 900)) {
        self.size = size
        self.grid = SpatialGrid(cellSize: 80, worldSize: size)
        self.biomeMap = BiomeMap(worldSize: size)
    }

    // MARK: - Setup

    func populate(creatures creatureCount: Int, food foodCount: Int) {
        for _ in 0..<creatureCount {
            var dna = DNA.random()
            // Urknall: alle Lebewesen starten als Pflanzenfresser — Fleischfresser entstehen durch Evolution
            dna.genes[3] = Float.random(in: 0...0.4)
            creatures.append(Creature(dna: dna, position: creatureSpawnPosition()))
        }
        for _ in 0..<foodCount {
            foodSources.append(FoodSource(position: spawnPosition()))
        }
        plantCount  = foodCount
        corpseCount = 0
    }

    // MARK: - Simulations-Tick

    func tick() {
        tickCount += 1
        grid.rebuild(creatures: creatures, food: foodSources)
        moveCreatures()
        attackCreatures()
        feedCreatures()
        checkDeaths()
        spawnMinimumIfNeeded()
        reproduceCreatures()
        growFood()
        decayFood()
    }

    // MARK: - Bewegung & Wahrnehmung

    private func moveCreatures() {
        let snapshot = creatures
        let count = snapshot.count
        guard count > 0 else { return }

        // Phase 1 — Parallel: Wahrnehmung + NN-Aktivierung.
        // Jede Kreatur liest nur ihren eigenen Zustand und den unveränderlichen Grid — kein Data Race.
        // withUnsafeMutableBufferPointer fixiert den Array-Puffer → COW-freier Schreibzugriff aus n Threads.
        var outputs = [ActionOutput](repeating: ActionOutput(fromArray: [0.5, 0, 0, 0, 1, 1]), count: count)
        outputs.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let input = sense(for: snapshot[i])
                // Jede Iteration schreibt ausschließlich ihre eigene Kreatur → kein Data Race.
                if sensorRecording { snapshot[i].lastSensors = input }
                buf[i] = snapshot[i].brain.activate(inputs: input)
            }
        }

        // Phase 2 — Sequential: Position und Zustand schreiben (Positionsänderungen beeinflussen den Tick).
        for (i, creature) in snapshot.enumerated() {
            creature.apply(output: outputs[i], in: self)
            creature.tick()
        }
    }

    // Baut den Sensor-Input für ein Lebewesen auf.
    // Nahrung und nächste Kreatur werden nur im Sichtkegel wahrgenommen (FOV).
    // Dichte und Herding-Richtung sind omnidirektional (Tastsinn / Druckwellen).
    // Läuft parallel aus n Threads: nur eigene lokale Variablen + read-only Grid,
    // keine Allokationen (Visitor-API), Distanzvergleiche quadriert (sqrt nur am Ende).
    private func sense(for creature: Creature) -> SensorInput {
        let px = Float(creature.position.x)
        let py = Float(creature.position.y)
        // Biom am eigenen Standort: Deckung verkürzt die effektive Sichtweite (Wald),
        // freie Zonen (Wüste) verlängern sie. Betrifft nur die Wahrnehmung, nicht das Gen.
        let localBiome  = biome(at: creature.position)
        let sightRadius = creature.sightRadius * CGFloat(localBiome.sightFactor)
        let sightR   = Float(sightRadius)
        let sightRSq = sightR * sightR
        let isFull   = creature.sightAngle >= 2 * .pi * 0.995

        // FOV per Skalarprodukt statt atan2: Winkel(d, heading) ≤ halbAngle
        //   ⇔ dot/|d| ≥ cos(halbAngle) — auflösbar ohne sqrt über Vorzeichen + Quadrate.
        let cosHalf   = cos(Float(creature.sightAngle) / 2)
        let cosHalfSq = cosHalf * cosHalf
        let hx = creature.headingCos
        let hy = creature.headingSin

        @inline(__always)
        func inFOV(_ dx: Float, _ dy: Float, _ distSq: Float) -> Bool {
            guard !isFull else { return true }
            let dot = dx * hx + dy * hy
            if cosHalf >= 0 {
                return dot >= 0 && dot * dot >= cosHalfSq * distSq
            } else {
                return dot >= 0 || dot * dot <= cosHalfSq * distSq
            }
        }

        // Ein Nahrungs-Pass für Sicht UND Geruch (gemeinsamer Query-Radius)
        let smellR   = Float(creature.olfactionSmellRadius)
        let smellRSq = smellR * smellR
        var nearestFoodDx: Float = 0, nearestFoodDy: Float = 0
        var nearestFoodDistSq   = Float.greatestFiniteMagnitude
        var nearestFoodIsCorpse = false
        var foodInFOVCount = 0
        var plantsSmelled  = 0
        grid.forEachFood(near: creature.position,
                         within: max(sightRadius, creature.olfactionSmellRadius)) { food in
            let dx = Float(food.position.x) - px
            let dy = Float(food.position.y) - py
            let distSq = dx * dx + dy * dy
            if food.type == .plant && distSq < smellRSq { plantsSmelled += 1 }
            if distSq < sightRSq && inFOV(dx, dy, distSq) {
                foodInFOVCount += 1
                if distSq < nearestFoodDistSq {
                    nearestFoodDistSq   = distSq
                    nearestFoodDx       = dx
                    nearestFoodDy       = dy
                    nearestFoodIsCorpse = food.type == .corpse
                }
            }
        }

        var angleToFood:     Float = 0
        var distToFood:      Float = 1
        var nearestFoodType: Float = 0
        if nearestFoodDistSq < .greatestFiniteMagnitude {
            angleToFood     = normalizeAngle(atan2(nearestFoodDy, nearestFoodDx) - creature.heading) / .pi
            distToFood      = sqrt(nearestFoodDistSq) / sightR
            nearestFoodType = nearestFoodIsCorpse ? 1.0 : 0.0
        }

        // Ein Kreatur-Pass für Sicht, Dichte (<55) und Herding (<80)
        var nearestDx: Float = 0, nearestDy: Float = 0
        var nearestDistSq = Float.greatestFiniteMagnitude
        var nearestOther: Creature? = nil
        var visibleCount = 0
        var densityCount = 0
        var herdSin: Float = 0, herdCos: Float = 0
        var herdCount = 0
        grid.forEachCreature(near: creature.position, within: max(sightRadius, 80)) { other in
            guard other !== creature else { return }
            let dx = Float(other.position.x) - px
            let dy = Float(other.position.y) - py
            let distSq = dx * dx + dy * dy
            if distSq < 55 * 55 { densityCount += 1 }
            if distSq < 80 * 80 {
                herdSin += other.headingSin
                herdCos += other.headingCos
                herdCount += 1
            }
            if distSq < sightRSq && inFOV(dx, dy, distSq) {
                visibleCount += 1
                if distSq < nearestDistSq {
                    nearestDistSq = distSq
                    nearestDx     = dx
                    nearestDy     = dy
                    nearestOther  = other
                }
            }
        }

        var angleToCreature:   Float = 0
        var distToCreature:    Float = 1
        var approachVelocity:  Float = 0
        var nearestCreatureRed:   Float = 0.5   // neutral grau wenn keine Kreatur sichtbar
        var nearestCreatureGreen: Float = 0.5
        var nearestCreatureBlue:  Float = 0.5
        if let other = nearestOther {
            let dist = sqrt(nearestDistSq)
            angleToCreature = normalizeAngle(atan2(nearestDy, nearestDx) - creature.heading) / .pi
            distToCreature  = dist / sightR
            let otherSpeed = (other.lastAction?.speed ?? 0) * other.maxSpeed
            let vx = other.headingCos * otherSpeed
            let vy = other.headingSin * otherSpeed
            if dist > 0 {
                let approach = (vx * (-nearestDx) + vy * (-nearestDy)) / dist
                approachVelocity = max(-1, min(1, approach / max(other.maxSpeed, 0.1)))
            }
            nearestCreatureRed   = other.dna.red
            nearestCreatureGreen = other.dna.green
            nearestCreatureBlue  = other.dna.blue
        }
        let visibleCreatureCount = min(Float(visibleCount), 10) / 10
        let visibleFoodCount     = min(Float(foodInFOVCount), 10) / 10
        let localPlantDensity    = min(Float(plantsSmelled) / 20.0, 1.0)
        let localDensity         = min(Float(densityCount) / 8.0, 1.0)

        var avgNearbyHeading: Float = 0
        if herdCount > 0 {
            avgNearbyHeading = normalizeAngle(atan2(herdSin, herdCos) - creature.heading) / .pi
        }

        // Richtungsaufgelöste Terrain-Wahrnehmung (nur bei aktiven Biomen; sonst alles 0 →
        // keine Wirkung auf die NN-Ausgabe, identisches Verhalten wie ohne Biome).
        var tbGrass: Float = 0, tbForest: Float = 0, tbDesert: Float = 0
        var tbWetland: Float = 0, tbWater: Float = 0
        if biomesEnabled {
            let b = biomeMap.directionalBearings(observerX: px, observerY: py,
                                                 headingCos: hx, headingSin: hy,
                                                 sightRadius: sightR,
                                                 sightAngle: Float(creature.sightAngle))
            tbGrass = b.grassland; tbForest = b.forest; tbDesert = b.desert
            tbWetland = b.wetland; tbWater = b.water
        }

        return SensorInput(
            angleToFood:          angleToFood,
            distanceToFood:       distToFood,
            angleToCreature:      angleToCreature,
            distanceToCreature:   distToCreature,
            ownEnergy:            creature.energy / creature.maxEnergy,
            localDensity:         localDensity,
            approachVelocity:     approachVelocity,
            nearestFoodType:      nearestFoodType,
            avgNearbyHeading:     avgNearbyHeading,
            nearestCreatureRed:   nearestCreatureRed,
            nearestCreatureGreen: nearestCreatureGreen,
            nearestCreatureBlue:  nearestCreatureBlue,
            visibleCreatureCount: visibleCreatureCount,
            ownSenescence:        min(creature.senescence, 1),
            visibleFoodCount:     visibleFoodCount,
            localPlantDensity:    localPlantDensity,
            recentFeedingRate:    min(creature.recentFeedingRate / 20.0, 1.0),
            localFertility:       min(localBiome.fertility / Biome.maxFertility, 1),
            localCover:           max(0, min(1 - localBiome.sightFactor, 1)),
            localDifficulty:      max(0, min(1 - localBiome.speedFactor, 1)),
            terrainBearingGrassland: tbGrass,
            terrainBearingForest:    tbForest,
            terrainBearingDesert:    tbDesert,
            terrainBearingWetland:   tbWetland,
            terrainBearingWater:     tbWater
        )
    }

    // MARK: - Angriff

    func attackCreatures() {
        // ObjectIdentifier: Pointer-Hash (8 Byte) statt UUID-Hash (16 Byte) — doppelt so schnell.
        var energyDeltas = [ObjectIdentifier: Float](minimumCapacity: creatures.count)

        for attacker in creatures {
            // Kein harter Aggression-Threshold — Schaden und Kosten skalieren bereits mit aggression.
            guard let action = attacker.lastAction,
                  action.wantsToAttack > 0.5 else { continue }

            guard let victim = nearestCreature(to: attacker, within: attacker.attackRadius) else { continue }
            guard attacker.dna.size >= victim.dna.size * 0.6 else { continue }

            let rawDamage = (attacker.dna.size * 0.6 + attacker.dna.aggression * 0.4) * 50
            // Größe = Robustheit (dickere Haut/Panzer), Aggression = Kampferfahrung/Reflexe
            let defense   = min(victim.dna.size * 0.30 + victim.dna.aggression * 0.60, 0.90)
            let damage    = rawDamage * (1 - defense)

            energyDeltas[ObjectIdentifier(attacker), default: 0] -= attacker.dna.aggression * 2
            energyDeltas[ObjectIdentifier(victim),   default: 0] -= damage
            victim.lastAttacker = attacker
        }

        for creature in creatures {
            guard let delta = energyDeltas[ObjectIdentifier(creature)] else { continue }
            creature.energy = max(0, min(creature.energy + delta, creature.maxEnergy))
        }
    }

    // MARK: - Fressen

    func feedCreatures() {
        var eatenIDs = Set<UUID>()
        var eatenPlants  = 0
        var eatenCorpses = 0
        for creature in creatures {
            // NN-Entscheidung pro Nahrungstyp — selektive Diäten sind möglich.
            let action = creature.lastAction
            let wantsPlant  = (action?.wantsToEatPlant  ?? 1.0) > 0.5
            let wantsCorpse = (action?.wantsToEatCorpse ?? 1.0) > 0.5
            // Spart die Grid-Abfrage, wenn die Kreatur gar nichts fressen will
            guard wantsPlant || wantsCorpse else { continue }
            let eatRadius = creature.eatRadius
            let eatRSq = Float(eatRadius * eatRadius)
            let px = Float(creature.position.x)
            let py = Float(creature.position.y)
            grid.forEachFood(near: creature.position, within: eatRadius) { food in
                let wants = food.type == .plant ? wantsPlant : wantsCorpse
                guard wants else { return }
                let dx = Float(food.position.x) - px
                let dy = Float(food.position.y) - py
                guard dx * dx + dy * dy < eatRSq, !eatenIDs.contains(food.id) else { return }
                creature.eat(food: food,
                             plantToxinFactor: plantToxinFactor,
                             plantToxinThreshold: plantToxinThreshold)
                if food.type == .plant { eatenPlants += 1 } else { eatenCorpses += 1 }
                eatenIDs.insert(food.id)
            }
        }
        if !eatenIDs.isEmpty {
            foodSources.removeAll { eatenIDs.contains($0.id) }
            plantCount  -= eatenPlants
            corpseCount -= eatenCorpses
        }
    }

    // MARK: - Tod

    func checkDeaths() {
        // Gompertz-ähnliche Sterblichkeit: kleines Grundrisiko + exponentiell steigendes Altersrisiko.
        // Ein Pass — kein UUID-Set, kein zweites Iterieren.
        var survivors: [Creature] = []
        survivors.reserveCapacity(creatures.count)
        for creature in creatures {
            let ageRatio    = Float(creature.age) / Float(creature.dna.maxAge)
            let deathChance = 0.0001 + ageRatio * ageRatio * 0.003
            let survivesAge = Float.random(in: 0...1) >= deathChance
            if creature.isAlive && survivesAge {
                survivors.append(creature)
            } else {
                totalDeaths += 1
                // Ursache: Energie-Tod (Hunger vs. Prädation je nach Angreifer diesen Tick),
                // sonst Alters-Mortalität (lebendig, aber Gompertz-Wurf ausgelöst).
                let cause: DeathCause
                if !creature.isAlive {
                    cause = creature.lastAttacker != nil ? .predation : .starvation
                } else {
                    cause = .oldAge
                }
                switch cause {
                case .starvation: deathsByStarvation += 1
                case .predation:  deathsByPredation  += 1
                case .oldAge:     deathsByOldAge      += 1
                }
                if eventRecording {
                    events.append(SimEvent(kind: .death, tick: tickCount,
                                           x: Float(creature.position.x), y: Float(creature.position.y),
                                           aggression: creature.dna.aggression, cause: cause))
                }
                if creature.bodyMass > 1 {
                    var corpseEnergy = creature.bodyMass
                    if let killer = creature.lastAttacker, killer.isAlive {
                        // Angreifer frisst direkt beim Kill — Anteil proportional zur Aggression.
                        // Energie wird von der Leiche abgezogen, nicht neu erzeugt.
                        let bonus = creature.bodyMass * killer.dna.aggression * 0.4
                        killer.energy = min(killer.energy + bonus, killer.maxEnergy)
                        corpseEnergy -= bonus
                    }
                    if corpseEnergy > 1 {
                        foodSources.append(FoodSource(position: creature.position,
                                                      energyValue: corpseEnergy,
                                                      type: .corpse,
                                                      spawnedAt: tickCount))
                        corpseCount += 1
                    }
                }
            }
        }
        creatures = survivors
    }

    // MARK: - Mindest-Spawn

    private func spawnMinimumIfNeeded() {
        guard minSpawnEnabled, creatures.count < minSpawnThreshold else { return }
        let count = minSpawnThreshold - creatures.count
        for _ in 0..<count {
            var dna = DNA.random()
            dna.genes[3] = Float.random(in: 0...0.4)   // immer Pflanzenfresser
            creatures.append(Creature(dna: dna, position: creatureSpawnPosition()))
        }
    }

    // MARK: - Fortpflanzung

    func reproduceCreatures() {
        guard creatures.count < maxPopulation else { return }

        // ObjectIdentifier statt UUID: Pointer-Vergleich, kein 16-Byte-Hash.
        var mated    = Set<ObjectIdentifier>(minimumCapacity: 64)
        var newborns = [Creature]()

        // Nur Lebewesen die Energie haben UND deren NN reproduzieren "will"
        let candidates = creatures
            .filter { $0.canReproduce && ($0.lastAction?.wantsToReproduce ?? 0) > 0.5 }
            .shuffled()

        for parent in candidates {
            guard !mated.contains(ObjectIdentifier(parent)) else { continue }
            guard creatures.count + newborns.count < maxPopulation else { break }

            // Grid-Abfrage statt O(candidates.count)-Scan: Partner wird räumlich gesucht.
            // Paarungsschranke: bei aktiver Speziation genetische Distanz, sonst nur Aggressions-Nische.
            var partner: Creature? = nil
            grid.forEachCreature(near: parent.position, within: 40) { other in
                guard partner == nil,
                      other !== parent,
                      !mated.contains(ObjectIdentifier(other)),
                      (other.lastAction?.wantsToReproduce ?? 0) > 0.5,
                      other.canReproduce else { return }
                let compatible = speciationEnabled
                    ? parent.dna.geneticDistance(to: other.dna) <= speciationThreshold
                    : abs(other.dna.aggression - parent.dna.aggression) < 0.3
                guard compatible else { return }
                partner = other
            }

            if let partner {
                // Sexuelle Fortpflanzung: Gene beider Eltern werden kombiniert
                mated.insert(ObjectIdentifier(parent))
                mated.insert(ObjectIdentifier(partner))
                let midPoint = CGPoint(x: (parent.position.x + partner.position.x) / 2,
                                       y: (parent.position.y + partner.position.y) / 2)
                let litter = min(parent.dna.litterSize, maxPopulation - creatures.count - newborns.count)
                // Jedes Elternteil investiert 30% seiner Maximalenergie — unabhängig von der Wurfgröße.
                // Die Gesamtinvestition beider Eltern wird gleichmäßig auf die Kinder verteilt.
                // Kein Energie-Leak: Kinder bekommen nur was Eltern bezahlen.
                let costPerParent: Float = 0.30
                let totalPool = parent.maxEnergy * costPerParent + partner.maxEnergy * costPerParent
                let perChildEnergy = totalPool / Float(litter)
                for _ in 0..<litter {
                    let childDNA = parent.dna.crossed(with: partner.dna)
                                             .mutated(rate: mutationRate, strength: mutationStrength)
                    let child = Creature(dna: childDNA, position: dispersedPosition(from: midPoint))
                    child.energy = min(child.maxEnergy * 0.6, perChildEnergy)
                    newborns.append(child)
                }
                parent.energy  -= parent.maxEnergy  * costPerParent
                partner.energy -= partner.maxEnergy * costPerParent
            } else {
                // Asexuell als Fallback — Elternteil investiert 40%, verteilt auf Wurf
                mated.insert(ObjectIdentifier(parent))
                let litter = min(parent.dna.litterSize, maxPopulation - creatures.count - newborns.count)
                let cost: Float = 0.40
                let perChildEnergy = parent.maxEnergy * cost / Float(litter)
                for _ in 0..<litter {
                    let childDNA = parent.dna.mutated(rate: mutationRate, strength: mutationStrength)
                    let child = Creature(dna: childDNA, position: dispersedPosition(from: parent.position))
                    child.energy = min(child.maxEnergy * 0.6, perChildEnergy)
                    newborns.append(child)
                }
                parent.energy -= parent.maxEnergy * cost
            }
        }

        if !newborns.isEmpty {
            if eventRecording {
                for child in newborns {
                    events.append(SimEvent(kind: .birth, tick: tickCount,
                                           x: Float(child.position.x), y: Float(child.position.y),
                                           aggression: child.dna.aggression, cause: nil))
                }
            }
            creatures.append(contentsOf: newborns)
            totalBirths += newborns.count
            generation  += 1
        }
    }

    // MARK: - Nahrungswachstum

    func growFood() {
        if biomesEnabled {
            growFoodWithBiomes()
        } else if latitudeGradientEnabled {
            growFoodWithGradient()
        } else {
            let fillRatio = Double(plantCount) / Double(maxFood)
            let newItems  = Int((foodGrowthRate * currentSeasonFactor * (1.0 - fillRatio) * Double(maxFood)).rounded())
            for _ in 0..<max(0, newItems) {
                foodSources.append(FoodSource(position: randomPosition()))
                plantCount += 1
            }
        }
    }

    // Biom-gewichtetes Wachstum: die globale logistische Menge wird per Rejection-Sampling
    // platziert — Akzeptanz ∝ fertility × growthFactor des Bioms. Wasser (0) bekommt nie
    // Pflanzen, Wüste selten, Sumpf/Wiese oft. So bilden sich fruchtbare und karge Zonen.
    private func growFoodWithBiomes() {
        let fillRatio = Double(plantCount) / Double(maxFood)
        let newItems  = Int((foodGrowthRate * currentSeasonFactor * (1.0 - fillRatio) * Double(maxFood)).rounded())
        guard newItems > 0 else { return }
        let norm = Biome.maxFertility * 1.40   // max. fertility × max. growthFactor (Sumpf)
        var added = 0
        var attempts = 0
        let maxAttempts = newItems * 12        // Deckel gegen Endlosschleife bei viel Wasser/Wüste
        while added < newItems && attempts < maxAttempts {
            attempts += 1
            let pos = randomPosition()
            let b   = biomeMap.biome(at: pos)
            let p   = b.fertility * b.growthFactor / norm
            if Float.random(in: 0...1) < p {
                foodSources.append(FoodSource(position: pos))
                plantCount += 1
                added += 1
            }
        }
    }

    // Streifen-basiertes Wachstum: Kapazität und Rate skalieren mit cos(Polabstand × π/2).
    // Äquatorstreifen wachsen schnell und können viele Pflanzen tragen;
    // Polstreifen sind karg und regenerieren langsam.
    // Gesamtkapazität = maxFood (Energieerhaltung über alle Streifen).
    private func growFoodWithGradient() {
        let strips     = 10
        let stripH     = size.height / CGFloat(strips)
        let equatorY   = Float(size.height / 2)
        let halfH      = Float(size.height / 2)

        // Fruchtbarkeit und Gesamtnormierung pro Streifen
        var fertilities    = [Double](repeating: 0, count: strips)
        var totalFertility = 0.0
        for i in 0..<strips {
            let centerY = Float((CGFloat(i) + 0.5) * stripH)
            let dy      = abs(centerY - equatorY) / halfH
            let f       = Double(cos(Double(dy) * .pi / 2))
            fertilities[i]  = f
            totalFertility += f
        }

        // Pflanzen pro Streifen zählen (einmalig, O(n_plants))
        var counts = [Int](repeating: 0, count: strips)
        for food in foodSources where food.type == .plant {
            counts[min(Int(food.position.y / stripH), strips - 1)] += 1
        }

        // Logistisches Wachstum pro Streifen
        for i in 0..<strips {
            let f        = fertilities[i]
            // Streifen-Kapazität proportional zur Fruchtbarkeit; Summe = maxFood
            let capacity = Double(maxFood) * f / totalFertility
            let fill     = capacity > 0 ? min(1.0, Double(counts[i]) / capacity) : 1.0
            // f² : Fruchtbarkeit steuert sowohl Kapazität als auch Rate → starker Äquatorvorteil
            let newItems = Int((f * foodGrowthRate * currentSeasonFactor * (1.0 - fill) * capacity).rounded())

            let minY = CGFloat(i) * stripH
            let maxY = minY + stripH
            for _ in 0..<max(0, newItems) {
                let pos = CGPoint(x: CGFloat.random(in: 0..<size.width),
                                  y: CGFloat.random(in: minY..<maxY))
                foodSources.append(FoodSource(position: pos))
                plantCount += 1
            }
        }
    }

    func decayFood() {
        // Leichen verrotten und verschwinden — keine Energieentstehung.
        var decayed = 0
        foodSources.removeAll {
            guard $0.type == .corpse, tickCount - $0.spawnedAt > 1200 else { return false }
            decayed += 1
            return true
        }
        corpseCount -= decayed
    }

    // MARK: - Hilfsmethoden

    func randomPosition() -> CGPoint {
        CGPoint(
            x: CGFloat.random(in: 0..<size.width),
            y: CGFloat.random(in: 0..<size.height)
        )
    }

    // Pflanzen-Spawn: mit Äquator-Gradient konzentrieren Pflanzen sich in Weltmitte (y-Achse).
    // Rejection-Sampling: Akzeptanzwahrscheinlichkeit = cos(normierter Polabstand × π/2).
    // Äquator (dy=0) → 100%, Pol (dy=1) → 0%. Mittlere Iterationen: ~1.6.
    private func spawnPosition() -> CGPoint {
        if biomesEnabled { return biomePlantPosition() }
        guard latitudeGradientEnabled else { return randomPosition() }
        let equatorY = Float(size.height / 2)
        let halfH    = Float(size.height / 2)
        while true {
            let pos = randomPosition()
            let dy  = abs(Float(pos.y) - equatorY) / halfH
            if Float.random(in: 0...1) < cos(dy * .pi / 2) { return pos }
        }
    }

    // Startpflanzen biomgewichtet platzieren (gleiches Rejection-Kriterium wie growFoodWithBiomes).
    // Deckel gegen Endlosschleife, falls die Welt überwiegend Wasser/Wüste ist.
    private func biomePlantPosition() -> CGPoint {
        let norm = Biome.maxFertility * 1.40
        for _ in 0..<40 {
            let pos = randomPosition()
            let b   = biomeMap.biome(at: pos)
            if Float.random(in: 0...1) < b.fertility * b.growthFactor / norm { return pos }
        }
        // Fallback: irgendeine passierbare Position (kein Startwasser-Baum)
        return creatureSpawnPosition()
    }

    // Passierbare Startposition für Kreaturen — vermeidet Wasser, wenn Biome aktiv sind.
    private func creatureSpawnPosition() -> CGPoint {
        guard biomesEnabled else { return randomPosition() }
        for _ in 0..<40 {
            let p = randomPosition()
            if biomeMap.biome(at: p).isPassable { return p }
        }
        return randomPosition()
    }

    // Nachwuchs spawnt in einem zufälligen Radius um das Elterntier,
    // damit Cluster sich nicht selbst verstärken. Landet der Wurf im Wasser,
    // wird zurück auf die (passierbare) Elternposition gefallen.
    private func dispersedPosition(from origin: CGPoint, spread: CGFloat = 30) -> CGPoint {
        for _ in 0..<8 {
            let angle = CGFloat.random(in: 0..<(.pi * 2))
            let dist  = CGFloat.random(in: 10..<spread)
            let p = CGPoint(
                x: (origin.x + cos(angle) * dist + size.width).truncatingRemainder(dividingBy: size.width),
                y: (origin.y + sin(angle) * dist + size.height).truncatingRemainder(dividingBy: size.height)
            )
            if !biomesEnabled || biomeMap.biome(at: p).isPassable { return p }
        }
        return origin
    }

    // Zählt distinkte Arten per Greedy-Clustering auf den Markergenen: jede Kreatur kommt
    // zum ersten Cluster, dessen Repräsentant näher als threshold liegt, sonst eröffnet sie
    // einen neuen. Näherung (Reihenfolge-abhängig), aber O(n·k) mit kleinem k und für die
    // Diversitäts-Anzeige völlig ausreichend.
    func countSpecies(threshold: Float) -> Int {
        var representatives: [DNA] = []
        for creature in creatures {
            var matched = false
            for rep in representatives where creature.dna.geneticDistance(to: rep) <= threshold {
                matched = true
                break
            }
            if !matched { representatives.append(creature.dna) }
        }
        return representatives.count
    }

    func nearestCreature(to creature: Creature, within radius: CGFloat) -> Creature? {
        let radiusSq = Float(radius * radius)
        let px = Float(creature.position.x)
        let py = Float(creature.position.y)
        var best: Creature? = nil
        var bestDistSq = radiusSq
        grid.forEachCreature(near: creature.position, within: radius) { other in
            guard other !== creature else { return }
            let dx = Float(other.position.x) - px
            let dy = Float(other.position.y) - py
            let distSq = dx * dx + dy * dy
            if distSq < bestDistSq {
                bestDistSq = distSq
                best = other
            }
        }
        return best
    }

private func normalizeAngle(_ angle: Float) -> Float {
        var a = angle
        while a >  .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
