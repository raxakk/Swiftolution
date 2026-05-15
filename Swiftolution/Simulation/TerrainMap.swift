import CoreGraphics

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#endif

// MARK: - Terrain-Typen

enum TerrainType {
    case grassland   // neutral — ausgeglichener Standard
    case forest      // dichtes Gestrüpp: langsamer, aber viel Nahrung
    case desert      // offenes Gelände: schnell, aber heiß und nahrungsarm
}

extension TerrainType {

    // Multiplikator für die tatsächliche Bewegungsgeschwindigkeit — unabhängig von Habitatpräferenz
    var baseSpeedModifier: Float {
        switch self {
        case .grassland: return 1.0
        case .forest:    return 0.70   // dichtes Gestrüpp verlangsamt alle
        case .desert:    return 1.15   // offenes Gelände — schnell, aber erschöpfend
        }
    }

    // Gewichtung für Nahrungswachstum (höher = Nahrung erscheint öfter)
    var foodWeight: Float {
        switch self {
        case .grassland: return 0.55
        case .forest:    return 1.00   // üppige Vegetation
        case .desert:    return 0.05   // karg
        }
    }

    // Hintergrundfarbe für die Visualisierung
    var color: PlatformColor {
        switch self {
        case .grassland: return PlatformColor(red: 0.08, green: 0.11, blue: 0.07, alpha: 1)
        case .forest:    return PlatformColor(red: 0.04, green: 0.10, blue: 0.04, alpha: 1)
        case .desert:    return PlatformColor(red: 0.17, green: 0.13, blue: 0.05, alpha: 1)
        }
    }
}

// MARK: - Terrain-Karte

struct TerrainMap {
    let cellSize:  CGFloat
    let worldSize: CGSize
    private let tiles: [[TerrainType]]
    let cols: Int
    let rows: Int

    init(worldSize: CGSize, cellSize: CGFloat = 60) {
        self.worldSize = worldSize
        self.cellSize  = cellSize
        self.cols = max(1, Int(ceil(worldSize.width  / cellSize)))
        self.rows = max(1, Int(ceil(worldSize.height / cellSize)))
        self.tiles = TerrainMap.generate(cols: cols, rows: rows)
    }

    // Terrain an einer Weltposition abfragen
    func at(_ point: CGPoint) -> TerrainType {
        let col = min(max(Int(point.x / cellSize), 0), cols - 1)
        let row = min(max(Int(point.y / cellSize), 0), rows - 1)
        return tiles[row][col]
    }

    // Pixelrechteck einer Zelle — für das Rendering
    func cellRect(col: Int, row: Int) -> CGRect {
        CGRect(x: CGFloat(col) * cellSize, y: CGFloat(row) * cellSize,
               width: cellSize, height: cellSize)
    }

    func forEachCell(_ body: (Int, Int, TerrainType) -> Void) {
        for r in 0..<rows { for c in 0..<cols { body(c, r, tiles[r][c]) } }
    }

    // MARK: - Voronoi-Generierung

    private static func generate(cols: Int, rows: Int) -> [[TerrainType]] {
        struct Seed { let cx: Double; let cy: Double; let type: TerrainType }

        // Biom-Verteilung: Grasland am häufigsten
        let palette: [TerrainType] = [
            .grassland, .grassland, .grassland, .grassland,
            .forest, .forest, .forest,
            .desert, .desert,
        ]
        let seeds = (0..<18).map { _ in
            Seed(cx: Double.random(in: 0...Double(cols)),
                 cy: Double.random(in: 0...Double(rows)),
                 type: palette.randomElement()!)
        }

        return (0..<rows).map { row in
            (0..<cols).map { col in
                seeds.min {
                    let d1 = ($0.cx - Double(col)) * ($0.cx - Double(col))
                           + ($0.cy - Double(row)) * ($0.cy - Double(row))
                    let d2 = ($1.cx - Double(col)) * ($1.cx - Double(col))
                           + ($1.cy - Double(row)) * ($1.cy - Double(row))
                    return d1 < d2
                }!.type
            }
        }
    }
}
