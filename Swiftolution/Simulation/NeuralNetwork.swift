import Foundation

struct NeuralNetwork {

    // MARK: - Architektur

    static let inputCount  = 8
    static let hiddenCount = 8
    static let outputCount = 4   // turnAngle, speed, wantsToReproduce, wantsToAttack

    static var totalWeightCount: Int {
        let layer1 = inputCount * hiddenCount + hiddenCount
        let layer2 = hiddenCount * outputCount + outputCount
        return layer1 + layer2
    }

    // MARK: - Gewichte

    private var weightsInputHidden:  [[Float]]   // [hiddenCount][inputCount]
    private var biasHidden:          [Float]
    private var weightsHiddenOutput: [[Float]]   // [outputCount][hiddenCount]
    private var biasOutput:          [Float]

    // MARK: - Init

    init(weights: [Float]) {
        guard weights.count >= NeuralNetwork.totalWeightCount else {
            weightsInputHidden  = Array(repeating: Array(repeating: 0, count: NeuralNetwork.inputCount),  count: NeuralNetwork.hiddenCount)
            biasHidden          = Array(repeating: 0, count: NeuralNetwork.hiddenCount)
            weightsHiddenOutput = Array(repeating: Array(repeating: 0, count: NeuralNetwork.hiddenCount), count: NeuralNetwork.outputCount)
            biasOutput          = Array(repeating: 0, count: NeuralNetwork.outputCount)
            return
        }

        // DNA-Gene liegen in [0,1]. Für NN-Gewichte auf [-1,1] remappen,
        // damit positive und negative Einflüsse gleichwahrscheinlich sind.
        // Ohne das würden alle Neuronen systematisch in eine Richtung feuern.
        func w(_ v: Float) -> Float { v * 2 - 1 }

        var idx = 0
        var wIH = [[Float]]()
        var bH  = [Float]()

        for _ in 0..<NeuralNetwork.hiddenCount {
            wIH.append(weights[idx..<idx + NeuralNetwork.inputCount].map(w))
            idx += NeuralNetwork.inputCount
            bH.append(w(weights[idx]))
            idx += 1
        }

        var wHO = [[Float]]()
        var bO  = [Float]()

        for _ in 0..<NeuralNetwork.outputCount {
            wHO.append(weights[idx..<idx + NeuralNetwork.hiddenCount].map(w))
            idx += NeuralNetwork.hiddenCount
            bO.append(w(weights[idx]))
            idx += 1
        }

        weightsInputHidden  = wIH
        biasHidden          = bH
        weightsHiddenOutput = wHO
        biasOutput          = bO
    }

    // MARK: - Forward Pass

    func activate(inputs: SensorInput) -> ActionOutput {
        let hidden = computeLayer(
            inputs: inputs.toArray(),
            weights: weightsInputHidden,
            biases: biasHidden,
            activation: tanhActivation
        )
        let output = computeLayer(
            inputs: hidden,
            weights: weightsHiddenOutput,
            biases: biasOutput,
            activation: sigmoid
        )
        return ActionOutput(fromArray: output)
    }

    // MARK: - Hilfsmethoden

    private func computeLayer(
        inputs: [Float],
        weights: [[Float]],
        biases: [Float],
        activation: (Float) -> Float
    ) -> [Float] {
        zip(weights, biases).map { row, bias in
            let sum = zip(row, inputs).reduce(bias) { $0 + $1.0 * $1.1 }
            return activation(sum)
        }
    }

    private func sigmoid(_ x: Float) -> Float {
        1.0 / (1.0 + exp(-x))
    }

    private func tanhActivation(_ x: Float) -> Float {
        tanh(x)
    }
}

// MARK: - Sensor-Daten (Inputs)

struct SensorInput {
    var angleToFood:               Float   // -1 (links) bis +1 (rechts), relativ zur Blickrichtung
    var distanceToFood:            Float   // 0 = direkt daneben, 1 = Rand des Sichtradius
    var angleToCreature:           Float
    var distanceToCreature:        Float
    var ownEnergy:                 Float   // 0 = leer, 1 = voll
    var ownAge:                    Float   // 0 = neugeboren, 1 = maximales Alter
    var localDensity:              Float   // 0 = allein, 1 = sehr viele Artgenossen in der Nähe
    var aggressionOfNearestCreature: Float // 0 = Pflanzenfresser, 1 = Fleischfresser — ermöglicht Beuteerkennung

    func toArray() -> [Float] {
        [angleToFood, distanceToFood, angleToCreature, distanceToCreature,
         ownEnergy, ownAge, localDensity, aggressionOfNearestCreature]
    }
}

// MARK: - Aktionen (Outputs)

struct ActionOutput {
    var turnAngle:        Float   // sigmoid → [0,1], wird in Creature auf [-maxTurn, +maxTurn] gemappt
    var speed:            Float   // [0,1] → wird auf Pixel/Tick skaliert
    var wantsToReproduce: Float   // > 0.5 = ja
    var wantsToAttack:    Float   // > 0.5 = Angriff auf nächstes Lebewesen

    init(fromArray arr: [Float]) {
        turnAngle        = arr.count > 0 ? arr[0] : 0.5
        speed            = arr.count > 1 ? arr[1] : 0
        wantsToReproduce = arr.count > 2 ? arr[2] : 0
        wantsToAttack    = arr.count > 3 ? arr[3] : 0
    }
}
