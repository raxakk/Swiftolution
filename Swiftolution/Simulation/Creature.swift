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
    var hiddenCount:  Int     {
        NeuralNetwork.minHiddenCount +
        Int(dna.brainSize * Float(NeuralNetwork.maxHiddenCount - NeuralNetwork.minHiddenCount))
    }
    // Herbivoren sind schneller — in der Natur evolut Beute zur Flucht, Räuber zur Ausdauer.
    // aggression=0 → +20% Geschwindigkeit, aggression=1 → -20% Geschwindigkeit
    var maxSpeed:     Float   { dna.speed * 2.5 * (1.2 - dna.aggression * 0.4) + 0.3 }

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
        let hc = NeuralNetwork.minHiddenCount +
            Int(dna.brainSize * Float(NeuralNetwork.maxHiddenCount - NeuralNetwork.minHiddenCount))
        self.brain    = NeuralNetwork(weights: dna.neuralWeights(), hiddenCount: hc)
    }

    // MARK: - Tick

    func tick() {
        age += 1
        consumeEnergy()
    }

    func apply(output: ActionOutput, in world: World, speedModifier: Float = 1.0) {
        lastAction = output

        let maxTurnRate: Float = 0.2
        heading += (output.turnAngle - 0.5) * 2 * maxTurnRate

        let speed = output.speed * maxSpeed * speedModifier
        position.x += CGFloat(cos(heading) * speed)
        position.y += CGFloat(sin(heading) * speed)

        // Toroidal wrap-around (Welt-Kanten verbinden sich)
        position.x = (position.x + world.size.width).truncatingRemainder(dividingBy: world.size.width)
        position.y = (position.y + world.size.height).truncatingRemainder(dividingBy: world.size.height)
    }

    func eat(food: FoodSource) {
        // Pflanzenfresser verdauen Pflanzen gut, Fleischfresser schlecht.
        // Leichen und Kampfabfall verdaut jeder gleich gut — Fleisch ist Fleisch.
        let digestibility: Float = food.type == .plant ? (1.0 - dna.aggression * 0.7) : 1.0
        energy = min(energy + food.energyValue * digestibility, maxEnergy)
    }

    // MARK: - Privates

    private func consumeEnergy() {
        let baseCost:       Float = 0.08
        let sizeCost:       Float = dna.size * 0.06
        let speedCost:      Float = (lastAction?.speed ?? 0) * maxSpeed * 0.025
        let aggressionCost: Float = dna.aggression * 0.09
        let brainCost:      Float = dna.brainSize * 0.02
        energy -= baseCost + sizeCost + speedCost + aggressionCost + brainCost
    }
}

// MARK: - Equatable

extension Creature: Equatable {
    static func == (lhs: Creature, rhs: Creature) -> Bool {
        lhs.id == rhs.id
    }
}
