import CoreGraphics

final class SpatialGrid {

    let cellSize: CGFloat
    private let cols: Int
    private let rows: Int
    // Flache Zell-Arrays statt Dictionary: kein Hashing, und removeAll(keepingCapacity:)
    // pro Zelle erhält die Kapazität — nach Aufwärmphase ist rebuild() allokationsfrei.
    private var creatureCells: [[Creature]]
    private var foodCells:     [[FoodSource]]

    // Eigenes, feineres Raster für die Pflanzendichte: Geruchsradien beginnen bei 30 px,
    // die 80-px-Nachbarschaftszellen wären dafür zu grob.
    private static let densityCellSize: CGFloat = 32
    private let dCols: Int
    private let dRows: Int
    private var plantCounts: [Int32]           // Pflanzen je Dichtezelle
    private var plantSAT:    [Int32]           // Summed-Area-Table, (dCols+1) × (dRows+1)

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

    // MARK: - Aufbau (einmal pro Tick)

    func rebuild(creatures: [Creature], food: [FoodSource]) {
        for i in creatureCells.indices { creatureCells[i].removeAll(keepingCapacity: true) }
        for i in foodCells.indices     { foodCells[i].removeAll(keepingCapacity: true) }
        for c in creatures { creatureCells[key(c.position)].append(c) }
        for f in food      { foodCells[key(f.position)].append(f) }
        rebuildPlantDensity(food: food)
    }

    // Summed-Area-Table über die Pflanzenzahl je Zelle. Kostet O(Zellen) pro Tick und macht
    // die Dichteabfrage danach O(1) — der Geruchsradius (bis 200 px) war zuvor der bindende
    // Radius der Nahrungsabfrage in sense(), obwohl er dort nur eine Zahl beisteuert.
    private func rebuildPlantDensity(food: [FoodSource]) {
        let cs = SpatialGrid.densityCellSize
        for i in plantCounts.indices { plantCounts[i] = 0 }
        for f in food where f.type == .plant {
            let col = min(max(Int(f.position.x / cs), 0), dCols - 1)
            let row = min(max(Int(f.position.y / cs), 0), dRows - 1)
            plantCounts[row * dCols + col] += 1
        }
        // sat[r+1][c+1] = sat[r][c+1] + Zeilensumme bis c. Zeile 0 und Spalte 0 bleiben 0 (Rand).
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

    // Pflanzen im Umkreis — O(1) über die Summed-Area-Table. Näherung: gezählt wird die
    // umschließende Box (Raster 32 px) statt des Kreises, skaliert mit π/4 auf die
    // erwartete Kreisfläche. Für einen Dichtewert (der ohnehin auf [0,1] gestaucht wird)
    // genügt das; ein exakter Zähl-Scan zwang den Nahrungs-Pass auf den Geruchsradius.
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
        return Float(d - b - c + a) * 0.7853982   // π/4: Box → Kreis
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
