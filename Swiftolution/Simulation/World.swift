import Foundation
import CoreGraphics

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
    var foodGrowthRate:   Double = 0.03   // logistische Rate: Anteil der freien Kapazität pro Tick
    var maxFood:          Int    = 250    // Kapazitätsgrenze (konfigurierbar)
    var mutationRate:     Float  = 0.05
    var mutationStrength: Float  = 0.10
    var maxPopulation:    Int    = 300
    var minSpawnEnabled:   Bool = false
    var minSpawnThreshold: Int  = 5

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
    }

    // MARK: - Setup

    func populate(creatures creatureCount: Int, food foodCount: Int) {
        for _ in 0..<creatureCount {
            var dna = DNA.random()
            // Urknall: alle Lebewesen starten als Pflanzenfresser — Fleischfresser entstehen durch Evolution
            dna.genes[3] = Float.random(in: 0...0.4)
            creatures.append(Creature(dna: dna, position: randomPosition()))
        }
        for _ in 0..<foodCount {
            foodSources.append(FoodSource(position: randomPosition()))
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
        let count = creatures.count
        guard count > 0 else { return }

        // Phase 1 — Parallel: Wahrnehmung + NN-Aktivierung.
        // Jede Kreatur liest nur ihren eigenen Zustand und den unveränderlichen Grid — kein Data Race.
        // withUnsafeMutableBufferPointer fixiert den Array-Puffer → COW-freier Schreibzugriff aus n Threads.
        var outputs = [ActionOutput](repeating: ActionOutput(fromArray: [0.5, 0, 0, 0, 1]), count: count)
        outputs.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: count) { [self] i in
                let input = sense(for: creatures[i])
                buf[i] = creatures[i].brain.activate(inputs: input)
            }
        }

        // Phase 2 — Sequential: Position und Zustand schreiben (Positionsänderungen beeinflussen den Tick).
        for (i, creature) in creatures.enumerated() {
            creature.apply(output: outputs[i], in: self)
            creature.tick()
        }
    }

    // Baut den Sensor-Input für ein Lebewesen auf.
    // Nahrung und nächste Kreatur werden nur im Sichtkegel wahrgenommen (FOV).
    // Dichte und Herding-Richtung sind omnidirektional (Tastsinn / Druckwellen).
    private func sense(for creature: Creature) -> SensorInput {
        let sightR    = Float(creature.sightRadius)
        let halfAngle = creature.sightAngle / 2
        let isFull    = creature.sightAngle >= 2 * .pi * 0.995

        // Prüft ob eine Position im Sichtkegel liegt.
        func inFOV(at pos: CGPoint) -> Bool {
            guard !isFull else { return true }
            let dx = Float(pos.x - creature.position.x)
            let dy = Float(pos.y - creature.position.y)
            return abs(normalizeAngle(atan2(dy, dx) - creature.heading)) <= Float(halfAngle)
        }

        // Nahrung im Sichtkegel
        var angleToFood:     Float = 0
        var distToFood:      Float = 1
        var nearestFoodType: Float = 0
        let foodInFOV = grid.nearbyFood(to: creature.position, within: creature.sightRadius)
            .filter { distance($0.position, creature.position) < creature.sightRadius && inFOV(at: $0.position) }
        if let food = foodInFOV.min(by: { distance($0.position, creature.position) < distance($1.position, creature.position) }) {
            let dx = Float(food.position.x - creature.position.x)
            let dy = Float(food.position.y - creature.position.y)
            let relAngle    = normalizeAngle(atan2(dy, dx) - creature.heading)
            angleToFood     = relAngle / .pi
            distToFood      = Float(distance(creature.position, food.position)) / sightR
            nearestFoodType = food.type == .corpse ? 1.0 : 0.0
        }

        // Eine Grid-Abfrage für alle Kreatur-Sensoren.
        // Radius = max(sightRadius, 80px) für Dichte/Herding-Sensoren.
        let crQueryRadius = max(creature.sightRadius, 80)
        let nearbyAll = grid.nearbyCreatures(to: creature.position, within: crQueryRadius)
                            .filter { $0 !== creature }

        // Nächste Kreatur im Sichtkegel (visuell)
        var angleToCreature:   Float = 0
        var distToCreature:    Float = 1
        var approachVelocity:  Float = 0
        var nearestCreatureRed:   Float = 0.5   // neutral grau wenn keine Kreatur sichtbar
        var nearestCreatureGreen: Float = 0.5
        var nearestCreatureBlue:  Float = 0.5
        let creaturesInFOV = nearbyAll
            .filter { distance($0.position, creature.position) < creature.sightRadius && inFOV(at: $0.position) }
        if let other = creaturesInFOV.min(by: { distance($0.position, creature.position) < distance($1.position, creature.position) }) {
            let dx   = Float(other.position.x - creature.position.x)
            let dy   = Float(other.position.y - creature.position.y)
            let dist = Float(distance(creature.position, other.position))
            angleToCreature = normalizeAngle(atan2(dy, dx) - creature.heading) / .pi
            distToCreature  = dist / sightR
            let otherSpeed = (other.lastAction?.speed ?? 0) * other.maxSpeed
            let vx = cos(other.heading) * otherSpeed
            let vy = sin(other.heading) * otherSpeed
            if dist > 0 {
                let approach = (vx * (-dx) + vy * (-dy)) / dist
                approachVelocity = max(-1, min(1, approach / max(other.maxSpeed, 0.1)))
            }
            nearestCreatureRed   = other.dna.red
            nearestCreatureGreen = other.dna.green
            nearestCreatureBlue  = other.dna.blue
        }
        let visibleCreatureCount = min(Float(creaturesInFOV.count), 10) / 10
        let visibleFoodCount     = min(Float(foodInFOV.count), 10) / 10

        // Dichte + Herding: omnidirektional — Druckwellen/Vibrationen, kein Sichtkegel nötig
        let densityCount = nearbyAll.filter { distance($0.position, creature.position) < 55 }.count
        let localDensity = min(Float(densityCount) / 8.0, 1.0)

        let neighbors80 = nearbyAll.filter { distance($0.position, creature.position) < 80 }
        var avgNearbyHeading: Float = 0
        if !neighbors80.isEmpty {
            let sinMean = neighbors80.reduce(Float(0)) { $0 + sin($1.heading) } / Float(neighbors80.count)
            let cosMean = neighbors80.reduce(Float(0)) { $0 + cos($1.heading) } / Float(neighbors80.count)
            avgNearbyHeading = normalizeAngle(atan2(sinMean, cosMean) - creature.heading) / .pi
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
            visibleFoodCount:     visibleFoodCount
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
        var eatenPlants = 0
        for creature in creatures {
            for food in grid.nearbyFood(to: creature.position, within: creature.eatRadius) {
                guard !eatenIDs.contains(food.id) else { continue }
                guard distance(creature.position, food.position) < creature.eatRadius else { continue }
                let wantsToEat = (creature.lastAction?.wantsToEat ?? 1.0) > 0.5
                guard wantsToEat else { continue }
                creature.eat(food: food)
                if food.type == .plant { eatenPlants += 1 }
                eatenIDs.insert(food.id)
            }
        }
        if !eatenIDs.isEmpty {
            let eatenCorpses = foodSources.filter { eatenIDs.contains($0.id) && $0.type == .corpse }.count
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
            if creature.isAlive && Float.random(in: 0...1) >= deathChance {
                survivors.append(creature)
            } else {
                totalDeaths += 1
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
            creatures.append(Creature(dna: dna, position: randomPosition()))
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
            let partner = grid.nearbyCreatures(to: parent.position, within: 40)
                .first {
                    $0 !== parent
                    && !mated.contains(ObjectIdentifier($0))
                    && ($0.lastAction?.wantsToReproduce ?? 0) > 0.5
                    && $0.canReproduce
                    && abs($0.dna.aggression - parent.dna.aggression) < 0.3
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
            creatures.append(contentsOf: newborns)
            totalBirths += newborns.count
            generation  += 1
        }
    }

    // MARK: - Nahrungswachstum

    func growFood() {
        let fillRatio = Double(plantCount) / Double(maxFood)
        let newItems  = Int((foodGrowthRate * currentSeasonFactor * (1.0 - fillRatio) * Double(maxFood)).rounded())
        for _ in 0..<max(0, newItems) {
            foodSources.append(FoodSource(position: randomPosition()))
            plantCount += 1
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

    // Nachwuchs spawnt in einem zufälligen Radius um das Elterntier,
    // damit Cluster sich nicht selbst verstärken.
    private func dispersedPosition(from origin: CGPoint, spread: CGFloat = 30) -> CGPoint {
        let angle = CGFloat.random(in: 0..<(.pi * 2))
        let dist  = CGFloat.random(in: 10..<spread)
        return CGPoint(
            x: (origin.x + cos(angle) * dist + size.width).truncatingRemainder(dividingBy: size.width),
            y: (origin.y + sin(angle) * dist + size.height).truncatingRemainder(dividingBy: size.height)
        )
    }

    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    func nearestFood(to point: CGPoint, within radius: CGFloat) -> FoodSource? {
        grid.nearbyFood(to: point, within: radius)
            .filter { distance($0.position, point) < radius }
            .min(by: { distance($0.position, point) < distance($1.position, point) })
    }

    func nearestCreature(to creature: Creature, within radius: CGFloat) -> Creature? {
        grid.nearbyCreatures(to: creature.position, within: radius)
            .filter { $0 != creature && distance($0.position, creature.position) < radius }
            .min(by: { distance($0.position, creature.position) < distance($1.position, creature.position) })
    }

private func normalizeAngle(_ angle: Float) -> Float {
        var a = angle
        while a >  .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
