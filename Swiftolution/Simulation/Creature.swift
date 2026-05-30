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
    // Körpermasse: akkumulierter Nährwert (Muskeln, Fett) — unabhängig vom metabolischen Akku.
    // Steigt wenn gut ernährt, baut sich bei Hunger durch Muskelkatabolismus ab.
    // Bestimmt den Nährwert der Leiche.
    var bodyMass: Float
    var age: Int = 0
    var isAlive: Bool { energy > 0 }

    // Interozeption: gleitender Durchschnitt der pro Tick gewonnenen Energie (EMA, α=0.05).
    // Hohe Rate → Zone gut, niedrige Rate → Zone karg oder falsche Diät.
    var recentFeedingRate: Float = 0
    private var energyGainedThisTick: Float = 0

    // Seneszenz: steigt ab 70% der genetischen Lebensspanne, läuft unkontrolliert weiter.
    // Bei maxAge = 1.0 → +50% Energiekosten, -30% Speed. Danach weiter steigend → Tod durch Energiemangel.
    var senescence: Float {
        let progress = Float(age) / Float(dna.maxAge)
        return max(0, (progress - 0.7) / 0.3)
    }
    var lastAction: ActionOutput?
    weak var lastAttacker: Creature?

    // MARK: - Abgeleitete Werte aus DNA

    var eatRadius:    CGFloat { CGFloat(dna.size * 8 + 4) }
    var sightRadius:  CGFloat { CGFloat((dna.sightRadius * 120 + 40) * max(0.3, 1 - senescence * 0.4)) }
    // Drehgeschwindigkeit in rad/Tick; Seneszenz macht Kreatur träger
    var maxTurnRate:  Float   { (dna.turnRate * 0.35 + 0.05) * max(0.3, 1 - senescence * 0.4) }
    // Sichtwinkel in Radian: gene=0 → 120° (2π/3), gene=1 → 360° (2π)
    // Breiter Winkel = hohe Energiekosten; schmaler Kegel = günstig, aber blind nach hinten/seitlich.
    var sightAngle:   CGFloat {
        let minAngle: CGFloat = 2 * .pi / 3   // 120° Minimum
        return CGFloat(dna.sightAngle) * (2 * .pi - minAngle) + minAngle
    }
    var attackRadius:        CGFloat { CGFloat(dna.size * 14 + dna.aggression * 10 + 4) }
    // Geruchsradius: omnidirektional, unabhängig vom Sichtkegel
    var olfactionSmellRadius: CGFloat { CGFloat(dna.olfaction * 170 + 30) }
    var maxEnergy:    Float   { dna.size * 150 + 80 }
    var hiddenCount:  Int     {
        NeuralNetwork.minHiddenCount +
        Int(dna.brainSize * Float(NeuralNetwork.maxHiddenCount - NeuralNetwork.minHiddenCount))
    }
    var maxSpeed:     Float   { dna.speed * 2.5 + 0.3 }

    var canReproduce: Bool {
        // reproductionThreshold-Gen [0,1] skaliert auf 55%–85% der maximalen Energie
        let threshold = dna.reproductionThreshold * 0.3 + 0.55
        // Geschlechtsreife: 10% der genetischen Lebensspanne (skaliert mit Strategie)
        return energy >= maxEnergy * Float(threshold) && age > dna.maxAge / 10
    }

    // MARK: - Init

    init(dna: DNA, position: CGPoint) {
        self.dna      = dna
        self.position = position
        self.energy   = dna.size * 80 + 40
        self.bodyMass = dna.size * 60 + 20   // Startmasse proportional zur Körpergröße
        let hc = NeuralNetwork.minHiddenCount +
            Int(dna.brainSize * Float(NeuralNetwork.maxHiddenCount - NeuralNetwork.minHiddenCount))
        self.brain    = NeuralNetwork(weights: dna.neuralWeights(), hiddenCount: hc)
    }

    // MARK: - Tick

    func tick() {
        age += 1
        lastAttacker = nil
        recentFeedingRate = recentFeedingRate * 0.95 + energyGainedThisTick * 0.05
        energyGainedThisTick = 0
        consumeEnergy()
    }

    func apply(output: ActionOutput, in world: World) {
        lastAction = output

        heading += (output.turnAngle - 0.5) * 2 * maxTurnRate

        let effectiveMaxSpeed = maxSpeed * max(0.1, 1 - senescence * 0.3)
        let speed = output.speed * effectiveMaxSpeed
        position.x += CGFloat(cos(heading) * speed)
        position.y += CGFloat(sin(heading) * speed)

        // Toroidal wrap-around (Welt-Kanten verbinden sich)
        position.x = (position.x + world.size.width).truncatingRemainder(dividingBy: world.size.width)
        position.y = (position.y + world.size.height).truncatingRemainder(dividingBy: world.size.height)
    }

    func digestibility(for food: FoodSource) -> Float {
        switch food.type {
        case .plant:
            // Pflanzenfresser-Enzyme: aggression=0 → 60 %, aggression=1 → 18 %
            return (1.0 - dna.aggression * 0.7) * 0.6
        case .corpse:
            // Fleischfresser-Enzyme: aggression=0 → 0 %, aggression=0.5 → 40 %, aggression=1 → 80 %
            return dna.aggression * 0.80
        }
    }

    func eat(food: FoodSource) {
        let d = digestibility(for: food)
        if d < 0.10 {
            // Zu fremdartige Nahrung: Verdauungsversuch kostet Energie (Übelkeit, Enzymverschwendung)
            energy = max(0, energy - 5)
        } else {
            let gain = food.energyValue * d
            energy = min(energy + gain, maxEnergy)
            energyGainedThisTick += gain
        }
    }

    // MARK: - Privates

    private func consumeEnergy() {
        let baseCost:       Float = 0.08
        // Statische Wartungskosten: quadratisch skaliert (gen² × 2 × alte_Konstante).
        // gene=0.5 → identisch zu vorher; gene=1.0 → doppelt so teuer.
        // Erzwingt Spezialisierung — alles auf Maximum ist überproportional teuer.
        let s = dna.size;       let sizeCost:       Float = s * s * 0.12
        let ag = dna.aggression; let aggressionCost: Float = ag * ag * 0.18
        let br = dna.brainSize;  let brainCost:      Float = br * br * 0.04
        let sr = dna.sightRadius; let sa = dna.sightAngle
        let sightCost:      Float = sr * sr * 0.024 + sa * sa * 0.030
        let ol = dna.olfaction;  let olfactionCost: Float = ol * ol * 0.020
        // Dynamische Kosten bleiben linear — abhängig vom tatsächlichen Verhalten, nicht nur vom Gen.
        let speedCost:      Float = (lastAction?.speed ?? 0) * maxSpeed * 0.025 * (1 + dna.size * 0.8)
        let actualTurn      = abs((lastAction?.turnAngle ?? 0.5) - 0.5) * 2   // [0,1]
        let turnCost:       Float = actualTurn * maxTurnRate * 0.08
        let baseCosts = baseCost + sizeCost + speedCost + aggressionCost + brainCost + sightCost + olfactionCost + turnCost
        energy -= baseCosts * (1 + senescence * 0.5)

        // Gut ernährt (>60%): Körpermasse aufbauen. Verhungernd (<20%): Muskelkatabolismus.
        let maxBodyMass = dna.size * 60 + 20
        if energy > maxEnergy * 0.6 {
            bodyMass = min(maxBodyMass, bodyMass + 0.05)
        } else if energy < maxEnergy * 0.2 {
            bodyMass = max(0, bodyMass - 0.3)
        }
    }
}

// MARK: - Equatable

extension Creature: Equatable {
    static func == (lhs: Creature, rhs: Creature) -> Bool {
        lhs.id == rhs.id
    }
}
