import Foundation
import CoreGraphics

// Why a creature died: the basis for diagnosing population dynamics.
enum DeathCause: String {
    case starvation   // energy <= 0 with no attacker (metabolism, hunger, poisoning)
    case predation    // energy <= 0 after being attacked this tick
    case oldAge       // age mortality (a Gompertz roll) despite energy in the tank
}

// A single simulation event for the optional live stream (World.events).
struct SimEvent {
    enum Kind: String { case birth, death }
    let kind: Kind
    let tick: Int
    let x: Float
    let y: Float
    let aggression: Float
    let cause: DeathCause?   // only set for .death
}

final class World {

    // MARK: - Properties

    let size: CGSize
    var creatures:   [Creature]   = []
    var foodSources: [FoodSource] = []
    var generation:  Int = 0
    var tickCount:   Int = 0
    var totalBirths: Int = 0

    var plantCount:  Int = 0  // cache: avoids a filter { .plant } every tick
    var corpseCount: Int = 0  // cache: avoids a filter { .corpse } in updateStats
    var totalDeaths: Int = 0

    // Causes of death (cumulative): which factor is pressing on the population, and how hard.
    var deathsByStarvation = 0
    var deathsByPredation  = 0
    var deathsByOldAge     = 0

    // Optional live event stream (births and deaths). Only filled in while eventRecording is
    // on; an observer such as the headless runner drains `events` after each tick().
    var eventRecording = false
    var events: [SimEvent] = []

    // Stores every creature's perception each tick (Creature.lastSensors), for tracing and
    // diagnostics only. Off by default, since it otherwise costs population x 30 floats a tick.
    var sensorRecording = false
    var foodGrowthRate:   Double = 0.03   // logistic rate: the share of free capacity filled per tick
    var maxFood:          Int    = 250    // carrying capacity (configurable)
    var mutationRate:     Float  = 0.05
    var mutationStrength: Float  = 0.10
    var maxPopulation:    Int    = 300
    var minSpawnEnabled:   Bool = false
    var minSpawnThreshold: Int  = 5
    var latitudeGradientEnabled: Bool = false

    // Assortative mating: creatures only pair with genetically similar partners. This drives
    // reproductive isolation, so species become visible instead of the gene pool blurring into
    // one. It coexists with a self-sustaining population (behavioural check: capacity holds
    // even under stepwise food reduction). A lower threshold gives more, tighter species but a
    // smaller pool of partners; lower it carefully in a population that is already thin.
    var speciationEnabled:   Bool  = true
    var speciationThreshold: Float = 0.45   // max genetic distance for mating (distance ranges over [0, 2])

    // Mating range in px: how close two partners have to be. It bounds the reach of gene flow,
    // so a smaller radius lets species separate on a finer spatial scale. It became a real
    // parameter once reproduceCreatures checked the distance explicitly; before that it fell
    // out of the grid's cell size and was effectively ~90 px.
    static let mateRadius: CGFloat = 40

    // Plant toxin: carnivores (aggression above the threshold) take on a toxin load when
    // eating plants. 0 = off. Passed to Creature.eat on every feeding.
    var plantToxinFactor:    Float = 0.60
    var plantToxinThreshold: Float = 0.50

    // Biomes: spatial niches (fertility, cover, going underfoot) plus water barriers. The map
    // is generated once per world; the flag switches its effects, spawns and rendering.
    let biomeMap: BiomeMap
    var biomesEnabled: Bool = false

    // The biome at a position. Switched off, everything is neutral grassland (all factors 1.0,
    // passable), so every biome-dependent path reproduces the old behaviour without special cases.
    @inline(__always)
    func biome(at point: CGPoint) -> Biome {
        biomesEnabled ? biomeMap.biome(at: point) : .grassland
    }

    // Seasons: a cosine cycle modulates plant growth
    var seasonEnabled:   Bool  = false
    var seasonLength:    Int   = 3000    // ticks per year
    var seasonAmplitude: Float = 0.7    // 0 = no effect, 1 = winter halts growth entirely

    // The current seasonal growth factor, in [1 - amplitude ... 1.0]
    var currentSeasonFactor: Double {
        guard seasonEnabled, seasonLength > 0 else { return 1.0 }
        let t = Double(tickCount % seasonLength) / Double(seasonLength)   // [0, 1)
        return (1.0 - Double(seasonAmplitude))
             + Double(seasonAmplitude) * 0.5 * (1.0 + cos(2.0 * .pi * t))
    }

