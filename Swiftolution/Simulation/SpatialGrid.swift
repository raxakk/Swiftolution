import CoreGraphics

final class SpatialGrid {

    let cellSize: CGFloat
    private let cols: Int
    private let rows: Int
    private var creatureBuckets: [Int: [Creature]]   = [:]
    private var foodBuckets:     [Int: [FoodSource]] = [:]

    init(cellSize: CGFloat, worldSize: CGSize) {
        self.cellSize = cellSize
        self.cols = max(1, Int(ceil(worldSize.width  / cellSize)))
        self.rows = max(1, Int(ceil(worldSize.height / cellSize)))
    }

    // MARK: - Aufbau (einmal pro Tick)

    func rebuild(creatures: [Creature], food: [FoodSource]) {
        creatureBuckets.removeAll(keepingCapacity: true)
        foodBuckets.removeAll(keepingCapacity: true)
        for c in creatures { creatureBuckets[key(c.position), default: []].append(c) }
        for f in food      { foodBuckets[key(f.position),     default: []].append(f) }
    }

    // MARK: - Abfragen

    func nearbyCreatures(to point: CGPoint, within radius: CGFloat) -> [Creature] {
        search(creatureBuckets, near: point, radius: radius)
    }

    func nearbyFood(to point: CGPoint, within radius: CGFloat) -> [FoodSource] {
        search(foodBuckets, near: point, radius: radius)
    }

    // MARK: - Intern

    private func search<T>(_ buckets: [Int: [T]], near point: CGPoint, radius: CGFloat) -> [T] {
        let r    = Int(ceil(radius / cellSize))
        let cCol = min(max(Int(point.x / cellSize), 0), cols - 1)
        let cRow = min(max(Int(point.y / cellSize), 0), rows - 1)
        var out: [T] = []
        for dRow in -r...r {
            for dCol in -r...r {
                let col = cCol + dCol
                let row = cRow + dRow
                guard col >= 0, col < cols, row >= 0, row < rows else { continue }
                if let items = buckets[row * cols + col] { out.append(contentsOf: items) }
            }
        }
        return out
    }

    private func key(_ p: CGPoint) -> Int {
        let col = min(max(Int(p.x / cellSize), 0), cols - 1)
        let row = min(max(Int(p.y / cellSize), 0), rows - 1)
        return row * cols + col
    }
}
