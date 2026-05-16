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
    var foodGrowthRate:   Double = 0.03   // logistische Rate: Anteil der freien Kapazität pro Tick
    var maxFood:          Int    = 250    // Kapazitätsgrenze (konfigurierbar)
    var mutationRate:     Float  = 0.05
    var mutationStrength: Float  = 0.10
    var maxPopulation:    Int    = 300

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
            // 80% Pflanzenfresser als Startpopulation — Fleischfresser sollen durch Evolution entstehen
            if Float.random(in: 0...1) < 0.8 {
                dna.genes[3] = Float.random(in: 0...0.4)
            }
            creatures.append(Creature(dna: dna, position: randomPosition()))
        }
        for _ in 0..<foodCount {
            foodSources.append(FoodSource(position: randomPosition()))
        }
        plantCount  = foodCount   // Startnahrung sind alles Pflanzen
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
        var outputs = [ActionOutput](repeating: ActionOutput(fromArray: [0.5, 0, 0, 0]), count: count)
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
    // Nur Objekte innerhalb des Sichtradius werden wahrgenommen.
    private func sense(for creature: Creature) -> SensorInput {
        let sightR = Float(creature.sightRadius)

        var angleToFood:  Float = 0
        var distToFood:   Float = 1
        var nearestFoodType: Float = 0   // 0 = Pflanze, 1 = Leiche
        if let food = nearestFood(to: creature.position, within: creature.sightRadius) {
            let dx = Float(food.position.x - creature.position.x)
            let dy = Float(food.position.y - creature.position.y)
            let relAngle = normalizeAngle(atan2(dy, dx) - creature.heading)
            angleToFood      = relAngle / .pi
            distToFood       = Float(distance(creature.position, food.position)) / sightR
            nearestFoodType  = food.type == .corpse ? 1.0 : 0.0
        }

        // Eine einzige Grid-Abfrage für alle drei Kreatur-Sensoren (Nearest, Dichte, Heading).
        // Radius = max(sightRadius, 80px), danach per Distanz gefiltert.
        // === statt UUID-Vergleich — Pointer-Identity ist O(1) ohne Hashing.
        let crQueryRadius = max(creature.sightRadius, 80)
        let nearbyAll = grid.nearbyCreatures(to: creature.position, within: crQueryRadius)
                            .filter { $0 !== creature }

        var angleToCreature:  Float = 0
        var distToCreature:   Float = 1
        var approachVelocity: Float = 0
        let inSight = creature.sightRadius
        if let other = nearbyAll
                .filter({ distance($0.position, creature.position) < inSight })
                .min(by: { distance($0.position, creature.position) < distance($1.position, creature.position) }) {
            let dx = Float(other.position.x - creature.position.x)
            let dy = Float(other.position.y - creature.position.y)
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
        }

        let densityCount = nearbyAll.filter { distance($0.position, creature.position) < 55 }.count
        let localDensity = min(Float(densityCount) / 8.0, 1.0)

        // Circular mean der Bewegungsrichtungen aller Nachbarn im 80px-Radius.
        let neighbors80 = nearbyAll.filter { distance($0.position, creature.position) < 80 }
        var avgNearbyHeading: Float = 0
        if !neighbors80.isEmpty {
            let sinMean = neighbors80.reduce(Float(0)) { $0 + sin($1.heading) } / Float(neighbors80.count)
            let cosMean = neighbors80.reduce(Float(0)) { $0 + cos($1.heading) } / Float(neighbors80.count)
            avgNearbyHeading = normalizeAngle(atan2(sinMean, cosMean) - creature.heading) / .pi
        }

        return SensorInput(
            angleToFood:        angleToFood,
            distanceToFood:     distToFood,
            angleToCreature:    angleToCreature,
            distanceToCreature: distToCreature,
            ownEnergy:          creature.energy / creature.maxEnergy,
            localDensity:       localDensity,
            approachVelocity:   approachVelocity,
            nearestFoodType:    nearestFoodType,
            avgNearbyHeading:   avgNearbyHeading
        )
    }

    // MARK: - Angriff

    func attackCreatures() {
        // ObjectIdentifier: Pointer-Hash (8 Byte) statt UUID-Hash (16 Byte) — doppelt so schnell.
        var energyDeltas = [ObjectIdentifier: Float](minimumCapacity: creatures.count)

        for attacker in creatures {
            guard let action = attacker.lastAction,
                  action.wantsToAttack > 0.5,
                  attacker.dna.aggression > 0.45 else { continue }

            guard let victim = nearestCreature(to: attacker, within: attacker.attackRadius) else { continue }
            guard attacker.dna.size >= victim.dna.size * 0.6 else { continue }

            let rawDamage = (attacker.dna.size * 0.6 + attacker.dna.aggression * 0.4) * 50
            let defense   = min(victim.dna.aggression * 0.9, 0.92)
            let damage    = rawDamage * (1 - defense)

            energyDeltas[ObjectIdentifier(attacker), default: 0] -= attacker.dna.aggression * 6
            energyDeltas[ObjectIdentifier(victim),   default: 0] -= damage
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
                if food.type == .plant  && creature.dna.aggression >  0.45 { continue }
                if food.type == .corpse && creature.dna.aggression <= 0.45 { continue }
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
            } else if creature.bodyMass > 1 {
                foodSources.append(FoodSource(position: creature.position,
                                              energyValue: creature.bodyMass * 0.7,
                                              type: .corpse,
                                              spawnedAt: tickCount))
                corpseCount += 1
            }
        }
        creatures = survivors
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
            guard $0.type == .corpse, tickCount - $0.spawnedAt > 600 else { return false }
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