    // Stable English identifiers, localized by the UI for display (see Biome.name).
    var currentSeasonName: String {
        guard seasonEnabled, seasonLength > 0 else { return "-" }
        let t = Double(tickCount % seasonLength) / Double(seasonLength)
        switch t {
        case 0..<0.25:   return "Summer"
        case 0.25..<0.5: return "Autumn"
        case 0.5..<0.75: return "Winter"
        default:         return "Spring"
        }
    }

    private var grid: SpatialGrid

    func rebuildGrid() { grid.rebuild(creatures: creatures, food: foodSources) }

    init(size: CGSize = CGSize(width: 1200, height: 900)) {
        self.size = size
        self.grid = SpatialGrid(cellSize: 80, worldSize: size)
        self.biomeMap = BiomeMap(worldSize: size)
    }

    // MARK: - Setup

    func populate(creatures creatureCount: Int, food foodCount: Int) {
        for _ in 0..<creatureCount {
            var dna = DNA.random()
            // The big bang: everything starts herbivorous, so carnivores have to evolve
            dna.genes[3] = Float.random(in: 0...0.4)
            creatures.append(Creature(dna: dna, position: creatureSpawnPosition()))
        }
        for _ in 0..<foodCount {
            foodSources.append(FoodSource(position: spawnPosition()))
        }
        plantCount  = foodCount
        corpseCount = 0
    }

    // MARK: - Simulation tick

    func tick() {
        tickCount += 1
        grid.rebuild(creatures: creatures, food: foodSources)
        moveCreatures()
        attackCreatures()
        feedCreatures()
        checkDeaths()
        spawnMinimumIfNeeded()
        reproduceCreatures()
        growFood()
        decayFood()
    }

    // MARK: - Movement & perception

    private func moveCreatures() {
        let snapshot = creatures
        let count = snapshot.count
        guard count > 0 else { return }

        // Phase 1, parallel: perception and network activation. Each creature reads only its
        // own state and the immutable grid, so there is no data race.
        // withUnsafeMutableBufferPointer pins the array buffer, giving COW-free writes from n threads.
        var outputs = [ActionOutput](repeating: ActionOutput(fromArray: [0.5, 0, 0, 0, 1, 1]), count: count)
        outputs.withUnsafeMutableBufferPointer { buf in
            DispatchQueue.concurrentPerform(iterations: count) { i in
                let input = sense(for: snapshot[i])
                // Each iteration writes only its own creature, so there is no data race.
                if sensorRecording { snapshot[i].lastSensors = input }
                // The context goes in and comes back out again: each iteration touches only
                // its own creature's memory, so the parallel phase stays race free.
                var memory = snapshot[i].brainMemory
                buf[i] = snapshot[i].brain.activate(inputs: input, memory: &memory)
                snapshot[i].brainMemory = memory
            }
        }

        // Phase 2, sequential: write position and state (position changes affect the same tick).
        for (i, creature) in snapshot.enumerated() {
            creature.apply(output: outputs[i], in: self)
            creature.tick()
        }
    }

