//
//  SwiftolutionTests.swift
//  SwiftolutionTests
//
//  Created by raxakk on 14.05.26.
//

import Testing
import CoreGraphics
@testable import Swiftolution

struct SwiftolutionTests {

    // MARK: - DNA

    @Test func dnaGenesStayInRangeAfterMutation() {
        let original = DNA.random()
        for _ in 0..<20 {
            let mutated = original.mutated(rate: 1.0, strength: 0.5)
            #expect(mutated.genes.allSatisfy { (0...1).contains($0) })
        }
    }

    @Test func dnaCrossoverPreservesGeneCount() {
        let a = DNA.random()
        let b = DNA.random()
        let child = a.crossed(with: b)
        #expect(child.genes.count == a.genes.count)
    }

    @Test func dnaLitterSizeMapping() {
        var dna = DNA.random()
        // genes[10] = 0.0 → max(1, Int(0*3)+1) = 1
        dna.genes[10] = 0.0
        #expect(dna.litterSize == 1)
        // genes[10] = 1.0 → max(1, Int(3)+1) = 4
        dna.genes[10] = 1.0
        #expect(dna.litterSize == 4)
        // genes[10] = 0.5 → max(1, Int(1.5)+1) = 2
        dna.genes[10] = 0.5
        #expect(dna.litterSize == 2)
        // genes[10] = 0.667 → max(1, Int(2.0)+1) = 3
        dna.genes[10] = 0.667
        #expect(dna.litterSize == 3)
    }

    @Test func dnaMaxAgeMapping() {
        var dna = DNA.random()
        dna.genes[4] = 0.0
        #expect(dna.maxAge == 1)   // max(1, Int(0*1000)) = 1
        dna.genes[4] = 1.0
        #expect(dna.maxAge == 1000)
        dna.genes[4] = 0.5
        #expect(dna.maxAge == 500)
    }

    @Test func dnaNeuralWeightCountMatchesNetwork() {
        let dna = DNA.random()
        #expect(dna.neuralWeights().count == NeuralNetwork.totalWeightCount)
    }

    // MARK: - NeuralNetwork

    @Test func networkOutputsInSigmoidRange() {
        for _ in 0..<30 {
            let dna = DNA.random()
            let nn = NeuralNetwork(weights: dna.neuralWeights(), hiddenCount: 8)
            let input = SensorInput(
                angleToFood:          Float.random(in: -1...1),
                distanceToFood:       Float.random(in: 0...1),
                angleToCreature:      Float.random(in: -1...1),
                distanceToCreature:   Float.random(in: 0...1),
                ownEnergy:            Float.random(in: 0...1),
                localDensity:         Float.random(in: 0...1),
                approachVelocity:     Float.random(in: -1...1),
                nearestFoodType:      Float.random(in: 0...1),
                avgNearbyHeading:     Float.random(in: -1...1),
                nearestCreatureRed:   Float.random(in: 0...1),
                nearestCreatureGreen: Float.random(in: 0...1),
                nearestCreatureBlue:  Float.random(in: 0...1),
                visibleCreatureCount: Float.random(in: 0...1),
                ownSenescence:        Float.random(in: 0...1),
                visibleFoodCount:     Float.random(in: 0...1)
            )
            let out = nn.activate(inputs: input)
            #expect((0...1).contains(out.turnAngle))
            #expect((0...1).contains(out.speed))
            #expect((0...1).contains(out.wantsToReproduce))
            #expect((0...1).contains(out.wantsToAttack))
            #expect((0...1).contains(out.wantsToEat))
        }
    }

    @Test func networkHiddenCountClamped() {
        let dna = DNA.random()
        let tooSmall = NeuralNetwork(weights: dna.neuralWeights(), hiddenCount: 0)
        #expect(tooSmall.hiddenCount == NeuralNetwork.minHiddenCount)
        let tooLarge = NeuralNetwork(weights: dna.neuralWeights(), hiddenCount: 999)
        #expect(tooLarge.hiddenCount == NeuralNetwork.maxHiddenCount)
    }

    // MARK: - Creature

    @Test func senescenceZeroWhenYoung() {
        var dna = DNA.random()
        dna.genes[4] = 0.5  // maxAge = 500
        let creature = Creature(dna: dna, position: .zero)
        // age = 0 → progress = 0/500 = 0 → max(0, (0-0.7)/0.3) = 0
        #expect(creature.senescence == 0)
    }

