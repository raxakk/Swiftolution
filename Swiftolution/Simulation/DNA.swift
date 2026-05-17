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
    // 0 → 1 Nachkomme (r-Stratege: viele, billige Nachkommen), 1 → 4 (K-Stratege: wenige, teure)
    var litterSize:            Int   { max(1, Int(genes[10] * 3) + 1) }   // [1, 4]
    // Sichtwinkel: gene=0 → 120° (schmaler Vorwärtskegel), gene=1 → 360° (Vollkreis)
    var sightAngle:            Float { genes[11] }
    // Drehgeschwindigkeit: gene=0 → 0.05 rad/Tick (träge), gene=1 → 0.40 rad/Tick (wendig)
    var turnRate:              Float { genes[12] }

    static let neuralWeightsStartIndex = 13

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
                // 1 %: Makro-Mutation — springt in neue Strategie-Region
                delta = Float.random(in: -strength * 5 ... strength * 5)
            } else if roll < 0.05 {
                // 4 %: Mittlere Mutation — erkundet breiteren Bereich
                delta = Float.random(in: -strength * 2 ... strength * 2)
            } else {
                // 95 %: Mikro-Mutation — feines Tuning
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

    // MARK: - NN-Gewichte

    func neuralWeights() -> [Float] {
        Array(genes[DNA.neuralWeightsStartIndex...])
    }
}