    // Builds the sensor input for one creature.
    // Food and the nearest creature are only perceived inside the sight cone (FOV), while
    // density and herding direction are omnidirectional (touch, pressure waves).
    // Runs in parallel across n threads: local variables plus a read-only grid, no allocations
    // (visitor API), and squared distance comparisons (sqrt only at the very end).
    private func sense(for creature: Creature) -> SensorInput {
        let px = Float(creature.position.x)
        let py = Float(creature.position.y)
        // The biome underfoot: cover shortens the effective sight range (forest) while open
        // ground lengthens it (desert). This affects perception only, never the gene.
        let localBiome  = biome(at: creature.position)
        let sightRadius = creature.sightRadius * CGFloat(localBiome.sightFactor)
        let sightR   = Float(sightRadius)
        let sightRSq = sightR * sightR
        let isFull   = creature.sightAngle >= 2 * .pi * 0.995

        // FOV via a dot product instead of atan2: angle(d, heading) <= halfAngle
        //   <=> dot / |d| >= cos(halfAngle), resolvable without sqrt using signs and squares.
        let cosHalf   = cos(Float(creature.sightAngle) / 2)
        let cosHalfSq = cosHalf * cosHalf
        let hx = creature.headingCos
        let hy = creature.headingSin

        @inline(__always)
        func inFOV(_ dx: Float, _ dy: Float, _ distSq: Float) -> Bool {
            guard !isFull else { return true }
            let dot = dx * hx + dy * hy
            if cosHalf >= 0 {
                return dot >= 0 && dot * dot >= cosHalfSq * distSq
            } else {
                return dot >= 0 || dot * dot <= cosHalfSq * distSq
            }
        }

        // Smell: omnidirectional plant density from an O(1) raster query. As a counting scan it
        // forced the food pass out to max(sight, smell), and the smell radius is usually the
        // larger of the two (median 115 px against 94 px) despite yielding this single number.
        let plantsSmelled = grid.plantsNear(creature.position,
                                            within: creature.olfactionSmellRadius)

        // The food pass for vision: nearest food plus the count inside the sight cone.
        var nearestFoodDx: Float = 0, nearestFoodDy: Float = 0
        var nearestFoodDistSq   = Float.greatestFiniteMagnitude
        var nearestFoodIsCorpse = false
        var foodInFOVCount = 0
        grid.forEachFood(near: creature.position, within: sightRadius) { food in
            let dx = Float(food.position.x) - px
            let dy = Float(food.position.y) - py
            let distSq = dx * dx + dy * dy
            if distSq < sightRSq && inFOV(dx, dy, distSq) {
                foodInFOVCount += 1
                if distSq < nearestFoodDistSq {
                    nearestFoodDistSq   = distSq
                    nearestFoodDx       = dx
                    nearestFoodDy       = dy
                    nearestFoodIsCorpse = food.type == .corpse
                }
            }
        }

        var angleToFood:     Float = 0
        var distToFood:      Float = 1
        var nearestFoodType: Float = 0
        if nearestFoodDistSq < .greatestFiniteMagnitude {
            angleToFood     = normalizeAngle(atan2(nearestFoodDy, nearestFoodDx) - creature.heading) / .pi
            distToFood      = sqrt(nearestFoodDistSq) / sightR
            nearestFoodType = nearestFoodIsCorpse ? 1.0 : 0.0
        }

        // A single creature pass covering sight, density (<55) and herding (<80)
        var nearestDx: Float = 0, nearestDy: Float = 0
        var nearestDistSq = Float.greatestFiniteMagnitude
        var nearestOther: Creature? = nil
        var visibleCount = 0
        var densityCount = 0
        var herdSin: Float = 0, herdCos: Float = 0
        var herdCount = 0
        grid.forEachCreature(near: creature.position, within: max(sightRadius, 80)) { other in
            guard other !== creature else { return }
            let dx = Float(other.position.x) - px
            let dy = Float(other.position.y) - py
            let distSq = dx * dx + dy * dy
            if distSq < 55 * 55 { densityCount += 1 }
            if distSq < 80 * 80 {
                herdSin += other.headingSin
                herdCos += other.headingCos
                herdCount += 1
            }
            if distSq < sightRSq && inFOV(dx, dy, distSq) {
                visibleCount += 1
                if distSq < nearestDistSq {
                    nearestDistSq = distSq
                    nearestDx     = dx
                    nearestDy     = dy
                    nearestOther  = other
                }
            }
        }

        var angleToCreature:   Float = 0
        var distToCreature:    Float = 1
        var approachVelocity:  Float = 0
        var nearestCreatureRed:   Float = 0.5   // neutral grey when no creature is visible
        var nearestCreatureGreen: Float = 0.5
        var nearestCreatureBlue:  Float = 0.5
        if let other = nearestOther {
            let dist = sqrt(nearestDistSq)
            angleToCreature = normalizeAngle(atan2(nearestDy, nearestDx) - creature.heading) / .pi
            distToCreature  = dist / sightR
            let otherSpeed = (other.lastAction?.speed ?? 0) * other.maxSpeed
            let vx = other.headingCos * otherSpeed
            let vy = other.headingSin * otherSpeed
            if dist > 0 {
                let approach = (vx * (-nearestDx) + vy * (-nearestDy)) / dist
                approachVelocity = max(-1, min(1, approach / max(other.maxSpeed, 0.1)))
            }
            nearestCreatureRed   = other.dna.red
            nearestCreatureGreen = other.dna.green
            nearestCreatureBlue  = other.dna.blue
        }
        let visibleCreatureCount = min(Float(visibleCount), 10) / 10
        let visibleFoodCount     = min(Float(foodInFOVCount), 10) / 10
        let localPlantDensity    = min(plantsSmelled / 20.0, 1.0)
        let localDensity         = min(Float(densityCount) / 8.0, 1.0)

        var avgNearbyHeading: Float = 0
        if herdCount > 0 {
            avgNearbyHeading = normalizeAngle(atan2(herdSin, herdCos) - creature.heading) / .pi
        }

        // Direction-resolved terrain perception, only with biomes on; otherwise everything is
        // 0, which leaves the network output untouched and behaviour unchanged.
        var tbGrass: Float = 0, tbForest: Float = 0, tbDesert: Float = 0
        var tbWetland: Float = 0, tbWater: Float = 0
        if biomesEnabled {
            // Perceive terrain on a landscape scale (a multiple of the sight range), otherwise
            // a creature always stands in uniform terrain and sees no gradient at all.
            // Cover (forest) damps the landscape view too, hence the same sightFactor.
            let terrainR = Float(creature.terrainSightRadius * CGFloat(localBiome.sightFactor))
            let b = biomeMap.directionalBearings(observerX: px, observerY: py,
                                                 headingCos: hx, headingSin: hy,
                                                 sightRadius: terrainR,
                                                 sightAngle: Float(creature.sightAngle))
            tbGrass = b.grassland; tbForest = b.forest; tbDesert = b.desert
            tbWetland = b.wetland; tbWater = b.water
        }

        return SensorInput(
            angleToFood:          angleToFood,
            distanceToFood:       distToFood,
            angleToCreature:      angleToCreature,
            distanceToCreature:   distToCreature,
            ownEnergy:            creature.energy / creature.maxEnergy,
            localDensity:         localDensity,
            approachVelocity:     approachVelocity,
            nearestFoodType:      nearestFoodType,
            avgNearbyHeading:     avgNearbyHeading,
            nearestCreatureRed:   nearestCreatureRed,
            nearestCreatureGreen: nearestCreatureGreen,
            nearestCreatureBlue:  nearestCreatureBlue,
            visibleCreatureCount: visibleCreatureCount,
            ownSenescence:        min(creature.senescence, 1),
            visibleFoodCount:     visibleFoodCount,
            localPlantDensity:    localPlantDensity,
            recentFeedingRate:    min(creature.recentFeedingRate / 20.0, 1.0),
            localFertility:       min(localBiome.fertility / Biome.maxFertility, 1),
            localCover:           max(0, min(1 - localBiome.sightFactor, 1)),
            localDifficulty:      max(0, min(1 - localBiome.speedFactor, 1)),
            terrainBearingGrassland: tbGrass,
            terrainBearingForest:    tbForest,
            terrainBearingDesert:    tbDesert,
            terrainBearingWetland:   tbWetland,
            terrainBearingWater:     tbWater,
            memory0:    creature.brainMemory[0],
            memory1:    creature.brainMemory[1],
            memory2:    creature.brainMemory[2],
            memory3:    creature.brainMemory[3],
            oscillator: creature.oscillator
        )
    }

