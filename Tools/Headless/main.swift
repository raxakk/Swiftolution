import Foundation
import CoreGraphics

// Headless-Runner für die Swiftolution-Simulation.
// Kompiliert nur den UI-freien Kern (World & Co.) — siehe run.sh.
// Läuft ungebremst (kein 60-fps-Cap) und gibt periodisch Statistiken aus.
//
// Zweck: andere Systeme (inkl. LLM-Agenten) sollen die laufende Simulation so beobachten
// können wie ein Mensch am Bildschirm. Deshalb neben Aggregaten auch:
//   --detail  räumliche ASCII-Weltkarte + Merkmals-Histogramme + Beispielindividuen
//   --json    strukturierte JSON-Lines (ein Objekt pro Intervall) zum maschinellen Auswerten

// MARK: - Optionen

struct Options {
    var ticks           = 5000
    var interval        = 500
    var width           = 2400
    var height          = 1800
    var creatures       = 80
    var foodCapacity    = 500      // Referenz für 800×600, skaliert mit √Fläche (wie die GUI)
    var foodGrowthRate  = 0.05
    var mutationRate:     Float = 0.05
    var mutationStrength: Float = 0.10
    var minSpawn        = 0        // >0 = Mindest-Spawn aktiv mit dieser Schwelle (hält die Welt am Leben)
    var biomes          = false
    var seasons         = false
    var speciation      = true
    var plantToxin      = true
    var csv             = false
    var detail          = false    // ASCII-Karte + Histogramme + Beispielindividuen
    var json            = false    // JSON-Lines statt Tabelle
    var events          = false    // Live-Ereignisstrom (Geburten/Tode je Tick) als NDJSON
    var samples         = 3        // Anzahl Beispielindividuen (detail/json)
    var mapCols         = 60       // Breite der ASCII-Weltkarte
    var foodSteps: [(tick: Int, capacity: Int)] = []   // Nahrungsabsenkungen zur Laufzeit
    // Verhaltens-Trace: wenige Individuen über ein enges Fenster, Wahrnehmung → Entscheidung.
    var trace           = false
    var traceFrom       = 0
    var traceTo         = -1       // -1 → traceFrom + 200 (sinnvolles Default-Fenster)
    var traceEvery      = 1
    var traceCreatures  = 3
    var traceWeights    = false    // rohe NN-Gewichte im Steckbrief (518 Zahlen/Kreatur!)
}

func printUsage() {
    print("""
    swiftolution-headless — Simulation ohne UI

    Verwendung: run.sh [Optionen]

      --ticks N            Anzahl Simulationsschritte (Default 5000)
      --interval N         Statistik alle N Ticks ausgeben (Default 500)
      --width N            Weltbreite in px (Default 2400)
      --height N           Welthöhe in px (Default 1800)
      --creatures N        Startpopulation (Default 80)
      --food-capacity N    Nahrungskapazität, √-skaliert (Default 500)
      --growth F           Nahrungswachstumsrate (Default 0.05)
      --mutation F         Mutationsrate (Default 0.05)
      --mutation-strength F Mutationsstärke (Default 0.10)
      --min-spawn N        Mindest-Spawn: reseedet unter N Kreaturen (Default aus)
      --reduce-food-at T C Bei Tick T die Nahrungskapazität auf C setzen (mehrfach möglich →
                           stufenweise Absenkung; deine Methode: erst max bootstrappen, dann senken)
      --biomes             Biome & Terrain aktivieren
      --seasons            Jahreszeiten aktivieren
      --no-speciation      Assortative Paarung / Artbildung aus
      --no-plant-toxin     Pflanzengift aus

    Beobachtung (reichere Einsicht):
      --detail             ASCII-Weltkarte + Merkmals-Histogramme + Beispielindividuen
      --json               strukturierte JSON-Lines-Snapshots (ein Objekt je Intervall)
      --events             Live-Ereignisstrom: Geburt/Tod je Tick als NDJSON (Tod inkl. Ursache)
      --trace              Verhaltens-Trace: pro Tick Wahrnehmung → Entscheidung einzelner Kreaturen
      --trace-from T       Trace-Fenster ab Tick T (Default 0)
      --trace-to T         Trace-Fenster bis Tick T (Default: traceFrom + 200)
      --trace-every N      nur jeden N-ten Tick tracen (Default 1)
      --trace-creatures N  Anzahl verfolgter Individuen (Default 3: ältestes, fittestes, zufällig)
      --trace-weights      rohe NN-Gewichte im Steckbrief mitgeben (518 Zahlen je Kreatur)
      --samples N          Anzahl Beispielindividuen bei --detail/--json (Default 3)
      --map-cols N         Breite der ASCII-Weltkarte (Default 60)
      --csv                Ausgabe als CSV-Tabelle
      -h, --help           Diese Hilfe
    """)
}

