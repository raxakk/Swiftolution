import Foundation
import CoreGraphics

final class Creature {

    // MARK: - Identity

    let id = UUID()
    var dna: DNA
    var brain: NeuralNetwork

    // MARK: - Position & movement

    var position: CGPoint
    var heading: Float = Float.random(in: 0..<(2 * .pi))
    // cos/sin of the heading, cached: every creature is a neighbour of many others, and the
    // herding/approach sensors read these values n times per tick.
    private(set) var headingCos: Float = 0
    private(set) var headingSin: Float = 0

    // MARK: - State

    var energy: Float
    // Body mass: accumulated nutritional value (muscle, fat), separate from the metabolic
    // battery but not outside it. Energy buys mass while well fed, and catabolism sells it
    // back at a loss while starving, so a corpse is worth only what was paid into it.
    // It determines how nourishing the corpse will be.
    var bodyMass: Float
    // Generation of descent: founders are 0, every child is one past its eldest parent. It is
    // what "Generation" in the UI and the headless table now means (the world reports the mean
    // over the living population), rather than a count of ticks in which something was born.
    let generation: Int
    var age: Int = 0
    var isAlive: Bool { energy > 0 }

    // Interoception: a moving average of the energy gained per tick (EMA, alpha = 0.05).
    // A high rate means a good patch; a low one means barren ground or the wrong diet.
    var recentFeedingRate: Float = 0
    private var energyGainedThisTick: Float = 0

    // Senescence: sets in at 70% of the genetic lifespan and keeps climbing without bound.
    // At maxAge it costs +50% energy and -30% speed, and it rises from there until the
    // creature dies of energy starvation.
    var senescence: Float {
        let progress = Float(age) / Float(dna.maxAge)
        return max(0, (progress - 0.7) / 0.3)
    }
    // Working memory carried from one tick to the next: the network's own hidden activations,
    // fed back in as inputs. Starts empty at birth, so nothing is inherited but the weights
    // that decide what to write into it.
    var brainMemory = SIMD4<Float>()

    // Internal clock in [-1,1]. The only input that changes with nothing happening around the
    // creature, which is what lets behaviour run without an external trigger.
    var oscillator: Float {
        sin(2 * .pi * Float(age) / dna.oscillatorPeriod)
    }

    var lastAction: ActionOutput?
    // The last perception, only filled in when World.sensorRecording is on (tracing and
    // diagnostics). It is what makes a network decision explainable: perception -> action.
    var lastSensors: SensorInput?
    // Damage taken this tick, per attacker. Cleared at the start of every tick, so it holds
    // exactly the attacks that led to this tick's deaths. The kill bonus is split along these
    // shares: with several attackers on one victim, whoever did the work gets paid for it.
    // The references are weak so that two creatures killing each other cannot keep each other
    // alive in memory after both leave the population.
    struct AttackRecord {
        weak var attacker: Creature?
        var damage: Float
    }
    private(set) var attacksTaken: [AttackRecord] = []
    var wasAttackedThisTick: Bool { !attacksTaken.isEmpty }

    func recordAttack(from attacker: Creature, damage: Float) {
        attacksTaken.append(AttackRecord(attacker: attacker, damage: damage))
    }

    // MARK: - Values derived from DNA

    var eatRadius:    CGFloat { CGFloat(dna.size * 8 + 4) }
    var sightRadius:  CGFloat { CGFloat((dna.sightRadius * 120 + 40) * max(0.3, 1 - senescence * 0.4)) }
    // Turn rate in rad/tick; senescence makes a creature more sluggish
    var maxTurnRate:  Float   { (dna.turnRate * 0.35 + 0.05) * max(0.3, 1 - senescence * 0.4) }
    // Sight angle in radians: gene=0 -> 120 degrees (2 pi / 3), gene=1 -> 360 (2 pi).
    // A wide angle costs a lot of energy; a narrow cone is cheap but blind to the sides and rear.
    var sightAngle:   CGFloat {
        let minAngle: CGFloat = 2 * .pi / 3   // 120 degrees minimum
        return CGFloat(dna.sightAngle) * (2 * .pi - minAngle) + minAngle
    }
    var attackRadius:        CGFloat { CGFloat(dna.size * 14 + dna.aggression * 10 + 4) }
    // Smell radius: omnidirectional, independent of the sight cone
    var olfactionSmellRadius: CGFloat { CGFloat(dna.olfaction * 170 + 30) }
    // Landscape horizon: large terrain features (lakes, forest edges) are recognizable from
    // much farther away than a single item of food. Without this factor, terrain perception
    // (40-160 px) would sit far below the scale of the biome regions (~600 px): a creature
    // would stand in the middle of uniform terrain and never receive a directional signal.
    // It stays tied to the sight gene, so range remains evolvable and costly.
    static let terrainSightFactor: CGFloat = 4
    var terrainSightRadius: CGFloat { sightRadius * Creature.terrainSightFactor }
    var maxEnergy:    Float   { dna.size * 150 + 80 }
    var maxBodyMass:  Float   { dna.size * 60 + 20 }
    var hiddenCount:  Int     { Creature.hiddenCount(for: dna.brainSize) }