    // MARK: - Attacking

    func attackCreatures() {
        // ObjectIdentifier: an 8-byte pointer hash instead of a 16-byte UUID hash, twice as fast.
        var energyDeltas = [ObjectIdentifier: Float](minimumCapacity: creatures.count)

        for attacker in creatures {
            // No hard aggression threshold: damage and cost already scale with aggression.
            guard let action = attacker.lastAction,
                  action.wantsToAttack > 0.5 else { continue }

            guard let victim = nearestCreature(to: attacker, within: attacker.attackRadius) else { continue }
            guard attacker.dna.size >= victim.dna.size * 0.6 else { continue }

            let rawDamage = (attacker.dna.size * 0.6 + attacker.dna.aggression * 0.4) * 50
            // Size is robustness (thicker hide, armour); aggression is combat experience and reflexes
            let defense   = min(victim.dna.size * 0.30 + victim.dna.aggression * 0.60, 0.90)
            let damage    = rawDamage * (1 - defense)

            energyDeltas[ObjectIdentifier(attacker), default: 0] -= attacker.dna.aggression * 2
            energyDeltas[ObjectIdentifier(victim),   default: 0] -= damage
            victim.lastAttacker = attacker
        }

        for creature in creatures {
            guard let delta = energyDeltas[ObjectIdentifier(creature)] else { continue }
            creature.energy = max(0, min(creature.energy + delta, creature.maxEnergy))
        }
    }