    @Test func senescencePositivePastThreshold() {
        var dna = DNA.random()
        dna.genes[4] = 0.5  // maxAge = 500
        let creature = Creature(dna: dna, position: .zero)
        creature.age = 400  // 80% of 500 → (0.8-0.7)/0.3 ≈ 0.333
        #expect(creature.senescence > 0)
    }

    @Test func senescenceExactlyZeroAtThreshold() {
        var dna = DNA.random()
        dna.genes[4] = 0.5  // maxAge = 500
        let creature = Creature(dna: dna, position: .zero)
        creature.age = 350  // exactly 70% → senescence = max(0, 0) = 0
        #expect(creature.senescence == 0)
    }

    @Test func canReproduceRequiresMaturityAndEnergy() {
        var dna = DNA.random()
        dna.genes[4] = 0.1  // maxAge = 100 → maturity at age > 10
        dna.genes[5] = 0.0  // reproductionThreshold = 0 → energy threshold = 55%

        let creature = Creature(dna: dna, position: .zero)

        // Too young, regardless of energy
        creature.age    = 5
        creature.energy = creature.maxEnergy
        #expect(!creature.canReproduce)

        // Mature but energy below threshold
        creature.age    = 20
        creature.energy = creature.maxEnergy * 0.3
        #expect(!creature.canReproduce)

        // Mature and energy above threshold
        creature.energy = creature.maxEnergy * 0.8
        #expect(creature.canReproduce)
    }

    @Test func eatPlantHerbivoreDigestibility() {
        var dna = DNA.random()
        dna.genes[3] = 0.0  // pure herbivore — digestibility = (1-0*0.7)*0.6 = 0.6
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        let food = FoodSource(position: .zero, energyValue: 100, type: .plant)
        creature.eat(food: food)
        #expect(abs(creature.energy - 60) < 0.01)
    }

    @Test func eatPlantCarnivoreDigestibility() {
        var dna = DNA.random()
        dna.genes[3] = 1.0  // pure carnivore — digestibility = (1-1*0.7)*0.6 = 0.18
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        let food = FoodSource(position: .zero, energyValue: 100, type: .plant)
        creature.eat(food: food)
        #expect(abs(creature.energy - 18) < 0.01)
    }

    @Test func eatCorpseDigestibility() {
        var dna = DNA.random()
        dna.genes[3] = 1.0  // carnivore — digestibility = 0.80
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        let food = FoodSource(position: .zero, energyValue: 100, type: .corpse)
        creature.eat(food: food)
        #expect(abs(creature.energy - 80) < 0.01)
    }

    // MARK: - World: feeding rules (kontinuierliche Verdaulichkeit + Mindest-Threshold)

    @Test func herbivoreGetsZeroFromCorpse() {
        // aggression=0 → corpse digestibility = 0*0.80 = 0
        var dna = DNA.random()
        dna.genes[3] = 0.0
        let creature = Creature(dna: dna, position: .zero)
        #expect(creature.digestibility(for: FoodSource(position: .zero, energyValue: 100, type: .corpse)) == 0)
    }