func parseArgs() -> Options {
    var o = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
    func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(2)
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--ticks":            if let v = value(), let n = Int(v)    { o.ticks = n; i += 1 }            else { fail("--ticks braucht eine Zahl") }
        case "--interval":         if let v = value(), let n = Int(v)    { o.interval = max(1, n); i += 1 } else { fail("--interval braucht eine Zahl") }
        case "--width":            if let v = value(), let n = Int(v)    { o.width = n; i += 1 }            else { fail("--width braucht eine Zahl") }
        case "--height":           if let v = value(), let n = Int(v)    { o.height = n; i += 1 }           else { fail("--height braucht eine Zahl") }
        case "--creatures":        if let v = value(), let n = Int(v)    { o.creatures = n; i += 1 }        else { fail("--creatures braucht eine Zahl") }
        case "--food-capacity":    if let v = value(), let n = Int(v)    { o.foodCapacity = n; i += 1 }     else { fail("--food-capacity braucht eine Zahl") }
        case "--growth":           if let v = value(), let n = Double(v) { o.foodGrowthRate = n; i += 1 }   else { fail("--growth braucht eine Zahl") }
        case "--mutation":         if let v = value(), let n = Float(v)  { o.mutationRate = n; i += 1 }     else { fail("--mutation braucht eine Zahl") }
        case "--mutation-strength": if let v = value(), let n = Float(v) { o.mutationStrength = n; i += 1 } else { fail("--mutation-strength braucht eine Zahl") }
        case "--min-spawn":        if let v = value(), let n = Int(v)    { o.minSpawn = n; i += 1 }         else { fail("--min-spawn braucht eine Zahl") }
        case "--reduce-food-at":
            if i + 2 < args.count, let t = Int(args[i + 1]), let cap = Int(args[i + 2]) {
                o.foodSteps.append((t, cap)); i += 2
            } else { fail("--reduce-food-at braucht TICK und KAPAZITÄT") }
        case "--samples":          if let v = value(), let n = Int(v)    { o.samples = max(0, n); i += 1 }  else { fail("--samples braucht eine Zahl") }
        case "--map-cols":         if let v = value(), let n = Int(v)    { o.mapCols = max(10, n); i += 1 } else { fail("--map-cols braucht eine Zahl") }
        case "--biomes":           o.biomes = true
        case "--seasons":          o.seasons = true
        case "--no-speciation":    o.speciation = false
        case "--no-plant-toxin":   o.plantToxin = false
        case "--csv":              o.csv = true
        case "--trace-from":       if let v = value(), let n = Int(v) { o.traceFrom = n; i += 1 }              else { fail("--trace-from braucht eine Zahl") }
        case "--trace-to":         if let v = value(), let n = Int(v) { o.traceTo = n; i += 1 }                else { fail("--trace-to braucht eine Zahl") }
        case "--trace-every":      if let v = value(), let n = Int(v) { o.traceEvery = max(1, n); i += 1 }     else { fail("--trace-every braucht eine Zahl") }
        case "--trace-creatures":  if let v = value(), let n = Int(v) { o.traceCreatures = max(1, n); i += 1 } else { fail("--trace-creatures braucht eine Zahl") }
        case "--trace":            o.trace = true
        case "--trace-weights":    o.traceWeights = true
        case "--detail":           o.detail = true
        case "--json":             o.json = true
        case "--events":           o.events = true
        case "-h", "--help":       printUsage(); exit(0)
        default:                   fail("Unbekanntes Argument: \(a)  (--help für Hilfe)")
        }
        i += 1
    }
    return o
}

