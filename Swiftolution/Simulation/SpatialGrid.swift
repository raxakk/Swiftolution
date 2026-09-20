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
        rebuildCreatures(creatures)
        for i in foodCells.indices { foodCells[i].removeAll(keepingCapacity: true) }
        for f in food { foodCells[key(f.position)].append(f) }
        rebuildPlantDensity(food: food)
    }

    // Creatures only. Movement invalidates nothing but the creature cells, so the tick can
    // refile them after the movement step without redoing the food raster (which is the
    // expensive half of a rebuild). Without that second pass the grid is one movement step
    // stale for everything that queries it after movement.
    func rebuildCreatures(_ creatures: [Creature]) {
        for i in creatureCells.indices { creatureCells[i].removeAll(keepingCapacity: true) }
        for c in creatures { creatureCells[key(c.position)].append(c) }
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
    // that itself, typically on squared toroidal distances.
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
    // A box crossing the world seam becomes up to four boxes, one per wrapped span, so smell
    // reaches across the edge exactly as movement does.
    func plantsNear(_ point: CGPoint, within radius: CGFloat) -> Float {
        let cs = SpatialGrid.densityCellSize
        let r = wrappedSpans(floorDiv(point.y - radius, cs), floorDiv(point.y + radius, cs), dRows)
        let c = wrappedSpans(floorDiv(point.x - radius, cs), floorDiv(point.x + radius, cs), dCols)
        var total = boxSum(cols: c.a, rows: r.a)
        if let rb = r.b { total += boxSum(cols: c.a, rows: rb) }
        if let cb = c.b {
            total += boxSum(cols: cb, rows: r.a)
            if let rb = r.b { total += boxSum(cols: cb, rows: rb) }
        }
        return Float(total) * 0.7853982   // pi/4: box -> circle
    }

    // MARK: - Internals

    @inline(__always)
    private func boxSum(cols colSpan: (Int, Int), rows rowSpan: (Int, Int)) -> Int32 {
        let w  = dCols + 1
        let r0 = rowSpan.0, r1 = rowSpan.1
        let c0 = colSpan.0, c1 = colSpan.1
        let a = plantSAT[r0 * w + c0]
        let b = plantSAT[r0 * w + (c1 + 1)]
        let c = plantSAT[(r1 + 1) * w + c0]
        let d = plantSAT[(r1 + 1) * w + (c1 + 1)]
        return d - b - c + a
    }

    // The cells of the query circle's bounding box: every cell that can hold a point within
    // radius. All callers check the true distance themselves, so the scan may be as tight as
    // possible: a block in cell steps (+/-ceil(radius / cellSize)) scanned 3x3 cells for an
    // eatRadius of ~12 px, i.e. 57,600 px2 of candidates instead of 452 px2.
    // Cell indices wrap rather than clamp: the world is a torus, so the block around a point
    // near x=0 has to continue at the far edge. Clamping instead made every query stop dead at
    // the seam while movement walked straight through it. Away from the seam -- the common
    // case by a wide margin -- this is still a single block and costs two comparisons extra.
    @inline(__always)
    private func forEachCell(near point: CGPoint, radius: CGFloat, _ body: (Int) -> Void) {
        let colLo = floorDiv(point.x - radius, cellSize)
        let colHi = floorDiv(point.x + radius, cellSize)
        let rowLo = floorDiv(point.y - radius, cellSize)
        let rowHi = floorDiv(point.y + radius, cellSize)
        if colLo >= 0, colHi < cols, rowLo >= 0, rowHi < rows {
            block(rows: (rowLo, rowHi), cols: (colLo, colHi), body)
            return
        }
        let r = wrappedSpans(rowLo, rowHi, rows)
        let c = wrappedSpans(colLo, colHi, cols)
        block(rows: r.a, cols: c.a, body)
        if let cb = r.b { block(rows: cb, cols: c.a, body) }
        if let cc = c.b {
            block(rows: r.a, cols: cc, body)
            if let cb = r.b { block(rows: cb, cols: cc, body) }
        }
    }

    @inline(__always)
    private func block(rows rowSpan: (Int, Int), cols colSpan: (Int, Int), _ body: (Int) -> Void) {
        for row in rowSpan.0...rowSpan.1 {
            let base = row * cols
            for col in colSpan.0...colSpan.1 { body(base + col) }
        }
    }

    // Cell index of a coordinate, rounding down rather than toward zero: Int(-0.4) is 0, which
    // would fold the first cell outside the world onto the first cell inside it.
    @inline(__always)
    private func floorDiv(_ value: CGFloat, _ size: CGFloat) -> Int {
        Int((value / size).rounded(.down))
    }

    // An index range that may run past either end of the grid, folded onto [0, n). It is one
    // span in the ordinary case and two when it crosses the seam; a range longer than the grid
    // collapses to the whole grid so that nothing is visited (and counted) twice.
    @inline(__always)
    private func wrappedSpans(_ lo: Int, _ hi: Int, _ n: Int) -> (a: (Int, Int), b: (Int, Int)?) {
        let span = hi - lo + 1
        guard span < n else { return ((0, n - 1), nil) }
        var start = lo % n
        if start < 0 { start += n }
        let end = start + span - 1
        if end < n { return ((start, end), nil) }
        return ((start, n - 1), (0, end - n))
    }

    private func key(_ p: CGPoint) -> Int {
        var col = floorDiv(p.x, cellSize) % cols
        if col < 0 { col += cols }
        var row = floorDiv(p.y, cellSize) % rows
        if row < 0 { row += rows }
        return row * cols + col
    }
}