    // brainSize -> neuron count, in equally wide buckets. Truncating over the span instead
    // (min + Int(gene * span)) left the largest brain reachable only at gene == 1.0 exactly,
    // i.e. as a point mass produced by the mutation clamp rather than by selection.
    static func hiddenCount(for brainSize: Float) -> Int {
        let buckets = NeuralNetwork.maxHiddenCount - NeuralNetwork.minHiddenCount + 1
        let bucket  = min(buckets - 1, Int(brainSize * Float(buckets)))
        return NeuralNetwork.minHiddenCount + max(0, bucket)
    }

    var maxSpeed:     Float   { dna.speed * 2.5 + 0.3 }

    var canReproduce: Bool {
        // The reproductionThreshold gene [0,1] scaled to 55%-85% of maximum energy
        let threshold = dna.reproductionThreshold * 0.3 + 0.55
        // Sexual maturity: 10% of the genetic lifespan, so it scales with the life strategy
        return energy >= maxEnergy * Float(threshold) && age > dna.maxAge / 10
    }

    // MARK: - Body mass economy

    // Mass is an investment, not free matter: building it is paid out of `energy` and burning
    // it back returns less than was paid, which is what makes catabolism a last resort rather
    // than a free second battery.
    static let massBuildCost:        Float = 1.25   // energy spent per unit of mass built
    static let massCatabolismYield:  Float = 0.5    // energy recovered per unit of mass burned
    static let massGrowthPerTick:    Float = 0.05
    static let massCatabolismPerTick: Float = 0.3
    // A newborn's starter body, as a share of its own maximum. The rest has to be earned by
    // feeding, so corpse value carries a signal about how well an individual actually lived.
    static let birthMassFraction: Float = 0.25
    // How much of the birth endowment may be spent on that starter body. The remainder stays
    // metabolic energy, so a cheaply fed litter starts smaller rather than starting in debt.
    static let birthMassShare:    Float = 0.25

    // MARK: - Init

    init(dna: DNA, position: CGPoint, generation: Int = 0) {
        self.dna        = dna
        self.position   = position
        self.generation = generation
        self.energy     = dna.size * 80 + 40
        // A starter body, proportional to body size but well short of the cap. Founders get it
        // for free (they are the world's initial seed); offspring buy theirs in endow(with:).
        self.bodyMass   = (dna.size * 60 + 20) * Creature.birthMassFraction
        self.brain      = NeuralNetwork(weights: dna.neuralWeights(),
                                        hiddenCount: Creature.hiddenCount(for: dna.brainSize))
        self.headingCos = cos(heading)
        self.headingSin = sin(heading)
    }

    // MARK: - Tick

    func tick() {
        age += 1
        attacksTaken.removeAll(keepingCapacity: true)
        recentFeedingRate = recentFeedingRate * 0.95 + energyGainedThisTick * 0.05
        energyGainedThisTick = 0
        consumeEnergy()
    }

    func apply(output: ActionOutput, in world: World) {
        lastAction = output

        heading += (output.turnAngle - 0.5) * 2 * maxTurnRate
        headingCos = cos(heading)
        headingSin = sin(heading)

        // The biome underfoot slows movement (sand, mire). Neutral (1.0) when biomes are off.
        let biomeSpeedFactor = world.biome(at: position).speedFactor
        let effectiveMaxSpeed = maxSpeed * max(0.1, 1 - senescence * 0.3) * biomeSpeedFactor
        let speed = output.speed * effectiveMaxSpeed

        // Target position with toroidal wrap-around (the world edges join up)
        let newX = (position.x + CGFloat(headingCos * speed) + world.size.width)
            .truncatingRemainder(dividingBy: world.size.width)
        let newY = (position.y + CGFloat(headingSin * speed) + world.size.height)
            .truncatingRemainder(dividingBy: world.size.height)

        // Impassable biomes (water) block movement outright, a genuine barrier. With biomes
        // off everything is grassland, hence passable, and behaviour is unchanged.
        if world.biome(at: CGPoint(x: newX, y: newY)).isPassable {
            position.x = newX
            position.y = newY
        }
    }