// MARK: - Snapshot (eine Momentaufnahme der Welt)

struct SampleJSON: Codable {
    let x, y: Int
    let biome: String?
    let age, maxAge: Int
    let energyPct: Double
    let size, speed, aggression, sightRadius, olfaction: Float
    let litter, brainNeurons: Int
    let actSpeed, actReproduce, actAttack, actEatPlant, actEatCorpse: Float
}

struct BiomeCountJSON: Codable { let biome: String; let count: Int }

// Eine Zeile im Live-Ereignisstrom (NDJSON). type = "birth" | "death".
struct EventJSON: Codable {
    let type: String
    let tick: Int
    let x, y: Int
    let aggression: Float
    let cause: String?   // nur bei death
}

struct SnapshotJSON: Codable {
    let type: String                          // "snapshot" (unterscheidet von Event-Zeilen im Stream)
    let tick, generation, population: Int
    let herbivores, omnivores, carnivores, species: Int
    let plants, maxFood, corpses, oldest: Int
    let birthsInterval, deathsInterval: Int   // seit letztem Intervall
    let deathsStarvation, deathsPredation, deathsOldAge: Int   // seit letztem Intervall
    let avgAggression, avgSize, avgSpeed, avgAge, avgEnergy: Double
    let perBiome: [BiomeCountJSON]?
    let aggressionHistogram: [Int]            // 10 Bins über [0,1]
    let sizeHistogram: [Int]
    let speedHistogram: [Int]
    let map: [String]?                        // gerenderte ASCII-Zeilen (Terrain + Kreaturdichte)
    let creatureGrid: [[Int]]?                // rohe Kreaturzahlen je Zelle (rows × cols)
    let samples: [SampleJSON]?
}

func biomeChar(_ b: Biome) -> Character {
    switch b {
    case .grassland: return "."
    case .forest:    return "f"
    case .desert:    return "d"
    case .wetland:   return "w"
    case .water:     return "~"
    }
}

// Baut die vollständige Momentaufnahme in einem Pass über die Population.
struct DeathTotals { var births = 0, deaths = 0, starvation = 0, predation = 0, oldAge = 0 }

