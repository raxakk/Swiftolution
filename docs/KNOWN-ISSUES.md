# Known issues

A review of [MECHANICS.md](MECHANICS.md) and [DESIGN.md](DESIGN.md) against
the code turned up ten defects. **All ten are fixed.** This file keeps the
record: what was wrong, the evidence that found it, and what was changed,
so that a future review does not re-derive any of it from scratch. Each fix
carries a test in `SwiftolutionTests/`.

| # | Issue | Severity | Status |
|---|---|---|---|
| [1](#1-perception-did-not-wrap-around-the-world) | Perception did not wrap around the world | high | fixed |
| [2](#2-body-mass-was-outside-the-energy-accounting) | Body mass was outside the energy accounting | high | fixed |
| [3](#3-body-mass-started-at-its-maximum) | Body mass started at its maximum | high | fixed |
| [4](#4-the-kill-bonus-went-to-an-arbitrary-attacker) | The kill bonus went to an arbitrary attacker | medium | fixed |
| [5](#5-feeding-favoured-early-array-positions) | Feeding favoured early array positions | medium | fixed |
| [6](#6-terrain-bearings-never-reached-their-documented-range) | Terrain bearings never reached their documented range | medium | fixed |
| [7](#7-generation-did-not-count-generations) | `generation` did not count generations | medium | fixed |
| [8](#8-the-top-bucket-of-every-intgene--n-mapping-was-a-point-mass) | The top bucket of every `Int(gene * N)` mapping was a point mass | low | fixed |
| [9](#9-the-spatial-grid-was-one-movement-step-stale) | The spatial grid was one movement step stale | low | fixed |
| [10](#10-empty-perception-was-indistinguishable-from-a-real-reading) | Empty perception was indistinguishable from a real reading | low | fixed |

---

## 1. Perception did not wrap around the world

**Severity: high.** Affected sight, smell, local density, herding, attacks and
mate choice.

Movement wraps toroidally (`Creature.apply`), and the biome map is generated
with toroidal distance (`BiomeMap.generate` uses `torDelta`). Every spatial
query did not. Distances were computed naively as `other.position.x - px`,
and `SpatialGrid.forEachCell` clamped cell indices to the grid instead of
wrapping, as did the density raster.

```
A at x=2395, B at x=5:  naive dx = 2390 px, true toroidal dx = 10 px
A.sightRadius = 160 px, mateRadius = 40 px
nearestCreature(to: A, within: 200) -> nil  <-- NOT FOUND
control: same 10 px gap mid-world  -> found

40 plants at x=0..19, y=900; smell radius 200 px
  observer at x=2395 (5 px away, across seam) -> 0.0
  observer at x=100   (81 px away, no seam)   -> 31.4

creature at x=2399 moving right -> x=1  (movement DOES wrap)
```

**Why it mattered.** Two creatures a few pixels apart across the seam could
not see, smell, attack or mate with each other, but they could walk through
each other's position. Since `mateRadius` is only 40 px, the lines x=0 and
y=0 acted as invisible reproductive barriers, so the simulation could produce
speciation at an artefact of the coordinate system rather than at a modelled
cause. It also quietly weakened the water-barrier story: some of the observed
isolation may have been the seam, not the lakes.

**Fixed.** `World.torDx` / `torDy` fold a separation onto the shorter way
round, and every query goes through them: `sense` (food, creatures, density,
herding), `nearestCreature`, `feedCreatures` and the mate search.
`SpatialGrid` wraps its cell iteration instead of clamping, and a wrapped
query box becomes up to four boxes in the summed-area table used for smell.
`World.midpoint` gives a seam-crossing pair a birthplace between them rather
than on the far side of the world. Away from the seam the grid still walks a
single block, at the cost of two comparisons.

Tests: `sightReachesAcrossTheWorldSeam`, `sightStopsAtTheTrueToroidalDistance`
(the control: half a world apart stays out of range),
`smellReachesAcrossTheWorldSeam`, `matingReachesAcrossTheWorldSeam`,
`midpointOfASeamCrossingPairStaysBetweenThem`,
`toroidalDeltasTakeTheShorterWayRound`.

---

## 2. Body mass was outside the energy accounting

**Severity: high.** Contradicted a stated invariant.

DESIGN.md states that energy is never created out of nothing and that this is
enforced at every transfer. That held for reproduction and for the predation
kill bonus, both of which were checked and are correct. It did not hold for
body mass.

`Creature.consumeEnergy` grew `bodyMass` by `0.05` per tick above 60% energy
with no debit from `energy`, and shrank it by `0.3` per tick below 20% with no
credit:

```
starving, 10 ticks:
  energy   15.500 -> 13.940  (delta -1.560)   == exactly the maintenance cost
  bodyMass 50.000 -> 47.000  (delta -3.000)   <- destroyed, nothing credited
```

Separately, `Creature.init` granted every newborn `size * 60 + 20` body mass
for free. Reproduction carefully capped what a child inherited in `energy`,
then handed it a full corpse's worth of mass on the side.

**Why it mattered.** Body mass becomes corpse energy on death, so it is real
food. At gene 0.5 every birth seeded 50 energy of carrion that nothing paid
for, against 18 energy for a plant eaten by a herbivore. Over the 2000 tick
reference run with 3884 births that is roughly 194,000 energy injected, the
same order of magnitude as the entire standing plant stock (9000 x 30 =
270,000). Scavenging was subsidised, and a population could in principle
sustain itself on the free mass its own birth rate created. Calling the shrink
path "catabolism" was also a misnomer: starving converted no mass back into
usable energy, it only made the eventual corpse smaller.

**Fixed** as the design notes describe it, the investment model. Growth is
paid out of `energy` at `massBuildCost = 1.25` per unit and never spends past
the 60% well-fed line; catabolism credits `massCatabolismYield = 0.5` per unit
burned, so selling back what was built returns 40% of its cost. A newborn's
starter body is bought out of the endowment its parents paid
(`Creature.endow`), so nothing arrives for free. In headless runs the corpse
standing stock fell from 200-4600 to 120-450 while the population still
reaches its cap.

Tests: `buildingBodyMassIsPaidForOutOfEnergy`,
`catabolismReturnsEnergyAtAConversionLoss`,
`newbornMassIsBoughtOutOfTheBirthEndowment`.

---

## 3. Body mass started at its maximum

**Severity: high.** Made the body mass mechanic informationally empty.

`Creature.init` set `bodyMass = dna.size * 60 + 20`, and `consumeEnergy`
computed `maxBodyMass = dna.size * 60 + 20`. The two expressions were
identical, so every creature was born at the cap and the growth branch could
never accumulate beyond the birth state. It only ever restored mass previously
lost to starvation.

**Why it mattered.** The intent stated in README and DESIGN.md is that mass
"builds up when well fed" and therefore "determines how nourishing the corpse
will be". In practice corpse value was a function of the size gene minus
however much starvation had burned off, and carried almost no signal about how
successfully an individual actually fed. A well fed and a barely fed creature
of the same size left the same corpse.

**Fixed.** Newborns start at `maxBodyMass * 0.25` (`Creature.birthMassFraction`),
and the remaining three quarters have to be earned by feeding, at the cost set
out in issue 2.

Tests: `newbornsStartWellBelowTheirMassCeiling`,
`wellFedCreaturesGrowTowardsTheirMassCeiling`.

---

## 4. The kill bonus went to an arbitrary attacker

**Severity: medium.**

`attackCreatures` wrote `victim.lastAttacker = attacker` inside a loop over
`creatures`. With several attackers on one victim, the field held whoever came
last in array order, and `checkDeaths` granted that one creature the whole
bonus `bodyMass * aggression * 0.4`. Damage dealt did not enter into it.

**Why it mattered.** Cooperative hunting was rewarded only indirectly, through
the corpse that everyone can scavenge; the direct share was assigned by array
position. Pack strategies therefore had no gradient to climb, which is notable
given how much of the design is about making strategies reachable by gradient.
`lastAttacker` also drove the starvation versus predation classification, so
death causes were attributed to an arbitrary participant as well.

**Fixed.** `Creature.attacksTaken` records every attack on a victim for the
tick (attacker plus damage dealt, weakly referenced so that two creatures
killing each other cannot keep each other alive in memory), and the bonus is
split in proportion to damage. The total still comes out of the corpse before
it is placed. A death counts as predation if anything attacked the creature
this tick, which no longer depends on who came last.

Tests: `killBonusIsSplitByDamageDealt`, `deathIsPredationWhoeverStruckLast`.

---

## 5. Feeding favoured early array positions

**Severity: medium.**

`reproduceCreatures` shuffles its candidates. `feedCreatures` iterated
`creatures` in array order and used an `eatenIDs` set, so the first creature
to reach a contested item took it.

**Why it mattered.** Survivors keep their array order and newborns are
appended, so array position correlates with age. Older creatures
systematically won food contests. That is a real selection pressure which
nothing in the design intends or documents, and it was inconsistent with the
care taken to shuffle the reproduction pass.

**Fixed.** `feedCreatures` shuffles its pass. The original review also listed
`attackCreatures` here; on closer reading attacking has no order dependence
once the kill bonus is split by damage (issue 4), because every attack is
accumulated into the delta dictionary and applied in a single pass afterwards.
Nobody strikes first, so that loop keeps its array order and does not pay for
a shuffle.

Test: `contestedFoodDoesNotAlwaysGoToTheSameArraySlot` (200 trials of two
identical creatures contesting one plant; both win a share).

---

## 6. Terrain bearings never reached their documented range

**Severity: medium.**

`BiomeMap.directionalBearings` normalized by the total sample weight and
clamped to `[-1, 1]`. The clamp never bound. Computing the best case, where
one biome fills exactly the half of the cone that maximizes the signal:

```
sightAngle 120deg -> max |bearing| = 0.239
sightAngle 180deg -> max |bearing| = 0.320
sightAngle 240deg -> max |bearing| = 0.362
sightAngle 300deg -> max |bearing| = 0.363
sightAngle 360deg -> max |bearing| = 0.327
```

**Why it mattered.** Two things. The sensor used only about a third of its
nominal dynamic range, so the network needed correspondingly larger weights to
act on terrain than on any other input. More importantly the scale depended on
the `sightAngle` gene: the same lake produced a 35% weaker signal for a
narrow-coned creature than for a wide-coned one, so an inherited network
weight did not mean the same thing across phenotypes, and changing
`sightAngle` perturbed terrain behaviour as a side effect.

**Fixed.** Normalization is by the maximum magnitude that creature's own cone
can produce, so `±1` means the same thing at every `sightAngle` and the full
range is reachable. Re-measured over ~1M creature-ticks with biomes on: the
largest bearing seen went from 0.37 to 1.00, the mean from 0.04-0.11 to
0.24-0.30, and the share of creature-ticks carrying a signal `>= 0.05` from
29-61% to 66-80%. MECHANICS.md and DESIGN.md carry the new numbers.

Tests: `terrainBearingsReachTheEndsOfTheirRange`,
`terrainBearingScaleIsIndependentOfTheSightAngleGene`.

---

## 7. `generation` did not count generations

**Severity: medium.** Visible in the UI and in the headless table.

`World.generation` was incremented once per tick in which any birth occurred,
not per generation of descent.

```
500 ticks, 6 births spread over 2 ticks -> world.generation = 2
2000 tick reference run -> generation 1287, mean age 221
```

At a mean age of 221 ticks the true generation count after 2000 ticks is
around 10. As the population grows, nearly every tick contains a birth and the
counter converges on `tickCount`.

**Why it mattered.** The sidebar and the headless table both label it
"Generation", so it read as a meaningful evolutionary quantity and was not
one.

**Fixed** by tracking real descent, the second of the two options. Every
`Creature` carries a `generation`: founders are 0, a child is
`max(parents) + 1`. `World.generation` is the mean over the living population.
A 3000 tick headless run now reports 10-17 at a mean age around 300, which is
the right order.

Tests: `offspringAreOneGenerationPastTheirParents`,
`worldGenerationIsThePopulationMean`.

---

## 8. The top bucket of every `Int(gene * N)` mapping was a point mass

**Severity: low.**

`DNA.litterSize` was `max(1, Int(genes[10] * 3) + 1)` and
`Creature.hiddenCount` was `min + Int(brainSize * (max - min))`. Truncation
put the top value out of reach except at exactly 1.0:

```
gene 0.990 -> litterSize 3, hiddenCount 15
gene 0.999 -> litterSize 3, hiddenCount 15
gene 1.000 -> litterSize 4, hiddenCount 16
```

**Why it mattered.** In the continuous interior the top bucket had measure
zero. It was reachable only because `DNA.mutated` clamps overshooting
mutations to exactly 1.0, which puts a point mass at the boundary. So litter
size 4 and a 16 neuron brain existed, but their frequency was an artefact of
the clamp rather than of selection, and the buckets were unequal in width.

**Fixed** with the explicit final bucket, the second of the two options:
`min(N - 1, Int(gene * N))` over `N` equally wide buckets, so a litter of 4
comes from `genes[10] >= 0.75` and a 16 neuron brain from the top thirteenth
of `brainSize`. `Creature.hiddenCount(for:)` is now the single definition of
that mapping; `init` used to inline a second copy of it.

Tests: `dnaLitterSizeMapping`, `brainSizeBucketsAreEqualWidthAndReachTheTop`.

---

## 9. The spatial grid was one movement step stale

**Severity: low.**

`World.tick()` rebuilt the grid in step 1, creatures moved in step 2, and
attacking, feeding and reproduction queried it afterwards. `Creature` is a
reference type, so the positions read out of the cells were current; only the
cell assignment was stale.

**Why it mattered.** Queries could miss a creature that moved into range this
tick, since it was still filed under its previous cell. Only false negatives
were possible, bounded by one movement step (max speed about 2.8 px against
80 px cells), so the practical effect was small. It did explain occasional
"why did it not react to that" moments when reading a trace.

**Fixed** by refiling rather than accepting it: `SpatialGrid.rebuildCreatures`
runs right after movement, as its own tick phase. Food does not move within a
tick, so the food cells and the density raster over them are still built once,
which is the expensive half of a rebuild.

Tests: `gridRefilesCreaturesAfterTheyMove`, `everyCreatureIsFindableAfterATick`.

---

## 10. Empty perception was indistinguishable from a real reading

**Severity: low.**

When nothing was visible, `sense` left `angleToFood = 0`,
`distanceToFood = 1` and `nearestFoodType = 0`, which is exactly the reading
for a plant dead ahead at the edge of the sight radius. The same applied to
the creature channel, and the "no creature" colour default of `0.5/0.5/0.5`
is a perfectly valid creature colour.

**Why it mattered.** The ambiguity was resolvable, since `visibleFoodCount`
and `visibleCreatureCount` are 0 in the empty case, but only by having the
network learn to gate one input on another. That costs hidden units, and brain
size is itself a costly gene.

**Fixed**, though not with the sentinel the original note suggested. Distance 0
is unreachable only in the exact sense: a creature about to eat reads a
distance just above 0, so "nothing in sight" would have collided with the most
behaviourally urgent reading there is. The inputs are now **proximity**
(`1 - distance / sightRadius`, and 0 when nothing is in sight), which puts the
collision at the other end, where it costs nothing: seeing nothing reads like
something at the very edge of sight, which warrants the same behaviour anyway.
`SensorInput.distanceToFood` / `distanceToCreature` are accordingly
`foodProximity` / `creatureProximity`, and the headless trace prints `p` where
it printed `d`. The colour default is left as it is: no value in `[0,1]` is
unreachable for a colour gene, and the proximity input now disambiguates it
for the price the counts used to charge.

Tests: `anEmptyFieldOfViewReadsAsZeroProximity`, `foodUnderfootReadsAsFullProximity`.

---

## Checked and correct

Recorded so that a future review does not re-derive them:

- Offspring never receive more `energy` than their parents pay, in both the
  sexual and the asexual path, and `canReproduce` guarantees the parents can
  cover the 30% / 40% investment.
- The predation kill bonus is genuinely deducted from the corpse before the
  corpse is placed.
- The parallel `sense()` pass is race free: phase 1 writes only each
  creature's own `lastSensors` and its own output slot, and reads only fields
  that nothing writes during that phase.
- `currentSeasonFactor` hits exactly 1.0 at the summer peak and `1 - amplitude`
  at the winter trough, and the season names line up with the curve.
- The biome rejection sampling normalization is correct: wetland accepts with
  probability 1.0 and water with 0.
- The per-tick maintenance cost table in MECHANICS.md reproduces the measured
  cost to three decimals.
