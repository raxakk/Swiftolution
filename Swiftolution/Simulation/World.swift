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

        var angleToCreature: Float = 0
        var distToCreature:  Float = 1
        if let other = nearestCreature(to: creature, within: creature.sightRadius) {
            let dx = Float(other.position.x - creature.position.x)
            let dy = Float(other.position.y - creature.position.y)
            let relAngle = normalizeAngle(atan2(dy, dx) - creature.heading)
            angleToCreature = relAngle / .pi
            distToCreature  = Float(distance(creature.position, other.position)) / sightR
        }

        return SensorInput(
            angleToFood:        angleToFood,
            distanceToFood:     distToFood,
            angleToCreature:    angleToCreature,
            distanceToCreature: distToCreature,
            ownEnergy:          creature.energy / creature.maxEnergy,
            ownAge:             Float(creature.age) / Float(creature.dna.maxAge)
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
                  attacker.dna.aggression > 0.2 else { continue }

            guard let victim = nearestCreature(to: attacker, within: attacker.attackRadius) else { continue }

            // Größenvorteil: Angreifer muss mindestens 60% der Opfer-Größe haben
            guard attacker.dna.size >= victim.dna.size * 0.6 else { continue }

            // Schaden abhängig von Größe und Aggression des Angreifers
            let damage = (attacker.dna.size * 0.6 + attacker.dna.aggression * 0.4) * 50

            // Nur so viel stehlen wie das Opfer noch hat (nach bisher gesammelten Schäden)
            let victimCurrentEnergy = victim.energy + (energyDeltas[victim.id] ?? 0)
            let stolen = min(damage, max(0, victimCurrentEnergy))

            energyDeltas[attacker.id, default: 0] += stolen * 0.45  // Kampf ist ineffizient: Fleischfresser brauchen viel Beute
            energyDeltas[victim.id,   default: 0] -= stolen
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
                creature.eat(food: food)
                return true
            }
        }
    }

    // MARK: - Tod

    private func checkDeaths() {
        creatures.removeAll { !$0.isAlive }
    }

    // MARK: - Fortpflanzung

    private func reproduceCreatures() {
        guard creatures.count < maxPopulation else { return }

        var newborns: [Creature] = []
        for creature in creatures where creature.canReproduce {
            let childDNA = creature.dna.mutated(rate: mutationRate, strength: mutationStrength)
            let child    = Creature(dna: childDNA, position: creature.position)
            creature.energy -= creature.maxEnergy * 0.4
            newborns.append(child)
            if creatures.count + newborns.count >= maxPopulation { break }
        }

        if !newborns.isEmpty {
            creatures.append(contentsOf: newborns)
            totalBirths += newborns.count
            generation  += 1
        }
    }

    // MARK: - Nahrungswachstum

    private func growFood() {
        // Logistisches Wachstum: schnell wenn Nahrung knapp, langsam wenn Kapazität fast voll.
        // Formel: newItems = rate × (1 − aktuelleNahrung/maxFood) × maxFood
        let fillRatio   = Double(foodSources.count) / Double(maxFood)
        let newItems    = Int((foodGrowthRate * (1.0 - fillRatio) * Double(maxFood)).rounded())
        for _ in 0..<max(0, newItems) {
            foodSources.append(FoodSource(position: randomPosition()))
        }
    }

    // MARK: - Hilfsmethoden

    func randomPosition() -> CGPoint {
        CGPoint(
            x: CGFloat.random(in: 0..<size.width),
            y: CGFloat.random(in: 0..<size.height)
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
