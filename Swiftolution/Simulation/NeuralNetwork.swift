import Foundation

struct NeuralNetwork {

    // MARK: - Architecture

    static let inputCount    = 25
    static let minHiddenCount = 4
    static let maxHiddenCount = 16
    static let outputCount   = 6   // turnAngle, speed, wantsToReproduce, wantsToAttack, wantsToEatPlant, wantsToEatCorpse

    // DNA always stores weights for maxHiddenCount, whatever the actual brain size. That keeps
    // the genome length constant, so crossover works without any special casing.
    static var totalWeightCount: Int {
        let layer1 = inputCount * maxHiddenCount + maxHiddenCount
        let layer2 = maxHiddenCount * outputCount + outputCount
        return layer1 + layer2
    }

    // MARK: - Weights

    // Flat row-major buffers instead of [[Float]]: contiguous memory, and no pointer
    // indirection per neuron.
    let hiddenCount: Int
    private var weightsIH: [Float]   // hiddenCount x inputCount
    private var biasH:     [Float]   // hiddenCount
    private var weightsHO: [Float]   // outputCount x hiddenCount
    private var biasO:     [Float]   // outputCount

    // MARK: - Init

    init(weights: [Float], hiddenCount: Int) {
        let hc = max(NeuralNetwork.minHiddenCount,
                     min(hiddenCount, NeuralNetwork.maxHiddenCount))
        self.hiddenCount = hc
        guard weights.count >= NeuralNetwork.totalWeightCount else {
            weightsIH = [Float](repeating: 0, count: hc * NeuralNetwork.inputCount)
            biasH     = [Float](repeating: 0, count: hc)
            weightsHO = [Float](repeating: 0, count: NeuralNetwork.outputCount * hc)
            biasO     = [Float](repeating: 0, count: NeuralNetwork.outputCount)
            return
        }

        // Genes live in [0,1]. Remap them to [-1,1] for network weights so that positive and
        // negative influences are equally likely — otherwise every neuron would be biased to
        // fire in the same direction.
        func w(_ v: Float) -> Float { v * 2 - 1 }

        var idx = 0
        var wIH = [Float](); wIH.reserveCapacity(hc * NeuralNetwork.inputCount)
        var bH  = [Float](); bH.reserveCapacity(hc)
        for _ in 0..<hc {
            for _ in 0..<NeuralNetwork.inputCount {
                wIH.append(w(weights[idx])); idx += 1
            }
            bH.append(w(weights[idx])); idx += 1
        }

        var wHO = [Float](); wHO.reserveCapacity(NeuralNetwork.outputCount * hc)
        var bO  = [Float](); bO.reserveCapacity(NeuralNetwork.outputCount)
        for _ in 0..<NeuralNetwork.outputCount {
            for _ in 0..<hc {
                wHO.append(w(weights[idx])); idx += 1
            }
            bO.append(w(weights[idx])); idx += 1
        }

        weightsIH = wIH
        biasH     = bH
        weightsHO = wHO
        biasO     = bO
    }

    // MARK: - Forward Pass

    // The hottest path in the simulation (population x 30 calls per frame): input and hidden
    // values live in a stack buffer, with no heap allocation.
    func activate(inputs: SensorInput) -> ActionOutput {
        let hc = hiddenCount
        let ic = NeuralNetwork.inputCount
        return withUnsafeTemporaryAllocation(of: Float.self, capacity: ic + hc) { buf in
            inputs.write(to: buf)
            weightsIH.withUnsafeBufferPointer { wIH in
                biasH.withUnsafeBufferPointer { bH in
                    for h in 0..<hc {
                        var sum = bH[h]
                        let rowBase = h * ic
                        for i in 0..<ic { sum += wIH[rowBase + i] * buf[i] }
                        buf[ic + h] = tanh(sum)
                    }
                }
            }
            var out = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
            weightsHO.withUnsafeBufferPointer { wHO in
                biasO.withUnsafeBufferPointer { bO in
                    @inline(__always)
                    func neuron(_ o: Int) -> Float {
                        var sum = bO[o]
                        let rowBase = o * hc
                        for h in 0..<hc { sum += wHO[rowBase + h] * buf[ic + h] }
                        return 1.0 / (1.0 + exp(-sum))   // sigmoid
                    }
                    out = (neuron(0), neuron(1), neuron(2), neuron(3), neuron(4), neuron(5))
                }
            }
            return ActionOutput(turnAngle: out.0, speed: out.1,
                                wantsToReproduce: out.2, wantsToAttack: out.3,
                                wantsToEatPlant: out.4, wantsToEatCorpse: out.5)
        }
    }
}

// MARK: - Sensor data (inputs)