    // MARK: - Feeding

    func feedCreatures() {
        var eatenIDs = Set<UUID>()
        var eatenPlants  = 0
        var eatenCorpses = 0
        for creature in creatures {
            // A separate network decision per food type, which makes selective diets possible.
            let action = creature.lastAction
            let wantsPlant  = (action?.wantsToEatPlant  ?? 1.0) > 0.5
            let wantsCorpse = (action?.wantsToEatCorpse ?? 1.0) > 0.5
            // Skips the grid query entirely when the creature wants to eat nothing at all
            guard wantsPlant || wantsCorpse else { continue }
            let eatRadius = creature.eatRadius
            let eatRSq = Float(eatRadius * eatRadius)
            let px = Float(creature.position.x)
            let py = Float(creature.position.y)
            grid.forEachFood(near: creature.position, within: eatRadius) { food in
                let wants = food.type == .plant ? wantsPlant : wantsCorpse
                guard wants else { return }
                let dx = Float(food.position.x) - px
                let dy = Float(food.position.y) - py
                guard dx * dx + dy * dy < eatRSq, !eatenIDs.contains(food.id) else { return }
                creature.eat(food: food,
                             plantToxinFactor: plantToxinFactor,
                             plantToxinThreshold: plantToxinThreshold)
                if food.type == .plant { eatenPlants += 1 } else { eatenCorpses += 1 }
                eatenIDs.insert(food.id)
            }
        }
        if !eatenIDs.isEmpty {
            foodSources.removeAll { eatenIDs.contains($0.id) }
            plantCount  -= eatenPlants
            corpseCount -= eatenCorpses
        }
    }

    // MARK: - Death

    func checkDeaths() {
        // Gompertz-like mortality: a small baseline risk plus an exponentially rising age risk.
        // A single pass: no UUID set, no second traversal.
        var survivors: [Creature] = []
        survivors.reserveCapacity(creatures.count)
        for creature in creatures {
            let ageRatio    = Float(creature.age) / Float(creature.dna.maxAge)
            let deathChance = 0.0001 + ageRatio * ageRatio * 0.003
            let survivesAge = Float.random(in: 0...1) >= deathChance
            if creature.isAlive && survivesAge {
                survivors.append(creature)
            } else {
                totalDeaths += 1
                // The cause is an energy death (starvation or predation, depending on whether
                // something attacked this tick), otherwise age mortality (still alive, but the
                // Gompertz roll came up).
                let cause: DeathCause
                if !creature.isAlive {
                    cause = creature.lastAttacker != nil ? .predation : .starvation
                } else {
                    cause = .oldAge
                }
                switch cause {
                case .starvation: deathsByStarvation += 1
                case .predation:  deathsByPredation  += 1
                case .oldAge:     deathsByOldAge      += 1
                }
                if eventRecording {
                    events.append(SimEvent(kind: .death, tick: tickCount,
                                           x: Float(creature.position.x), y: Float(creature.position.y),
                                           aggression: creature.dna.aggression, cause: cause))
                }
                if creature.bodyMass > 1 {
                    var corpseEnergy = creature.bodyMass
                    if let killer = creature.lastAttacker, killer.isAlive {
                        // The attacker feeds on the kill directly, taking a share proportional
                        // to its aggression. That energy is deducted from the corpse rather than
                        // created out of nothing.
                        let bonus = creature.bodyMass * killer.dna.aggression * 0.4
                        killer.energy = min(killer.energy + bonus, killer.maxEnergy)
                        corpseEnergy -= bonus
                    }
                    if corpseEnergy > 1 {
                        foodSources.append(FoodSource(position: creature.position,
                                                      energyValue: corpseEnergy,
                                                      type: .corpse,
                                                      spawnedAt: tickCount))
                        corpseCount += 1
                    }
                }
            }
        }
        creatures = survivors
    }

