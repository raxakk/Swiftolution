import Foundation
import Combine

struct StatSnapshot: Identifiable {
    let id: Int   // tick — eindeutig innerhalb einer Simulation
    let tick: Int
    let herbivores: Int
    let omnivores:  Int
    let carnivores: Int
    let plantFood: Int
    let corpseFood: Int
    let avgAggression: Double
    let avgSpeed: Double
    let avgSize: Double
    let avgBrainSize: Double
    let avgMaxAge: Double     // gene value [0,1] — 0 = short-lived, 1 = long-lived
    let avgLitterSize: Double // gene value [0,1] — 0 = K-strategist, 1 = r-strategist
    let avgEnergy: Double     // [0,1] — the mean energy level
}

final class StatisticsTracker: ObservableObject {
    @Published private(set) var snapshots: [StatSnapshot] = []

    private let maxSnapshots   = 300
    private let recordInterval = 10

    func update(world: World) {
        guard world.tickCount % recordInterval == 0 else { return }

        let creatures = world.creatures
        let herbivores = creatures.filter { $0.dna.aggression <= 0.33 }.count
        let omnivores  = creatures.filter { $0.dna.aggression > 0.33 && $0.dna.aggression <= 0.67 }.count
        let carnivores = creatures.filter { $0.dna.aggression > 0.67 }.count
        let corpseFood = world.foodSources.filter { $0.type == .corpse }.count
        let n = Double(creatures.count)

        func avg(_ f: (Creature) -> Float) -> Double {
            n > 0 ? Double(creatures.map(f).reduce(0, +)) / n : 0
        }

        snapshots.append(StatSnapshot(
            id:            world.tickCount,
            tick:          world.tickCount,
            herbivores:    herbivores,
            omnivores:     omnivores,
            carnivores:    carnivores,
            plantFood:     world.plantCount,
            corpseFood:    corpseFood,
            avgAggression: avg { $0.dna.aggression },
            avgSpeed:      avg { $0.dna.speed },
            avgSize:       avg { $0.dna.size },
            avgBrainSize:  avg { $0.dna.brainSize },
            avgMaxAge:     avg { $0.dna.genes[4] },
            avgLitterSize: avg { $0.dna.genes[10] },
            avgEnergy:     avg { $0.energy / $0.maxEnergy }
        ))

        if snapshots.count > maxSnapshots { snapshots.removeFirst() }
    }

    func reset() { snapshots = [] }
}
