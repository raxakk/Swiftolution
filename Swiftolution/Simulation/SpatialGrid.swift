import CoreGraphics

final class SpatialGrid {

    let cellSize: CGFloat
    private let cols: Int
    private let rows: Int
    // Flat cell arrays instead of a dictionary: no hashing, and removeAll(keepingCapacity:)
    // per cell keeps the capacity, so rebuild() is allocation-free once warmed up.
    private var creatureCells: [[Creature]]
    private var foodCells:     [[FoodSource]]

    // A separate, finer raster for plant density: smell radii start at 30 px, for which the
    // 80 px neighbourhood cells would be far too coarse.
    private static let densityCellSize: CGFloat = 32
    private let dCols: Int
    private let dRows: Int
    private var plantCounts: [Int32]           // plants per density cell
    private var plantSAT:    [Int32]           // summed-area table, (dCols+1) x (dRows+1)

    init(cellSize: CGFloat, worldSize: CGSize) {
        self.cellSize = cellSize
        self.cols = max(1, Int(ceil(worldSize.width  / cellSize)))
        self.rows = max(1, Int(ceil(worldSize.height / cellSize)))
        self.creatureCells = Array(repeating: [], count: cols * rows)
        self.foodCells     = Array(repeating: [], count: cols * rows)
        let dc = max(1, Int(ceil(worldSize.width  / SpatialGrid.densityCellSize)))
        let dr = max(1, Int(ceil(worldSize.height / SpatialGrid.densityCellSize)))
        self.dCols = dc
        self.dRows = dr
        self.plantCounts = [Int32](repeating: 0, count: dc * dr)
        self.plantSAT    = [Int32](repeating: 0, count: (dc + 1) * (dr + 1))
    }

    // MARK: - Rebuild (once per tick)

    func rebuild(creatures: [Creature], food: [FoodSource]) {
        for i in creatureCells.indices { creatureCells[i].removeAll(keepingCapacity: true) }
        for i in foodCells.indices     { foodCells[i].removeAll(keepingCapacity: true) }
        for c in creatures { creatureCells[key(c.position)].append(c) }
        for f in food      { foodCells[key(f.position)].append(f) }
        rebuildPlantDensity(food: food)
    }

    // Summed-area table over the plant count per cell. Costs O(cells) per tick and makes the
    // density query O(1) afterwards. Before this, the smell radius (up to 200 px) was the
    // binding radius of the food query in sense(), even though it contributes a single number.
    private func rebuildPlantDensity(food: [FoodSource]) {
        let cs = SpatialGrid.densityCellSize
        for i in plantCounts.indices { plantCounts[i] = 0 }
        for f in food where f.type == .plant {
            let col = min(max(Int(f.position.x / cs), 0), dCols - 1)
            let row = min(max(Int(f.position.y / cs), 0), dRows - 1)
            plantCounts[row * dCols + col] += 1
        }
        // sat[r+1][c+1] = sat[r][c+1] + row sum up to c. Row 0 and column 0 stay 0 (the border).
        let w = dCols + 1
        for r in 0..<dRows {
            var rowSum: Int32 = 0
            let above = r * w
            let cur   = (r + 1) * w
            for c in 0..<dCols {
                rowSum += plantCounts[r * dCols + c]
                plantSAT[cur + c + 1] = plantSAT[above + c + 1] + rowSum
            }
        }
    }

    // MARK: - Queries (allocation-free: candidates are handed to a closure)

    // Yields every candidate in the cells around point. No distance filter; the caller does
    // that itself, typically on squared distances.
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

    // Plants within a radius, O(1) via the summed-area table. It is an approximation: the
    // enclosing box (32 px raster) is counted rather than the circle, then scaled by pi/4 to
    // the expected circle area. That is ample for a density value which gets clamped to [0,1]
    // anyway, whereas an exact counting scan forced the food pass out to the smell radius.
    func plantsNear(_ point: CGPoint, within radius: CGFloat) -> Float {
        let cs = SpatialGrid.densityCellSize
        let c0 = min(max(Int((point.x - radius) / cs), 0), dCols - 1)
        let c1 = min(max(Int((point.x + radius) / cs), 0), dCols - 1)
        let r0 = min(max(Int((point.y - radius) / cs), 0), dRows - 1)
        let r1 = min(max(Int((point.y + radius) / cs), 0), dRows - 1)
        let w = dCols + 1
        let a = plantSAT[r0 * w + c0]
        let b = plantSAT[r0 * w + (c1 + 1)]
        let c = plantSAT[(r1 + 1) * w + c0]
        let d = plantSAT[(r1 + 1) * w + (c1 + 1)]
        return Float(d - b - c + a) * 0.7853982   // pi/4: box -> circle
    }

    // MARK: - Internals

    // The cells of the query circle's bounding box: every cell that can hold a point within
    // radius. All callers check the true distance themselves, so the scan may be as tight as
    // possible: a block in cell steps (+/-ceil(radius / cellSize)) scanned 3x3 cells for an
    // eatRadius of ~12 px, i.e. 57,600 px2 of candidates instead of 452 px2.
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