    // MARK: - Minimum spawn

    private func spawnMinimumIfNeeded() {
        guard minSpawnEnabled, creatures.count < minSpawnThreshold else { return }
        let count = minSpawnThreshold - creatures.count
        for _ in 0..<count {
            var dna = DNA.random()
            dna.genes[3] = Float.random(in: 0...0.4)   // always herbivorous
            creatures.append(Creature(dna: dna, position: creatureSpawnPosition()))
        }
    }

    // MARK: - Reproduction

    func reproduceCreatures() {
        guard creatures.count < maxPopulation else { return }

        // ObjectIdentifier instead of UUID: a pointer comparison, not a 16-byte hash.
        var mated    = Set<ObjectIdentifier>(minimumCapacity: 64)
        var newborns = [Creature]()

        // Only creatures that have the energy AND whose network "wants" to reproduce
        let candidates = creatures
            .filter { $0.canReproduce && ($0.lastAction?.wantsToReproduce ?? 0) > 0.5 }
            .shuffled()

        for parent in candidates {
            guard !mated.contains(ObjectIdentifier(parent)) else { continue }
            guard creatures.count + newborns.count < maxPopulation else { break }

            // A grid query rather than an O(candidates.count) scan: the partner is looked up
            // spatially. The mating barrier is genetic distance when speciation is on, and the
            // aggression niche otherwise.
            // The distance is checked explicitly: without that check the scanned cell block set
            // the range, which let the cell size (a performance knob) decide the mating range,
            // in practice a ~90 px median instead of the stated 40.
            var partner: Creature? = nil
            let mateRSq = Float(World.mateRadius * World.mateRadius)
            let parentX = Float(parent.position.x)
            let parentY = Float(parent.position.y)
            grid.forEachCreature(near: parent.position, within: World.mateRadius) { other in
                guard partner == nil,
                      other !== parent,
                      !mated.contains(ObjectIdentifier(other)),
                      (other.lastAction?.wantsToReproduce ?? 0) > 0.5,
                      other.canReproduce else { return }
                let dx = Float(other.position.x) - parentX
                let dy = Float(other.position.y) - parentY
                guard dx * dx + dy * dy < mateRSq else { return }
                let compatible = speciationEnabled
                    ? parent.dna.geneticDistance(to: other.dna) <= speciationThreshold
                    : abs(other.dna.aggression - parent.dna.aggression) < 0.3
                guard compatible else { return }
                partner = other
            }

            if let partner {
                // Sexual reproduction: the genes of both parents are combined
                mated.insert(ObjectIdentifier(parent))
                mated.insert(ObjectIdentifier(partner))
                let midPoint = CGPoint(x: (parent.position.x + partner.position.x) / 2,
                                       y: (parent.position.y + partner.position.y) / 2)
                let litter = min(parent.dna.litterSize, maxPopulation - creatures.count - newborns.count)
                // Each parent invests 30% of its maximum energy, regardless of litter size, and
                // the combined investment is split evenly across the offspring. No energy leak:
                // children receive only what the parents actually paid.
                let costPerParent: Float = 0.30
                let totalPool = parent.maxEnergy * costPerParent + partner.maxEnergy * costPerParent
                let perChildEnergy = totalPool / Float(litter)
                for _ in 0..<litter {
                    let childDNA = parent.dna.crossed(with: partner.dna)
                                             .mutated(rate: mutationRate, strength: mutationStrength)
                    let child = Creature(dna: childDNA, position: dispersedPosition(from: midPoint))
                    child.energy = min(child.maxEnergy * 0.6, perChildEnergy)
                    newborns.append(child)
                }
                parent.energy  -= parent.maxEnergy  * costPerParent
                partner.energy -= partner.maxEnergy * costPerParent
            } else {
                // Asexual as a fallback: the parent invests 40%, split across the litter
                mated.insert(ObjectIdentifier(parent))
                let litter = min(parent.dna.litterSize, maxPopulation - creatures.count - newborns.count)
                let cost: Float = 0.40
                let perChildEnergy = parent.maxEnergy * cost / Float(litter)
                for _ in 0..<litter {
                    let childDNA = parent.dna.mutated(rate: mutationRate, strength: mutationStrength)
                    let child = Creature(dna: childDNA, position: dispersedPosition(from: parent.position))
                    child.energy = min(child.maxEnergy * 0.6, perChildEnergy)
                    newborns.append(child)
                }
                parent.energy -= parent.maxEnergy * cost
            }
        }

        if !newborns.isEmpty {
            if eventRecording {
                for child in newborns {
                    events.append(SimEvent(kind: .birth, tick: tickCount,
                                           x: Float(child.position.x), y: Float(child.position.y),
                                           aggression: child.dna.aggression, cause: nil))
                }
            }
            creatures.append(contentsOf: newborns)
            totalBirths += newborns.count
            generation  += 1
        }
    }

