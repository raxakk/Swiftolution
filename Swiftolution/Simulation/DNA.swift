import Foundation
import CoreGraphics

struct DNA {

    // MARK: - Gene

    var genes: [Float]

    var speed:                Float { genes[0] }
    var sightRadius:          Float { genes[1] }
    var size:                 Float { genes[2] }
    var aggression:           Float { genes[3] }  // 0 = reiner Pflanzenfresser, 1 = reiner Fleischfresser
    var maxAge:                Int   { max(1, Int(genes[4] * 1000)) }
    var reproductionThreshold: Float { genes[5] }
    var brainSize:             Float { genes[6] }   // [0,1] → minHiddenCount…maxHiddenCount Neuronen
    var red:                   Float { genes[7] }
    var green:                 Float { genes[8] }
    var blue:                  Float { genes[9] }
    // 0 = Wüstenangepasst (schnell+effizient in der Wüste), 1 = Waldangepasst (effizient im Wald)
    var habitatPreference:     Float { genes[10] }

    static let neuralWeightsStartIndex = 11

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
            if Float.random(in: 0...1) < rate {
                newGenes[i] += Float.random(in: -strength...strength)
                newGenes[i] = max(0, min(1, newGenes[i]))
            }
        }
        return DNA(genes: newGenes)
    }

    // MARK: - Crossover

    func crossed(with other: DNA) -> DNA {
        let split = Int.random(in: 0..<genes.count)
        let childGenes = Array(genes[0..<split]) + Array(other.genes[split...])
        return DNA(genes: childGenes)
    }

    // MARK: - NN-Gewichte

    func neuralWeights() -> [Float] {
        Array(genes[DNA.neuralWeightsStartIndex...])
    }
}