    @Test func wantsToEatFalseSkipsFood() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[3] = 0.5
        let creature = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        let initialEnergy   = creature.energy
        creature.lastAction = ActionOutput(fromArray: [0.5, 0.0, 0.0, 0.0, 0.0])  // wantsToEat=0
        world.creatures     = [creature]
        world.foodSources   = [FoodSource(position: CGPoint(x: 100, y: 100),
                                          energyValue: 100, type: .plant)]
        world.plantCount    = 1
        world.rebuildGrid()
        world.feedCreatures()
        #expect(world.foodSources.count == 1)
        #expect(creature.energy == initialEnergy)
    }

    @Test func wrongFoodCausesEnergyPenalty() {
        // Verdaulichkeit < 10%: Fressen kostet Energie (Übelkeit)
        var dna = DNA.random(); dna.genes[3] = 0.0  // reiner Pflanzenfresser
        let creature = Creature(dna: dna, position: .zero)
        let startEnergy = creature.energy
        creature.eat(food: FoodSource(position: .zero, energyValue: 100, type: .corpse))
        #expect(creature.energy < startEnergy)
    }

    @Test func wrongFoodConsumedAndPenalizesInWorld() {
        // Kreatur frisst falsche Nahrung (wantsToEat=1, lastAction=nil) → Strafe, Nahrung weg
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[3] = 0.0  // Herbivore
        let creature = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        creature.energy = 50  // lastAction=nil → wantsToEat default=1
        world.creatures   = [creature]
        world.foodSources = [FoodSource(position: CGPoint(x: 100, y: 100),
                                        energyValue: 100, type: .corpse)]
        world.corpseCount = 1
        world.rebuildGrid()
        world.feedCreatures()
        #expect(world.foodSources.isEmpty)   // Leiche versucht verdaut → weg
        #expect(creature.energy < 50)        // Energie gesunken durch Strafkosten
    }

    @Test func omnivoreEatsBothFoodTypes() {
        // aggression=0.5 → plant: (1-0.35)*0.6=0.39; corpse: 0.5*0.80=0.40 — beide verwertbar
        var dna = DNA.random()
        dna.genes[3] = 0.5
        let creature = Creature(dna: dna, position: .zero)

        creature.energy = 0
        creature.eat(food: FoodSource(position: .zero, energyValue: 100, type: .plant))
        let plantGain = creature.energy
        #expect(plantGain > 0)

        creature.energy = 0
        creature.eat(food: FoodSource(position: .zero, energyValue: 100, type: .corpse))
        let corpseGain = creature.energy
        #expect(corpseGain > 0)

        // Omnivore ist in beiden Strategien schlechter als der jeweilige Spezialist
        #expect(plantGain  < 60)   // Herbivore (aggr=0) bekommt 60
        #expect(corpseGain < 80)   // Carnivore (aggr=1) bekommt 80
    }

    @Test func specialistOutperformsOmnivoreOnPreferredFood() {
        var herbDNA = DNA.random(); herbDNA.genes[3] = 0.0
        var omniDNA = DNA.random(); omniDNA.genes[3] = 0.5
        var carnDNA = DNA.random(); carnDNA.genes[3] = 1.0

        let herb = Creature(dna: herbDNA, position: .zero)
        let omni = Creature(dna: omniDNA, position: .zero)
        let carn = Creature(dna: carnDNA, position: .zero)
        herb.energy = 0; omni.energy = 0; carn.energy = 0

        let plant = FoodSource(position: .zero, energyValue: 100, type: .plant)
        herb.eat(food: plant); omni.eat(food: plant)
        #expect(herb.energy > omni.energy)   // Spezialist gewinnt bei Pflanzen

        omni.energy = 0; carn.energy = 0
        let corpse = FoodSource(position: .zero, energyValue: 100, type: .corpse)
        omni.eat(food: corpse); carn.eat(food: corpse)
        #expect(carn.energy > omni.energy)   // Spezialist gewinnt bei Leichen
    }

    // MARK: - World: energy conservation

    @Test func corpseEnergyDerivedFromBodyMass() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random()
        dna.genes[2] = 0.5  // size = 0.5 → bodyMass starts at 0.5*60+20 = 50
        let creature = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        let expectedCorpseEnergy = creature.bodyMass * 1.0
        creature.energy = -1  // force death (isAlive = energy > 0 → false)
        world.creatures = [creature]
        world.checkDeaths()
        #expect(world.foodSources.count == 1)
        #expect(world.foodSources[0].type == .corpse)
        #expect(abs(world.foodSources[0].energyValue - expectedCorpseEnergy) < 0.01)
        #expect(world.corpseCount == 1)
    }

    @Test func reproductionChildEnergyFromParentInvestment() {
        let world = World(size: CGSize(width: 500, height: 500))
        world.maxPopulation = 100
        world.mutationRate  = 0.0  // no mutation — child DNA identical to parents

        var dna = DNA.random()
        dna.genes[3]  = 0.2  // herbivore
        dna.genes[4]  = 0.1  // maxAge = 100 → maturity at age > 10
        dna.genes[5]  = 0.0  // reproductionThreshold = 0 → threshold = 55%
        dna.genes[10] = 0.0  // litterSize = 1

        let parent  = Creature(dna: dna, position: CGPoint(x: 250, y: 250))
        let partner = Creature(dna: dna, position: CGPoint(x: 250, y: 250))
        parent.age    = 20
        partner.age   = 20
        parent.energy  = parent.maxEnergy  * 0.9
        partner.energy = partner.maxEnergy * 0.9
        parent.lastAction  = ActionOutput(fromArray: [0.5, 0.0, 1.0, 0.0])
        partner.lastAction = ActionOutput(fromArray: [0.5, 0.0, 1.0, 0.0])

        let maxInvestment = parent.maxEnergy * 0.30 + partner.maxEnergy * 0.30

        world.creatures = [parent, partner]
        world.reproduceCreatures()

        let children = world.creatures.filter { $0 !== parent && $0 !== partner }
        #expect(!children.isEmpty)
        for child in children {
            #expect(child.energy <= maxInvestment + 0.01)
        }
    }

    @Test func growFoodRespectsCap() {
        let world = World(size: CGSize(width: 500, height: 500))
        world.maxFood       = 10
        world.foodGrowthRate = 1.0
        // Fill to capacity
        for _ in 0..<10 {
            world.foodSources.append(FoodSource(position: CGPoint(x: 100, y: 100)))
        }
        world.plantCount = 10
        world.growFood()
        #expect(world.plantCount == 10)
        #expect(world.foodSources.filter { $0.type == .plant }.count == 10)
    }

    @Test func growFoodAddsPlantsBelowCap() {
        let world = World(size: CGSize(width: 500, height: 500))
        world.maxFood        = 100
        world.foodGrowthRate = 1.0  // grows aggressively
        world.plantCount     = 0
        world.growFood()
        #expect(world.plantCount > 0)
        #expect(world.foodSources.filter { $0.type == .plant }.count == world.plantCount)
    }

    // MARK: - World: seasons

    @Test func seasonFactorOneWhenDisabled() {
        let world = World()
        world.seasonEnabled = false
        #expect(world.currentSeasonFactor == 1.0)
    }

    @Test func seasonFactorPeakAtSummer() {
        let world = World()
        world.seasonEnabled   = true
        world.seasonLength    = 100
        world.seasonAmplitude = 0.7
        world.tickCount       = 0   // t = 0/100 = 0 → cos(0) = 1 → factor = 1.0
        #expect(abs(world.currentSeasonFactor - 1.0) < 0.001)
    }

    @Test func seasonFactorTroughAtWinter() {
        let world = World()
        world.seasonEnabled   = true
        world.seasonLength    = 100
        world.seasonAmplitude = 0.7
        world.tickCount       = 50  // t = 0.5 → cos(π) = -1 → factor = 1-amplitude = 0.3
        #expect(abs(world.currentSeasonFactor - 0.3) < 0.001)
    }

    @Test func seasonFactorStaysInValidRange() {
        let world = World()
        world.seasonEnabled   = true
        world.seasonLength    = 200
        world.seasonAmplitude = 1.0  // maximum amplitude
        for tick in stride(from: 0, to: 200, by: 7) {
            world.tickCount = tick
            let factor = world.currentSeasonFactor
            #expect(factor >= 0.0 - 1e-6)
            #expect(factor <= 1.0 + 1e-6)
        }
    }

    // MARK: - World: population

    @Test func populateAllHerbivores() {
        // Urknall: alle Startkreaturen sind Pflanzenfresser (aggression ≤ 0.4)
        let world = World(size: CGSize(width: 1000, height: 1000))
        world.populate(creatures: 200, food: 0)
        let herbivores = world.creatures.filter { $0.dna.aggression <= 0.4 }
        #expect(herbivores.count == 200)
    }

    @Test func populatePlantCountMatchesFoodArgument() {
        let world = World(size: CGSize(width: 500, height: 500))
        world.populate(creatures: 10, food: 50)
        #expect(world.plantCount == 50)
        #expect(world.corpseCount == 0)
        #expect(world.foodSources.count == 50)
    }

    // MARK: - World: corpse decay

    @Test func corpsesDecayAfterTimeout() {
        let world = World(size: CGSize(width: 200, height: 200))
        world.tickCount   = 1201
        world.foodSources = [FoodSource(position: CGPoint(x: 100, y: 100),
                                        energyValue: 50, type: .corpse, spawnedAt: 0)]
        world.corpseCount = 1
        world.decayFood()
        #expect(world.foodSources.isEmpty)
        #expect(world.corpseCount == 0)
    }

    @Test func corpsesSurviveBeforeTimeout() {
        let world = World(size: CGSize(width: 200, height: 200))
        world.tickCount   = 600
        world.foodSources = [FoodSource(position: CGPoint(x: 100, y: 100),
                                        energyValue: 50, type: .corpse, spawnedAt: 0)]
        world.corpseCount = 1
        world.decayFood()
        #expect(world.foodSources.count == 1)
        #expect(world.corpseCount == 1)
    }

    @Test func plantsAreNotRemovedByDecay() {
        let world = World(size: CGSize(width: 200, height: 200))
        world.tickCount = 9999
        world.foodSources = [FoodSource(position: CGPoint(x: 100, y: 100),
                                        energyValue: 30, type: .plant, spawnedAt: 0)]
        world.plantCount = 1
        world.decayFood()
        #expect(world.foodSources.count == 1)  // plants never decay
        #expect(world.plantCount == 1)
    }
}