    // MARK: - Food growth

    func growFood() {
        if biomesEnabled {
            growFoodWithBiomes()
        } else if latitudeGradientEnabled {
            growFoodWithGradient()
        } else {
            let fillRatio = Double(plantCount) / Double(maxFood)
            let newItems  = Int((foodGrowthRate * currentSeasonFactor * (1.0 - fillRatio) * Double(maxFood)).rounded())
            for _ in 0..<max(0, newItems) {
                foodSources.append(FoodSource(position: randomPosition()))
                plantCount += 1
            }
        }
    }

    // Biome-weighted growth: the global logistic amount is placed by rejection sampling, with
    // acceptance proportional to the biome's fertility x growthFactor. Water (0) never gets
    // plants, desert rarely, wetland and grassland often, so fertile and barren zones form.
    private func growFoodWithBiomes() {
        let fillRatio = Double(plantCount) / Double(maxFood)
        let newItems  = Int((foodGrowthRate * currentSeasonFactor * (1.0 - fillRatio) * Double(maxFood)).rounded())
        guard newItems > 0 else { return }
        let norm = Biome.maxFertility * 1.40   // max fertility x max growthFactor (wetland)
        var added = 0
        var attempts = 0
        let maxAttempts = newItems * 12        // guards against spinning on a mostly water/desert world
        while added < newItems && attempts < maxAttempts {
            attempts += 1
            let pos = randomPosition()
            let b   = biomeMap.biome(at: pos)
            let p   = b.fertility * b.growthFactor / norm
            if Float.random(in: 0...1) < p {
                foodSources.append(FoodSource(position: pos))
                plantCount += 1
                added += 1
            }
        }
    }

    // Band-based growth: capacity and rate both scale with cos(distance from the equator x pi/2).
    // Equatorial bands grow fast and can carry many plants; polar bands are barren and slow to
    // regenerate. Total capacity stays maxFood, so energy is conserved across all bands.
    private func growFoodWithGradient() {
        let strips     = 10
        let stripH     = size.height / CGFloat(strips)
        let equatorY   = Float(size.height / 2)
        let halfH      = Float(size.height / 2)

        // Per-band fertility and the overall normalization
        var fertilities    = [Double](repeating: 0, count: strips)
        var totalFertility = 0.0
        for i in 0..<strips {
            let centerY = Float((CGFloat(i) + 0.5) * stripH)
            let dy      = abs(centerY - equatorY) / halfH
            let f       = Double(cos(Double(dy) * .pi / 2))
            fertilities[i]  = f
            totalFertility += f
        }

        // Count the plants per band (once, O(n_plants))
        var counts = [Int](repeating: 0, count: strips)
        for food in foodSources where food.type == .plant {
            counts[min(Int(food.position.y / stripH), strips - 1)] += 1
        }

        // Logistic growth per band
        for i in 0..<strips {
            let f        = fertilities[i]
            // Band capacity is proportional to fertility, and the bands sum to maxFood
            let capacity = Double(maxFood) * f / totalFertility
            let fill     = capacity > 0 ? min(1.0, Double(counts[i]) / capacity) : 1.0
            // f^2: fertility drives both capacity and rate, giving the equator a strong advantage
            let newItems = Int((f * foodGrowthRate * currentSeasonFactor * (1.0 - fill) * capacity).rounded())

            let minY = CGFloat(i) * stripH
            let maxY = minY + stripH
            for _ in 0..<max(0, newItems) {
                let pos = CGPoint(x: CGFloat.random(in: 0..<size.width),
                                  y: CGFloat.random(in: minY..<maxY))
                foodSources.append(FoodSource(position: pos))
                plantCount += 1
            }
        }
    }

