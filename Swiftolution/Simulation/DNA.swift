import Foundation
import CoreGraphics

struct DNA {

    // MARK: - Genes

    var genes: [Float]

    var speed:                Float { genes[0] }
    var sightRadius:          Float { genes[1] }
    var size:                 Float { genes[2] }
    var aggression:           Float { genes[3] }  // 0 = pure herbivore, 1 = pure carnivore
    var maxAge:                Int   { max(1, Int(genes[4] * 1000)) }
    var reproductionThreshold: Float { genes[5] }
    var brainSize:             Float { genes[6] }   // [0,1] -> minHiddenCount...maxHiddenCount neurons
    var red:                   Float { genes[7] }
    var green:                 Float { genes[8] }
    var blue:                  Float { genes[9] }
    // 0 -> 1 offspring (r-strategist: many, cheap), 1 -> 4 (K-strategist: few, expensive)
    var litterSize:            Int   { max(1, Int(genes[10] * 3) + 1) }   // [1, 4]
    // Sight angle: gene=0 -> 120 degrees (narrow forward cone), gene=1 -> 360 (full circle)
    var sightAngle:            Float { genes[11] }
    // Turn rate: gene=0 -> 0.05 rad/tick (sluggish), gene=1 -> 0.40 rad/tick (nimble)
    var turnRate:              Float { genes[12] }
    // Olfaction: gene=0 -> 30 px (barely), gene=1 -> 200 px (wide omnidirectional perception)
    var olfaction:             Float { genes[13] }
    // Period of the internal clock in ticks: gene=0 -> 10 (frantic), gene=1 -> 200 (slow sweep).
    // It gives the oscillator input its frequency, so how fast a creature paces or zigzags is
    // itself under selection: a hunter needs a different search rhythm than a grazer.
    var oscillatorPeriod:      Float { genes[14] * 190 + 10 }

    static let neuralWeightsStartIndex = 15

    static func totalLength(networkWeightCount: Int) -> Int {
        neuralWeightsStartIndex + networkWeightCount
    }

    // MARK: - Factory

    static func random(networkWeightCount: Int = NeuralNetwork.totalWeightCount) -> DNA {
        let genes = (0..<totalLength(networkWeightCount: networkWeightCount))
            .map { _ in Float.random(in: 0...1) }
        return DNA(genes: genes)
    }

    // MARK: - Mutation

    func mutated(rate: Float = 0.05, strength: Float = 0.1) -> DNA {
        var newGenes = genes
        for i in newGenes.indices {
            guard Float.random(in: 0...1) < rate else { continue }
            let roll = Float.random(in: 0...1)
            let delta: Float
            if roll < 0.01 {
                // 1%: macro mutation, jumps into a new region of strategy space
                delta = Float.random(in: -strength * 5 ... strength * 5)
            } else if roll < 0.05 {
                // 4%: medium mutation, explores a wider neighbourhood
                delta = Float.random(in: -strength * 2 ... strength * 2)
            } else {
                // 95%: micro mutation, fine tuning
                delta = Float.random(in: -strength...strength)
            }
            newGenes[i] = max(0, min(1, newGenes[i] + delta))
        }
        return DNA(genes: newGenes)
    }

    // MARK: - Crossover

    func crossed(with other: DNA) -> DNA {
        let split = Int.random(in: 0..<genes.count)
        let childGenes = Array(genes[0..<split]) + Array(other.genes[split...])
        return DNA(genes: childGenes)
    }

    // MARK: - Network weights

    func neuralWeights() -> [Float] {
        Array(genes[DNA.neuralWeightsStartIndex...])
    }

    // MARK: - Genetic distance (species identity)

    // A "species signature" for assortative mating: color dominates (it is both visible on
    // screen and perceived as a sensor input), with aggression contributing the ecological
    // niche. Deliberately NOT the whole genome: across ~200 network weights every pair would
    // sit at roughly the same distance (the curse of dimensionality), and color is the signal
    // one can actually watch cluster on screen.
    // Euclidean distance over 4 markers in [0,1], so the range is [0, 2].
    func geneticDistance(to other: DNA) -> Float {
        let dr = red        - other.red
        let dg = green      - other.green
        let db = blue       - other.blue
        let da = aggression - other.aggression
        return (dr * dr + dg * dg + db * db + da * da).squareRoot()
    }
}
