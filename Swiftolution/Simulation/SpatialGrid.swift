import CoreGraphics

final class SpatialGrid {

    let cellSize: CGFloat
    private let cols: Int
    private let rows: Int
    // Flache Zell-Arrays statt Dictionary: kein Hashing, und removeAll(keepingCapacity:)
    // pro Zelle erhält die Kapazität — nach Aufwärmphase ist rebuild() allokationsfrei.
    private var creatureCells: [[Creature]]
    private var foodCells:     [[FoodSource]]

    init(cellSize: CGFloat, worldSize: CGSize) {
        self.cellSize = cellSize
        self.cols = max(1, Int(ceil(worldSize.width  / cellSize)))
        self.rows = max(1, Int(ceil(worldSize.height / cellSize)))
        self.creatureCells = Array(repeating: [], count: cols * rows)
        self.foodCells     = Array(repeating: [], count: cols * rows)
    }

    // MARK: - Aufbau (einmal pro Tick)

    func rebuild(creatures: [Creature], food: [FoodSource]) {
        for i in creatureCells.indices { creatureCells[i].removeAll(keepingCapacity: true) }
        for i in foodCells.indices     { foodCells[i].removeAll(keepingCapacity: true) }
        for c in creatures { creatureCells[key(c.position)].append(c) }
        for f in food      { foodCells[key(f.position)].append(f) }
    }

    // MARK: - Abfragen (allokationsfrei — Kandidaten werden per Closure geliefert)

    // Liefert alle Kandidaten in den Zellen rund um point. Kein Distanz-Filter —
    // der Aufrufer prüft selbst (typisch mit quadrierter Distanz).
    func forEachCreature(near point: CGPoint, within radius: CGFloat, _ body: (Creature) -> Void) {
        forEachCell(near: point, radius: radius) { cell in
            for c in creatureCells[cell] { body(c) }
        }
    }

    func forEachFood(near point: CGPoint, within radius: CGFloat, _ body: (FoodSource) -> Void) {
        forEachCell(near: point, radius: radius) { cell in
            for f in foodCells[cell] { body(f) }
        }
    }

    // MARK: - Intern

    @inline(__always)
    private func forEachCell(near point: CGPoint, radius: CGFloat, _ body: (Int) -> Void) {
        let r    = Int(ceil(radius / cellSize))
        let cCol = min(max(Int(point.x / cellSize), 0), cols - 1)
        let cRow = min(max(Int(point.y / cellSize), 0), rows - 1)
        let rowLo = max(cRow - r, 0), rowHi = min(cRow + r, rows - 1)
        let colLo = max(cCol - r, 0), colHi = min(cCol + r, cols - 1)
        for row in rowLo...rowHi {
            let base = row * cols
            for col in colLo...colHi { body(base + col) }
        }
    }

    private func key(_ p: CGPoint) -> Int {
        let col = min(max(Int(p.x / cellSize), 0), cols - 1)
        let row = min(max(Int(p.y / cellSize), 0), rows - 1)
        return row * cols + col
    }
}
