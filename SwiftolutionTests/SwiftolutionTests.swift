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

    // Four buckets of equal width, and the top one is an interval rather than the single
    // point gene == 1.0 that truncating over a span of 3 used to leave it as.
    @Test func dnaLitterSizeMapping() {
        var dna = DNA.random()
        dna.genes[10] = 0.0;  #expect(dna.litterSize == 1)
        dna.genes[10] = 0.24; #expect(dna.litterSize == 1)
        dna.genes[10] = 0.26; #expect(dna.litterSize == 2)
        dna.genes[10] = 0.51; #expect(dna.litterSize == 3)
        dna.genes[10] = 0.76; #expect(dna.litterSize == 4)
        dna.genes[10] = 1.0;  #expect(dna.litterSize == 4)
    }

    // The same equal-width mapping for the brain-size gene: the largest brain has to be
    // reachable from an interval of gene values, not only from the clamp at exactly 1.0.
    @Test func brainSizeBucketsAreEqualWidthAndReachTheTop() {
        let span = Float(NeuralNetwork.maxHiddenCount - NeuralNetwork.minHiddenCount + 1)
        #expect(Creature.hiddenCount(for: 0.0)   == NeuralNetwork.minHiddenCount)
        #expect(Creature.hiddenCount(for: 1.0)   == NeuralNetwork.maxHiddenCount)
        // A whole bucket below 1.0 already reaches the maximum.
        #expect(Creature.hiddenCount(for: 1.0 - 0.5 / span) == NeuralNetwork.maxHiddenCount)
        // Every bucket is one neuron wide, and every neuron count is reachable.
        var seen = Set<Int>()
        for i in 0..<200 { seen.insert(Creature.hiddenCount(for: Float(i) / 200)) }
        #expect(seen.count == Int(span))
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

    // MARK: - Genetic distance (species identity)

    @Test func geneticDistanceZeroForIdenticalMarkers() {
        var a = DNA.random()
        var b = a
        // Align the markers (color 7,8,9 plus aggression 3); the network weights may differ
        for i in [3, 7, 8, 9] { b.genes[i] = a.genes[i] }
        #expect(a.geneticDistance(to: b) == 0)
    }

    @Test func geneticDistanceGrowsWithColorGap() {
        var a = DNA.random(); a.genes[3] = 0.5; a.genes[7] = 0; a.genes[8] = 0; a.genes[9] = 0
        var b = a; b.genes[7] = 1   // maximally far apart on red
        var c = a; c.genes[7] = 0.2
        #expect(a.geneticDistance(to: b) > a.geneticDistance(to: c))
        // Markers in [0,1] over 4 axes, so the distance never exceeds 2
        #expect(a.geneticDistance(to: b) <= 2.0)
    }

    @Test func geneticDistanceIsSymmetric() {
        let a = DNA.random()
        let b = DNA.random()
        #expect(abs(a.geneticDistance(to: b) - b.geneticDistance(to: a)) < 1e-6)
    }

    @Test func speciationBlocksDistantPartners() {
        // Two genetically distant creatures, both ready to mate, must NOT reproduce sexually.
        let world = World(size: CGSize(width: 200, height: 200))
        world.maxPopulation      = 100
        world.speciationEnabled  = true
        world.speciationThreshold = 0.3

        var dnaA = DNA.random()
        dnaA.genes[4]  = 0.1   // maxAge 100 -> mature above age 10
        dnaA.genes[5]  = 0.0   // energy threshold 55%
        dnaA.genes[10] = 0.0   // litterSize 1
        dnaA.genes[3]  = 0.2
        dnaA.genes[7]  = 0.0; dnaA.genes[8] = 0.0; dnaA.genes[9] = 0.0

        var dnaB = dnaA
        dnaB.genes[7] = 1.0; dnaB.genes[8] = 1.0; dnaB.genes[9] = 1.0  // a completely different color -> distance ~1.73

        let a = Creature(dna: dnaA, position: CGPoint(x: 100, y: 100))
        let b = Creature(dna: dnaB, position: CGPoint(x: 105, y: 100))
        for c in [a, b] {
            c.age = 20
            c.energy = c.maxEnergy * 0.9
            c.lastAction = ActionOutput(fromArray: [0.5, 0.0, 1.0, 0.0])  // wantsToReproduce
        }
        world.creatures = [a, b]
        world.rebuildGrid()
        world.reproduceCreatures()

        // Asexual offspring are now possible for both, but no SHARED child: a sexual child
        // would sit at the midpoint (102.5,100), whereas asexual ones scatter around their
        // parent. The robust check: no child is genetically close to BOTH parents at once.
        let children = world.creatures.filter { $0 !== a && $0 !== b }
        for child in children {
            let hybrid = child.dna.geneticDistance(to: dnaA) < 0.5
                      && child.dna.geneticDistance(to: dnaB) < 0.5
            #expect(!hybrid)
        }
    }

    @Test func speciationAllowsSimilarPartners() {
        // Genetically close partners do mate sexually, producing a shared child.
        let world = World(size: CGSize(width: 200, height: 200))
        world.maxPopulation       = 100
        world.mutationRate        = 0.0
        world.speciationEnabled   = true
        world.speciationThreshold = 0.45

        var dna = DNA.random()
        dna.genes[4]  = 0.1
        dna.genes[5]  = 0.0
        dna.genes[10] = 0.0
        dna.genes[3]  = 0.2
        dna.genes[7]  = 0.5; dna.genes[8] = 0.5; dna.genes[9] = 0.5

        let a = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        let b = Creature(dna: dna, position: CGPoint(x: 105, y: 100))
        for c in [a, b] {
            c.age = 20
            c.energy = c.maxEnergy * 0.9
            c.lastAction = ActionOutput(fromArray: [0.5, 0.0, 1.0, 0.0])
        }
        world.creatures = [a, b]
        world.rebuildGrid()
        world.reproduceCreatures()

        #expect(world.creatures.count > 2)   // at least one offspring
    }

    @Test func countSpeciesSeparatesColorClusters() {
        let world = World(size: CGSize(width: 200, height: 200))
        // Two clearly separated color clusters
        for _ in 0..<5 {
            var dna = DNA.random(); dna.genes[3] = 0.2
            dna.genes[7] = 0.0; dna.genes[8] = 0.0; dna.genes[9] = 0.0
            world.creatures.append(Creature(dna: dna, position: .zero))
        }
        for _ in 0..<5 {
            var dna = DNA.random(); dna.genes[3] = 0.2
            dna.genes[7] = 1.0; dna.genes[8] = 1.0; dna.genes[9] = 1.0
            world.creatures.append(Creature(dna: dna, position: .zero))
        }
        #expect(world.countSpecies(threshold: 0.3) == 2)
    }

    // MARK: - NeuralNetwork

    @Test func networkOutputsInSigmoidRange() {
        for _ in 0..<30 {
            let dna = DNA.random()
            let nn = NeuralNetwork(weights: dna.neuralWeights(), hiddenCount: 8)
            let input = SensorInput(
                angleToFood:          Float.random(in: -1...1),
                foodProximity:        Float.random(in: 0...1),
                angleToCreature:      Float.random(in: -1...1),
                creatureProximity:    Float.random(in: 0...1),
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
                visibleFoodCount:     Float.random(in: 0...1),
                localPlantDensity:    Float.random(in: 0...1),
                recentFeedingRate:    Float.random(in: 0...1),
                localFertility:       Float.random(in: 0...1),
                localCover:           Float.random(in: 0...1),
                localDifficulty:      Float.random(in: 0...1),
                terrainBearingGrassland: Float.random(in: -1...1),
                terrainBearingForest:    Float.random(in: -1...1),
                terrainBearingDesert:    Float.random(in: -1...1),
                terrainBearingWetland:   Float.random(in: -1...1),
                terrainBearingWater:     Float.random(in: -1...1),
                memory0:    Float.random(in: -1...1),
                memory1:    Float.random(in: -1...1),
                memory2:    Float.random(in: -1...1),
                memory3:    Float.random(in: -1...1),
                oscillator: Float.random(in: -1...1)
            )
            var memory = SIMD4<Float>()
            let out = nn.activate(inputs: input, memory: &memory)
            // The context handed to the next tick is a tanh activation, hence bounded.
            for c in 0..<NeuralNetwork.contextCount { #expect((-1...1).contains(memory[c])) }
            #expect((0...1).contains(out.turnAngle))
            #expect((0...1).contains(out.speed))
            #expect((0...1).contains(out.wantsToReproduce))
            #expect((0...1).contains(out.wantsToAttack))
            #expect((0...1).contains(out.wantsToEatPlant))
            #expect((0...1).contains(out.wantsToEatCorpse))
        }
    }

    @Test func networkHiddenCountClamped() {
        let dna = DNA.random()
        let tooSmall = NeuralNetwork(weights: dna.neuralWeights(), hiddenCount: 0)
        #expect(tooSmall.hiddenCount == NeuralNetwork.minHiddenCount)
        let tooLarge = NeuralNetwork(weights: dna.neuralWeights(), hiddenCount: 999)
        #expect(tooLarge.hiddenCount == NeuralNetwork.maxHiddenCount)
    }

    // A brain that grows by one neuron must keep the wiring it inherited. Weights live in
    // fixed blocks, so the position of a gene does not depend on the brain size: growing is an
    // addition, not a reinterpretation of the output layer. Here the extra neuron's outgoing
    // weights are neutralized (gene 0.5 decodes to weight 0), so the grown brain has to behave
    // exactly like the small one. Read as one consecutive run instead, layer 2 would start 31
    // genes later and the two would disagree on everything.
    @Test func growingTheBrainPreservesTheInheritedWiring() {
        let small = NeuralNetwork.minHiddenCount
        var weights = DNA.random().neuralWeights()
        for o in 0..<NeuralNetwork.outputCount {
            weights[NeuralNetwork.layer2StartIndex + o * NeuralNetwork.layer2BlockSize + small] = 0.5
        }
        let parent = NeuralNetwork(weights: weights, hiddenCount: small)
        let child  = NeuralNetwork(weights: weights, hiddenCount: small + 1)
        #expect(child.hiddenCount == small + 1)

        let input = uniformSensorInput(0.3)
        var parentMemory = SIMD4<Float>(), childMemory = SIMD4<Float>()
        let a = parent.activate(inputs: input, memory: &parentMemory)
        let b = child.activate(inputs: input, memory: &childMemory)

        #expect(parentMemory == childMemory)
        #expect(abs(a.turnAngle        - b.turnAngle)        < 1e-6)
        #expect(abs(a.speed            - b.speed)            < 1e-6)
        #expect(abs(a.wantsToReproduce - b.wantsToReproduce) < 1e-6)
        #expect(abs(a.wantsToAttack    - b.wantsToAttack)    < 1e-6)
        #expect(abs(a.wantsToEatPlant  - b.wantsToEatPlant)  < 1e-6)
        #expect(abs(a.wantsToEatCorpse - b.wantsToEatCorpse) < 1e-6)
    }

    // MARK: - Creature

    @Test func oscillatorCompletesOneCycleOverItsGeneticPeriod() {
        var dna = DNA.random()
        dna.genes[14] = 0.0                      // period = 10 ticks, the fastest clock
        let creature = Creature(dna: dna, position: .zero)
        #expect(abs(creature.dna.oscillatorPeriod - 10) < 0.001)

        // Sampled over one full period the clock has to swing through both signs and come
        // back: without that, "internal clock" would be an input that never moves.
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        for age in 0...10 {
            creature.age = age
            let v = creature.oscillator
            #expect((-1...1).contains(v))
            minimum = min(minimum, v)
            maximum = max(maximum, v)
        }
        #expect(minimum < -0.9)
        #expect(maximum > 0.9)
        creature.age = 0
        #expect(abs(creature.oscillator) < 0.001)   // starts at zero, so birth is not a kick
    }

    @Test func oscillatorPeriodSpansTheGeneRange() {
        var dna = DNA.random()
        dna.genes[14] = 0.0
        #expect(abs(dna.oscillatorPeriod - 10) < 0.001)
        dna.genes[14] = 1.0
        #expect(abs(dna.oscillatorPeriod - 200) < 0.001)
    }

    @Test func brainMemoryStartsEmptyAndIsCarriedAcrossTicks() {
        let world = World(size: CGSize(width: 600, height: 600))
        world.populate(creatures: 20, food: 200)
        // Nothing is inherited: every creature is born with a blank slate.
        for c in world.creatures {
            #expect(c.brainMemory == SIMD4<Float>())
        }

        world.tick()
        // After one tick the context holds hidden activations, and it stays bounded: the
        // values are tanh outputs, so the feedback loop cannot run away.
        var anyNonZero = false
        for c in world.creatures {
            for i in 0..<NeuralNetwork.contextCount {
                #expect((-1...1).contains(c.brainMemory[i]))
                if c.brainMemory[i] != 0 { anyNonZero = true }
            }
        }
        #expect(anyNonZero)

        for _ in 0..<200 { world.tick() }
        for c in world.creatures {
            for i in 0..<NeuralNetwork.contextCount {
                #expect(c.brainMemory[i].isFinite)
                #expect((-1...1).contains(c.brainMemory[i]))
            }
        }
    }

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
        dna.genes[3] = 0.0  // pure herbivore: digestibility = (1-0*0.7)*0.6 = 0.6
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        let food = FoodSource(position: .zero, energyValue: 100, type: .plant)
        creature.eat(food: food)
        #expect(abs(creature.energy - 60) < 0.01)
    }

    @Test func eatPlantCarnivoreDigestibility() {
        var dna = DNA.random()
        dna.genes[3] = 1.0  // pure carnivore: digestibility = (1-1*0.7)*0.6 = 0.18
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        let food = FoodSource(position: .zero, energyValue: 100, type: .plant)
        creature.eat(food: food)
        #expect(abs(creature.energy - 18) < 0.01)
    }

    @Test func eatCorpseDigestibility() {
        var dna = DNA.random()
        dna.genes[3] = 1.0  // carnivore: digestibility = 0.80
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        let food = FoodSource(position: .zero, energyValue: 100, type: .corpse)
        creature.eat(food: food)
        #expect(abs(creature.energy - 80) < 0.01)
    }

    // MARK: - World: feeding rules (continuous digestibility plus a minimum threshold)

    @Test func herbivoreScavengesCorpseAtBaseRate() {
        // Carrion as a stepping stone: aggression=0 -> corpse digestibility = 0.2 + 0*0.60 = 0.2
        // (opportunistic scavenging; it used to be 0, which put a hard fitness valley between the diets)
        var dna = DNA.random()
        dna.genes[3] = 0.0
        let creature = Creature(dna: dna, position: .zero)
        let d = creature.digestibility(for: FoodSource(position: .zero, energyValue: 100, type: .corpse))
        #expect(abs(d - 0.2) < 0.0001)
    }

    @Test func wantsToEatFalseSkipsFood() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[3] = 0.5
        let creature = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        let initialEnergy   = creature.energy
        creature.lastAction = ActionOutput(fromArray: [0.5, 0.0, 0.0, 0.0, 0.0, 0.0])  // wantsToEatPlant/Corpse = 0
        world.creatures     = [creature]
        world.foodSources   = [FoodSource(position: CGPoint(x: 100, y: 100),
                                          energyValue: 100, type: .plant)]
        world.plantCount    = 1
        world.rebuildGrid()
        world.feedCreatures()
        #expect(world.foodSources.count == 1)
        #expect(creature.energy == initialEnergy)
    }

    @Test func herbivoreGainsReducedEnergyFromCorpse() {
        // There is no "wrong food" penalty model any more: a herbivore (aggr=0) digests carrion
        // at 20%, so it gains energy (100 x 0.2 = 20), just less than a carnivore would (80).
        var dna = DNA.random(); dna.genes[3] = 0.0  // pure herbivore
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        creature.eat(food: FoodSource(position: .zero, energyValue: 100, type: .corpse))
        #expect(abs(creature.energy - 20) < 0.01)
    }

    @Test func herbivoreScavengesCorpseInWorld() {
        // A herbivore scavenges opportunistically (wantsToEatCorpse defaults to 1): corpse gone, energy up
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[3] = 0.0  // Herbivore
        let creature = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        creature.energy = 50  // lastAction = nil -> wantsToEatCorpse defaults to 1
        world.creatures   = [creature]
        world.foodSources = [FoodSource(position: CGPoint(x: 100, y: 100),
                                        energyValue: 100, type: .corpse)]
        world.corpseCount = 1
        world.rebuildGrid()
        world.feedCreatures()
        #expect(world.foodSources.isEmpty)   // the corpse was eaten, so it is gone
        #expect(creature.energy > 50)        // energy rose (20% of 100)
    }

    @Test func omnivoreEatsBothFoodTypes() {
        // aggression=0.5 -> plant: (1-0.35)*0.6=0.39; corpse: 0.2+0.5*0.60=0.50, both are usable
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

        // The omnivore does worse than the respective specialist in both strategies
        #expect(plantGain  < 60)   // a herbivore (aggr=0) gets 60
        #expect(corpseGain < 80)   // a carnivore (aggr=1) gets 80
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
        #expect(herb.energy > omni.energy)   // the specialist wins on plants

        omni.energy = 0; carn.energy = 0
        let corpse = FoodSource(position: .zero, energyValue: 100, type: .corpse)
        omni.eat(food: corpse); carn.eat(food: corpse)
        #expect(carn.energy > omni.energy)   // the specialist wins on corpses
    }

    // MARK: - Plant toxin (threshold variant)

    @Test func carnivoreLosesEnergyEatingPlantWithToxin() {
        // aggr=1.0, threshold 0.5, factor 0.6: plant d=0.18 -> +5.4, toxin load 0.5*0.6*30=9 -> net -3.6
        var dna = DNA.random(); dna.genes[3] = 1.0   // pure carnivore
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 50
        creature.eat(food: FoodSource(position: .zero, energyValue: 30, type: .plant),
                     plantToxinFactor: 0.6, plantToxinThreshold: 0.5)
        #expect(creature.energy < 50)   // poisoning outweighs the nutritional value -> a net loss
    }

    @Test func herbivoreBelowThresholdImmuneToToxin() {
        // aggr=0.3 is below the 0.5 threshold, so excess=0: no toxin load and the full plant
        // gain. This pins down that the filled-in part of the fitness valley stays untouched.
        var dna = DNA.random(); dna.genes[3] = 0.3
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        creature.eat(food: FoodSource(position: .zero, energyValue: 30, type: .plant),
                     plantToxinFactor: 0.6, plantToxinThreshold: 0.5)
        let expected: Float = 30 * (1 - 0.3 * 0.7) * 0.6   // = 14.22, undiminished
        #expect(abs(creature.energy - expected) < 0.01)
    }

    @Test func plantToxinLeavesCorpseGainUntouched() {
        // The toxin load applies to plants only; the carrion stepping stone is fully intact for carnivores.
        var dna = DNA.random(); dna.genes[3] = 1.0
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        creature.eat(food: FoodSource(position: .zero, energyValue: 100, type: .corpse),
                     plantToxinFactor: 0.6, plantToxinThreshold: 0.5)
        #expect(abs(creature.energy - 80) < 0.01)   // 100 x 0.80, nothing deducted
    }

    // MARK: - World: energy conservation

    @Test func corpseEnergyDerivedFromBodyMass() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random()
        // size = 0.5 → maxBodyMass 50, of which a newborn starts with birthMassFraction
        dna.genes[2] = 0.5
        let creature = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        #expect(abs(creature.bodyMass - 50 * Creature.birthMassFraction) < 0.01)
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
        world.mutationRate  = 0.0  // no mutation: child DNA identical to parents

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
        world.tickCount       = 0   // t = 0/100 = 0 -> cos(0) = 1 -> factor = 1.0
        #expect(abs(world.currentSeasonFactor - 1.0) < 0.001)
    }

    @Test func seasonFactorTroughAtWinter() {
        let world = World()
        world.seasonEnabled   = true
        world.seasonLength    = 100
        world.seasonAmplitude = 0.7
        world.tickCount       = 50  // t = 0.5 -> cos(pi) = -1 -> factor = 1 - amplitude = 0.3
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
        // The big bang: every starting creature is a herbivore (aggression <= 0.4)
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

    // MARK: - Biomes

    @Test func waterIsTheOnlyImpassableBiome() {
        for biome in Biome.allCases {
            #expect(biome.isPassable == (biome != .water))
        }
    }

    @Test func biomePropertiesHaveExpectedOrdering() {
        // Wetland is the most fertile; water carries no plants at all.
        #expect(Biome.wetland.fertility == Biome.maxFertility)
        #expect(Biome.water.fertility == 0)
        #expect(Biome.water.growthFactor == 0)
        // Forest gives cover (short sight); desert opens the view.
        #expect(Biome.forest.sightFactor < 1)
        #expect(Biome.desert.sightFactor > 1)
        // Grassland is the neutral reference point throughout.
        #expect(Biome.grassland.fertility == 1)
        #expect(Biome.grassland.speedFactor == 1)
        #expect(Biome.grassland.sightFactor == 1)
    }

    @Test func biomeMapCoversWholeWorldWithValidBiomes() {
        let size = CGSize(width: 2400, height: 1800)
        let map  = BiomeMap(worldSize: size, tileSize: 200)
        #expect(map.cols == 12)
        #expect(map.rows == 9)
        // Every position, edges included, yields a valid biome.
        for _ in 0..<500 {
            let p = CGPoint(x: CGFloat.random(in: 0..<size.width),
                            y: CGFloat.random(in: 0..<size.height))
            #expect(Biome.allCases.contains(map.biome(at: p)))
        }
    }

    @Test func biomeMapGuaranteesWaterBarriers() {
        // Across many maps, at least one water tile always appears.
        for _ in 0..<10 {
            let map = BiomeMap(worldSize: CGSize(width: 2400, height: 1800), tileSize: 200)
            var hasWater = false
            for row in 0..<map.rows {
                for col in 0..<map.cols where map.biomeAt(col: col, row: row) == .water {
                    hasWater = true
                }
            }
            #expect(hasWater)
        }
    }

    @Test func biomeDisabledWorldBehavesAsNeutralGrassland() {
        // With biomes off, biome(at:) returns grassland everywhere: neutral factors, all passable.
        let world = World(size: CGSize(width: 800, height: 600))
        world.biomesEnabled = false
        for _ in 0..<50 {
            let p = CGPoint(x: CGFloat.random(in: 0..<800), y: CGFloat.random(in: 0..<600))
            #expect(world.biome(at: p) == .grassland)
        }
    }

    @Test func creatureCannotMoveIntoWater() {
        // The creature starts next to a water tile and steers straight into it, so movement is blocked.
        let world = World(size: CGSize(width: 800, height: 600))
        world.biomesEnabled = true
        // Find a passable tile adjacent to a water tile, place the creature there and point it
        // at the water.
        let map = world.biomeMap
        var placed = false
        outer: for row in 0..<map.rows {
            for col in 0..<map.cols where map.biomeAt(col: col, row: row) == .water {
                // the right-hand neighbour
                let nCol = col + 1
                guard nCol < map.cols, map.biomeAt(col: nCol, row: row).isPassable else { continue }
                let start = CGPoint(x: (CGFloat(nCol) + 0.5) * map.tileSize,
                                    y: (CGFloat(row) + 0.5) * map.tileSize)
                var dna = DNA.random()
                dna.genes[0] = 1.0            // maximum speed
                let creature = Creature(dna: dna, position: start)
                creature.heading = .pi       // to the left (-x), toward the water tile
                // Full speed, no turning (apply() refreshes the heading cache itself)
                let action = ActionOutput(fromArray: [0.5, 1.0, 0.0, 0.0, 0.0, 0.0])
                // Move far enough that the target position would land inside the water tile
                for _ in 0..<200 { creature.apply(output: action, in: world) }
                // The creature must never end up standing on a water tile.
                #expect(world.biome(at: creature.position).isPassable)
                placed = true
                break outer
            }
        }
        #expect(placed)  // the test case was actually constructed
    }

    @Test func biomeWorldNeverPlacesLifeOnWater() {
        // Integration: the full tick loop with biomes on. A core invariant across the whole
        // simulation: neither living creatures nor plants may ever end up in water (spawns
        // avoid it, movement is blocked, and growth rejects it).
        let world = World(size: CGSize(width: 1600, height: 1200))
        world.biomesEnabled = true
        world.populate(creatures: 120, food: world.maxFood)

        // The initial state
        for c in world.creatures {
            #expect(world.biomeMap.biome(at: c.position).isPassable)
        }
        for f in world.foodSources where f.type == .plant {
            #expect(world.biomeMap.biome(at: f.position) != .water)
        }

        for _ in 0..<400 { world.tick() }

        // Still unviolated after 400 ticks
        for c in world.creatures {
            #expect(world.biomeMap.biome(at: c.position).isPassable)
        }
        for f in world.foodSources where f.type == .plant {
            #expect(world.biomeMap.biome(at: f.position) != .water)
        }
        // The simulation actually ran: ticks were counted, with no infinite loop and no crash.
        #expect(world.tickCount == 400)
    }

    // MARK: - Biomes: directional perception

    @Test func terrainBearingPointsLeftRightToVisibleBiomes() {
        // A vertical 1x3 map: water at the bottom, grassland in the middle, wetland on top. The
        // observer stands in the middle of the grassland looking along +x, which puts "up" (+y)
        // on the right and "down" (-y) on the left (the angleToFood convention).
        let map = BiomeMap(tiles: [.water, .grassland, .wetland], cols: 1, rows: 3, tileSize: 100)
        let b = map.directionalBearings(observerX: 50, observerY: 150,
                                        headingCos: 1, headingSin: 0,
                                        sightRadius: 250, sightAngle: 2 * .pi)
        #expect(b.wetland > 0.05)    // wetland above -> to the right (+)
        #expect(b.water   < -0.05)   // water below -> to the left (-)
        #expect(b.forest == 0)       // not present on this map
        #expect(b.desert == 0)
        for v in [b.grassland, b.forest, b.desert, b.wetland, b.water] {
            #expect(v >= -1 && v <= 1)
        }
    }

    @Test func terrainPerceptionWorksAtRealisticSightRadii() {
        // Regression: real sight radii are ~20-160 px while the tile raster is 200 px. At that
        // scale the old tile-centre sampling never found a tile at all, not even the creature's
        // own, and returned a constant 0, leaving the sense effectively dead.
        // Map: water on the left (x < 200), grassland on the right. The observer stands close to
        // the border with 60 px of sight.
        let map = BiomeMap(tiles: [.water, .grassland], cols: 2, rows: 1, tileSize: 200)
        let b = map.directionalBearings(observerX: 210, observerY: 100,
                                        headingCos: 0, headingSin: 1,   // looking along +y
                                        sightRadius: 60, sightAngle: 2 * .pi)
        // The water lies at -x, which is to the right (+) of the heading, so it is perceived.
        #expect(b.water > 0)
        #expect(b.water <= 1)
    }

    @Test func terrainSightIsMultipleOfFoodSight() {
        let c = Creature(dna: DNA.random(), position: .zero)
        #expect(Creature.terrainSightFactor > 1)
        #expect(c.terrainSightRadius == c.sightRadius * Creature.terrainSightFactor)
    }

    @Test func terrainSightReachesBeyondFoodSight() {
        // Landscape is visible on a larger scale than a single item of food.
        // Map: water on the left (x < 200), grassland on the right. The observer is 150 px from
        // the border looking along +y, so the water is off to one side and does give a bearing.
        let map = BiomeMap(tiles: [.water, .grassland], cols: 2, rows: 1, tileSize: 200)
        let foodSight: Float = 60

        // At plain food sight range the water would stay invisible ...
        let near = map.directionalBearings(observerX: 350, observerY: 100,
                                           headingCos: 0, headingSin: 1,
                                           sightRadius: foodSight, sightAngle: 2 * .pi)
        #expect(near.water == 0)

        // ... but at the landscape horizon (4x) it is perceived.
        let far = map.directionalBearings(observerX: 350, observerY: 100,
                                          headingCos: 0, headingSin: 1,
                                          sightRadius: foodSight * Float(Creature.terrainSightFactor),
                                          sightAngle: 2 * .pi)
        #expect(far.water > 0)
    }

    @Test func terrainBearingIgnoresTerrainOutsideFOV() {
        // A narrow 60 degree cone along +x with short sight: the cone stays entirely inside the
        // grassland tile, so the water below and the wetland above fall outside it and read 0.
        let map = BiomeMap(tiles: [.water, .grassland, .wetland], cols: 1, rows: 3, tileSize: 100)
        let b = map.directionalBearings(observerX: 50, observerY: 150,
                                        headingCos: 1, headingSin: 0,
                                        sightRadius: 80, sightAngle: .pi / 3)
        #expect(b.wetland == 0)
        #expect(b.water == 0)
    }

    @Test func terrainBearingsCancelOnUniformTerrain() {
        // Uniform terrain all around gives no directional signal, since the contributions
        // cancel. Unlike before, "no signal" no longer means "blind": the creature does sample
        // its surroundings, they simply look the same in every direction.
        let map = BiomeMap(tiles: [.grassland], cols: 1, rows: 1, tileSize: 400)
        let b = map.directionalBearings(observerX: 200, observerY: 200,
                                        headingCos: 1, headingSin: 0,
                                        sightRadius: 100, sightAngle: 2 * .pi)
        #expect(abs(b.grassland) < 0.001)
        #expect(b.water == 0)   // not present on this map
    }

    @Test func terrainBearingsStayInRangeOnRandomMap() {
        let map = BiomeMap(worldSize: CGSize(width: 1600, height: 1200), tileSize: 200)
        for _ in 0..<300 {
            let px = Float.random(in: 0..<1600), py = Float.random(in: 0..<1200)
            let hx = Float.random(in: -1...1)
            let hy = (1 - hx * hx).squareRoot() * (Bool.random() ? 1 : -1)
            let b = map.directionalBearings(observerX: px, observerY: py,
                                            headingCos: hx, headingSin: hy,
                                            sightRadius: Float.random(in: 20...300),
                                            sightAngle: Float.random(in: (2 * .pi / 3)...(2 * .pi)))
            for v in [b.grassland, b.forest, b.desert, b.wetland, b.water] {
                #expect(v >= -1 && v <= 1)
            }
        }
    }

    // MARK: - Causes of death & the event stream

    @Test func deathByStarvationClassified() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[4] = 1.0   // a large maxAge, so no death from old age
        let c = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        c.energy = -1                                // an energy death with no attacker
        world.creatures = [c]
        world.checkDeaths()
        #expect(world.deathsByStarvation == 1)
        #expect(world.deathsByPredation == 0)
        #expect(world.deathsByOldAge == 0)
    }

    @Test func deathByPredationClassified() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[4] = 1.0
        let victim = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        let killer = Creature(dna: DNA.random(), position: CGPoint(x: 100, y: 100))
        victim.energy = -1
        victim.recordAttack(from: killer, damage: 10) // attacked this tick -> predation
        world.creatures = [victim]                   // the killer need not be in the list
        world.checkDeaths()
        #expect(world.deathsByPredation == 1)
        #expect(world.deathsByStarvation == 0)
    }

    @Test func deathByOldAgeClassified() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[4] = 0.001 // maxAge = 1
        let c = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        c.age = 100_000                              // a huge ageRatio, so the age roll is certain to fire
        c.energy = 50                                // alive, so this is not an energy death
        world.creatures = [c]
        world.checkDeaths()
        #expect(world.deathsByOldAge == 1)
        #expect(world.deathsByStarvation == 0)
        #expect(world.deathsByPredation == 0)
    }

    @Test func eventRecordingCapturesDeathWithCause() {
        let world = World(size: CGSize(width: 200, height: 200))
        world.eventRecording = true
        var dna = DNA.random(); dna.genes[4] = 1.0
        let c = Creature(dna: dna, position: CGPoint(x: 50, y: 60)); c.energy = -1
        world.creatures = [c]
        world.checkDeaths()
        #expect(world.events.count == 1)
        #expect(world.events.first?.kind == .death)
        #expect(world.events.first?.cause == .starvation)
    }

    // MARK: - A wrapping world: perception across the seam

    // Movement has always wrapped; perception used to stop dead at x=0 and y=0. Two creatures a
    // few pixels apart across that line could walk through each other but not see, smell,
    // attack or mate with each other, which made the world edge an invisible reproductive
    // barrier and a source of speciation that nothing in the model asks for.
    @Test func sightReachesAcrossTheWorldSeam() {
        let world = World(size: CGSize(width: 400, height: 400))
        let observer = Creature(dna: DNA.random(), position: CGPoint(x: 395, y: 200))
        let neighbour = Creature(dna: DNA.random(), position: CGPoint(x: 5, y: 200))
        world.creatures = [observer, neighbour]
        world.rebuildGrid()
        // 10 px apart the short way round, 390 px the long way.
        #expect(world.nearestCreature(to: observer, within: 40) === neighbour)
        #expect(world.nearestCreature(to: neighbour, within: 40) === observer)
    }

    @Test func sightStopsAtTheTrueToroidalDistance() {
        // The control: the wrap must not make everything visible. Half a world apart is the
        // furthest two points can be, and that stays out of range.
        let world = World(size: CGSize(width: 400, height: 400))
        let a = Creature(dna: DNA.random(), position: CGPoint(x: 0, y: 200))
        let b = Creature(dna: DNA.random(), position: CGPoint(x: 200, y: 200))
        world.creatures = [a, b]
        world.rebuildGrid()
        #expect(world.nearestCreature(to: a, within: 40) == nil)
        #expect(world.nearestCreature(to: a, within: 210) === b)
    }

    @Test func toroidalDeltasTakeTheShorterWayRound() {
        let world = World(size: CGSize(width: 400, height: 300))
        #expect(abs(world.torDx(390) - (-10)) < 0.001)
        #expect(abs(world.torDx(-390) - 10)  < 0.001)
        #expect(abs(world.torDy(290) - (-10)) < 0.001)
        #expect(abs(world.torDx(30) - 30)    < 0.001)
    }

    // A pair straddling the seam must produce offspring next to themselves, not in the middle
    // of the world on the far side.
    @Test func midpointOfASeamCrossingPairStaysBetweenThem() {
        let world = World(size: CGSize(width: 400, height: 400))
        let mid = world.midpoint(CGPoint(x: 390, y: 10), CGPoint(x: 10, y: 390))
        #expect(mid.x == 0)
        #expect(mid.y == 0)
    }

    @Test func smellReachesAcrossTheWorldSeam() {
        let world = World(size: CGSize(width: 400, height: 400))
        var dna = DNA.random()
        dna.genes[13] = 1.0   // olfaction: 200 px smell radius
        let observer = Creature(dna: dna, position: CGPoint(x: 395, y: 200))
        for i in 0..<20 {
            world.foodSources.append(FoodSource(position: CGPoint(x: CGFloat(i), y: 200)))
        }
        world.plantCount = 20
        world.creatures  = [observer]
        world.sensorRecording = true
        world.rebuildGrid()
        world.tick()
        // The plants sit 5-25 px away across the seam; without wrapping the density raster
        // clamps to the world edge and reports nothing at all.
        #expect((observer.lastSensors?.localPlantDensity ?? 0) > 0)
    }

    @Test func matingReachesAcrossTheWorldSeam() {
        let world = World(size: CGSize(width: 400, height: 400))
        world.maxPopulation = 100
        world.mutationRate  = 0
        var dna = DNA.random()
        dna.genes[4]  = 0.5   // maxAge 500 -> mature past age 50
        dna.genes[5]  = 0.0   // reproduce from 55% energy
        dna.genes[10] = 0.0   // litter of 1
        let a = Creature(dna: dna, position: CGPoint(x: 395, y: 200))
        let b = Creature(dna: dna, position: CGPoint(x: 5,   y: 200))
        for c in [a, b] {
            c.age = 100
            c.energy = c.maxEnergy * 0.9
            c.lastAction = ActionOutput(fromArray: [0.5, 0.0, 1.0, 0.0])
        }
        world.creatures = [a, b]
        world.rebuildGrid()
        world.reproduceCreatures()
        // Sexual reproduction (both parents paid), not two asexual fallbacks.
        #expect(world.creatures.count == 3)
    }

    // MARK: - The spatial grid tracks movement

    @Test func gridRefilesCreaturesAfterTheyMove() {
        let grid = SpatialGrid(cellSize: 80, worldSize: CGSize(width: 400, height: 400))
        let c = Creature(dna: DNA.random(), position: CGPoint(x: 10, y: 10))
        grid.rebuild(creatures: [c], food: [])
        c.position = CGPoint(x: 300, y: 300)
        grid.rebuildCreatures([c])

        var foundAtNewPlace = false
        grid.forEachCreature(near: CGPoint(x: 300, y: 300), within: 10) { if $0 === c { foundAtNewPlace = true } }
        #expect(foundAtNewPlace)

        var foundAtOldPlace = false
        grid.forEachCreature(near: CGPoint(x: 10, y: 10), within: 10) { if $0 === c { foundAtOldPlace = true } }
        #expect(!foundAtOldPlace)
    }

    // Everything that queries the grid runs after movement, so the cells have to be refiled in
    // between. Otherwise a creature that moved into range this tick is still filed under the
    // cell it left, and the query misses it.
    @Test func everyCreatureIsFindableAfterATick() {
        let world = World(size: CGSize(width: 2000, height: 2000))
        world.populate(creatures: 8, food: 0)
        world.tick()
        for creature in world.creatures {
            let probe = Creature(dna: DNA.random(), position: creature.position)
            #expect(world.nearestCreature(to: probe, within: 1) != nil)
        }
    }

    // MARK: - Body mass is inside the energy accounting

    @Test func buildingBodyMassIsPaidForOutOfEnergy() {
        var dna = DNA.random()
        dna.genes[2] = 0.5                       // size 0.5 -> maxBodyMass 50
        let c = Creature(dna: dna, position: .zero)
        c.energy = c.maxEnergy                   // well fed: mass may grow
        let massBefore   = c.bodyMass
        let energyBefore = c.energy
        c.tick()
        let gained = c.bodyMass - massBefore
        #expect(gained > 0)
        // The energy bill is maintenance plus the mass just bought, never less.
        let spent = energyBefore - c.energy
        #expect(spent > gained * Creature.massBuildCost)
    }

    @Test func catabolismReturnsEnergyAtAConversionLoss() {
        var dna = DNA.random()
        dna.genes[2] = 0.5
        let c = Creature(dna: dna, position: .zero)
        c.energy = c.maxEnergy * 0.1             // starving: mass is burned back
        let massBefore   = c.bodyMass
        let energyBefore = c.energy
        c.tick()
        let burned = massBefore - c.bodyMass
        #expect(burned > 0)
        // Mass no longer vanishes without a trace: it comes back as energy, but at a loss, so
        // the net energy change is better than maintenance alone and worse than a full refund.
        let credited = burned * Creature.massCatabolismYield
        #expect(c.energy > energyBefore - credited)
        #expect(Creature.massCatabolismYield < Creature.massBuildCost)
    }

    @Test func newbornMassIsBoughtOutOfTheBirthEndowment() {
        var dna = DNA.random()
        dna.genes[2] = 0.5
        let c = Creature(dna: dna, position: .zero)
        let endowment: Float = 40
        c.endow(with: endowment)
        // Nothing is created: energy kept plus energy spent on mass equals what was paid in.
        #expect(abs((c.energy + c.bodyMass * Creature.massBuildCost) - endowment) < 0.01)
        #expect(c.bodyMass > 0)
        #expect(c.bodyMass <= c.maxBodyMass * Creature.birthMassFraction + 0.001)
    }

    // Body mass has to be earned, otherwise corpse value is just the size gene and says
    // nothing about how well an individual actually fed.
    @Test func newbornsStartWellBelowTheirMassCeiling() {
        let c = Creature(dna: DNA.random(), position: .zero)
        #expect(c.bodyMass < c.maxBodyMass)
        #expect(abs(c.bodyMass - c.maxBodyMass * Creature.birthMassFraction) < 0.001)
    }

    @Test func wellFedCreaturesGrowTowardsTheirMassCeiling() {
        var dna = DNA.random()
        dna.genes[2] = 0.5
        let c = Creature(dna: dna, position: .zero)
        let start = c.bodyMass
        for _ in 0..<50 {
            c.energy = c.maxEnergy               // kept well fed throughout
            c.tick()
        }
        #expect(c.bodyMass > start)
        #expect(c.bodyMass <= c.maxBodyMass + 0.001)
    }

    // MARK: - The kill bonus follows the damage

    @Test func killBonusIsSplitByDamageDealt() {
        let world = World(size: CGSize(width: 400, height: 400))
        var dna = DNA.random()
        dna.genes[2] = 0.5
        dna.genes[3] = 0.8                       // the same aggression for both attackers
        let strong = Creature(dna: dna, position: CGPoint(x: 10, y: 10))
        let weak   = Creature(dna: dna, position: CGPoint(x: 20, y: 20))
        let victim = Creature(dna: dna, position: CGPoint(x: 15, y: 15))
        strong.energy = 10
        weak.energy   = 10
        victim.energy = -1                       // dies this tick
        victim.recordAttack(from: strong, damage: 30)
        victim.recordAttack(from: weak,   damage: 10)

        world.creatures = [strong, weak, victim]
        world.checkDeaths()

        let strongGain = strong.energy - 10
        let weakGain   = weak.energy - 10
        #expect(strongGain > 0)
        #expect(weakGain > 0)
        // Three quarters of the damage, three quarters of the bonus.
        #expect(abs(strongGain - 3 * weakGain) < 0.01)
        // Everything paid out still comes off the corpse.
        let corpse = world.foodSources.first { $0.type == .corpse }
        #expect(corpse != nil)
        #expect(abs((corpse!.energyValue + strongGain + weakGain) - victim.bodyMass) < 0.01)
    }

    @Test func deathIsPredationWhoeverStruckLast() {
        let world = World(size: CGSize(width: 200, height: 200))
        let killerA = Creature(dna: DNA.random(), position: .zero)
        let killerB = Creature(dna: DNA.random(), position: .zero)
        let victim  = Creature(dna: DNA.random(), position: .zero)
        victim.energy = -1
        victim.recordAttack(from: killerA, damage: 5)
        victim.recordAttack(from: killerB, damage: 5)
        world.creatures = [killerA, killerB, victim]
        world.checkDeaths()
        #expect(world.deathsByPredation == 1)
        #expect(world.deathsByStarvation == 0)
    }

    // MARK: - Contested food does not go by array position

    // Survivors keep their index and newborns are appended, so array order correlates with
    // age. Resolving contested food by iteration order therefore let older creatures win every
    // contest, a selection pressure nothing in the design intends.
    @Test func contestedFoodDoesNotAlwaysGoToTheSameArraySlot() {
        var firstWins = 0
        let trials = 200
        for _ in 0..<trials {
            let world = World(size: CGSize(width: 200, height: 200))
            let dna = DNA.random()
            let first  = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
            let second = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
            first.energy  = 1
            second.energy = 1
            world.creatures   = [first, second]
            world.foodSources = [FoodSource(position: CGPoint(x: 100, y: 100))]
            world.plantCount  = 1
            world.rebuildGrid()
            world.feedCreatures()
            #expect(world.foodSources.isEmpty)           // exactly one of them ate it
            if first.energy > second.energy { firstWins += 1 }
        }
        #expect(firstWins > 0)
        #expect(firstWins < trials)
    }

    // MARK: - Generations count descent

    @Test func offspringAreOneGenerationPastTheirParents() {
        let world = World(size: CGSize(width: 400, height: 400))
        world.maxPopulation = 100
        world.mutationRate  = 0
        var dna = DNA.random()
        dna.genes[4]  = 0.5
        dna.genes[5]  = 0.0
        dna.genes[10] = 0.0
        let a = Creature(dna: dna, position: CGPoint(x: 200, y: 200))
        let b = Creature(dna: dna, position: CGPoint(x: 210, y: 200))
        for c in [a, b] {
            c.age = 100
            c.energy = c.maxEnergy * 0.9
            c.lastAction = ActionOutput(fromArray: [0.5, 0.0, 1.0, 0.0])
        }
        #expect(a.generation == 0)                 // founders
        world.creatures = [a, b]
        world.rebuildGrid()
        world.reproduceCreatures()
        let children = world.creatures.filter { $0 !== a && $0 !== b }
        #expect(!children.isEmpty)
        #expect(children.allSatisfy { $0.generation == 1 })
    }

    // The world reports the mean generation of the living population, not the number of ticks
    // in which something happened to be born.
    @Test func worldGenerationIsThePopulationMean() {
        let world = World(size: CGSize(width: 400, height: 400))
        let dna = DNA.random()
        world.creatures = [
            Creature(dna: dna, position: .zero, generation: 2),
            Creature(dna: dna, position: .zero, generation: 4)
        ]
        #expect(world.generation == 3)
        world.creatures = []
        #expect(world.generation == 0)
    }

    // MARK: - Terrain bearings use their full range

    // One biome filling exactly the half of the cone that points hardest to one side is the
    // strongest reading there is, and it has to read as 1. Normalizing by the total sample
    // weight instead capped the sensor at about a third of its nominal range.
    @Test func terrainBearingsReachTheEndsOfTheirRange() {
        // Grassland below, water above, observer on the boundary looking along +x: every
        // sample to its right is water, every sample to its left is grassland.
        let map = BiomeMap(tiles: [.grassland, .water], cols: 1, rows: 2, tileSize: 100)
        let b = map.directionalBearings(observerX: 50, observerY: 100,
                                        headingCos: 1, headingSin: 0,
                                        sightRadius: 50, sightAngle: 2 * .pi)
        #expect(abs(b.water - 1) < 0.001)
        #expect(abs(b.grassland + 1) < 0.001)
    }

    // The scale must not depend on the sightAngle gene: the same lake has to read the same for
    // a narrow-coned creature and a wide-coned one, or an inherited weight means different
    // things in different phenotypes and changing sightAngle silently perturbs terrain
    // behaviour as a side effect.
    @Test func terrainBearingScaleIsIndependentOfTheSightAngleGene() {
        let map = BiomeMap(tiles: [.grassland, .water], cols: 1, rows: 2, tileSize: 100)
        for angle: Float in [2 * .pi / 3, .pi, 4 * .pi / 3, 2 * .pi] {
            let b = map.directionalBearings(observerX: 50, observerY: 100,
                                            headingCos: 1, headingSin: 0,
                                            sightRadius: 50, sightAngle: angle)
            #expect(abs(b.water - 1) < 0.001)
        }
    }

    // MARK: - Perceiving nothing is not a reading

    @Test func anEmptyFieldOfViewReadsAsZeroProximity() {
        let world = World(size: CGSize(width: 2000, height: 2000))
        world.sensorRecording = true
        let c = Creature(dna: DNA.random(), position: CGPoint(x: 1000, y: 1000))
        world.creatures = [c]
        world.tick()
        #expect(c.lastSensors?.foodProximity == 0)
        #expect(c.lastSensors?.creatureProximity == 0)
        #expect(c.lastSensors?.visibleFoodCount == 0)
    }

    @Test func foodUnderfootReadsAsFullProximity() {
        let world = World(size: CGSize(width: 2000, height: 2000))
        world.sensorRecording = true
        var dna = DNA.random()
        dna.genes[11] = 1.0                        // 360 degree sight: no cone to miss with
        let c = Creature(dna: dna, position: CGPoint(x: 1000, y: 1000))
        world.creatures   = [c]
        world.foodSources = [FoodSource(position: CGPoint(x: 1000, y: 1000))]
        world.plantCount  = 1
        world.tick()
        // Proximity is monotone the other way round from distance: nothing in sight is 0 and
        // being right on top of something is 1.
        #expect((c.lastSensors?.foodProximity ?? 0) > 0.9)
    }

    @Test func eventRecordingOffKeepsBufferEmpty() {
        let world = World(size: CGSize(width: 200, height: 200))
        // eventRecording stays false (the default)
        var dna = DNA.random(); dna.genes[4] = 1.0
        let c = Creature(dna: dna, position: .zero); c.energy = -1
        world.creatures = [c]
        world.checkDeaths()
        #expect(world.events.isEmpty)
        #expect(world.deathsByStarvation == 1)   // the counting still happens
    }
}

// Every sensor set to the same value: enough to compare two networks on identical input
// without spelling out thirty fields per call site.
private func uniformSensorInput(_ v: Float) -> SensorInput {
    SensorInput(
        angleToFood: v, foodProximity: v, angleToCreature: v, creatureProximity: v,
        ownEnergy: v, localDensity: v, approachVelocity: v, nearestFoodType: v,
        avgNearbyHeading: v, nearestCreatureRed: v, nearestCreatureGreen: v,
        nearestCreatureBlue: v, visibleCreatureCount: v, ownSenescence: v,
        visibleFoodCount: v, localPlantDensity: v, recentFeedingRate: v,
        localFertility: v, localCover: v, localDifficulty: v,
        terrainBearingGrassland: v, terrainBearingForest: v, terrainBearingDesert: v,
        terrainBearingWetland: v, terrainBearingWater: v,
        memory0: v, memory1: v, memory2: v, memory3: v, oscillator: v
    )
}