func buildSnapshot(_ world: World, _ o: Options,
                   prev: DeathTotals,
                   mapCols: Int, mapRows: Int, wantExtras: Bool) -> SnapshotJSON {
    var herb = 0, omni = 0, carn = 0, oldest = 0
    var aggrSum = 0.0, sizeSum = 0.0, speedSum = 0.0, ageSum = 0.0, energySum = 0.0
    var aggrHist = [Int](repeating: 0, count: 10)
    var sizeHist = [Int](repeating: 0, count: 10)
    var speedHist = [Int](repeating: 0, count: 10)
    var perBiome = [Int](repeating: 0, count: Biome.allCases.count)
    var grid = Array(repeating: Array(repeating: 0, count: mapCols), count: mapRows)
    let cw = Double(o.width) / Double(mapCols)
    let ch = Double(o.height) / Double(mapRows)

    for c in world.creatures {
        let a = c.dna.aggression
        if a <= 0.33      { herb += 1 }
        else if a <= 0.67 { omni += 1 }
        else              { carn += 1 }
        aggrSum += Double(a); sizeSum += Double(c.dna.size); speedSum += Double(c.dna.speed)
        ageSum += Double(c.age); energySum += Double(c.energy / c.maxEnergy)
        if c.age > oldest { oldest = c.age }
        aggrHist[min(9, Int(a * 10))]              += 1
        sizeHist[min(9, Int(c.dna.size * 10))]     += 1
        speedHist[min(9, Int(c.dna.speed * 10))]   += 1
        if o.biomes { perBiome[world.biome(at: c.position).rawValue] += 1 }
        if wantExtras {
            let gx = min(mapCols - 1, max(0, Int(Double(c.position.x) / cw)))
            let gy = min(mapRows - 1, max(0, Int(Double(c.position.y) / ch)))
            grid[gy][gx] += 1
        }
    }

    let n = Double(max(1, world.creatures.count))
    let species = world.speciationEnabled ? world.countSpecies(threshold: world.speciationThreshold) : 0

    // ASCII-Karte: belegte Zelle → Kreaturzahl (1–9 / #), leere Zelle → Terrainbuchstabe.
    var mapLines: [String]? = nil
    if wantExtras {
        var lines: [String] = []
        for r in 0..<mapRows {
            var line = ""
            for col in 0..<mapCols {
                let cnt = grid[r][col]
                if cnt > 0 {
                    line.append(cnt >= 10 ? "#" : Character("\(cnt)"))
                } else if o.biomes {
                    let center = CGPoint(x: (Double(col) + 0.5) * cw, y: (Double(r) + 0.5) * ch)
                    line.append(biomeChar(world.biome(at: center)))
                } else {
                    line.append(" ")
                }
            }
            lines.append(line)
        }
        mapLines = lines
    }

    // Beispielindividuen: ältestes, energiereichstes, dann zufällige — dedupliziert.
    var samples: [SampleJSON]? = nil
    if wantExtras && o.samples > 0 && !world.creatures.isEmpty {
        var picked: [Creature] = []
        func add(_ c: Creature?) {
            guard let c, !picked.contains(where: { $0 === c }), picked.count < o.samples else { return }
            picked.append(c)
        }
        add(world.creatures.max(by: { $0.age < $1.age }))
        add(world.creatures.max(by: { ($0.energy / $0.maxEnergy) < ($1.energy / $1.maxEnergy) }))
        var shuffled = world.creatures.shuffled()
        while picked.count < o.samples, let c = shuffled.popLast() { add(c) }
        samples = picked.map { c in
            SampleJSON(
                x: Int(c.position.x), y: Int(c.position.y),
                biome: o.biomes ? world.biome(at: c.position).name : nil,
                age: c.age, maxAge: c.dna.maxAge,
                energyPct: Double(c.energy / c.maxEnergy),
                size: c.dna.size, speed: c.dna.speed, aggression: c.dna.aggression,
                sightRadius: c.dna.sightRadius, olfaction: c.dna.olfaction,
                litter: c.dna.litterSize, brainNeurons: c.hiddenCount,
                actSpeed: c.lastAction?.speed ?? 0,
                actReproduce: c.lastAction?.wantsToReproduce ?? 0,
                actAttack: c.lastAction?.wantsToAttack ?? 0,
                actEatPlant: c.lastAction?.wantsToEatPlant ?? 1,
                actEatCorpse: c.lastAction?.wantsToEatCorpse ?? 1)
        }
    }

    let biomeCounts: [BiomeCountJSON]? = o.biomes
        ? Biome.allCases.map { BiomeCountJSON(biome: $0.name, count: perBiome[$0.rawValue]) }
        : nil

    return SnapshotJSON(
        type: "snapshot",
        tick: world.tickCount, generation: world.generation, population: world.creatures.count,
        herbivores: herb, omnivores: omni, carnivores: carn, species: species,
        plants: world.plantCount, maxFood: world.maxFood, corpses: world.corpseCount, oldest: oldest,
        birthsInterval: world.totalBirths - prev.births, deathsInterval: world.totalDeaths - prev.deaths,
        deathsStarvation: world.deathsByStarvation - prev.starvation,
        deathsPredation:  world.deathsByPredation  - prev.predation,
        deathsOldAge:     world.deathsByOldAge     - prev.oldAge,
        avgAggression: aggrSum / n, avgSize: sizeSum / n, avgSpeed: speedSum / n,
        avgAge: ageSum / n, avgEnergy: energySum / n,
        perBiome: biomeCounts,
        aggressionHistogram: aggrHist, sizeHistogram: sizeHist, speedHistogram: speedHist,
        map: mapLines, creatureGrid: wantExtras ? grid : nil, samples: samples)
}

// MARK: - Menschenlesbare Ausgabe

func fmt(_ v: Double, _ w: Int, _ p: Int = 2) -> String { String(format: "%\(w).\(p)f", v) }
func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : String(repeating: " ", count: w - s.count) + s
}

