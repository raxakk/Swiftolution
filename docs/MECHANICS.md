# Mechanics

A precise reference for how the simulation works: every formula, constant and
rule, as implemented. [README.md](../README.md) is the overview and
[DESIGN.md](DESIGN.md) is the reasoning behind the numbers; this document is
the specification in between, describing what actually happens, tick by tick.

Source of truth throughout: `Swiftolution/Simulation/` and
`Swiftolution/Engine/SimulationEngine.swift`. Line references point at the
version current when this was written; behaviour, not line numbers, is the
contract.

This document describes the simulation as it actually behaves.
[KNOWN-ISSUES.md](KNOWN-ISSUES.md) is the record of the defects a review of
this document turned up, all of them now fixed, with the evidence that found
them and what was changed; several rules below read the way they do because
of that review.

## Contents

- [The tick loop](#the-tick-loop)
- [Genome](#genome)
- [Brain](#brain)
  - [Sensors](#sensors)
  - [Outputs](#outputs)
- [Derived traits](#derived-traits)
- [Metabolism](#metabolism)
- [Movement](#movement)
- [Feeding](#feeding)
- [Combat](#combat)
- [Death](#death)
- [Reproduction](#reproduction)
- [Food](#food)
- [Biomes](#biomes)
- [Seasons](#seasons)
- [Speciation](#speciation)
- [Spatial grid](#spatial-grid)
- [World scaling](#world-scaling)
- [Observability](#observability)

## The tick loop

Each call to `World.tick()` runs ten phases, in this fixed order:

1. **Rebuild the spatial grid** from the current creature and food positions.
2. **Move**: sense, think, act (see [Movement](#movement)).
3. **Refile the moved creatures** in the grid, so that every query after this
   point sees current cells. Food has not moved, so its half of the grid and
   the density raster over it stand.
4. **Attack**: resolve all attacks declared this tick.
5. **Feed**: resolve all eating declared this tick.
6. **Check deaths**: energy and age mortality; spawn corpses.
7. **Spawn minimum** (optional): top up a collapsing population.
8. **Reproduce**: pair up willing, eligible creatures.
9. **Grow food**: logistic plant growth.
10. **Decay food**: remove corpses older than 1200 ticks.

Everything a creature does in a tick is decided once, at the start (step 2),
from a single snapshot of the world. Attacking, feeding and reproducing all
read that same decision (`Creature.lastAction`) rather than re-sensing. A
creature acts on one perception per tick, not a new one per phase.

In the app, ticks run in batches on a background queue, decoupled from the
60 fps display timer via a speed multiplier and an accumulator (capped at 10
ticks of backlog so an overloaded run degrades gracefully instead of
freezing the UI). The headless runner instead calls `tick()` in a tight loop,
uncapped.

## Genome

A creature's entire hereditary makeup is one flat array of **613 floats**,
each in `[0, 1]`: 15 named genes followed by 598 raw neural network weights.

| # | Gene | Meaning |
|---|------|---------|
| 0 | `speed` | top movement speed |
| 1 | `sightRadius` | vision range |
| 2 | `size` | body size |
| 3 | `aggression` | 0 = pure herbivore, 1 = pure carnivore |
| 4 | `maxAge` | lifespan, `1..1000` ticks |
| 5 | `reproductionThreshold` | energy fraction required to breed |
| 6 | `brainSize` | hidden-neuron count, `4..16` |
| 7-9 | `red, green, blue` | display colour and species signature |
| 10 | `litterSize` | offspring per birth, `1..4` |
| 11 | `sightAngle` | field of view, `120°..360°` |
| 12 | `turnRate` | steering agility |
| 13 | `olfaction` | smell range |
| 14 | `oscillatorPeriod` | period of the internal clock, `10..200` ticks |
| 15-612 | *(network weights)* | see [Brain](#brain) |

DNA always carries weights sized for the **maximum** brain (16 hidden
neurons), regardless of the creature's actual `brainSize`. That keeps every
genome the same length, so crossover never needs special-casing for
differently sized brains. A smaller brain reads a fixed subset of the weight
block and leaves the rest unexpressed; which slots those are does not depend
on the brain size (see [Brain](#brain)).

Genes that map onto a small integer are cut into **buckets of equal width**,
`min(N - 1, Int(gene * N))` over `N` buckets: a litter of 4 comes from
`genes[10] >= 0.75` and a 16 neuron brain from the top thirteenth of
`brainSize`. Truncating over the span instead (`Int(gene * 3) + 1`) left the
top value reachable only at exactly `gene == 1.0`, where `DNA.mutated` clamps
overshooting mutations and piles up a point mass, so the largest litter and
the largest brain existed as an artefact of that clamp rather than as
strategies selection could find.

**Mutation** (`DNA.mutated`, applied to every offspring gene-by-gene at the
configured `mutationRate`, default 5%): a mutated gene receives one of three
deltas, chosen once the gene is picked for mutation:

- 95%: micro (`±mutationStrength`, default `±0.10`), fine-tuning
- 4%: medium (`±2×strength`), exploring a wider neighbourhood
- 1%: macro (`±5×strength`), a jump into a new region of strategy space

The result is clamped back into `[0, 1]`.

**Crossover** (`DNA.crossed`): single-point. A random split index is chosen
once; the child takes genes `[0, split)` from one parent and `[split, 613)`
from the other. Because gene indices are fixed, this can split a network
weight in the middle of a neuron's input row. The resulting recombination is
somewhat destructive at the network level by design, matching how crossover
would work in a real (non-network) genome.

## Brain

A feed-forward network with one hidden layer and a recurrent context:

```
25 sensors + 4 context + 1 oscillator -> [4..16 hidden, tanh] -> 6 outputs, sigmoid
                     ^                                  |
                     +---- previous tick, first 4 ------+
```

The **context** (`Creature.brainMemory`, a `SIMD4<Float>`) is the first four
hidden activations of the previous tick, fed back in as inputs. It is the
network's only state: without it the brain is a pure reflex, and behaviour
that spans more than one tick — pursuing something that went out of sight,
continuing a flight, staying on a search pattern — cannot be represented at
all. Nothing assigns the four values a meaning; what it pays to remember is
what selection puts there.

Four is not arbitrary: `minHiddenCount` is 4, so those activations exist in
every brain no matter how small, and no special-casing is needed. The values
are `tanh` outputs, so the feedback loop is bounded by construction and
cannot diverge numerically. It *can* latch — a hidden unit driven into
saturation stays there — which is a behavioural outcome selection can act
on, not a numerical failure.

The **oscillator** (input 29) is `sin(2π × age / oscillatorPeriod)`, with the
period an evolvable gene (`10..200` ticks). It is the only input that changes
without an external cause. Without it a creature with nothing in sight has
constant inputs, hence a constant output, and walks in a perfectly straight
line forever; with it, self-driven behaviour — zigzag search, patrolling,
looping back — becomes representable, and its frequency is under selection.
It starts at exactly 0 at age 0, so birth is not a kick.

The context is owned by the creature, not by `NeuralNetwork`: `activate`
takes it `inout`, so the network stays a stateless value type. Each parallel
iteration in `World.moveCreatures` reads and writes only its own creature's
memory, so the perception phase remains race free.

Hidden layer size is itself a gene (`brainSize`), interpolated between
`NeuralNetwork.minHiddenCount` (4) and `maxHiddenCount` (16). Weights are
decoded from genes `[0,1]` to `[-1,1]` via `v * 2 - 1`, so positive and
negative influence are equally likely from the start. Otherwise every neuron
would be biased to fire the same way at birth.

**Weight layout.** The genome always carries weights for `maxHiddenCount`,
whatever the brain actually is, and every weight sits in a fixed block whose
position does not depend on `hiddenCount`:

```
layer 1: 16 blocks of 31   genes   0..495   (30 weights, then a bias)
layer 2:  6 blocks of 17   genes 496..597   (16 weights, then a bias)
```

A brain with `hc` neurons reads the first `hc` blocks of layer 1 and the
first `hc` weights of every layer-2 block. The remaining 444 of 598 weight
genes in a minimal (4-neuron) brain are unexpressed and drift neutrally, so
a lineage that later grows a neuron finds pre-drifted structure waiting for
it rather than a fresh random one.

Fixed blocks are what makes `brainSize` evolvable at all. Reading the two
layers as one consecutive run instead puts the start of layer 2 at
`hc * (inputCount + 1)`, so a mutation from 4 to 5 neurons shifts the entire
output layer by 31 genes: the child inherits its parent's motor mapping
scrambled, and crossover between parents of different brain sizes is a frame
shift rather than a mix. A test pins this down
(`growingTheBrainPreservesTheInheritedWiring`): neutralize the extra
neuron's outgoing weights and a grown brain must behave exactly like the one
it grew from.

The forward pass runs on a stack buffer (`withUnsafeTemporaryAllocation`),
no heap allocation, since it is the hottest path in the simulation
(population x one call per tick).

### Sensors

30 inputs, built once per creature per tick by `World.sense(for:)`: 25
sensory readings, the 4 context values and the oscillator. Two perception
rules apply throughout:

- **Food and the nearest creature** are only perceived inside the sight
  cone, a field of view of `sightAngle` (`120°` at gene 0 to full `360°` at
  gene 1), tested via a dot-product against the heading (no `atan2` on the
  hot path).
- **Local density and herding direction** are omnidirectional, modeled as
  touch/pressure sensing rather than vision, so they ignore the FOV.

| # | Input | Range | Notes |
|---|-------|-------|-------|
| 0 | angle to nearest food | `[-1, 1]` | left/right of heading |
| 1 | proximity of nearest food | `[0, 1]` | `0` = nothing in sight, `1` = right here |
| 2 | angle to nearest creature | `[-1, 1]` | |
| 3 | proximity of nearest creature | `[0, 1]` | `0` = nothing in sight |
| 4 | own energy | `[0, 1]` | |
| 5 | local density | `[0, 1]` | creatures within 55 px, capped at 8 |
| 6 | approach velocity of nearest creature | `[-1, 1]` | `>0` closing in |
| 7 | nearest food type | `{0, 1}` | 0 = plant, 1 = corpse |
| 8 | average nearby heading | `[-1, 1]` | herding cue, within 80 px |
| 9-11 | colour of nearest creature | `[0, 1]` each | `0.5/0.5/0.5` if none visible |
| 12 | visible creature count | `[0, 1]` | `min(count, 10) / 10` |
| 13 | own senescence | `[0, 1]` | see [Metabolism](#metabolism) |
| 14 | visible food count | `[0, 1]` | `min(count, 10) / 10` |
| 15 | local plant density (smell) | `[0, 1]` | omnidirectional, olfaction-scaled |
| 16 | recent feeding rate | `[0, 1]` | EMA of energy gained per tick |
| 17 | local fertility | `[0, 1]` | biome underfoot |
| 18 | local cover | `[0, 1]` | biome underfoot |
| 19 | local difficulty | `[0, 1]` | biome underfoot |
| 20-24 | terrain bearing (grassland/forest/desert/wetland/water) | `[-1, 1]`, fully used | see [Biomes](#biomes) |
| 25-28 | working memory | `[-1, 1]` each | previous tick's first 4 hidden activations |
| 29 | oscillator | `[-1, 1]` | `sin(2π × age / oscillatorPeriod)` |

These inputs and the "nearest creature" search share a single pass over the
spatial grid per creature, at `max(sightRadius, 80)`, so density and herding
(80 px) are always covered even for short-sighted creatures. Every one of
these queries measures **toroidal** distance, the shorter way round a world
that wraps (see [Movement](#movement)).

Inputs 1 and 3 are **proximity, not distance**, which is what keeps an empty
field of view from reading as a real sighting. The empty case has to be
reported as some number, and under a distance encoding that number (`1`, the
sight-radius edge) was also a perfectly good reading of a plant dead ahead.
Proximity puts the collision where it costs nothing: seeing nothing reads
like something at the very edge of sight, which calls for the same behaviour
anyway. The residue is the "no creature" colour default `0.5/0.5/0.5`, which
is a valid creature colour; inputs 3 and 12 are what separate it from a real
sighting.

### Outputs

6 outputs, all sigmoid (`[0, 1]`), interpreted as:

| # | Output | Meaning |
|---|--------|---------|
| 0 | `turnAngle` | mapped to `[-maxTurnRate, +maxTurnRate]` via `(v - 0.5) * 2` |
| 1 | `speed` | fraction of `maxSpeed` |
| 2 | `wantsToReproduce` | `>0.5` = yes |
| 3 | `wantsToAttack` | `>0.5` = attack the nearest creature in range |
| 4 | `wantsToEatPlant` | `>0.5` = eat a plant within reach |
| 5 | `wantsToEatCorpse` | `>0.5` = eat a corpse within reach |

Feeding has two independent switches rather than one, so diet selectivity
(e.g. carrion yes, live plants no) is itself evolvable.

## Derived traits

Everything a creature can *do* is computed from its genes, not stored
directly. From `Creature`:

| Trait | Formula |
|---|---|
| `eatRadius` | `size * 8 + 4` px |
| `sightRadius` | `(sightRadius_gene * 120 + 40) * max(0.3, 1 - senescence * 0.4)` px |
| `maxTurnRate` | `(turnRate_gene * 0.35 + 0.05) * max(0.3, 1 - senescence * 0.4)` rad/tick |
| `sightAngle` | `sightAngle_gene * (2π - 2π/3) + 2π/3` rad; `120°` at 0, `360°` at 1 |
| `attackRadius` | `size * 14 + aggression * 10 + 4` px |
| `olfactionSmellRadius` | `olfaction_gene * 170 + 30` px |
| `terrainSightRadius` | `sightRadius * 4`; see [DESIGN.md](DESIGN.md#terrain-perception-and-three-bugs-worth-remembering) |
| `maxEnergy` | `size * 150 + 80` |
| `hiddenCount` | `4 + brainSize_gene * (16 - 4)`, rounded down |
| `maxSpeed` | `speed_gene * 2.5 + 0.3` px/tick |
| `canReproduce` | `energy >= maxEnergy * (reproThreshold_gene * 0.3 + 0.55)` **and** `age > maxAge / 10` |

Senescence (below) shrinks sight radius and turn rate, on top of the biome
and age effects applied elsewhere.

## Metabolism

**Energy** is the universal currency; a creature dies the tick its energy
reaches 0. **Body mass** is a second store, the nutritional content that
would be recovered from a corpse. It is a separate store but not a separate
economy: every unit of it is bought from `energy` and sold back at a loss.

- Above 60% energy: mass grows by up to `0.05/tick`, capped at
  `maxBodyMass = size * 60 + 20`, and each unit costs `massBuildCost = 1.25`
  energy. Growth never spends past the 60% line, so it cannot starve its
  owner.
- Below 20% energy: catabolism burns up to `0.3/tick` of mass, crediting
  `massCatabolismYield = 0.5` energy per unit. Burning back what was built
  therefore returns 40% of what it cost, which is what keeps mass an
  investment rather than a second battery.
- Between 20% and 60%: mass is unchanged.
- At birth: a newborn starts at up to `maxBodyMass * 0.25`, bought out of the
  endowment its parents paid (see [Reproduction](#reproduction)). The rest
  has to be earned, so corpse value carries a signal about how well an
  individual actually fed instead of restating its size gene.

This is the part of [Energy conservation](DESIGN.md#energy-conservation) that
used to be missing. Mass grew with nothing debited and shrank with nothing
credited, while every newborn was handed a full `size * 60 + 20` for free: at
gene 0.5 that is 50 energy of future carrion per birth against 18 for a plant
eaten by a herbivore, on the order of the entire standing plant stock over a
2000 tick run. Scavenging was subsidised by the birth rate.

**Senescence** sets in at 70% of the genetic lifespan and rises without
bound afterward:

```
senescence = max(0, (age / maxAge - 0.7) / 0.3)
```

At exactly `maxAge` (`senescence = 1`), maintenance costs are +50% and sight
radius / turn rate are reduced by 40%; senescence keeps climbing past that
point, so a creature that survives well beyond its "natural" lifespan (via
the age-mortality roll not landing) becomes correspondingly more fragile.

**Per-tick energy cost** (`Creature.consumeEnergy`), all terms summed:

| Term | Formula | Notes |
|---|---|---|
| base | `0.08` | flat |
| size | `size² * 0.12` | static, quadratic |
| aggression | `aggression² * 0.07` | static, quadratic, deliberately cheap (see below) |
| brain | `brainSize² * 0.04` | static, quadratic |
| sight | `sightRadius² * 0.024 + sightAngle² * 0.030` | static, quadratic |
| olfaction | `olfaction² * 0.020` | static, quadratic |
| speed | `actualSpeedFraction * maxSpeed * 0.025 * (1 + size * 0.8)` | dynamic, linear |
| turning | `|actualTurn| * maxTurnRate * 0.08` | dynamic, linear |

The sum is then multiplied by `(1 + senescence * 0.5)`.

**Static** costs (paid every tick regardless of behaviour) scale
**quadratically** with the gene, calibrated so `gene = 0.5` costs the same
as the old linear model. Maxing out a trait is therefore disproportionately
expensive, which is what forces specialization instead of one dominant
generalist. **Dynamic** costs (speed, turning) stay **linear**, since they
already scale with what the creature actually did that tick, not with what
it merely could do.

Aggression's static coefficient (`0.07`) is deliberately lower than a naive
quadratic model would use (`0.18`). Its real cost is charged per attack
(see [Combat](#combat)) instead of as standing rent, because a hunter needs
both `size` and `aggression` at once and would otherwise pay a double
quadratic tax permanently. See
[DESIGN.md](DESIGN.md#herbivore-to-carnivore) for the full reasoning.

## Movement

Applied from the network's `turnAngle` and `speed` outputs
(`Creature.apply`):

1. **Turn**: `heading += (turnAngle - 0.5) * 2 * maxTurnRate`.
2. **Speed**: `effectiveMaxSpeed = maxSpeed * max(0.1, 1 - senescence * 0.3) * biomeSpeedFactor`, then `speed = output.speed * effectiveMaxSpeed`.
3. **Step**: the new position is computed with **toroidal wraparound**:
   `(position + heading_vector * speed + worldSize) mod worldSize` on both
   axes, so the world edges join up.
4. **Water check**: if the destination tile is impassable (water, when
   biomes are enabled), the move is rejected outright and the creature stays
   in place; turning still happened, so it can pivot away next tick.

**The whole world wraps, not just movement.** Sight, smell, local density,
herding, attack range, mate range and the biome map all measure the shorter
way round: separations go through `World.torDx` / `torDy`, and the spatial
grid wraps its cell iteration rather than clamping it at the world edge. Two
creatures a few pixels apart across the x=0 or y=0 line see, smell, attack
and mate with each other exactly as they would mid-world, and a pair
straddling the seam breeds next to itself (`World.midpoint`) rather than on
the far side of the map. Before this, those lines were invisible
reproductive barriers that creatures could walk through but not perceive
across, so speciation could form at a coordinate artefact.

## Feeding

A creature eats only what its brain currently wants (`wantsToEatPlant` /
`wantsToEatCorpse`, independently), and only food within `eatRadius`. If
neither switch is on, the grid query for that creature is skipped entirely.

**Digestibility** (`Creature.digestibility`) depends on `aggression`:

- Plant: `(1 - aggression * 0.7) * 0.6`, i.e. 60% at `aggression = 0`, down
  to 18% at `aggression = 1`.
- Corpse: `0.2 + aggression * 0.6`, i.e. a 20% floor even for pure
  herbivores, up to 80% for pure carnivores.

The corpse floor is what makes scavenging worthwhile from the very start of
the herbivore-to-carnivore gradient; see
[DESIGN.md](DESIGN.md#herbivore-to-carnivore).

**Plant toxin** (on by default, `plantToxinFactor = 0.60`,
`plantToxinThreshold = 0.50`): above the aggression threshold, eating a
plant also costs `(aggression - threshold) * toxinFactor * food.energyValue`,
subtracted from the raw digestible gain. Below the threshold there is no
penalty at all. A sufficiently specialized carnivore can end up with **net
negative** energy from eating a plant (poisoning). The loss is still capped
so energy cannot go below 0. Meat carries no toxin.

Energy gained is added up per tick into `recentFeedingRate`, an exponential
moving average (`α = 0.05`) that feeds sensor input 16, a creature's sense
of whether it is currently in a good patch.

A food item can be eaten by at most one creature per tick (`feedCreatures`
tracks consumed IDs within the tick and removes them once, afterward). Which
one gets it is decided by iteration order, and that order is **shuffled every
tick**. Array order would not do: survivors keep their index and newborns are
appended, so it correlates with age, and contested food would systematically
go to the older creature -- a selection pressure nothing in the design asks
for.

## Combat

A creature attacks if `wantsToAttack > 0.5`, a victim exists within
`attackRadius`, and the attacker is at least 60% of the victim's size
(`attacker.size >= victim.size * 0.6`). Only the upper end is gated: nothing
stops a creature attacking something smaller than itself, but it cannot take
on prey more than about 1.7x its own size. There is no hard aggression
threshold on the attack itself; the cost of attacking and the poor payoff
for a weak digester already discourage a herbivore's network from ever
emitting it.

```
rawDamage = (attacker.size * 0.6 + attacker.aggression * 0.4) * 50
defense   = min(victim.size * 0.30 + victim.aggression * 0.60, 0.90)
damage    = rawDamage * (1 - defense)
```

Size contributes to defense as passive robustness (hide, armour), while
aggression contributes as combat experience, and dominates, since a victim's
own aggression counts almost twice as much toward defense as its size.
Defense caps at 90%, so no combination of genes makes a creature unkillable.

The attacker also pays `aggression * 2` energy for the attempt itself,
**regardless of whether the attack lands**. The cost of aggression is
concentrated here rather than in standing maintenance (see
[Metabolism](#metabolism)). All attack and defense **energy deltas** across
the tick are collected into a dictionary and applied once, after every
attacker has been resolved, so damage does not depend on attack order and a
creature can be both an attacker and a victim in the same tick without one
resolution clobbering the other.

The **credit** for a kill follows the damage. Every attack is recorded on the
victim (`Creature.attacksTaken`: the attacker and what it dealt), and the
kill bonus below is split in proportion to damage dealt. That is what gives
cooperative hunting a gradient to climb; a single `lastAttacker` reference
handed the whole bonus to whichever attacker came last in array order, so
pack strategies were rewarded only indirectly, through the corpse everyone
can scavenge.

A successful kill does not directly grant the attacker energy; it produces
a corpse (see [Death](#death)), and the attackers' shares are taken out of
that corpse's value the moment it is created.

Attackers are iterated in plain array order, and that is safe: damage is
accumulated into the delta dictionary and applied in one pass afterwards, so
nobody strikes "first", and the bonus no longer depends on who came last.

## Death

Checked once per tick, after combat and feeding, in a single pass
(`World.checkDeaths`):

- **Energy death**: `energy <= 0`. Classified as `predation` if anything
  attacked the creature this tick (`attacksTaken` is non-empty), otherwise
  `starvation` (metabolism, hunger, or plant poisoning).
- **Age death**: a Gompertz-like mortality roll, independent of energy:
  `deathChance = 0.0001 + (age / maxAge)² * 0.003`, rolled every tick against
  a uniform random draw. A small baseline risk at any age, rising sharply as
  a creature approaches and passes its genetic lifespan. Classified as
  `oldAge`.

All three causes accumulate in `World.deathsByStarvation` /
`deathsByPredation` / `deathsByOldAge`, which is what makes a population
decline diagnosable rather than mysterious (see
[Observability](#observability)).

**Corpse creation**: if the dead creature's `bodyMass > 1`, a `FoodSource`
of type `.corpse` is spawned at its position with `energyValue = bodyMass`.
Mass is earned over a lifetime and bought out of energy (see
[Metabolism](#metabolism)), so that value says something about how well the
individual fed rather than restating its size gene.
Each still-living attacker immediately takes a share,
`bodyMass * killer.aggression * 0.4 * (its damage / total damage)`, credited
to its own energy and **deducted from the corpse's value** before the corpse
is placed. The kill bonus is not created out of nothing; it comes out of the
body being consumed. The remainder (if `> 1`) becomes the corpse other creatures can
scavenge. Corpses decay and are removed after 1200 ticks
(`World.decayFood`), releasing no energy in the process.

## Reproduction

Runs once per tick, after deaths, and only while
`creatures.count < maxPopulation`.

**Eligibility**: `canReproduce` (energy threshold **and** past 10% of
`maxAge`, see [Derived traits](#derived-traits)) **and** the creature's own
last network decision had `wantsToReproduce > 0.5`.

**Pairing**: eligible creatures are shuffled, then each takes the first
compatible, still-available, similarly-willing partner within
`World.mateRadius` (40 px) found via a spatial-grid query. Compatibility is:

- with speciation on (default): `geneticDistance(parent, partner) <=
  speciationThreshold` (default `0.45`, distance ranges over `[0, 2]`); see
  [Speciation](#speciation)
- with speciation off: `|aggression_parent - aggression_partner| < 0.3`

A creature that finds no partner reproduces **asexually** instead. This is a
fallback, not a separate strategy choice.

**Energy cost and inheritance**. The transfer is conserved exactly: offspring
never receive more than the parents pay, and `canReproduce` guarantees the
parents can cover it. Body mass is inside that accounting. What a child
receives is an **endowment** (`Creature.endow`), and its starter body is
bought out of that endowment at the same conversion cost growth pays later:

```
bodyMass = min(maxBodyMass * 0.25, endowment * 0.25 / massBuildCost)
energy   = endowment - bodyMass * massBuildCost
```

| | Cost per parent | Split across litter | Child's endowment |
|---|---|---|---|
| Sexual | `maxEnergy * 0.30` each | evenly | `min(childMaxEnergy * 0.6, pooledEnergy / litterSize)` |
| Asexual | `maxEnergy * 0.40` | evenly | `min(childMaxEnergy * 0.6, parentInvestment / litterSize)` |

Each child also carries a `generation`, one past its eldest parent; the
world's founders are generation 0 (see [Observability](#observability)).

Litter size is the `litterSize` gene (`1..4`), capped by remaining room
under `maxPopulation`. Sexual offspring DNA is `parent.crossed(with:
partner)` then `.mutated(...)`; asexual offspring DNA is just
`parent.mutated(...)`, a clone with mutation and no crossover partner.

Offspring spawn at a **dispersed** position, a random point 10-30 px from
the birth location (the parents' toroidal midpoint for sexual reproduction,
the parent's own position for asexual), so litters do not reinforce their own
starting cluster. With biomes on, a dispersed point that would land in water
is retried up to 8 times, falling back to the origin.

## Food

Plants regrow **logistically** toward `maxFood` (the carrying capacity):

```
fillRatio  = plantCount / maxFood
newPlants  = round(foodGrowthRate * seasonFactor * (1 - fillRatio) * maxFood)
```

`foodGrowthRate` (default `0.05`) is the share of remaining headroom filled
per tick. This is evaluated by one of three modes, mutually exclusive and
chosen by which world features are enabled:

- **Uniform** (default): each new plant lands at a uniformly random
  position.
- **Latitude gradient** (`latitudeGradientEnabled`): plants concentrate
  around the vertical mid-line via rejection sampling. A candidate position
  is accepted with probability `cos(distanceFromEquator/halfHeight * π/2)`,
  so the equator accepts every candidate and the poles accept none.
- **Biomes** (`biomesEnabled`, takes priority over the gradient): plants are
  placed by rejection sampling weighted by
  `biome.fertility * biome.growthFactor`, normalized so the most fertile
  biome (wetland) accepts with probability 1. Water never accepts. See
  [Biomes](#biomes).

Plant energy value is a flat **30** per item
(`FoodSource(energyValue: 30, type: .plant)`). Corpse value is whatever body
mass remains at death (see [Death](#death)).

## Biomes

Off by default; when off, `World.biome(at:)` always returns `.grassland`
(all factors neutral, passable), so every biome-dependent code path
reproduces pre-biome behaviour with no special-casing.

Five biomes, each pulling the four factors in different directions so no
biome dominates on every axis:

| Biome | Fertility | Growth | Speed | Sight | Passable |
|---|---|---|---|---|---|
| Grassland | 1.00 | 1.20 | 1.00 | 1.00 | yes |
| Forest | 0.70 | 0.90 | 0.85 | 0.55 | yes |
| Desert | 0.15 | 0.50 | 0.80 | 1.25 | yes |
| Wetland | 1.30 | 1.40 | 0.55 | 0.85 | yes |
| Water | 0.00 | 0.00 | 0.30* | 1.00 | **no** |

*Water's speed factor is never actually applied to movement, since water is
impassable; it exists only as the raw value a sensor could in principle
read.

**Map generation**: a Voronoi diagram over random seed points, using
toroidal distance (matching the wraparound world) so regions are
contiguous rather than per-tile noise. Seed count is `max(6, tileCount /
8)`; seed biomes are drawn from a weighted bag (grassland 35%, forest 25%,
desert 15%, wetland 10%, water 15%) with **at least 2 water seeds forced**,
guaranteeing real dividing bodies of water on every map. Generated once per
`World` instance, at 200x200 px tiles.

**Underfoot effects** apply continuously: `speedFactor` scales movement
directly, `sightFactor` scales `sightRadius` for perception only (the gene
itself is untouched), and `fertility x growthFactor` weight where plants are
placed. `isPassable` is checked on every attempted move; failing it simply
cancels that tick's step.

**Directional terrain perception** (sensors 20-24, "bearings"): each biome
gets a signed value where the sign is left/right of heading and the magnitude
is how strongly that biome dominates the field of view.
Computed by `BiomeMap.directionalBearings`, sampling a **polar grid on the
creature's own sight cone** (3 distance rings x 8 angles, nearer rings
weighted more), *not* the tile grid. Tiles are 200 px apart while real sight
radii run 20-160 px, so tile-center sampling almost never found a tile in
range at all. The radius used is `terrainSightRadius = sightRadius * 4`: a
creature standing inside one ~600 px biome region would otherwise see the
same biome in every direction and the bearing would cancel to ~0 regardless
of sampling resolution. See
[DESIGN.md](DESIGN.md#terrain-perception-and-three-bugs-worth-remembering)
for the bugs this fixed and the measured effect.

The contributions are normalized by the **largest magnitude that creature's
own cone can produce**: one biome filling exactly the half of the cone that
points hardest to one side. So `±1` means the same thing at every
`sightAngle`, and the full range is genuinely reachable. Normalizing by the
total sample weight instead capped the sensor at 0.24 (120° cone) to 0.36
(300° cone), about a third of its nominal range, and made the scale depend on
the `sightAngle` gene: the same lake read roughly 35% weaker for a
narrow-coned creature than for a wide-coned one, so an inherited weight meant
different things in different phenotypes. Measured over ~1M creature-ticks
with biomes on, the largest bearing seen went from 0.37 to 1.00, the mean
from 0.04-0.11 to 0.24-0.30, and the share of creature-ticks carrying a
signal `>= 0.05` from 29-61% to 66-80%.

## Seasons

Off by default. A cosine cycle over `seasonLength` ticks (default 3000)
modulates the plant growth rate:

```
t                  = (tickCount mod seasonLength) / seasonLength     // [0,1)
currentSeasonFactor = (1 - amplitude) + amplitude * 0.5 * (1 + cos(2π * t))
```

`seasonAmplitude` (default `0.70`) sets the trough: at `t = 0.5` (winter)
the factor is `1 - amplitude`; at `t = 0` (summer) it is `1.0`. An amplitude
of 1 would halt growth entirely at the trough. Displayed season names
(`Summer/Autumn/Winter/Spring`) are just quarters of the cycle for the UI
and have no independent mechanical effect beyond the factor.

## Speciation

On by default (`speciationEnabled`). It does not track species as discrete
entities; it is a **mating filter** applied per candidate pair, from which
visible clustering emerges.

**Genetic distance** (`DNA.geneticDistance`) is Euclidean over exactly four
genes (red, green, blue, aggression), each in `[0, 1]`, so distance ranges
over `[0, 2]`:

```
d = sqrt((Δr)² + (Δg)² + (Δb)² + (Δa)²)
```

This is deliberately **not** computed over the full genome: with ~200
network weights, nearly every pair of creatures sits at roughly the same
distance from each other (the curse of dimensionality), so the measure
would carry no usable signal. Colour is chosen because it is simultaneously
a visible trait on screen and a sensor input other creatures actually
perceive (inputs 9-11); aggression contributes the ecological niche axis.

Two creatures may mate only if `d <= speciationThreshold` (default `0.45`)
**and** they are within `World.mateRadius` (40 px) of each other. Gene flow
is bounded both genetically and spatially. A smaller radius lets species
separate on a finer spatial scale; a lower threshold gives more, tighter
clusters but shrinks the pool of eligible partners.

`World.countSpecies(threshold:)` (used for the live species-count stat)
approximates species count by **greedy clustering**: each creature joins the
first existing cluster whose representative is within `threshold`,
otherwise it opens a new one. This is an approximation, since it depends on
iteration order, but it is `O(n·k)` for a small cluster count `k` and is used
purely as a diversity readout, not as a mechanic that affects the
simulation itself.

Water barriers (see [Biomes](#biomes)) add a second, allopatric route to the
same outcome: geographic separation with no genetic-distance check involved
at all.

## Spatial grid

`SpatialGrid` backs every proximity query (`nearestCreature`, `forEachFood`,
`forEachCreature`, mate search, attack search) so none of them are O(n²)
over the population.

It is rebuilt in full in step 1 of the tick, and the creature half is refiled
again in step 3, right after movement, so everything that queries it
afterwards sees current cells. (Food does not move within a tick, so its
cells and the density raster over it are built once.) Cell iteration
**wraps** at the world edge instead of clamping: the block around a point
near x=0 continues at the far edge, and a wrapped query box becomes up to
four boxes in the summed-area table. Away from the seam, the common case, it
is still a single block and costs two comparisons extra.

- **Coarse grid**: 80x80 px cells, flat arrays (not a dictionary, so no
  hashing), rebuilt every tick with `removeAll(keepingCapacity:)` so it is
  allocation-free once warmed up. A query visits only the cells overlapping
  the bounding box of the search radius, not a fixed `±N` cell block, so the
  scan is sized to the query rather than to the cell size.
- **Plant-density raster**: a separate, finer 32x32 px grid with a
  **summed-area table**, rebuilt once per tick in `O(cells)`. The smell
  sensor (input 15) only needs a *count* of plants within a radius, and
  counting by scanning would otherwise force the food pass out to
  `olfactionSmellRadius` (typically larger than `sightRadius`) just to
  produce one number. The summed-area table answers that query in `O(1)`,
  approximating the circular query region as its enclosing box scaled by
  `π/4`.

## World scaling

Two config values are expressed as reference numbers for an 800x600 world
and then scaled by `sqrt(currentArea / referenceArea)` in
`SimulationEngine.syncConfigToWorld`. The scaling is a **square root**, not
linear, so doubling the world area gives ~1.4x the value rather than 2x:

- `world.maxFood = foodCapacity_config * scale`
- `world.maxPopulation = max(300 * scale, initialCreatures)`

Consequence: the largest supported world (4800x3600) has 36x the reference
area but only ~6x the food capacity, so its plant *density* is a sixth of
the default world's. See
[DESIGN.md](DESIGN.md#food-capacity-scales-with-the-square-root-of-area)
for why the UI's food-capacity slider compensates for this.

## Observability

Built to be watched, by both the app UI and automated tooling:

- **Death causes**: cumulative counters for starvation, predation and old
  age (see [Death](#death)), so a declining population is diagnosable
  rather than mysterious.
- **Event stream** (`World.eventRecording`, off by default): a buffer of
  birth/death events (`SimEvent`), including death cause and position,
  meant to be drained once per tick by an external observer.
- **Sensor recording** (`World.sensorRecording`, off by default): stores
  each creature's last `SensorInput`, at a cost of `population x 30` floats
  per tick when enabled. What makes a decision explainable as perception to
  action.
- **Statistics**: `SimulationEngine` computes population composition
  (herbivore/omnivore/carnivore split at aggression `0.33`/`0.67`), average
  age/energy/aggression and live species count once per rendered frame;
  `StatisticsTracker` additionally records a rolling history (every 10
  ticks, last 300 samples) of population and trait averages for the charts.
- **Counters** on `World`: `tickCount`, `totalBirths`, `totalDeaths`, the
  three death-cause tallies, and `generation`. The last is the **mean
  generation of descent** over the living population: every creature carries
  one, founders are 0 and a child is one past its eldest parent. It used to
  be a counter incremented once per tick in which any birth occurred, which
  converges on the tick count in a busy population (a 2000 tick run with a
  mean age of 221 reported about 1287 where the true figure was nearer 10)
  while being labelled "Generation" in the sidebar and the headless table.
- **`Tools/Headless/run.sh`**: compiles and runs the UI-free simulation
  core directly with `swiftc`, uncapped, several thousand ticks/second. Exposes
  all of the above plus an ASCII world map, trait histograms, NDJSON
  snapshots, and a per-creature behaviour trace (all 30 inputs and 6 outputs,
  every tick). See the README's
  [Watching it headlessly](../README.md#watching-it-headlessly) section for
  usage.
