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

    // MARK: - Genetische Distanz (Artkennung)

    @Test func geneticDistanceZeroForIdenticalMarkers() {
        var a = DNA.random()
        var b = a
        // Marker angleichen (Farbe 7,8,9 + Aggression 3), NN-Gewichte dürfen abweichen
        for i in [3, 7, 8, 9] { b.genes[i] = a.genes[i] }
        #expect(a.geneticDistance(to: b) == 0)
    }

    @Test func geneticDistanceGrowsWithColorGap() {
        var a = DNA.random(); a.genes[3] = 0.5; a.genes[7] = 0; a.genes[8] = 0; a.genes[9] = 0
        var b = a; b.genes[7] = 1   // rot maximal auseinander
        var c = a; c.genes[7] = 0.2
        #expect(a.geneticDistance(to: b) > a.geneticDistance(to: c))
        // Marker in [0,1] über 4 Achsen → Distanz nie größer als 2
        #expect(a.geneticDistance(to: b) <= 2.0)
    }

    @Test func geneticDistanceIsSymmetric() {
        let a = DNA.random()
        let b = DNA.random()
        #expect(abs(a.geneticDistance(to: b) - b.geneticDistance(to: a)) < 1e-6)
    }

    @Test func speciationBlocksDistantPartners() {
        // Zwei genetisch weit entfernte, paarungsbereite Kreaturen dürfen sich NICHT sexuell paaren.
        let world = World(size: CGSize(width: 200, height: 200))
        world.maxPopulation      = 100
        world.speciationEnabled  = true
        world.speciationThreshold = 0.3

        var dnaA = DNA.random()
        dnaA.genes[4]  = 0.1   // maxAge 100 → reif ab age > 10
        dnaA.genes[5]  = 0.0   // Energie-Schwelle 55%
        dnaA.genes[10] = 0.0   // litterSize 1
        dnaA.genes[3]  = 0.2
        dnaA.genes[7]  = 0.0; dnaA.genes[8] = 0.0; dnaA.genes[9] = 0.0

        var dnaB = dnaA
        dnaB.genes[7] = 1.0; dnaB.genes[8] = 1.0; dnaB.genes[9] = 1.0  // ganz andere Farbe → Distanz ~1.73

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

        // Beide sind nun asexuelle Nachkommen möglich, aber KEIN gemeinsames Kind:
        // Ein sexuelles Kind läge auf dem Mittelpunkt (102.5,100) — asexuelle streuen um den Elternpunkt.
        // Robuster Check: kein Kind ist genetisch nahe an BEIDEN Eltern zugleich.
        let children = world.creatures.filter { $0 !== a && $0 !== b }
        for child in children {
            let hybrid = child.dna.geneticDistance(to: dnaA) < 0.5
                      && child.dna.geneticDistance(to: dnaB) < 0.5
            #expect(!hybrid)
        }
    }

    @Test func speciationAllowsSimilarPartners() {
        // Genetisch nahe Partner paaren sich sexuell (gemeinsames Kind entsteht).
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

        #expect(world.creatures.count > 2)   // mindestens ein Nachkomme
    }

    @Test func countSpeciesSeparatesColorClusters() {
        let world = World(size: CGSize(width: 200, height: 200))
        // Zwei klar getrennte Farb-Cluster
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
                terrainBearingWater:     Float.random(in: -1...1)
            )
            let out = nn.activate(inputs: input)
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

    @Test func herbivoreScavengesCorpseAtBaseRate() {
        // Aas als Trittstein: aggression=0 → corpse digestibility = 0.2 + 0*0.60 = 0.2
        // (opportunistisches Aasfressen; früher 0 → hartes Fitness-Tal zwischen den Diäten)
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
        creature.lastAction = ActionOutput(fromArray: [0.5, 0.0, 0.0, 0.0, 0.0, 0.0])  // wantsToEatPlant/Corpse=0
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
        // Kein "falsches Futter"-Strafmodell mehr: Pflanzenfresser (aggr=0) verwertet Aas zu 20 %
        // → gewinnt Energie (100 × 0.2 = 20), aber weniger als ein Fleischfresser (80).
        var dna = DNA.random(); dna.genes[3] = 0.0  // reiner Pflanzenfresser
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        creature.eat(food: FoodSource(position: .zero, energyValue: 100, type: .corpse))
        #expect(abs(creature.energy - 20) < 0.01)
    }

    @Test func herbivoreScavengesCorpseInWorld() {
        // Pflanzenfresser nimmt Aas opportunistisch mit (wantsToEatCorpse default=1) → Leiche weg, Energie steigt
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[3] = 0.0  // Herbivore
        let creature = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        creature.energy = 50  // lastAction=nil → wantsToEatCorpse default=1
        world.creatures   = [creature]
        world.foodSources = [FoodSource(position: CGPoint(x: 100, y: 100),
                                        energyValue: 100, type: .corpse)]
        world.corpseCount = 1
        world.rebuildGrid()
        world.feedCreatures()
        #expect(world.foodSources.isEmpty)   // Leiche gefressen → weg
        #expect(creature.energy > 50)        // Energie gestiegen (20 % von 100)
    }

    @Test func omnivoreEatsBothFoodTypes() {
        // aggression=0.5 → plant: (1-0.35)*0.6=0.39; corpse: 0.2+0.5*0.60=0.50 — beide verwertbar
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

    // MARK: - Pflanzengift (Schwellen-Variante)

    @Test func carnivoreLosesEnergyEatingPlantWithToxin() {
        // aggr=1.0, Schwelle 0.5, Faktor 0.6: plant d=0.18 → +5.4, Giftlast 0.5×0.6×30=9 → netto −3.6
        var dna = DNA.random(); dna.genes[3] = 1.0   // reiner Fleischfresser
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 50
        creature.eat(food: FoodSource(position: .zero, energyValue: 30, type: .plant),
                     plantToxinFactor: 0.6, plantToxinThreshold: 0.5)
        #expect(creature.energy < 50)   // Vergiftung übersteigt Nährwert → Netto-Verlust
    }

    @Test func herbivoreBelowThresholdImmuneToToxin() {
        // aggr=0.3 unter Schwelle 0.5 → excess=0 → keine Giftlast, voller Pflanzengewinn.
        // Belegt: der aufgefüllte Teil des Fitness-Tals bleibt unangetastet.
        var dna = DNA.random(); dna.genes[3] = 0.3
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        creature.eat(food: FoodSource(position: .zero, energyValue: 30, type: .plant),
                     plantToxinFactor: 0.6, plantToxinThreshold: 0.5)
        let expected: Float = 30 * (1 - 0.3 * 0.7) * 0.6   // = 14.22, ungeschmälert
        #expect(abs(creature.energy - expected) < 0.01)
    }

    @Test func plantToxinLeavesCorpseGainUntouched() {
        // Giftlast wirkt nur auf Pflanzen — das Aas-Trittstein bleibt für Fleischfresser voll erhalten.
        var dna = DNA.random(); dna.genes[3] = 1.0
        let creature = Creature(dna: dna, position: .zero)
        creature.energy = 0
        creature.eat(food: FoodSource(position: .zero, energyValue: 100, type: .corpse),
                     plantToxinFactor: 0.6, plantToxinThreshold: 0.5)
        #expect(abs(creature.energy - 80) < 0.01)   // 100 × 0.80, kein Abzug
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

    // MARK: - Biome

    @Test func waterIsTheOnlyImpassableBiome() {
        for biome in Biome.allCases {
            #expect(biome.isPassable == (biome != .water))
        }
    }

    @Test func biomePropertiesHaveExpectedOrdering() {
        // Sumpf ist am fruchtbarsten, Wasser trägt keine Pflanzen.
        #expect(Biome.wetland.fertility == Biome.maxFertility)
        #expect(Biome.water.fertility == 0)
        #expect(Biome.water.growthFactor == 0)
        // Wald deckt (kurze Sicht), Wüste öffnet den Blick.
        #expect(Biome.forest.sightFactor < 1)
        #expect(Biome.desert.sightFactor > 1)
        // Wiese ist überall der neutrale Referenzpunkt.
        #expect(Biome.grassland.fertility == 1)
        #expect(Biome.grassland.speedFactor == 1)
        #expect(Biome.grassland.sightFactor == 1)
    }

    @Test func biomeMapCoversWholeWorldWithValidBiomes() {
        let size = CGSize(width: 2400, height: 1800)
        let map  = BiomeMap(worldSize: size, tileSize: 200)
        #expect(map.cols == 12)
        #expect(map.rows == 9)
        // Jede Position (inkl. Ränder) liefert ein gültiges Biom.
        for _ in 0..<500 {
            let p = CGPoint(x: CGFloat.random(in: 0..<size.width),
                            y: CGFloat.random(in: 0..<size.height))
            #expect(Biome.allCases.contains(map.biome(at: p)))
        }
    }

    @Test func biomeMapGuaranteesWaterBarriers() {
        // Über viele Karten hinweg entsteht immer mindestens eine Wasserkachel.
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
        // Ohne Biome liefert biome(at:) überall Wiese → alle Faktoren neutral, alles passierbar.
        let world = World(size: CGSize(width: 800, height: 600))
        world.biomesEnabled = false
        for _ in 0..<50 {
            let p = CGPoint(x: CGFloat.random(in: 0..<800), y: CGFloat.random(in: 0..<600))
            #expect(world.biome(at: p) == .grassland)
        }
    }

    @Test func creatureCannotMoveIntoWater() {
        // Kreatur startet neben einer Wasserkachel und steuert direkt hinein → Bewegung blockiert.
        let world = World(size: CGSize(width: 800, height: 600))
        world.biomesEnabled = true
        // Eine passierbare Nachbarkachel einer Wasserkachel suchen und Kreatur dort platzieren,
        // Blickrichtung auf das Wasser.
        let map = world.biomeMap
        var placed = false
        outer: for row in 0..<map.rows {
            for col in 0..<map.cols where map.biomeAt(col: col, row: row) == .water {
                // rechter Nachbar
                let nCol = col + 1
                guard nCol < map.cols, map.biomeAt(col: nCol, row: row).isPassable else { continue }
                let start = CGPoint(x: (CGFloat(nCol) + 0.5) * map.tileSize,
                                    y: (CGFloat(row) + 0.5) * map.tileSize)
                var dna = DNA.random()
                dna.genes[0] = 1.0            // maximale Geschwindigkeit
                let creature = Creature(dna: dna, position: start)
                creature.heading = .pi       // nach links (−x) → in Richtung Wasserkachel
                // Volle Geschwindigkeit, keine Drehung (apply() frischt den Heading-Cache selbst auf)
                let action = ActionOutput(fromArray: [0.5, 1.0, 0.0, 0.0, 0.0, 0.0])
                // So weit bewegen, dass die Zielposition in der Wasserkachel läge
                for _ in 0..<200 { creature.apply(output: action, in: world) }
                // Kreatur darf nie auf einer Wasserkachel stehen.
                #expect(world.biome(at: creature.position).isPassable)
                placed = true
                break outer
            }
        }
        #expect(placed)  // Testfall wurde tatsächlich aufgebaut
    }

    @Test func biomeWorldNeverPlacesLifeOnWater() {
        // Integration: volle Tick-Schleife mit aktiven Biomen. Kernel-Invariante über die
        // gesamte Simulation — weder lebende Kreaturen noch Pflanzen dürfen je im Wasser landen
        // (Spawns meiden Wasser, Bewegung wird blockiert, Wachstum lehnt Wasser ab).
        let world = World(size: CGSize(width: 1600, height: 1200))
        world.biomesEnabled = true
        world.populate(creatures: 120, food: world.maxFood)

        // Startzustand
        for c in world.creatures {
            #expect(world.biomeMap.biome(at: c.position).isPassable)
        }
        for f in world.foodSources where f.type == .plant {
            #expect(world.biomeMap.biome(at: f.position) != .water)
        }

        for _ in 0..<400 { world.tick() }

        // Nach 400 Ticks weiterhin verletzungsfrei
        for c in world.creatures {
            #expect(world.biomeMap.biome(at: c.position).isPassable)
        }
        for f in world.foodSources where f.type == .plant {
            #expect(world.biomeMap.biome(at: f.position) != .water)
        }
        // Die Simulation ist gelaufen (Ticks gezählt, keine Endlosschleife/kein Crash).
        #expect(world.tickCount == 400)
    }

    // MARK: - Biom: Richtungswahrnehmung

    @Test func terrainBearingPointsLeftRightToVisibleBiomes() {
        // Vertikale 1×3-Karte: unten Wasser, Mitte Wiese, oben Sumpf. Beobachter in der Wiese-Mitte,
        // Blick nach +x. Damit liegt „oben" (+y) rechts, „unten" (−y) links (Konvention von angleToFood).
        let map = BiomeMap(tiles: [.water, .grassland, .wetland], cols: 1, rows: 3, tileSize: 100)
        let b = map.directionalBearings(observerX: 50, observerY: 150,
                                        headingCos: 1, headingSin: 0,
                                        sightRadius: 250, sightAngle: 2 * .pi)
        #expect(b.wetland > 0.05)    // Sumpf oben → rechts (+)
        #expect(b.water   < -0.05)   // Wasser unten → links (−)
        #expect(b.forest == 0)       // nicht vorhanden
        #expect(b.desert == 0)
        for v in [b.grassland, b.forest, b.desert, b.wetland, b.water] {
            #expect(v >= -1 && v <= 1)
        }
    }

    @Test func terrainPerceptionWorksAtRealisticSightRadii() {
        // Regression: reale Sichtradien liegen bei ~20–160 px, das Kachelraster bei 200 px.
        // Die frühere Kachelmittelpunkt-Abtastung fand in diesem Maßstab nie eine Kachel
        // (nicht mal die eigene) und lieferte konstant 0 — die Wahrnehmung war praktisch tot.
        // Karte: links Wasser (x < 200), rechts Wiese. Beobachter dicht an der Grenze, 60 px Sicht.
        let map = BiomeMap(tiles: [.water, .grassland], cols: 2, rows: 1, tileSize: 200)
        let b = map.directionalBearings(observerX: 210, observerY: 100,
                                        headingCos: 0, headingSin: 1,   // Blick nach +y
                                        sightRadius: 60, sightAngle: 2 * .pi)
        // Wasser liegt bei −x, also relativ zur Blickrichtung rechts (+) → wird wahrgenommen.
        #expect(b.water > 0)
        #expect(b.water <= 1)
    }

    @Test func terrainSightIsMultipleOfFoodSight() {
        let c = Creature(dna: DNA.random(), position: .zero)
        #expect(Creature.terrainSightFactor > 1)
        #expect(c.terrainSightRadius == c.sightRadius * Creature.terrainSightFactor)
    }

    @Test func terrainSightReachesBeyondFoodSight() {
        // Landschaft ist auf größerer Skala sichtbar als ein einzelnes Futterobjekt.
        // Karte: Wasser links (x < 200), Wiese rechts. Beobachter 150 px von der Grenze,
        // Blick nach +y → Wasser liegt seitlich (gibt also ein Richtungssignal).
        let map = BiomeMap(tiles: [.water, .grassland], cols: 2, rows: 1, tileSize: 200)
        let foodSight: Float = 60

        // Mit bloßer Futter-Sichtweite bliebe das Wasser unsichtbar …
        let near = map.directionalBearings(observerX: 350, observerY: 100,
                                           headingCos: 0, headingSin: 1,
                                           sightRadius: foodSight, sightAngle: 2 * .pi)
        #expect(near.water == 0)

        // … mit dem Landschaftshorizont (4×) wird es wahrgenommen.
        let far = map.directionalBearings(observerX: 350, observerY: 100,
                                          headingCos: 0, headingSin: 1,
                                          sightRadius: foodSight * Float(Creature.terrainSightFactor),
                                          sightAngle: 2 * .pi)
        #expect(far.water > 0)
    }

    @Test func terrainBearingIgnoresTerrainOutsideFOV() {
        // Schmaler 60°-Kegel nach +x mit kurzer Sicht: der Kegel bleibt vollständig in der
        // Wiese-Kachel → Wasser (unten) und Sumpf (oben) sind außerhalb → 0.
        let map = BiomeMap(tiles: [.water, .grassland, .wetland], cols: 1, rows: 3, tileSize: 100)
        let b = map.directionalBearings(observerX: 50, observerY: 150,
                                        headingCos: 1, headingSin: 0,
                                        sightRadius: 80, sightAngle: .pi / 3)
        #expect(b.wetland == 0)
        #expect(b.water == 0)
    }

    @Test func terrainBearingsCancelOnUniformTerrain() {
        // Gleichförmiges Terrain rundum → kein Richtungssignal (Beiträge heben sich auf).
        // Anders als früher heißt "kein Signal" nicht mehr "blind": die Kreatur tastet ihre
        // Umgebung sehr wohl ab, sie ist nur in jede Richtung gleich.
        let map = BiomeMap(tiles: [.grassland], cols: 1, rows: 1, tileSize: 400)
        let b = map.directionalBearings(observerX: 200, observerY: 200,
                                        headingCos: 1, headingSin: 0,
                                        sightRadius: 100, sightAngle: 2 * .pi)
        #expect(abs(b.grassland) < 0.001)
        #expect(b.water == 0)   // nicht vorhanden
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

    // MARK: - Todesursachen & Ereignisstrom

    @Test func deathByStarvationClassified() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[4] = 1.0   // maxAge groß → kein Alterstod
        let c = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        c.energy = -1                                // Energie-Tod, kein Angreifer
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
        victim.lastAttacker = killer                 // diesen Tick angegriffen → Prädation
        world.creatures = [victim]                   // killer muss nicht in der Liste sein
        world.checkDeaths()
        #expect(world.deathsByPredation == 1)
        #expect(world.deathsByStarvation == 0)
    }

    @Test func deathByOldAgeClassified() {
        let world = World(size: CGSize(width: 200, height: 200))
        var dna = DNA.random(); dna.genes[4] = 0.001 // maxAge = 1
        let c = Creature(dna: dna, position: CGPoint(x: 100, y: 100))
        c.age = 100_000                              // ageRatio riesig → Alterswurf feuert sicher
        c.energy = 50                                // lebendig → kein Energie-Tod
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

    @Test func eventRecordingOffKeepsBufferEmpty() {
        let world = World(size: CGSize(width: 200, height: 200))
        // eventRecording bleibt false (Default)
        var dna = DNA.random(); dna.genes[4] = 1.0
        let c = Creature(dna: dna, position: .zero); c.energy = -1
        world.creatures = [c]
        world.checkDeaths()
        #expect(world.events.isEmpty)
        #expect(world.deathsByStarvation == 1)   // Zählung läuft dennoch
    }
}
