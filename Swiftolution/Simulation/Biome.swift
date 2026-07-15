import Foundation
import CoreGraphics

// MARK: - Biom

// Ein Biom ist eine ökologische Zone mit eigenem Charakter. Jedes Biom moduliert
// vier Dinge: wie viel Pflanzennahrung dort wächst (fertility × growthFactor),
// wie schnell man sich bewegt (speedFactor), wie weit man sieht (sightFactor —
// Deckung) und ob man es überhaupt betreten kann (isPassable — Wasser ist eine
// Barriere für geografische Isolation). Die Werte sind bewusst gegenläufig, damit
// kein Biom in allem gut ist und verschiedene Nischen verschiedene Phänotypen belohnen.
enum Biome: Int, CaseIterable {
    case grassland   // Wiese  — Standard: fruchtbar, offen, leicht begehbar
    case forest      // Wald   — mäßig fruchtbar, viel Deckung (kurze Sicht)
    case desert      // Wüste  — karg, offen (weite Sicht), zähe Fortbewegung
    case wetland     // Sumpf  — sehr fruchtbar, aber langsam zu durchqueren
    case water       // Wasser — keine Nahrung, unpassierbar (Barriere)

    var name: String {
        switch self {
        case .grassland: return "Wiese"
        case .forest:    return "Wald"
        case .desert:    return "Wüste"
        case .wetland:   return "Sumpf"
        case .water:     return "Wasser"
        }
    }

    // Pflanzen-Tragfähigkeit relativ zur Wiese. 0 = keine Pflanzen (Wasser).
    var fertility: Float {
        switch self {
        case .grassland: return 1.00
        case .forest:    return 0.70
        case .desert:    return 0.15
        case .wetland:   return 1.30
        case .water:     return 0.00
        }
    }

    // Multiplikator auf die Pflanzenwachstumsrate.
    var growthFactor: Float {
        switch self {
        case .grassland: return 1.20
        case .forest:    return 0.90
        case .desert:    return 0.50
        case .wetland:   return 1.40
        case .water:     return 0.00
        }
    }

    // Bewegungsfaktor: <1 verlangsamt (Sand, Morast). Grasland = neutral.
    var speedFactor: Float {
        switch self {
        case .grassland: return 1.00
        case .forest:    return 0.85
        case .desert:    return 0.80
        case .wetland:   return 0.55
        case .water:     return 0.30   // relevant nur als Sensorwert — Wasser ist ohnehin unpassierbar
        }
    }

    // Sichtfaktor: <1 = Deckung (Wald verkürzt die Sicht), >1 = freies Blickfeld (Wüste).
    var sightFactor: Float {
        switch self {
        case .grassland: return 1.00
        case .forest:    return 0.55
        case .desert:    return 1.25
        case .wetland:   return 0.85
        case .water:     return 1.00
        }
    }

    // Wasser blockiert Bewegung → trennt Populationen → allopatrische Artbildung.
    var isPassable: Bool { self != .water }

    static let maxFertility: Float = 1.30   // Sumpf — für die Normierung der Sensorwerte

    // Darstellungsfarbe (dunkel gehalten, damit helle Kreaturen sich abheben).
    var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .grassland: return (0.20, 0.35, 0.16)
        case .forest:    return (0.10, 0.22, 0.12)
        case .desert:    return (0.38, 0.33, 0.18)
        case .wetland:   return (0.16, 0.28, 0.28)
        case .water:     return (0.10, 0.16, 0.32)
        }
    }
}

// MARK: - Biom-Karte

// Statische Aufteilung der Welt in Biom-Kacheln, einmal pro Welt erzeugt.
// Erzeugung per Voronoi über zufällige Saatpunkte: jede Kachel bekommt das Biom
// des nächstgelegenen Saatpunkts (toroidale Distanz, passend zur Wrap-around-Welt).
// Ergebnis sind zusammenhängende Regionen statt Kachel-Rauschen. Mindestens zwei
// Wasser-Saaten garantieren echte Barrieren.
struct BiomeMap {

    let cols: Int
    let rows: Int
    let tileSize: CGFloat
    private let tiles: [Biome]   // row-major, cols × rows

    init(worldSize: CGSize, tileSize: CGFloat = 200) {
        self.tileSize = tileSize
        let cols = max(1, Int((worldSize.width  / tileSize).rounded(.up)))
        let rows = max(1, Int((worldSize.height / tileSize).rounded(.up)))
        self.cols = cols
        self.rows = rows
        self.tiles = BiomeMap.generate(cols: cols, rows: rows,
                                       worldSize: worldSize, tileSize: tileSize)
    }

    // Explizite Kacheln (Tests / Custom-Karten).
    init(tiles: [Biome], cols: Int, rows: Int, tileSize: CGFloat) {
        precondition(tiles.count == cols * rows, "tiles.count muss cols × rows sein")
        self.tiles    = tiles
        self.cols     = cols
        self.rows     = rows
        self.tileSize = tileSize
    }

    // MARK: Abfragen

    @inline(__always)
    func biome(at point: CGPoint) -> Biome {
        let col = min(max(Int(point.x / tileSize), 0), cols - 1)
        let row = min(max(Int(point.y / tileSize), 0), rows - 1)
        return tiles[row * cols + col]
    }

    func biomeAt(col: Int, row: Int) -> Biome {
        tiles[min(max(row, 0), rows - 1) * cols + min(max(col, 0), cols - 1)]
    }

    func isPassable(_ point: CGPoint) -> Bool { biome(at: point).isPassable }

    // MARK: Richtungswahrnehmung

