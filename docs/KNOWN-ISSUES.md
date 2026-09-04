# Known issues

| # | Issue | Severity |
|---|---|---|
| [1](#1-perception-does-not-wrap-around-the-world) | Perception does not wrap around the world | high |
| [2](#2-body-mass-is-outside-the-energy-accounting) | Body mass is outside the energy accounting | high |
| [3](#3-body-mass-starts-at-its-maximum) | Body mass starts at its maximum | high |
| [4](#4-the-kill-bonus-goes-to-an-arbitrary-attacker) | The kill bonus goes to an arbitrary attacker | medium |
| [5](#5-feeding-and-attacking-favour-early-array-positions) | Feeding and attacking favour early array positions | medium |
| [6](#6-terrain-bearings-never-reach-their-documented-range) | Terrain bearings never reach their documented range | medium |
| [7](#7-generation-does-not-count-generations) | `generation` does not count generations | medium |
| [8](#8-the-top-bucket-of-every-intgene--n-mapping-is-a-point-mass) | The top bucket of every `Int(gene * N)` mapping is a point mass | low |
| [9](#9-the-spatial-grid-is-one-movement-step-stale) | The spatial grid is one movement step stale | low |
| [10](#10-empty-perception-is-indistinguishable-from-a-real-reading) | Empty perception is indistinguishable from a real reading | low |

---

## 1. Perception does not wrap around the world

**Severity: high.** Affects sight, smell, local density, herding, attacks and
mate choice.

Movement wraps toroidally (`Creature.apply`), and the biome map is generated
with toroidal distance (`BiomeMap.generate` uses `torDelta`). Every spatial
query does not. Distances are computed naively as `other.position.x - px`
(`World.swift:262`, `:229`, `:409`, `:778`), and `SpatialGrid.forEachCell`
clamps cell indices to the grid instead of wrapping (`SpatialGrid.swift:111`),
as does the density raster (`SpatialGrid.swift:91`).

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

**Why it matters.** Two creatures a few pixels apart across the seam cannot
see, smell, attack or mate with each other, but they can walk through each
other's position. Since `mateRadius` is only 40 px, the lines x=0 and y=0 act
as invisible reproductive barriers, so the simulation can produce speciation
at an artefact of the coordinate system rather than at a modelled cause. It
also silently weakens the water-barrier story: some of the observed isolation
may be the seam, not the lakes.

**Suggested fix.** A toroidal delta helper used by every query, plus wrapping
cell iteration in `forEachCell` and in the summed-area query. The latter is
the invasive part, since a wrapped box is up to four rectangles in the
summed-area table. Worth a test that asserts symmetric perception across the
seam.

---

## 2. Body mass is outside the energy accounting

**Severity: high.** Contradicts a stated invariant.

DESIGN.md states that energy is never created out of nothing and that this is
enforced at every transfer. That holds for reproduction and for the predation
kill bonus, both of which were checked and are correct. It does not hold for
body mass.

`Creature.consumeEnergy` (`Creature.swift:198-203`) grows `bodyMass` by
`0.05` per tick above 60% energy with no debit from `energy`, and shrinks it
by `0.3` per tick below 20% with no credit:

```
starving, 10 ticks:
  energy   15.500 -> 13.940  (delta -1.560)   == exactly the maintenance cost
  bodyMass 50.000 -> 47.000  (delta -3.000)   <- destroyed, nothing credited
```

Separately, `Creature.init` (`Creature.swift:91`) grants every newborn
`size * 60 + 20` body mass for free. Reproduction carefully caps what a child
inherits in `energy`, then hands it a full corpse's worth of mass on the side.

**Why it matters.** Body mass becomes corpse energy on death, so it is real
food. At gene 0.5 every birth seeds 50 energy of carrion that nothing paid
for, against 18 energy for a plant eaten by a herbivore. Over the 2000 tick
reference run with 3884 births that is roughly 194,000 energy injected, the
same order of magnitude as the entire standing plant stock (9000 x 30 =
270,000). Scavenging is therefore subsidised, and a population can in
principle sustain itself on the free mass its own birth rate creates.

Calling the shrink path "catabolism" is also a misnomer: starving converts no
mass back into usable energy, it only makes the eventual corpse smaller.

**Suggested fix.** Decide which model is wanted. Either body mass is an
investment, in which case growth is paid out of `energy` and catabolism
credits it back at some conversion loss, or it is a fixed property of size, in
which case the growth and shrink paths should go and the corpse value should
be derived directly. The first option is what the design notes describe.

---

## 3. Body mass starts at its maximum

**Severity: high.** Makes the body mass mechanic informationally empty.

`Creature.init` sets `bodyMass = dna.size * 60 + 20` (`Creature.swift:91`),
and `consumeEnergy` computes `maxBodyMass = dna.size * 60 + 20`
(`Creature.swift:198`). The two expressions are identical, so every creature
is born at the cap and the growth branch can never accumulate beyond the birth
state. It only ever restores mass previously lost to starvation.

**Why it matters.** The intent stated in README and DESIGN.md is that mass
"builds up when well fed" and therefore "determines how nourishing the corpse
will be". In practice corpse value is a function of the size gene minus
however much starvation burned off, and carries almost no signal about how
successfully an individual actually fed. A well fed and a barely fed creature
of the same size leave the same corpse.

**Suggested fix.** Start newborns at a fraction of `maxBodyMass` so that mass
has to be earned. This interacts with issue 2 and should be decided together
with it.

---

## 4. The kill bonus goes to an arbitrary attacker

**Severity: medium.**

`attackCreatures` writes `victim.lastAttacker = attacker`
(`World.swift:380`) inside a loop over `creatures`. With several attackers on
one victim, the field holds whoever came last in array order, and
`checkDeaths` grants that one creature the whole bonus
`bodyMass * aggression * 0.4`. Damage dealt does not enter into it.

**Why it matters.** Cooperative hunting is rewarded only indirectly, through
the corpse that everyone can scavenge; the direct share is assigned by array
position. Pack strategies therefore have no gradient to climb, which is
notable given how much of the design is about making strategies reachable by
gradient.

`lastAttacker` also drives the starvation versus predation classification, so
death causes are attributed to an arbitrary participant as well.

**Suggested fix.** Accumulate damage per victim and per attacker in the
existing delta dictionary, then split the bonus proportionally to damage
dealt. The dictionary pass is already there, so this is cheap.

---

## 5. Feeding and attacking favour early array positions

**Severity: medium.**

`reproduceCreatures` shuffles its candidates (`World.swift:507`).
`feedCreatures` (`World.swift:395`) and `attackCreatures`
(`World.swift:365`) iterate `creatures` in array order, and `feedCreatures`
uses an `eatenIDs` set so the first creature to reach a contested item takes
it.

**Why it matters.** Survivors keep their array order and newborns are
appended, so array position correlates with age. Older creatures
systematically win food contests and strike first. That is a real selection
pressure which nothing in the design intends or documents, and it is
inconsistent with the care taken to shuffle the reproduction pass.

**Suggested fix.** Shuffle in `feedCreatures` and `attackCreatures` too, or
resolve contested food by an explicit rule (nearest wins, say) rather than by
iteration order.

---

## 6. Terrain bearings never reach their documented range

**Severity: medium.**

`BiomeMap.directionalBearings` normalizes by the total sample weight and
clamps to `[-1, 1]` (`Biome.swift:200-201`). The clamp never binds. Computing
the best case, where one biome fills exactly the half of the cone that
maximizes the signal:

```
sightAngle 120deg -> max |bearing| = 0.239
sightAngle 180deg -> max |bearing| = 0.320
sightAngle 240deg -> max |bearing| = 0.362
sightAngle 300deg -> max |bearing| = 0.363
sightAngle 360deg -> max |bearing| = 0.327
```

**Why it matters.** Two things. The sensor uses only about a third of its
nominal dynamic range, so the network needs correspondingly larger weights to
act on terrain than on any other input. More importantly the scale depends on
the `sightAngle` gene: the same lake produces a 35% weaker signal for a
narrow-coned creature than for a wide-coned one, so an inherited network
weight does not mean the same thing across phenotypes, and changing
`sightAngle` perturbs terrain behaviour as a side effect.

**Suggested fix.** Normalize by the maximum attainable magnitude for the
creature's own `sightAngle` rather than by `totalW`, which makes the sensor
phenotype-independent and restores the full `[-1, 1]` range. The measurement
in DESIGN.md ("share of creature-ticks carrying a terrain signal >= 0.05")
would need redoing against the new scale.

---

## 7. `generation` does not count generations

**Severity: medium.** Visible in the UI and in the headless table.

`World.generation` is incremented once per tick in which any birth occurred
(`World.swift:587`), not per generation of descent.

```
500 ticks, 6 births spread over 2 ticks -> world.generation = 2
2000 tick reference run -> generation 1287, mean age 221
```

At a mean age of 221 ticks the true generation count after 2000 ticks is
around 10. As the population grows, nearly every tick contains a birth and the
counter converges on `tickCount`.

**Why it matters.** The sidebar and the headless table both label it
"Generation", so it reads as a meaningful evolutionary quantity and is not
one.

**Suggested fix.** Either rename it to something honest such as "breeding
ticks", or track real descent by carrying a generation number on `Creature`
(`max(parents) + 1`) and reporting the population mean.

---

## 8. The top bucket of every `Int(gene * N)` mapping is a point mass

**Severity: low.**

`DNA.litterSize` is `max(1, Int(genes[10] * 3) + 1)` (`DNA.swift:21`) and
`Creature.hiddenCount` is `min + Int(brainSize * (max - min))`
(`Creature.swift:72`). Truncation puts the top value out of reach except at
exactly 1.0:

```
gene 0.990 -> litterSize 3, hiddenCount 15
gene 0.999 -> litterSize 3, hiddenCount 15
gene 1.000 -> litterSize 4, hiddenCount 16
```

**Why it matters.** In the continuous interior the top bucket has measure
zero. It is reachable only because `DNA.mutated` clamps overshooting
mutations to exactly 1.0, which puts a point mass at the boundary. So litter
size 4 and a 16 neuron brain exist, but their frequency is an artefact of the
clamp rather than of selection, and the buckets are unequal in width.

**Suggested fix.** Round instead of truncating, or map through
`min(N - 1, Int(gene * N))` with an explicit final bucket of equal width.

---

## 9. The spatial grid is one movement step stale

**Severity: low.** Noted mainly so it is not rediscovered during tracing.

`World.tick()` rebuilds the grid in step 1, creatures move in step 2, and
attacking, feeding and reproduction query it afterwards. `Creature` is a
reference type, so the positions read out of the cells are current; only the
cell assignment is stale.

**Why it matters.** Queries can miss a creature that moved into range this
tick, since it is still filed under its previous cell. Only false negatives
are possible, bounded by one movement step (max speed about 2.8 px against
80 px cells), so the practical effect is small. It does explain occasional
"why did it not react to that" moments when reading a trace.

**Suggested fix.** Rebuild the grid after movement rather than before, or
accept it and document it, which is what MECHANICS.md now does.

---

## 10. Empty perception is indistinguishable from a real reading

**Severity: low.**

When nothing is visible, `sense` leaves `angleToFood = 0`,
`distanceToFood = 1` and `nearestFoodType = 0`, which is exactly the reading
for a plant dead ahead at the edge of the sight radius. The same applies to
the creature channel, and the "no creature" colour default of `0.5/0.5/0.5`
is a perfectly valid creature colour.

**Why it matters.** The ambiguity is resolvable, since `visibleFoodCount` and
`visibleCreatureCount` are 0 in the empty case, but only by having the network
learn to gate one input on another. That costs hidden units, and brain size is
itself a costly gene.

**Suggested fix.** Either make the empty case unambiguous (distance 0 is
otherwise unreachable and would work as a sentinel) or accept it as a modelled
limitation and leave it, given the counts already carry the information.

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
