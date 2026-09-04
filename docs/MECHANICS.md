# Mechanics

A precise reference for how the simulation works: every formula, constant and
rule, as implemented. [README.md](../README.md) is the overview and
[DESIGN.md](DESIGN.md) is the reasoning behind the numbers; this document is
the specification in between, describing what actually happens, tick by tick.

Source of truth throughout: `Swiftolution/Simulation/` and
`Swiftolution/Engine/SimulationEngine.swift`. Line references point at the
version current when this was written; behaviour, not line numbers, is the
contract.

This document describes the simulation as it actually behaves, including the
places where that differs from what the design intends. Those places are
marked and link to [KNOWN-ISSUES.md](KNOWN-ISSUES.md), which lists them as
defects with evidence and a suggested fix.

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

Each call to `World.tick()` runs nine phases, in this fixed order:

1. **Rebuild the spatial grid** from the current creature and food positions.
2. **Move**: sense, think, act (see [Movement](#movement)).
3. **Attack**: resolve all attacks declared this tick.
4. **Feed**: resolve all eating declared this tick.
5. **Check deaths**: energy and age mortality; spawn corpses.
6. **Spawn minimum** (optional): top up a collapsing population.
7. **Reproduce**: pair up willing, eligible creatures.
8. **Grow food**: logistic plant growth.
9. **Decay food**: remove corpses older than 1200 ticks.

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

A creature's entire hereditary makeup is one flat array of **532 floats**,
each in `[0, 1]`: 14 named genes followed by 518 raw neural network weights.

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
| 14-531 | *(network weights)* | see [Brain](#brain) |

DNA always carries weights sized for the **maximum** brain (16 hidden
neurons), regardless of the creature's actual `brainSize`. That keeps every
genome the same length, so crossover never needs special-casing for
differently sized brains. A smaller brain simply uses a prefix of the weight
block and ignores the rest.

Genes that map onto a small integer do so by truncation, `Int(gene * N)`,
which makes the **top bucket reachable only at exactly `gene == 1.0`**: a
litter of 4 needs `genes[10] == 1.0`, and a 16 neuron brain needs
`brainSize == 1.0`. At `0.999` both still yield the bucket below. The top
value does occur, because `DNA.mutated` clamps overshooting mutations to
exactly 1.0 and so puts a point mass on the boundary, but its frequency is an
artefact of that clamp rather than of selection. See
[KNOWN-ISSUES.md](KNOWN-ISSUES.md#8-the-top-bucket-of-every-intgene--n-mapping-is-a-point-mass).

**Mutation** (`DNA.mutated`, applied to every offspring gene-by-gene at the
configured `mutationRate`, default 5%): a mutated gene receives one of three
deltas, chosen once the gene is picked for mutation:

- 95%: micro (`±mutationStrength`, default `±0.10`), fine-tuning
- 4%: medium (`±2×strength`), exploring a wider neighbourhood
- 1%: macro (`±5×strength`), a jump into a new region of strategy space

The result is clamped back into `[0, 1]`.

**Crossover** (`DNA.crossed`): single-point. A random split index is chosen
once; the child takes genes `[0, split)` from one parent and `[split, 532)`
from the other. Because gene indices are fixed, this can split a network
weight in the middle of a neuron's input row. The resulting recombination is
somewhat destructive at the network level by design, matching how crossover
would work in a real (non-network) genome.

## Brain

A feed-forward network, one hidden layer, evaluated fresh every tick:

```
25 inputs -> [4..16 hidden, tanh] -> 6 outputs, sigmoid
```

Hidden layer size is itself a gene (`brainSize`), interpolated between
`NeuralNetwork.minHiddenCount` (4) and `maxHiddenCount` (16). Weights are
decoded from genes `[0,1]` to `[-1,1]` via `v * 2 - 1`, so positive and
negative influence are equally likely from the start. Otherwise every neuron
would be biased to fire the same way at birth.

The forward pass runs on a stack buffer (`withUnsafeTemporaryAllocation`),
no heap allocation, since it is the hottest path in the simulation
(population x one call per tick).

### Sensors

25 inputs, built once per creature per tick by `World.sense(for:)`. Two
perception rules apply throughout:

- **Food and the nearest creature** are only perceived inside the sight
  cone, a field of view of `sightAngle` (`120°` at gene 0 to full `360°` at
  gene 1), tested via a dot-product against the heading (no `atan2` on the
  hot path).
- **Local density and herding direction** are omnidirectional, modeled as
  touch/pressure sensing rather than vision, so they ignore the FOV.

| # | Input | Range | Notes |
|---|-------|-------|-------|
| 0 | angle to nearest food | `[-1, 1]` | left/right of heading |
| 1 | distance to nearest food | `[0, 1]` | `1` = at sight-radius edge |
| 2 | angle to nearest creature | `[-1, 1]` | |
| 3 | distance to nearest creature | `[0, 1]` | |
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
| 20-24 | terrain bearing (grassland/forest/desert/wetland/water) | `±0.24..0.36` in practice | see [Biomes](#biomes) |

Distances and the "nearest creature" search share a single pass over the
spatial grid per creature, at `max(sightRadius, 80)`, so density and herding
(80 px) are always covered even for short-sighted creatures.

Two properties of this input set are worth knowing when reading a trace.
First, an **empty** reading is not distinct from a real one: with no food in
view, inputs 0, 1 and 7 read `0, 1, 0`, which is exactly a plant dead ahead
at the edge of sight, and the "no creature" colour default `0.5/0.5/0.5` is a
valid creature colour. Only the count inputs (12 and 14) separate the two
cases. Second, the terrain bearings do not span `[-1, 1]` despite the clamp
in the code; see [Biomes](#biomes). Both are listed in
[KNOWN-ISSUES.md](KNOWN-ISSUES.md).

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
| `terrainSightRadius` | `sightRadius * 4`; see [DESIGN.md](DESIGN.md#terrain-perception-and-two-bugs-worth-remembering) |
| `maxEnergy` | `size * 150 + 80` |
| `hiddenCount` | `4 + brainSize_gene * (16 - 4)`, rounded down |
| `maxSpeed` | `speed_gene * 2.5 + 0.3` px/tick |
| `canReproduce` | `energy >= maxEnergy * (reproThreshold_gene * 0.3 + 0.55)` **and** `age > maxAge / 10` |

Senescence (below) shrinks sight radius and turn rate, on top of the biome
and age effects applied elsewhere.

## Metabolism

**Energy** is the universal currency; a creature dies the tick its energy
reaches 0. **Body mass** is a separate store, the nutritional content that
would be recovered from a corpse, decoupled from the energy battery:

- Above 60% energy: body mass grows, `+0.05/tick`, capped at `size * 60 + 20`.
- Below 20% energy: body mass shrinks, `-0.3/tick`, floored at 0.
- Between 20% and 60%: body mass is unchanged.

Two things about this store are worth stating plainly, because the wording
elsewhere suggests otherwise (see
[KNOWN-ISSUES.md](KNOWN-ISSUES.md#2-body-mass-is-outside-the-energy-accounting)):

- **It sits outside the energy accounting.** Growth is not debited from
  `energy`, and shrinking is not credited back to it. The shrink path is not
  catabolism in the metabolic sense; it converts nothing, it only makes the
  eventual corpse smaller. Newborns are additionally granted their full mass
  for free at birth, so every birth injects `size * 60 + 20` of future
  carrion that nothing paid for.
- **Every creature is born at the cap.** `Creature.init` and the
  `maxBodyMass` used in `consumeEnergy` are the same expression, so the
  growth branch can only ever restore mass lost to starvation, never
  accumulate past the birth state. Corpse value is therefore close to a pure
  function of the size gene and says little about how well an individual fed
  (see
  [KNOWN-ISSUES.md](KNOWN-ISSUES.md#3-body-mass-starts-at-its-maximum)).

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

**Movement is the only thing that wraps.** Perception and interaction do not:
every spatial query computes distances naively and clamps its cell iteration
at the world edge instead of wrapping. Two creatures a few pixels apart across
the x=0 or y=0 line therefore cannot see, smell, attack or mate with each
other, even though either can walk across to the other's position. The biome
map, by contrast, *is* generated with toroidal distance. See
[KNOWN-ISSUES.md](KNOWN-ISSUES.md#1-perception-does-not-wrap-around-the-world).

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
one gets it is decided by iteration order over `creatures`, which is array
order and therefore correlates with age, since survivors keep their order and
newborns are appended. See
[KNOWN-ISSUES.md](KNOWN-ISSUES.md#5-feeding-and-attacking-favour-early-array-positions).

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

The **credit** for a kill does depend on order. `victim.lastAttacker` is a
single reference overwritten by each attacker in turn, so after a tick it
holds whichever attacker came last in `creatures` array order, regardless of
how much damage each dealt. That one creature receives the entire kill bonus
below, and it also decides whether the death is classified as predation or
starvation. See
[KNOWN-ISSUES.md](KNOWN-ISSUES.md#4-the-kill-bonus-goes-to-an-arbitrary-attacker).

A successful kill does not directly grant the attacker energy; it produces
a corpse (see [Death](#death)), and the recorded killer's share is taken out
of that corpse's value the moment it is created.

Attackers are iterated in plain array order, without the shuffle that
[Reproduction](#reproduction) uses, so a creature earlier in the array
strikes first. See
[KNOWN-ISSUES.md](KNOWN-ISSUES.md#5-feeding-and-attacking-favour-early-array-positions).

## Death

Checked once per tick, after combat and feeding, in a single pass
(`World.checkDeaths`):

- **Energy death**: `energy <= 0`. Classified as `predation` if something
  attacked the creature this tick (`lastAttacker != nil`), otherwise
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
Since body mass is granted in full at birth and only ever shrinks, that value
is close to a pure function of the size gene (see
[Metabolism](#metabolism)).
If it was killed by a still-living attacker, that attacker immediately takes
a share, `bodyMass * killer.aggression * 0.4`, credited to its own energy
and **deducted from the corpse's value** before the corpse is placed. The
kill bonus is not created out of nothing; it comes out of the body being
consumed. The remainder (if `> 1`) becomes the corpse other creatures can
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

**Energy cost and inheritance**. The `energy` transfer is conserved exactly,
in that offspring never receive more than the parents pay, and `canReproduce`
guarantees the parents can cover it. Body mass is not part of this accounting:
each newborn is additionally granted a full `size * 60 + 20` of it for free
(see [Metabolism](#metabolism)).

| | Cost per parent | Split across litter | Child receives |
|---|---|---|---|
| Sexual | `maxEnergy * 0.30` each | evenly | `min(childMaxEnergy * 0.6, pooledEnergy / litterSize)` |
| Asexual | `maxEnergy * 0.40` | evenly | `min(childMaxEnergy * 0.6, parentInvestment / litterSize)` |

Litter size is the `litterSize` gene (`1..4`), capped by remaining room
under `maxPopulation`. Sexual offspring DNA is `parent.crossed(with:
partner)` then `.mutated(...)`; asexual offspring DNA is just
`parent.mutated(...)`, a clone with mutation and no crossover partner.

Offspring spawn at a **dispersed** position, a random point 10-30 px from
the birth location (the parents' midpoint for sexual reproduction, the
parent's own position for asexual), so litters do not reinforce their own
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
[DESIGN.md](DESIGN.md#terrain-perception-and-two-bugs-worth-remembering) for
the two bugs this fixed and the measured effect.

The code clamps the result to `[-1, 1]`, but that clamp never binds. Because
the contributions are normalized by the total sample weight and cancel
symmetrically, the largest magnitude actually attainable, with one biome
filling exactly the most favourable half of the cone, is:

| `sightAngle` | max attainable `|bearing|` |
|---|---|
| 120° | 0.239 |
| 180° | 0.320 |
| 240° | 0.362 |
| 300° | 0.363 |
| 360° | 0.327 |

So the sensor uses about a third of its nominal range, and its scale depends
on the `sightAngle` gene: the same lake reads roughly 35% weaker for a
narrow-coned creature than for a wide-coned one. See
[KNOWN-ISSUES.md](KNOWN-ISSUES.md#6-terrain-bearings-never-reach-their-documented-range).

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

It is rebuilt in step 1 of the tick, before creatures move in step 2, while
attacking, feeding and reproduction query it afterwards. Because `Creature`
is a reference type the positions read out of the cells are current; only the
cell assignment is one movement step old. That can only ever cause a query to
miss a creature that moved into range this tick, bounded by one step (about
2.8 px against 80 px cells). Cell iteration also clamps at the world edge
rather than wrapping, which is the mechanism behind
[the perception seam](#movement).

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
  each creature's last `SensorInput`, at a cost of `population x 25` floats
  per tick when enabled. What makes a decision explainable as perception to
  action.
- **Statistics**: `SimulationEngine` computes population composition
  (herbivore/omnivore/carnivore split at aggression `0.33`/`0.67`), average
  age/energy/aggression and live species count once per rendered frame;
  `StatisticsTracker` additionally records a rolling history (every 10
  ticks, last 300 samples) of population and trait averages for the charts.
- **Counters** on `World`: `tickCount`, `totalBirths`, `totalDeaths`, the
  three death-cause tallies, and `generation`. Note that `generation` is
  incremented once per tick in which any birth occurred, so it counts
  breeding ticks rather than generations of descent: a 2000 tick run with a
  mean age of 221 reports about 1287, where the true figure is nearer 10. It
  is labelled "Generation" in both the sidebar and the headless table. See
  [KNOWN-ISSUES.md](KNOWN-ISSUES.md#7-generation-does-not-count-generations).
- **`Tools/Headless/run.sh`**: compiles and runs the UI-free simulation
  core directly with `swiftc`, uncapped, several thousand ticks/second. Exposes
  all of the above plus an ASCII world map, trait histograms, NDJSON
  snapshots, and a per-creature behaviour trace (all 25 inputs and 6 outputs,
  every tick). See the README's
  [Watching it headlessly](../README.md#watching-it-headlessly) section for
  usage.
