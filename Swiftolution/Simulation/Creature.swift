import Foundation
import CoreGraphics

final class Creature {

    // MARK: - Identität

    let id = UUID()
    var dna: DNA
    var brain: NeuralNetwork

    // MARK: - Position & Bewegung

    var position: CGPoint
    var heading: Float = Float.random(in: 0..<(2 * .pi))

    // MARK: - Zustand

    var energy: Float
    var age: Int = 0
    var isAlive: Bool { energy > 0 && age < dna.maxAge }
    var lastAction: ActionOutput?

    // MARK: - Abgeleitete Werte aus DNA

    var eatRadius:    CGFloat { CGFloat(dna.size * 8 + 4) }
    var sightRadius:  CGFloat { CGFloat(dna.sightRadius * 120 + 40) }
    var attackRadius: CGFloat { CGFloat(dna.size * 14 + dna.aggression * 10 + 4) }
    var maxEnergy:    Float   { dna.size * 150 + 80 }
    var maxSpeed:     Float   { dna.speed * 2.5 + 0.3 }

    var canReproduce: Bool {
        // reproductionThreshold-Gen [0,1] skaliert auf 55%–85% der maximalen Energie
        let threshold = dna.reproductionThreshold * 0.3 + 0.55
        return energy >= maxEnergy * Float(threshold) && age > 60
    }

    // MARK: - Init

    init(dna: DNA, position: CGPoint) {
        self.dna      = dna
        self.position = position
        self.energy   = dna.size * 80 + 40
        self.brain    = NeuralNetwork(weights: dna.neuralWeights())
    }

    // MARK: - Tick

    func tick() {
        age += 1
        consumeEnergy()
    }

    func apply(output: ActionOutput, in world: World) {
        lastAction = output

        let maxTurnRate: Float = 0.2   // ~11° pro Tick
        // sigmoid-Output [0,1] auf [-maxTurn, +maxTurn] mappen
        heading += (output.turnAngle - 0.5) * 2 * maxTurnRate

        let speed = output.speed * maxSpeed
        position.x += CGFloat(cos(heading) * speed)
        position.y += CGFloat(sin(heading) * speed)

        // Toroidal wrap-around (Welt-Kanten verbinden sich)
        position.x = (position.x + world.size.width).truncatingRemainder(dividingBy: world.size.width)
        position.y = (position.y + world.size.height).truncatingRemainder(dividingBy: world.size.height)
    }

    func eat(food: FoodSource) {
        // Fleischfresser sind schlecht darin Pflanzen zu verdauen — echter Trade-off.
        // aggression=0 → 100% Effizienz, aggression=1 → 30% Effizienz
        let digestibility = 1.0 - dna.aggression * 0.7
        energy = min(energy + food.energyValue * digestibility, maxEnergy)
    }

    // MARK: - Privates

    private func consumeEnergy() {
        // Größere, schnellere und aggressivere Lebewesen verbrauchen mehr Energie
        let baseCost:       Float = 0.08
        let sizeCost:       Float = dna.size * 0.06
        let speedCost:      Float = dna.speed * 0.04
        let aggressionCost: Float = dna.aggression * 0.18   // Aggression ist teuer: nur rentabel wenn genug Beute vorhanden
        energy -= baseCost + sizeCost + speedCost + aggressionCost
    }
}

// MARK: - Equatable

extension Creature: Equatable {
    static func == (lhs: Creature, rhs: Creature) -> Bool {
        lhs.id == rhs.id
    }
}