let humanHeader = [
    pad("tick", 7), pad("gen", 5), pad("pop", 5),
    pad("herb", 5), pad("omni", 5), pad("carn", 5), pad("arten", 6),
    pad("pflanzen", 9), pad("aas", 4), pad("+geb", 5), pad("-tod", 5),
    pad("aggr", 5), pad("size", 5), pad("spd", 5),
    pad("ø-alt", 6), pad("ø-nrg", 6), pad("max-alt", 7)
].joined(separator: " ")

func humanRow(_ s: SnapshotJSON) -> String {
    [
        pad("\(s.tick)", 7), pad("\(s.generation)", 5), pad("\(s.population)", 5),
        pad("\(s.herbivores)", 5), pad("\(s.omnivores)", 5), pad("\(s.carnivores)", 5), pad("\(s.species)", 6),
        pad("\(s.plants)/\(s.maxFood)", 9), pad("\(s.corpses)", 4),
        pad("\(s.birthsInterval)", 5), pad("\(s.deathsInterval)", 5),
        pad(fmt(s.avgAggression, 4), 5), pad(fmt(s.avgSize, 4), 5), pad(fmt(s.avgSpeed, 4), 5),
        pad(fmt(s.avgAge, 0, 0), 6), pad(fmt(s.avgEnergy * 100, 0, 0) + "%", 6), pad("\(s.oldest)", 7)
    ].joined(separator: " ")
}

func renderHistogram(_ name: String, _ bins: [Int], width: Int = 32) -> String {
    let maxv = max(1, bins.max() ?? 1)
    var out = "  \(name):\n"
    for i in 0..<bins.count {
        let lo = Double(i) / Double(bins.count)
        let hi = Double(i + 1) / Double(bins.count)
        let len = Int((Double(bins[i]) / Double(maxv)) * Double(width))
        out += "    \(fmt(lo,3,1))–\(fmt(hi,3,1)) |" + String(repeating: "#", count: len) + " \(bins[i])\n"
    }
    return out
}

func renderSample(_ s: SampleJSON) -> String {
    let biome = s.biome.map { " [\($0)]" } ?? ""
    return String(format:
        "    (%4d,%4d)%@ Alter %d/%d  E %.0f%%  | size %.2f spd %.2f aggr %.2f sight %.2f olf %.2f litter %d brain %d\n" +
        "        Verhalten: spd %.2f repro %.2f attack %.2f eatPlant %.2f eatCorpse %.2f",
        s.x, s.y, biome, s.age, s.maxAge, s.energyPct * 100,
        s.size, s.speed, s.aggression, s.sightRadius, s.olfaction, s.litter, s.brainNeurons,
        s.actSpeed, s.actReproduce, s.actAttack, s.actEatPlant, s.actEatCorpse)
}

func printDetail(_ s: SnapshotJSON, biomes: Bool) {
    print("        Tode: Hunger \(s.deathsStarvation)  Prädation \(s.deathsPredation)  Alter \(s.deathsOldAge)   Geburten \(s.birthsInterval)")
    if let per = s.perBiome {
        print("        └ " + per.map { "\($0.biome) \($0.count)" }.joined(separator: "  "))
    }
    if let map = s.map {
        let legend = biomes ? "  (Terrain: . Wiese  f Wald  d Wüste  w Sumpf  ~ Wasser  |  Ziffern = Kreaturen je Zelle, # ≥10)"
                            : "  (Ziffern = Kreaturen je Zelle, # ≥10)"
        print("  Weltkarte \(map.first?.count ?? 0)×\(map.count):" + legend)
        for line in map { print("  " + line) }
    }
    print(renderHistogram("Aggression", s.aggressionHistogram), terminator: "")
    print(renderHistogram("Größe",      s.sizeHistogram), terminator: "")
    print(renderHistogram("Tempo",      s.speedHistogram), terminator: "")
    if let samples = s.samples, !samples.isEmpty {
        print("  Beispielindividuen (ältestes, energiereichstes, zufällig):")
        for smp in samples { print(renderSample(smp)) }
    }
    print("")
}

