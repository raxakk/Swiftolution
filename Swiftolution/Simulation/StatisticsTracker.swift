import Foundation
import Combine

struct StatSnapshot: Identifiable {
    let id: Int   // tick — eindeutig innerhalb einer Simulation
    let tick: Int
    let herbivores: Int
    let carnivores: Int
    let plantFood: Int
    let avgAggression: Double
    let avgSpeed: Double
    let avgSize: Double
}

final class StatisticsTracker: ObservableObject {
    @Published private(set) var snapshots: [StatSnapshot] = []

    private let maxSnapshots   = 300
    private let recordInterval = 10

    func update(world: World) {
        guard world.tickCount % recordInterval == 0 else { return }

        let creatures    = world.creatures
        let herbivores   = creatures.filter { $0.dna.aggression <= 0.45 }.count
        let carnivores   = creatures.filter { $0.dna.aggression  > 0.45 }.count
        let plantFood    = world.foodSources.filter { $0.type == .plant }.count
        let n            = Double(creatures.count)
        let avgAggression = n > 0 ? Double(creatures.map { $0.dna.aggression }.reduce(0, +)) / n : 0
        let avgSpeed      = n > 0 ? Double(creatures.map { $0.dna.speed      }.reduce(0, +)) / n : 0
        let avgSize       = n > 0 ? Double(creatures.map { $0.dna.size       }.reduce(0, +)) / n : 0

        snapshots.append(StatSnapshot(
            id:            world.tickCount,
            tick:          world.tickCount,
            herbivores:    herbivores,
            carnivores:    carnivores,
            plantFood:     plantFood,
            avgAggression: avgAggression,
            avgSpeed:      avgSpeed,
            avgSize:       avgSize
        ))

        if snapshots.count > maxSnapshots { snapshots.removeFirst() }
    }

    func reset() { snapshots = [] }
}
