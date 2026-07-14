import Foundation

struct NeuralNetwork {

    // MARK: - Architektur

    static let inputCount    = 17
    static let minHiddenCount = 4
    static let maxHiddenCount = 16
    static let outputCount   = 5   // turnAngle, speed, wantsToReproduce, wantsToAttack, wantsToEat

    // DNA speichert immer Gewichte für maxHiddenCount — unabhängig von der tatsächlichen Gehirngröße.
    // So bleibt die DNA-Länge konstant und Crossover funktioniert ohne Sonderbehandlung.
    static var totalWeightCount: Int {
        let layer1 = inputCount * maxHiddenCount + maxHiddenCount
        let layer2 = maxHiddenCount * outputCount + outputCount
        return layer1 + layer2
    }

    // MARK: - Gewichte

    // Flache, zeilenweise Buffer statt [[Float]] — zusammenhängender Speicher,
    // keine Pointer-Indirektion pro Neuron.
    let hiddenCount: Int
    private var weightsIH: [Float]   // hiddenCount × inputCount
    private var biasH:     [Float]   // hiddenCount
    private var weightsHO: [Float]   // outputCount × hiddenCount
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

        // DNA-Gene liegen in [0,1]. Für NN-Gewichte auf [-1,1] remappen,
        // damit positive und negative Einflüsse gleichwahrscheinlich sind.
        // Ohne das würden alle Neuronen systematisch in eine Richtung feuern.
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

    // Heißester Pfad der Simulation (Population × 30 Aufrufe pro Frame):
    // Input- und Hidden-Werte leben in einem Stack-Puffer, keine Heap-Allokation.
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
            var out = (Float(0), Float(0), Float(0), Float(0), Float(0))
            weightsHO.withUnsafeBufferPointer { wHO in
                biasO.withUnsafeBufferPointer { bO in
                    @inline(__always)
                    func neuron(_ o: Int) -> Float {
                        var sum = bO[o]
                        let rowBase = o * hc
                        for h in 0..<hc { sum += wHO[rowBase + h] * buf[ic + h] }
                        return 1.0 / (1.0 + exp(-sum))   // Sigmoid
                    }
                    out = (neuron(0), neuron(1), neuron(2), neuron(3), neuron(4))
                }
            }
            return ActionOutput(turnAngle: out.0, speed: out.1,
                                wantsToReproduce: out.2, wantsToAttack: out.3,
                                wantsToEat: out.4)
        }
    }
}

// MARK: - Sensor-Daten (Inputs)

struct SensorInput {
    var angleToFood:               Float   // -1 (links) bis +1 (rechts), relativ zur Blickrichtung
    var distanceToFood:            Float   // 0 = direkt daneben, 1 = Rand des Sichtradius
    var angleToCreature:           Float
    var distanceToCreature:        Float
    var ownEnergy:                 Float   // 0 = leer, 1 = voll
    var localDensity:              Float   // 0 = allein, 1 = sehr viele Artgenossen in der Nähe
    var approachVelocity:          Float   // >0 = Kreatur nähert sich, <0 = flieht, normiert [-1, +1]
    var nearestFoodType:           Float   // 0 = Pflanze, 1 = Leiche
    var avgNearbyHeading:          Float   // Ø Bewegungsrichtung der Nachbarn relativ zur eigenen [-1, +1]
    // Farbe der nächsten sichtbaren Kreatur (DNA-Gene [0,1]; 0.5/0.5/0.5 wenn keine sichtbar)
    var nearestCreatureRed:        Float
    var nearestCreatureGreen:      Float
    var nearestCreatureBlue:       Float
    var visibleCreatureCount:      Float   // normiert [0,1]: min(Anzahl, 10) / 10
    var ownSenescence:             Float   // 0 = jung, 1 = hoch gealtert
    var visibleFoodCount:          Float   // normiert [0,1]: min(Anzahl, 10) / 10
    var localPlantDensity:         Float   // 0 = karg, 1 = üppig (omnidirektionaler Geruch, skaliert mit olfaction-Gen)
    var recentFeedingRate:         Float   // 0 = lange nichts gefressen, 1 = gut ernährt

    // Schreibt die Inputs in einen (Stack-)Puffer — Reihenfolge definiert das NN-Input-Layout.
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
    }
}

// MARK: - Aktionen (Outputs)

struct ActionOutput {
    var turnAngle:        Float   // sigmoid → [0,1], wird in Creature auf [-maxTurn, +maxTurn] gemappt
    var speed:            Float   // [0,1] → wird auf Pixel/Tick skaliert
    var wantsToReproduce: Float   // > 0.5 = ja
    var wantsToAttack:    Float   // > 0.5 = Angriff auf nächstes Lebewesen
    var wantsToEat:       Float   // > 0.5 = Nahrung in Reichweite aktiv fressen

    init(turnAngle: Float, speed: Float, wantsToReproduce: Float,
         wantsToAttack: Float, wantsToEat: Float) {
        self.turnAngle        = turnAngle
        self.speed            = speed
        self.wantsToReproduce = wantsToReproduce
        self.wantsToAttack    = wantsToAttack
        self.wantsToEat       = wantsToEat
    }

    init(fromArray arr: [Float]) {
        turnAngle        = arr.count > 0 ? arr[0] : 0.5
        speed            = arr.count > 1 ? arr[1] : 0
        wantsToReproduce = arr.count > 2 ? arr[2] : 0
        wantsToAttack    = arr.count > 3 ? arr[3] : 0
        wantsToEat       = arr.count > 4 ? arr[4] : 1   // Default: fressen (sicherer Start)
    }
}