// MARK: - Verhaltens-Trace (für Analyse durch einen Beobachter, nicht für Maschinen-Parsing)

func n2(_ v: Float, _ p: Int = 2) -> String { String(format: "%.\(p)f", v) }
func sg(_ v: Float, _ p: Int = 2) -> String { String(format: "%+.\(p)f", v) }
func shortID(_ c: Creature) -> String { String(c.id.uuidString.prefix(4)) }

func printTraceLegend() {
    print("""
    ── TRACE ─────────────────────────────────────────────────────────────────────
      Zeile 1: t=Tick #id (x,y) h=Heading E=Energieanteil a=Alter [Biom]
        F(a d T n) nächste Nahrung — a Winkel (−links/+rechts), d Distanz, T P=Pflanze/K=Kadaver, n sichtbare Menge
        C(a d v n) nächste Kreatur — v Annäherung (+kommt näher/−flieht)
        dn Dichte | hd Herdenrichtung | sm Pflanzengeruch | fd Fressrate | sn Seneszenz
        fert/cov/dif Biom am Standort | bear Terrain-Peilung (. Wiese  f Wald  d Wüste  w Sumpf  ~ Wasser)
      Zeile 2: ⇒ NN-Entscheidung — turn (−links/+rechts) spd rep atk eatP eatC
    ──────────────────────────────────────────────────────────────────────────────
    """)
}

func printTraceProfile(_ c: Creature, _ world: World, _ o: Options) {
    let b = o.biomes ? " [\(world.biome(at: c.position).name)]" : ""
    print("── Steckbrief #\(shortID(c))\(b)  Alter \(c.age)/\(c.dna.maxAge)  E \(n2(c.energy / c.maxEnergy))")
    print("   DNA: size \(n2(c.dna.size))  speed \(n2(c.dna.speed))  aggr \(n2(c.dna.aggression))"
        + "  sight \(n2(c.dna.sightRadius)) (\(Int(c.sightRadius))px)  fov \(Int(c.sightAngle * 180 / .pi))°"
        + "  turn \(n2(c.dna.turnRate))  reproThr \(n2(c.dna.reproductionThreshold))"
        + "  litter \(c.dna.litterSize)  brain \(c.hiddenCount)  olf \(n2(c.dna.olfaction))"
        + "  rgb(\(n2(c.dna.red)),\(n2(c.dna.green)),\(n2(c.dna.blue)))")
    if o.traceWeights {
        let w = c.dna.neuralWeights()
        print("   NN-Gewichte (\(w.count)): " + w.map { n2($0, 3) }.joined(separator: " "))
    }
}

func printTraceLine(_ c: Creature, _ world: World, _ o: Options) {
    guard let s = c.lastSensors else { return }
    let biome = o.biomes ? " [\(world.biome(at: c.position).name)]" : ""
    let foodT = s.nearestFoodType > 0.5 ? "K" : "P"
    print("t=\(world.tickCount) #\(shortID(c)) (\(Int(c.position.x)),\(Int(c.position.y)))"
        + " h\(sg(c.heading)) E\(n2(c.energy / c.maxEnergy)) a\(c.age)\(biome)"
        + " | F(a\(sg(s.angleToFood)) d\(n2(s.distanceToFood)) \(foodT) n\(n2(s.visibleFoodCount, 1)))"
        + " | C(a\(sg(s.angleToCreature)) d\(n2(s.distanceToCreature)) v\(sg(s.approachVelocity)) n\(n2(s.visibleCreatureCount, 1)))"
        + " | dn\(n2(s.localDensity)) hd\(sg(s.avgNearbyHeading)) sm\(n2(s.localPlantDensity)) fd\(n2(s.recentFeedingRate)) sn\(n2(s.ownSenescence))"
        + " | fert\(n2(s.localFertility)) cov\(n2(s.localCover)) dif\(n2(s.localDifficulty))"
        + " | bear .\(sg(s.terrainBearingGrassland)) f\(sg(s.terrainBearingForest)) d\(sg(s.terrainBearingDesert)) w\(sg(s.terrainBearingWetland)) ~\(sg(s.terrainBearingWater))")
    if let a = c.lastAction {
        print("       ⇒ turn\(sg((a.turnAngle - 0.5) * 2)) spd\(n2(a.speed)) rep\(n2(a.wantsToReproduce))"
            + " atk\(n2(a.wantsToAttack)) eatP\(n2(a.wantsToEatPlant)) eatC\(n2(a.wantsToEatCorpse))")
    }
}