    func decayFood() {
        // Corpses rot away and vanish; no energy is created in the process.
        var decayed = 0
        foodSources.removeAll {
            guard $0.type == .corpse, tickCount - $0.spawnedAt > 1200 else { return false }
            decayed += 1
            return true
        }
        corpseCount -= decayed
    }

    // MARK: - Helpers

    func randomPosition() -> CGPoint {
        CGPoint(
            x: CGFloat.random(in: 0..<size.width),
            y: CGFloat.random(in: 0..<size.height)
        )
    }

    // Plant spawning: with the equator gradient on, plants concentrate around the middle of the
    // world along the y axis. Rejection sampling with acceptance = cos(normalized distance from
    // the equator x pi/2), so the equator (dy=0) accepts 100% and the poles (dy=1) none.
    // Average iterations: ~1.6.
    private func spawnPosition() -> CGPoint {
        if biomesEnabled { return biomePlantPosition() }
        guard latitudeGradientEnabled else { return randomPosition() }
        let equatorY = Float(size.height / 2)
        let halfH    = Float(size.height / 2)
        while true {
            let pos = randomPosition()
            let dy  = abs(Float(pos.y) - equatorY) / halfH
            if Float.random(in: 0...1) < cos(dy * .pi / 2) { return pos }
        }
    }

    // Places the initial plants weighted by biome, using the same rejection criterion as
    // growFoodWithBiomes, with a cap in case the world is mostly water or desert.
    private func biomePlantPosition() -> CGPoint {
        let norm = Biome.maxFertility * 1.40
        for _ in 0..<40 {
            let pos = randomPosition()
            let b   = biomeMap.biome(at: pos)
            if Float.random(in: 0...1) < b.fertility * b.growthFactor / norm { return pos }
        }
        // Fallback: any passable position at all (never a plant in open water)
        return creatureSpawnPosition()
    }

    // A passable starting position for creatures: avoids water when biomes are enabled.
    private func creatureSpawnPosition() -> CGPoint {
        guard biomesEnabled else { return randomPosition() }
        for _ in 0..<40 {
            let p = randomPosition()
            if biomeMap.biome(at: p).isPassable { return p }
        }
        return randomPosition()
    }

    // Offspring spawn within a random radius around the parent so that clusters do not
    // reinforce themselves. If the litter would land in water, it falls back to the parent's
    // own (passable) position.
    private func dispersedPosition(from origin: CGPoint, spread: CGFloat = 30) -> CGPoint {
        for _ in 0..<8 {
            let angle = CGFloat.random(in: 0..<(.pi * 2))
            let dist  = CGFloat.random(in: 10..<spread)
            let p = CGPoint(
                x: (origin.x + cos(angle) * dist + size.width).truncatingRemainder(dividingBy: size.width),
                y: (origin.y + sin(angle) * dist + size.height).truncatingRemainder(dividingBy: size.height)
            )
            if !biomesEnabled || biomeMap.biome(at: p).isPassable { return p }
        }
        return origin
    }

    // Counts distinct species by greedy clustering over the marker genes: each creature joins
    // the first cluster whose representative is closer than the threshold, and otherwise opens
    // a new one. It is an approximation and depends on iteration order, but it is O(n*k) with a
    // small k and entirely adequate for a diversity readout.
    func countSpecies(threshold: Float) -> Int {
        var representatives: [DNA] = []
        for creature in creatures {
            var matched = false
            for rep in representatives where creature.dna.geneticDistance(to: rep) <= threshold {
                matched = true
                break
            }
            if !matched { representatives.append(creature.dna) }
        }
        return representatives.count
    }

    func nearestCreature(to creature: Creature, within radius: CGFloat) -> Creature? {
        let radiusSq = Float(radius * radius)
        let px = Float(creature.position.x)
        let py = Float(creature.position.y)
        var best: Creature? = nil
        var bestDistSq = radiusSq
        grid.forEachCreature(near: creature.position, within: radius) { other in
            guard other !== creature else { return }
            let dx = Float(other.position.x) - px
            let dy = Float(other.position.y) - py
            let distSq = dx * dx + dy * dy
            if distSq < bestDistSq {
                bestDistSq = distSq
                best = other
            }
        }
        return best
    }

private func normalizeAngle(_ angle: Float) -> Float {
        var a = angle
        while a >  .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }
}
