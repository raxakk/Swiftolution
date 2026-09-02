import Foundation
import CoreGraphics

// MARK: - Biome

// A biome is an ecological zone with a character of its own. Each one modulates
// four things: how much plant food grows there (fertility x growthFactor), how
// fast you move (speedFactor), how far you see (sightFactor — cover), and whether
// you can enter it at all (isPassable — water is a barrier for geographic
// isolation). The values deliberately pull against each other so that no biome is
// good at everything and different niches reward different phenotypes.
enum Biome: Int, CaseIterable {
    case grassland   // the default: fertile, open, easy to cross
    case forest      // moderately fertile, plenty of cover (short sight)
    case desert      // barren, open (long sight), heavy going
    case wetland     // very fertile, but slow to traverse
    case water       // no food, impassable (a barrier)

    // A stable English identifier. The UI looks it up in the string catalog for display; the
    // headless runner prints it as is.
    var name: String {
        switch self {
        case .grassland: return "Grassland"
        case .forest:    return "Forest"
        case .desert:    return "Desert"
        case .wetland:   return "Wetland"
        case .water:     return "Water"
        }
    }

    // Plant carrying capacity relative to grassland. 0 = no plants (water).
    var fertility: Float {
        switch self {
        case .grassland: return 1.00
        case .forest:    return 0.70
        case .desert:    return 0.15
        case .wetland:   return 1.30
        case .water:     return 0.00
        }
    }

    // Multiplier on the plant growth rate.
    var growthFactor: Float {
        switch self {
        case .grassland: return 1.20
        case .forest:    return 0.90
        case .desert:    return 0.50
        case .wetland:   return 1.40
        case .water:     return 0.00
        }
    }

    // Movement factor: <1 slows you down (sand, mire). Grassland is neutral.
    var speedFactor: Float {
        switch self {
        case .grassland: return 1.00
        case .forest:    return 0.85
        case .desert:    return 0.80
        case .wetland:   return 0.55
        case .water:     return 0.30   // only ever read as a sensor value — water is impassable anyway
        }
    }

    // Sight factor: <1 = cover (forest shortens sight), >1 = clear view (desert).
    var sightFactor: Float {
        switch self {
        case .grassland: return 1.00
        case .forest:    return 0.55
        case .desert:    return 1.25
        case .wetland:   return 0.85
        case .water:     return 1.00
        }
    }

    // Water blocks movement -> splits populations -> allopatric speciation.
    var isPassable: Bool { self != .water }

    static let maxFertility: Float = 1.30   // wetland — used to normalize sensor values

    // Display color (kept dark so that bright creatures stand out against it).
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

// MARK: - Biome map

// A static partition of the world into biome tiles, generated once per world.
// Generation is a Voronoi diagram over random seed points: every tile takes the
// biome of its nearest seed (toroidal distance, matching the wrap-around world).
// The result is contiguous regions rather than per-tile noise. At least two water
// seeds are guaranteed, so there are always real barriers.
struct BiomeMap {

    let cols: Int
    let rows: Int
    let tileSize: CGFloat
    private let tiles: [Biome]   // row-major, cols x rows

    init(worldSize: CGSize, tileSize: CGFloat = 200) {
        self.tileSize = tileSize
        let cols = max(1, Int((worldSize.width  / tileSize).rounded(.up)))
        let rows = max(1, Int((worldSize.height / tileSize).rounded(.up)))
        self.cols = cols
        self.rows = rows
        self.tiles = BiomeMap.generate(cols: cols, rows: rows,
                                       worldSize: worldSize, tileSize: tileSize)
    }

    // Explicit tiles (tests / custom maps).
    init(tiles: [Biome], cols: Int, rows: Int, tileSize: CGFloat) {
        precondition(tiles.count == cols * rows, "tiles.count must be cols x rows")
        self.tiles    = tiles
        self.cols     = cols
        self.rows     = rows
        self.tileSize = tileSize
    }

    // MARK: Queries

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

    // MARK: Directional perception

    // Direction-resolved terrain perception across the sight cone: one value in [-1, 1]
    // per biome — the sign is the direction (-1 left ... +1 right, relative to the heading)
    // and the magnitude is how strongly that biome sits in the field of view. Nearer samples
    // count for more; the sum is normalized over all samples so the values stay bounded.
    // Uniform terrain all around yields ~0 (the contributions cancel), which is correct:
    // there is no directional signal to report.
    //
    // What gets sampled is the creature's OWN sight cone (a polar grid of distance rings x
    // angles), not the tile grid. Reason: real sight radii are ~20-160 px while tiles are
    // 200 px, so sampling tile centres almost never found a tile within sight — not even the
    // creature's own — and returned a constant 0. Resolution now follows the sight radius
    // rather than the tile size, and works at any radius.
    //
    // The angle offsets cover the cone by construction, so no FOV check is needed; at 360
    // degrees the full circle falls out automatically. Read-only, hence safe on the parallel
    // sense() path. The sign follows the convention of angleToFood, so the network reads
    // left/right the same way everywhere.
    func directionalBearings(observerX px: Float, observerY py: Float,
                             headingCos hx: Float, headingSin hy: Float,
                             sightRadius sightR: Float, sightAngle: Float)
        -> (grassland: Float, forest: Float, desert: Float, wetland: Float, water: Float) {

        guard sightR > 0, sightAngle > 0 else { return (0, 0, 0, 0, 0) }

        let rings = 3     // distance rings
        let rays  = 8     // angular samples per ring, spread evenly over the sight cone
        let heading = atan2(hy, hx)
        let half    = sightAngle / 2
        let step    = sightAngle / Float(rays)

        // Left/right accumulator per biome: (grassland, forest, desert, wetland, water)
        var lr: (Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0)
        var totalW: Float = 0

        for r in 0..<rings {
            let frac = (Float(r) + 0.5) / Float(rings)   // 0.17, 0.5, 0.83 of the sight radius
            let dist = frac * sightR
            let w    = 1 - frac                          // closer samples count for more
            for a in 0..<rays {
                let offset = -half + (Float(a) + 0.5) * step   // angle relative to the heading
                let angle  = heading + offset
                let x = px + cos(angle) * dist
                let y = py + sin(angle) * dist
                totalW += w
                let contrib = w * sin(offset)            // -1 left ... +1 right
                // biome(at:) clamps out-of-world points to the edge tile, so at the world
                // border a creature simply perceives more of that same edge terrain.
                switch biome(at: CGPoint(x: CGFloat(x), y: CGFloat(y))) {
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

    // MARK: Generation

    private static func generate(cols: Int, rows: Int,
                                 worldSize: CGSize, tileSize: CGFloat) -> [Biome] {
        let seedCount = max(6, (cols * rows) / 8)

        // Fill a bag of biomes according to the target distribution, then shuffle it.
        // Water is raised to at least 2 seeds so dividing bodies of water always form.
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

        // Scatter the seed points at random.
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