// Auswahl: ältestes + energiereichstes (bewährte Strategien) + zufällige als Baseline.
func selectTraced(_ world: World, _ count: Int) -> [Creature] {
    var picked: [Creature] = []
    func add(_ c: Creature?) {
        guard let c, !picked.contains(where: { $0 === c }), picked.count < count else { return }
        picked.append(c)
    }
    add(world.creatures.max(by: { $0.age < $1.age }))
    add(world.creatures.max(by: { ($0.energy / $0.maxEnergy) < ($1.energy / $1.maxEnergy) }))
    var shuffled = world.creatures.shuffled()
    while picked.count < count, let c = shuffled.popLast() { add(c) }
    return picked
}

// MARK: - Lauf

let o = parseArgs()
let size = CGSize(width: o.width, height: o.height)
let world = World(size: size)

// Skalierung analog SimulationEngine.syncConfigToWorld
let scale = (Double(size.width * size.height) / (800.0 * 600.0)).squareRoot()
world.maxFood          = Int(Double(o.foodCapacity) * scale)
world.maxPopulation    = max(Int(300.0 * scale), o.creatures)
world.foodGrowthRate   = o.foodGrowthRate
world.mutationRate     = o.mutationRate
world.mutationStrength = o.mutationStrength
world.minSpawnEnabled   = o.minSpawn > 0
world.minSpawnThreshold = max(1, o.minSpawn)
world.biomesEnabled    = o.biomes
world.seasonEnabled    = o.seasons
world.speciationEnabled = o.speciation
world.plantToxinFactor  = o.plantToxin ? 0.60 : 0
world.plantToxinThreshold = 0.50
world.eventRecording    = o.events
world.sensorRecording   = o.trace   // Wahrnehmung nur speichern, wenn getract wird

world.populate(creatures: o.creatures, food: world.maxFood)

// Kartendimensionen (Zeichen sind ~2:1 hoch → Höhe halbieren)
let mapCols = o.mapCols
let mapRows = max(8, Int(Double(mapCols) * Double(o.height) / Double(o.width) / 2.0))
let wantExtras = o.detail || o.json

FileHandle.standardError.write(Data("Welt \(o.width)×\(o.height)  maxFood \(world.maxFood)  maxPop \(world.maxPopulation)  Biome \(o.biomes ? "an" : "aus")  min-spawn \(o.minSpawn)  → \(o.ticks) Ticks\n".utf8))

let encoder = JSONEncoder()
encoder.outputFormatting = [.withoutEscapingSlashes]
func jsonLine<T: Encodable>(_ v: T) -> String? {
    guard let d = try? encoder.encode(v) else { return nil }
    return String(data: d, encoding: .utf8)
}

// NDJSON, sobald Snapshots (--json) ODER Ereignisse (--events) strukturiert ausgegeben werden.
let ndjson = o.json || o.events
var prev = DeathTotals()

func emitSnapshot() {
    let s = buildSnapshot(world, o, prev: prev, mapCols: mapCols, mapRows: mapRows, wantExtras: wantExtras)
    prev = DeathTotals(births: world.totalBirths, deaths: world.totalDeaths,
                       starvation: world.deathsByStarvation, predation: world.deathsByPredation,
                       oldAge: world.deathsByOldAge)
    if ndjson {
        if let line = jsonLine(s) { print(line) }
    } else if o.csv {
        print("\(s.tick),\(s.generation),\(s.population),\(s.herbivores),\(s.omnivores),\(s.carnivores),\(s.species),\(s.plants),\(s.maxFood),\(s.corpses),\(s.birthsInterval),\(s.deathsInterval),\(s.deathsStarvation),\(s.deathsPredation),\(s.deathsOldAge),\(fmt(s.avgAggression,0,4)),\(fmt(s.avgSize,0,4)),\(fmt(s.avgSpeed,0,4)),\(fmt(s.avgAge,0,1)),\(fmt(s.avgEnergy,0,4)),\(s.oldest)")
    } else {
        print(humanRow(s))
        if o.detail { printDetail(s, biomes: o.biomes) }
    }
}

