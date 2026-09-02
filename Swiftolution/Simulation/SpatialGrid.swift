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

    // Zellen der Bounding-Box des Abfragekreises — enthält jede Zelle, die einen Punkt
    // innerhalb von radius halten kann. Alle Aufrufer prüfen die Distanz selbst, deshalb
    // darf der Scan so eng wie möglich sein: ein Block in Zellschritten (±ceil(radius/cellSize))
    // scannte für einen eatRadius von ~12 px 3×3 Zellen = 57.600 px² statt 452 px².
    @inline(__always)
    private func forEachCell(near point: CGPoint, radius: CGFloat, _ body: (Int) -> Void) {
        let colLo = min(max(Int((point.x - radius) / cellSize), 0), cols - 1)
        let colHi = min(max(Int((point.x + radius) / cellSize), 0), cols - 1)
        let rowLo = min(max(Int((point.y - radius) / cellSize), 0), rows - 1)
        let rowHi = min(max(Int((point.y + radius) / cellSize), 0), rows - 1)
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