struct SensorInput {
    var angleToFood:               Float   // -1 (left) to +1 (right), relative to the heading
    var distanceToFood:            Float   // 0 = right next to it, 1 = edge of the sight radius
    var angleToCreature:           Float
    var distanceToCreature:        Float
    var ownEnergy:                 Float   // 0 = empty, 1 = full
    var localDensity:              Float   // 0 = alone, 1 = densely surrounded by others
    var approachVelocity:          Float   // >0 = creature closing in, <0 = fleeing; normalized [-1, +1]
    var nearestFoodType:           Float   // 0 = plant, 1 = corpse
    var avgNearbyHeading:          Float   // mean heading of neighbours relative to own [-1, +1]
    // Color of the nearest visible creature (genes in [0,1]; 0.5/0.5/0.5 when none is visible)
    var nearestCreatureRed:        Float
    var nearestCreatureGreen:      Float
    var nearestCreatureBlue:       Float
    var visibleCreatureCount:      Float   // normalized [0,1]: min(count, 10) / 10
    var ownSenescence:             Float   // 0 = young, 1 = deeply aged
    var visibleFoodCount:          Float   // normalized [0,1]: min(count, 10) / 10
    var localPlantDensity:         Float   // 0 = barren, 1 = lush (omnidirectional smell, scaled by the olfaction gene)
    var recentFeedingRate:         Float   // 0 = has not eaten in a long while, 1 = well fed
    // Perception of the current biome, expressed functionally rather than as a one-hot id:
    // the creature "feels" the ecological conditions where it stands and can tell them apart.
    var localFertility:            Float   // 0 = barren (desert/water), 1 = the lushest zone (wetland)
    var localCover:                Float   // 0 = clear view, 1 = maximum cover (forest)
    var localDifficulty:           Float   // 0 = easy going, 1 = the heaviest ground (wetland)
    // Direction-resolved terrain perception across the field of view: per biome -1 (left) ...
    // +1 (right), with 0 meaning out of sight or dead ahead. This is what lets creatures steer
    // toward preferred terrain and away from water.
    var terrainBearingGrassland:   Float
    var terrainBearingForest:      Float
    var terrainBearingDesert:      Float
    var terrainBearingWetland:     Float
    var terrainBearingWater:       Float

    // Writes the inputs into a (stack) buffer — the order defines the network's input layout.
    func write(to buf: UnsafeMutableBufferPointer<Float>) {
        buf[0]  = angleToFood
        buf[1]  = distanceToFood
        buf[2]  = angleToCreature
        buf[3]  = distanceToCreature
        buf[4]  = ownEnergy
        buf[5]  = localDensity
        buf[6]  = approachVelocity
        buf[7]  = nearestFoodType
        buf[8]  = avgNearbyHeading
        buf[9]  = nearestCreatureRed
        buf[10] = nearestCreatureGreen
        buf[11] = nearestCreatureBlue
        buf[12] = visibleCreatureCount
        buf[13] = ownSenescence
        buf[14] = visibleFoodCount
        buf[15] = localPlantDensity
        buf[16] = recentFeedingRate
        buf[17] = localFertility
        buf[18] = localCover
        buf[19] = localDifficulty
        buf[20] = terrainBearingGrassland
        buf[21] = terrainBearingForest
        buf[22] = terrainBearingDesert
        buf[23] = terrainBearingWetland
        buf[24] = terrainBearingWater
    }
}

// MARK: - Actions (outputs)

struct ActionOutput {
    var turnAngle:        Float   // sigmoid -> [0,1], mapped to [-maxTurn, +maxTurn] in Creature
    var speed:            Float   // [0,1] -> scaled to pixels per tick
    var wantsToReproduce: Float   // > 0.5 = yes
    var wantsToAttack:    Float   // > 0.5 = attack the nearest creature
    // Separate feeding switches, so the network can evolve selective diets (plants yes, carrion no, or the reverse).
    var wantsToEatPlant:  Float   // > 0.5 = actively eat a plant within reach
    var wantsToEatCorpse: Float   // > 0.5 = actively eat a corpse within reach

    init(turnAngle: Float, speed: Float, wantsToReproduce: Float,
         wantsToAttack: Float, wantsToEatPlant: Float, wantsToEatCorpse: Float) {
        self.turnAngle        = turnAngle
        self.speed            = speed
        self.wantsToReproduce = wantsToReproduce
        self.wantsToAttack    = wantsToAttack
        self.wantsToEatPlant  = wantsToEatPlant
        self.wantsToEatCorpse = wantsToEatCorpse
    }

    init(fromArray arr: [Float]) {
        turnAngle        = arr.count > 0 ? arr[0] : 0.5
        speed            = arr.count > 1 ? arr[1] : 0
        wantsToReproduce = arr.count > 2 ? arr[2] : 0
        wantsToAttack    = arr.count > 3 ? arr[3] : 0
        wantsToEatPlant  = arr.count > 4 ? arr[4] : 1   // default: eat (a safe start)
        wantsToEatCorpse = arr.count > 5 ? arr[5] : 1   // default: eat (a safe start)
    }
}