func streamEvents() {
    guard o.events, !world.events.isEmpty else { return }
    for e in world.events {
        let ej = EventJSON(type: e.kind.rawValue, tick: e.tick,
                           x: Int(e.x), y: Int(e.y), aggression: e.aggression, cause: e.cause?.rawValue)
        if let line = jsonLine(ej) { print(line) }
    }
    world.events.removeAll(keepingCapacity: true)
}

if o.csv && !ndjson {
    print("tick,generation,population,herbivores,omnivores,carnivores,species,plants,maxFood,corpses,births,deaths,deathsStarvation,deathsPredation,deathsOldAge,avgAggression,avgSize,avgSpeed,avgAge,avgEnergy,oldest")
} else if !ndjson {
    print(humanHeader)
}

// Nahrungsabsenkungen nach Tick sortiert abarbeiten (Kapazität wird √-flächenskaliert wie beim Start).
let foodSteps = o.foodSteps.sorted { $0.tick < $1.tick }
var nextStep = 0

// Trace-Fenster: Default 200 Ticks ab traceFrom — bewusst eng, der Trace ist zum Lesen da.
let traceTo = o.traceTo >= 0 ? o.traceTo : o.traceFrom + 200
var traced: [Creature] = []
var traceStarted = false
if o.trace {
    let lines = max(0, (traceTo - o.traceFrom) / o.traceEvery) * o.traceCreatures * 2
    FileHandle.standardError.write(Data("Trace: Tick \(o.traceFrom)–\(traceTo), jeder \(o.traceEvery). Tick, \(o.traceCreatures) Individuen → ca. \(lines) Zeilen (~\(lines * 115 / 1024) KB)\n".utf8))
}

emitSnapshot()   // Ausgangszustand (Tick 0)
let start = Date()
for _ in 0..<o.ticks {
    world.tick()
    while nextStep < foodSteps.count && world.tickCount >= foodSteps[nextStep].tick {
        let cap = foodSteps[nextStep].capacity
        world.maxFood = Int(Double(cap) * scale)
        FileHandle.standardError.write(Data("» Tick \(world.tickCount): Nahrungskapazität → \(cap) (maxFood \(world.maxFood))\n".utf8))
        nextStep += 1
    }
    streamEvents()                                          // Ereignisse dieses Ticks live

    // Verhaltens-Trace: dieselben Individuen über das Fenster verfolgen (nicht jedes Mal neue),
    // damit zusammenhängende Trajektorien entstehen.
    if o.trace, world.tickCount >= o.traceFrom, world.tickCount <= traceTo {
        if !traceStarted {
            traceStarted = true
            printTraceLegend()
            traced = selectTraced(world, o.traceCreatures)
            for c in traced { printTraceProfile(c, world, o) }
        }
        if (world.tickCount - o.traceFrom) % o.traceEvery == 0, !traced.isEmpty {
            let alive = Set(world.creatures.map { ObjectIdentifier($0) })
            var survivors: [Creature] = []
            for c in traced {
                if alive.contains(ObjectIdentifier(c)) {
                    printTraceLine(c, world, o)
                    survivors.append(c)
                } else {
                    print("t=\(world.tickCount) #\(shortID(c)) † gestorben — Trace endet für dieses Individuum")
                }
            }
            traced = survivors
        }
    }

    if world.tickCount % o.interval == 0 { emitSnapshot() } // periodische Zusammenfassung
}
let elapsed = Date().timeIntervalSince(start)
let tps = elapsed > 0 ? Double(o.ticks) / elapsed : 0
FileHandle.standardError.write(Data(String(format: "Fertig: %d Ticks in %.2fs (%.0f Ticks/s), Endpopulation %d\n",
                                            o.ticks, elapsed, tps, world.creatures.count).utf8))