    // Richtungsaufgelöste Terrain-Wahrnehmung im Sichtkegel: für jedes Biom ein Wert in
    // [-1, 1] — Vorzeichen = Richtung (−1 links … +1 rechts, relativ zur Blickrichtung),
    // Betrag = wie stark dieses Biom im Blickfeld liegt. Nähere Kacheln zählen mehr; die Summe
    // wird über das gesamte sichtbare Terrain normiert, sodass die Werte gebunden bleiben.
    // Nicht in Sicht oder genau voraus → ~0. Damit kann das Netz lernen, aufs bevorzugte Terrain
    // zuzusteuern und Wasser zu meiden. Abtastung über Kachelmittelpunkte — grob, aber für die
    // Richtungsinformation ausreichend. Read-only → sicher im parallelen sense()-Pfad.
    // Das Vorzeichen entspricht der Konvention von angleToFood (gleiche Links/Rechts-Deutung fürs NN).
    func directionalBearings(observerX px: Float, observerY py: Float,
                             headingCos hx: Float, headingSin hy: Float,
                             sightRadius sightR: Float, sightAngle: Float)
        -> (grassland: Float, forest: Float, desert: Float, wetland: Float, water: Float) {

        guard sightR > 0 else { return (0, 0, 0, 0, 0) }
        let ts       = Float(tileSize)
        let sightRSq = sightR * sightR
        let full     = sightAngle >= 2 * .pi * 0.995
        let cosHalf  = cos(sightAngle / 2)

        let minCol = max(0, Int((px - sightR) / ts))
        let maxCol = min(cols - 1, Int((px + sightR) / ts))
        let minRow = max(0, Int((py - sightR) / ts))
        let maxRow = min(rows - 1, Int((py + sightR) / ts))
        guard minCol <= maxCol, minRow <= maxRow else { return (0, 0, 0, 0, 0) }

        // Links/Rechts-Akkumulator je Biom: (grassland, forest, desert, wetland, water)
        var lr: (Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0)
        var totalW: Float = 0

        for row in minRow...maxRow {
            let cy = (Float(row) + 0.5) * ts
            for col in minCol...maxCol {
                let cx = (Float(col) + 0.5) * ts
                let dx = cx - px, dy = cy - py
                let distSq = dx * dx + dy * dy
                guard distSq < sightRSq else { continue }
                let dist    = distSq.squareRoot()
                let invDist = dist > 0 ? 1 / dist : 0
                if !full {
                    let dot = (dx * hx + dy * hy) * invDist   // cos(Winkel zur Kachel)
                    guard dot >= cosHalf else { continue }    // außerhalb des Sichtkegels
                }
                let sinT = (hx * dy - hy * dx) * invDist      // −1 links … +1 rechts
                let w    = 1 - dist / sightR                  // Nähe-Gewicht (dist < sightR)
                totalW  += w
                let contrib = w * sinT
                switch tiles[row * cols + col] {
                case .grassland: lr.0 += contrib
                case .forest:    lr.1 += contrib
                case .desert:    lr.2 += contrib
                case .wetland:   lr.3 += contrib
                case .water:     lr.4 += contrib
                }
            }
        }

        guard totalW > 0 else { return (0, 0, 0, 0, 0) }
        let inv = 1 / totalW
        @inline(__always) func c(_ v: Float) -> Float { max(-1, min(1, v * inv)) }
        return (c(lr.0), c(lr.1), c(lr.2), c(lr.3), c(lr.4))
    }

    // MARK: Erzeugung

    private static func generate(cols: Int, rows: Int,
                                 worldSize: CGSize, tileSize: CGFloat) -> [Biome] {
        let seedCount = max(6, (cols * rows) / 8)

        // Biom-Beutel gemäß Zielverteilung befüllen, dann mischen. Wasser wird auf
        // mindestens 2 Saaten angehoben, damit immer trennende Gewässer entstehen.
        let weights: [(Biome, Int)] = [
            (.grassland, 35), (.forest, 25), (.desert, 15), (.wetland, 10), (.water, 15)
        ]
        var bag: [Biome] = []
        for (biome, w) in weights {
            let n = max(0, Int((Double(w) / 100.0 * Double(seedCount)).rounded()))
            bag.append(contentsOf: repeatElement(biome, count: n))
        }
        while bag.count < seedCount { bag.append(.grassland) }
        if bag.count > seedCount { bag.removeLast(bag.count - seedCount) }
        if bag.filter({ $0 == .water }).count < 2 {
            bag[0] = .water; bag[min(1, bag.count - 1)] = .water
        }
        bag.shuffle()

        // Saatpunkte zufällig platzieren.
        let seeds: [(x: Float, y: Float, biome: Biome)] = bag.map { biome in
            (Float.random(in: 0..<Float(worldSize.width)),
             Float.random(in: 0..<Float(worldSize.height)),
             biome)
        }

        let w = Float(worldSize.width)
        let h = Float(worldSize.height)

        @inline(__always)
        func torDelta(_ a: Float, _ b: Float, _ span: Float) -> Float {
            let d = abs(a - b)
            return min(d, span - d)
        }

        var tiles = [Biome](repeating: .grassland, count: cols * rows)
        for row in 0..<rows {
            let cy = (Float(row) + 0.5) * Float(tileSize)
            for col in 0..<cols {
                let cx = (Float(col) + 0.5) * Float(tileSize)
                var bestDistSq = Float.greatestFiniteMagnitude
                var bestBiome: Biome = .grassland
                for seed in seeds {
                    let dx = torDelta(cx, seed.x, w)
                    let dy = torDelta(cy, seed.y, h)
                    let distSq = dx * dx + dy * dy
                    if distSq < bestDistSq {
                        bestDistSq = distSq
                        bestBiome  = seed.biome
                    }
                }
                tiles[row * cols + col] = bestBiome
            }
        }
        return tiles
    }
}