    func digestibility(for food: FoodSource) -> Float {
        switch food.type {
        case .plant:
            // Herbivore enzymes: aggression=0 -> 60%, aggression=1 -> 18%
            return (1.0 - dna.aggression * 0.7) * 0.6
        case .corpse:
            // Carrion as a stepping stone: aggression=0 -> 20%, 0.5 -> 50%, 1 -> 80%.
            // The 0.2 floor makes scavenging worthwhile even for omnivores and creates a
            // continuous fitness gradient herbivore -> scavenger -> hunter. Without it the two
            // strategies are separated by a valley that only large mutations can cross.
            return 0.2 + dna.aggression * 0.60
        }
    }

    func eat(food: FoodSource, plantToxinFactor: Float = 0, plantToxinThreshold: Float = 0.5) {
        let d = digestibility(for: food)
        var gain = food.energyValue * d

        if food.type == .plant {
            // Plants defend themselves chemically (tannins, alkaloids, fibre). Plant-adapted
            // animals (aggression below the threshold) detoxify cheaply and pay nothing.
            // Above it a carnivore takes on a toxin load proportional to how specialized it is
            // times how much it ate, until eating plants costs net energy. Meat stays toxin
            // free, so the carrion stepping stone (see digestibility) is left fully intact for
            // omnivores on the way up.
            let excess = max(0, dna.aggression - plantToxinThreshold)
            gain -= excess * plantToxinFactor * food.energyValue
        }

        if gain > 0 {
            energy = min(energy + gain, maxEnergy)
            energyGainedThisTick += gain
        } else {
            // Net loss: the toxin load exceeds the nutritional value (poisoning)
            energy = max(0, energy + gain)
        }
    }

    // The birth endowment the parents paid, split into a starter body and metabolic energy.
    // Nothing is created here: the mass is bought out of the endowment at the same conversion
    // cost growth pays later, so a child never carries more than its parents put in.
    func endow(with endowment: Float) {
        let affordable = endowment * Creature.birthMassShare / Creature.massBuildCost
        bodyMass = max(0, min(maxBodyMass * Creature.birthMassFraction, affordable))
        energy   = max(0, endowment - bodyMass * Creature.massBuildCost)
    }

    // MARK: - Private

    private func consumeEnergy() {
        let baseCost:       Float = 0.08
        // Static maintenance cost, scaled quadratically (gene^2 x 2 x the old constant), so
        // gene=0.5 matches the old linear cost and gene=1.0 is twice as expensive. This forces
        // specialization: maxing out everything is disproportionately expensive.
        let s = dna.size;       let sizeCost:       Float = s * s * 0.12
        // Aggression is a behavioural/muscular trait: its real cost is paid when attacking
        // (aggression x 2 per attack in World.attackCreatures), not as high standing rent. The
        // lower coefficient (0.07 instead of 0.18) eases the double quadratic tax that hunters,
        // who need both size AND aggression, would otherwise pay permanently.
        let ag = dna.aggression; let aggressionCost: Float = ag * ag * 0.07
        let br = dna.brainSize;  let brainCost:      Float = br * br * 0.04
        let sr = dna.sightRadius; let sa = dna.sightAngle
        let sightCost:      Float = sr * sr * 0.024 + sa * sa * 0.030
        let ol = dna.olfaction;  let olfactionCost: Float = ol * ol * 0.020
        // Dynamic costs stay linear: they depend on actual behaviour, not on the gene alone.
        let speedCost:      Float = (lastAction?.speed ?? 0) * maxSpeed * 0.025 * (1 + dna.size * 0.8)
        let actualTurn      = abs((lastAction?.turnAngle ?? 0.5) - 0.5) * 2   // [0,1]
        let turnCost:       Float = actualTurn * maxTurnRate * 0.08
        let baseCosts = baseCost + sizeCost + speedCost + aggressionCost + brainCost + sightCost + olfactionCost + turnCost
        energy -= baseCosts * (1 + senescence * 0.5)

        // Well fed (>60%): buy body mass out of energy. Starving (<20%): burn it back at a
        // conversion loss. Both directions run through `energy`, so mass stays inside the
        // energy accounting instead of appearing beside it: a corpse is worth what was paid
        // into it, minus what starvation already burned.
        if energy > maxEnergy * 0.6 {
            // Never spend past the well-fed line, so growth cannot starve its owner.
            let affordable = (energy - maxEnergy * 0.6) / Creature.massBuildCost
            let grown = min(Creature.massGrowthPerTick, maxBodyMass - bodyMass, affordable)
            if grown > 0 {
                bodyMass += grown
                energy   -= grown * Creature.massBuildCost
            }
        } else if energy < maxEnergy * 0.2 {
            let burned = min(Creature.massCatabolismPerTick, bodyMass)
            if burned > 0 {
                bodyMass -= burned
                energy    = min(maxEnergy, energy + burned * Creature.massCatabolismYield)
            }
        }
    }
}

// MARK: - Equatable

extension Creature: Equatable {
    static func == (lhs: Creature, rhs: Creature) -> Bool {
        lhs.id == rhs.id
    }
}
