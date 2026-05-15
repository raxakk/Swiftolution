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

    var foodGrowthRate:   Double = 0.03   // logistische Rate: Anteil der freien Kapazität pro Tick
    var maxFood:          Int    = 250    // Kapazitätsgrenze (konfigurierbar)
    var mutationRate:     Float  = 0.05
    var mutationStrength: Float  = 0.10
    let maxPopulation:    Int    = 300

    init(size: CGSize = CGSize(width: 800, height: 600)) {
        self.size = size
    }

    // MARK: - Setup

    func populate(creatures creatureCount: Int, food foodCount: Int) {
        for _ in 0..<creatureCount {
            creatures.append(Creature(dna: DNA.random(), position: randomPosition()))
        }
        for _ in 0..<foodCount {
            foodSources.append(FoodSource(position: randomPosition()))
        }
    }

    // MARK: - Simulations-Tick

    func tick() {
        tickCount += 1
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
        for creature in creatures {
            let input  = sense(for: creature)
            let output = creature.brain.activate(inputs: input)
            creature.apply(output: output, in: self)
            creature.tick()
        }
    }

    // Baut den Sensor-Input für ein Lebewesen auf.
    // Nur Objekte innerhalb des Sichtradius werden wahrgenommen.
    private func sense(for creature: Creature) -> SensorInput {
        let sightR = Float(creature.sightRadius)

        var angleToFood:     Float = 0
        var distToFood:      Float = 1
        if let food = nearestFood(to: creature.position, within: creature.sightRadius) {
            let dx = Float(food.position.x - creature.position.x)
            let dy = Float(food.position.y - creature.position.y)
            let relAngle = normalizeAngle(atan2(dy, dx) - creature.heading)
            angleToFood = relAngle / .pi                                           // → [-1, 1]
            distToFood  = Float(distance(creature.position, food.position)) / sightR
        }

        var angleToCreature:    Float = 0
        var distToCreature:     Float = 1
        var nearestAggression:  Float = 0
        if let other = nearestCreature(to: creature, within: creature.sightRadius) {
            let dx = Float(other.position.x - creature.position.x)
            let dy = Float(other.position.y - creature.position.y)
            let relAngle = normalizeAngle(atan2(dy, dx) - creature.heading)
            angleToCreature   = relAngle / .pi
            distToCreature    = Float(distance(creature.position, other.position)) / sightR
            nearestAggression = other.dna.aggression
        }

        // Lokale Dichte: Anzahl Artgenossen im Nahbereich, normalisiert auf [0,1].
        // Gibt dem NN die Möglichkeit, überfüllte Bereiche zu meiden.
        let densityRadius: CGFloat = 55
        let nearbyCount   = creatures.filter { $0 != creature && distance($0.position, creature.position) < densityRadius }.count
        let localDensity  = min(Float(nearbyCount) / 8.0, 1.0)

        return SensorInput(
            angleToFood:                 angleToFood,
            distanceToFood:              distToFood,
            angleToCreature:             angleToCreature,
            distanceToCreature:          distToCreature,
            ownEnergy:                   creature.energy / creature.maxEnergy,
            ownAge:                      Float(creature.age) / Float(creature.dna.maxAge),
            localDensity:                localDensity,
            aggressionOfNearestCreature: nearestAggression
        )
    }

    // MARK: - Angriff

    private func attackCreatures() {
        // Alle Angriffe werden zuerst gesammelt und dann gleichzeitig angewendet,
        // damit die Reihenfolge im Array keinen unfairen Vorteil bringt.
        var energyDeltas: [UUID: Float] = [:]

        for attacker in creatures {
            guard let action = attacker.lastAction,
                  action.wantsToAttack > 0.5,
                  attacker.dna.aggression > 0.45 else { continue }  // nur echte Räuber greifen an

            guard let victim = nearestCreature(to: attacker, within: attacker.attackRadius) else { continue }

            // Größenvorteil: Angreifer muss mindestens 60% der Opfer-Größe haben
            guard attacker.dna.size >= victim.dna.size * 0.6 else { continue }

            // Schaden abhängig von Größe und Aggression des Angreifers
            let rawDamage = (attacker.dna.size * 0.6 + attacker.dna.aggression * 0.4) * 50
            // Verteidigung: Fleischfresser sind kampferfahrener — bis zu 50% Schadensreduktion
            let defense = victim.dna.aggression * 0.5
            let damage  = rawDamage * (1 - defense)

            // Nur so viel stehlen wie das Opfer noch hat (nach bisher gesammelten Schäden)
            let victimCurrentEnergy = victim.energy + (energyDeltas[victim.id] ?? 0)
            let stolen = min(damage, max(0, victimCurrentEnergy))

            // Angriff kostet Energie — Jagd muss sich lohnen, sonst ist sie ruinös
            energyDeltas[attacker.id, default: 0] -= attacker.dna.aggression * 5
            energyDeltas[attacker.id, default: 0] += stolen * 0.45
            energyDeltas[victim.id,   default: 0] -= stolen

            // Die 55% die beim Kampf "verspritzt" werden erscheinen als Nahrung am Kampfort.
            let waste = stolen * 0.55
            if waste > 3 {
                let midPoint = CGPoint(x: (attacker.position.x + victim.position.x) / 2,
                                       y: (attacker.position.y + victim.position.y) / 2)
                foodSources.append(FoodSource(position: midPoint, energyValue: waste, type: .waste, spawnedAt: tickCount))
            }
        }

        for creature in creatures {
            guard let delta = energyDeltas[creature.id] else { continue }
            creature.energy = max(0, min(creature.energy + delta, creature.maxEnergy))
        }
    }

    // MARK: - Fressen

    private func feedCreatures() {
        for creature in creatures {
            foodSources.removeAll { food in
                guard distance(creature.position, food.position) < creature.eatRadius else { return false }
                if food.type == .plant && creature.dna.aggression > 0.45 { return false }
                creature.eat(food: food)
                return true
            }
        }
    }

    // MARK: - Tod

    private func checkDeaths() {
        for creature in creatures where !creature.isAlive {
            // Körpermasse zerfällt zu Nahrung — unabhängig davon wie viel Energie
            // das Lebewesen zuletzt hatte (der Körper existiert ja trotzdem).
            let bodyEnergy = creature.dna.size * 45 + 12
            foodSources.append(FoodSource(position: creature.position,
                                          energyValue: bodyEnergy,
                                          type: .corpse,
                                          spawnedAt: tickCount))
        }
        creatures.removeAll { !$0.isAlive }
    }

    // MARK: - Fortpflanzung

    private func reproduceCreatures() {
        guard creatures.count < maxPopulation else { return }

        var mated    = Set<UUID>()
        var newborns = [Creature]()

        // Nur Lebewesen die Energie haben UND deren NN reproduzieren "will"
        let candidates = creatures
            .filter { $0.canReproduce && ($0.lastAction?.wantsToReproduce ?? 0) > 0.5 }
            .shuffled()

        for parent in candidates {
            guard !mated.contains(parent.id) else { continue }
            guard creatures.count + newborns.count < maxPopulation else { break }

            let partner = candidates.first {
                $0 != parent
                && !mated.contains($0.id)
                && distance($0.position, parent.position) < 40
                && abs($0.dna.aggression - parent.dna.aggression) < 0.3   // Artkompatibilität
            }

            if let partner {
                // Sexuelle Fortpflanzung: Gene beider Eltern werden kombiniert
                mated.insert(parent.id)
                mated.insert(partner.id)
                let midPoint = CGPoint(x: (parent.position.x + partner.position.x) / 2,
                                       y: (parent.position.y + partner.position.y) / 2)
                let childDNA = parent.dna.crossed(with: partner.dna)
                                         .mutated(rate: mutationRate, strength: mutationStrength)
                newborns.append(Creature(dna: childDNA, position: dispersedPosition(from: midPoint)))
                parent.energy  -= parent.maxEnergy  * 0.25
                partner.energy -= partner.maxEnergy * 0.25
            } else {
                // Asexuell als Fallback — teurer, da kein genetischer Vorteil
                mated.insert(parent.id)
                let childDNA = parent.dna.mutated(rate: mutationRate, strength: mutationStrength)
                newborns.append(Creature(dna: childDNA, position: dispersedPosition(from: parent.position)))
                parent.energy -= parent.maxEnergy * 0.4
            }
        }

        if !newborns.isEmpty {
            creatures.append(contentsOf: newborns)
            totalBirths += newborns.count
            generation  += 1
        }
    }

    // MARK: - Nahrungswachstum

    private func growFood() {
        // Nur Pflanzennahrung zählt zur Kapazitätsgrenze —
        // Leichen und Kampfabfall blockieren das Pflanzenwachstum nicht.
        let plantCount = foodSources.filter { $0.type == .plant }.count
        let fillRatio  = Double(plantCount) / Double(maxFood)
        let newItems   = Int((foodGrowthRate * (1.0 - fillRatio) * Double(maxFood)).rounded())
        for _ in 0..<max(0, newItems) {
            foodSources.append(FoodSource(position: randomPosition()))
        }
    }

    private func decayFood() {
        // Nährstoffkreislauf: Leichen und Kampfabfall zersetzen sich zu pflanzlicher Nahrung.
        // Energie bleibt vollständig im System — sie wechselt nur die Form.
        for i in foodSources.indices {
            let food = foodSources[i]
            let decayAge: Int
            switch food.type {
            case .plant:   continue
            case .corpse:  decayAge = 600
            case .waste:   decayAge = 200
            }
            guard tickCount - food.spawnedAt > decayAge else { continue }
            foodSources[i] = FoodSource(position: food.position, type: .plant)
        }
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
        foodSources
            .filter { distance($0.position, point) < radius }
            .min(by: { distance($0.position, point) < distance($1.position, point) })
    }

    func nearestCreature(to creature: Creature, within radius: CGFloat) -> Creature? {
        creatures
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
