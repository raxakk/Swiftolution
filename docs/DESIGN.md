# Design notes

Why the simulation works the way it does. These notes exist because most of the
interesting decisions here are ecological rather than technical: the code is
straightforward, but the *numbers* in it are the result of watching populations
collapse in specific ways and fixing the cause.

## The central problem: fitness valleys

An evolutionary simulation only produces interesting behaviour if the fitness
landscape is climbable. Wherever two viable strategies are separated by a region
of low fitness, evolution cannot cross it. Only a lucky large mutation can, and
those are rare enough that in practice the population stays on one side forever.

Most of the tuning in this project is about removing such valleys.

### Herbivore to carnivore

The obvious valley is between eating plants and eating meat. A herbivore that
mutates toward aggression pays the cost of aggression immediately but cannot yet
digest meat well enough to profit from it.

The bridge is carrion. Corpse digestibility is `0.2 + aggression * 0.6`, so even
a pure herbivore recovers 20% of a corpse's value. Scavenging is worthwhile from
the very start, which turns the gap into a continuous gradient:

    herbivore -> opportunistic scavenger -> hunter

Plant digestibility runs the other way, `(1 - aggression * 0.7) * 0.6`, so
specializing still costs something in the other direction.

Two further adjustments serve the same goal:

- **Separate feeding outputs.** The network has distinct `wantsToEatPlant` and
  `wantsToEatCorpse` outputs, so a creature can evolve a selective diet instead
  of an all-or-nothing one.
- **Aggression is cheap to have, expensive to use.** Static maintenance for
  aggression uses a low coefficient (0.07); the real cost is charged per attack.
  Hunters need both size and aggression, and with a high static cost they paid a
  double quadratic tax permanently, which kept the strategy out of reach.

### Plant toxin

Making carnivory reachable is not enough. Carnivores also have to be pushed to
*specialize*, or the population settles into undifferentiated omnivores.

Plants defend themselves chemically. Above an aggression threshold (default 0.5)
a creature takes a toxin load proportional to its specialization times the amount
eaten, until eating plants is a net energy loss. Below the threshold there is no
penalty at all, which is deliberate: the herbivore end of the gradient must stay
untouched. Meat carries no toxin, so the carrion stepping stone also survives.

## Energy conservation

Energy is never created out of nothing, and this is enforced at every transfer:

- Offspring receive exactly what their parents pay. Each parent invests 30% of
  its maximum energy regardless of litter size, and the combined investment is
  split evenly across the children. Asexual reproduction invests 40%.
- A predator eating at a kill takes its share *out of the corpse*, it is not
  granted separately.
- Corpses decay and vanish rather than releasing energy.
- Body mass is a separate store from the metabolic battery: it grows when well
  fed, is catabolized when starving, and determines how nourishing the corpse is.

The one exception is plant growth, which is the system's energy input, driven by
a logistic curve toward the configured carrying capacity.

## Specialization pressure

Static maintenance costs scale quadratically with the genes that drive them
(`gene^2 * 2 * k`, calibrated so `gene = 0.5` matches a linear cost). Maxing out
every trait is therefore disproportionately expensive, and creatures are pushed
into niches instead of converging on one generalist optimum. Dynamic costs stay
linear, because they depend on what a creature actually does rather than on what
it could do.

## Speciation

Assortative mating produces reproductive isolation: creatures only mate with
partners whose genetic distance is below a threshold.

The distance is deliberately **not** computed over the whole genome. With ~200
network weights every pair of creatures sits at roughly the same distance (the
curse of dimensionality), and the measure carries no signal. Instead it uses a
four-axis species signature: colour (r, g, b) plus aggression. Colour dominates
because it is both perceived by other creatures as a sensor input and visible on
screen, so clusters are something a human observer can actually watch form.
Aggression contributes the ecological niche.

Gene flow is also bounded spatially. `World.mateRadius` (40 px) is the distance
within which partners can find each other; a smaller radius lets species separate
on a finer spatial scale.

Water barriers add the allopatric route to the same outcome; see below.

## Biomes and terrain

Biomes give the world spatial structure so that different regions reward
different phenotypes. Five of them (grassland, forest, desert, wetland, water)
each modulate fertility, growth rate, movement speed, sight cover and
passability, with values that deliberately pull against each other so no biome is
good at everything.

The map is a Voronoi diagram over random seed points using toroidal distance,
which produces contiguous regions rather than per-tile noise. At least two water
seeds are guaranteed, so dividing bodies of water always exist.

### Terrain perception, and two bugs worth remembering

Creatures sense terrain directionally: per biome, a bearing in `[-1, 1]` where
the sign is left/right relative to the heading. Getting this to carry any
information at all took two fixes, both instructive.

**Sampling the tile grid does not work.** The original implementation sampled
biome *tile centres* within the sight radius. Tiles are 200 px apart, but real
sight radii are 20-160 px, so the nearest tile centre was almost never in range,
not even the creature's own. All five bearings were constantly 0. The sensor
inputs existed, carried nothing, and water avoidance could never be learned.
The fix samples the creature's own sight cone on a polar grid (3 distance rings
x 8 angles), so resolution follows the sight radius rather than the tile size.

**Terrain is a landscape-scale feature.** Even with correct sampling, a creature
inside a ~600 px biome region sees the same biome in every direction: the
contributions cancel and the bearing is ~0. Correct, but useless. Terrain
therefore has its own horizon, `terrainSightRadius = sightRadius * 4`. Lakes and
forest edges are visible from much farther away than a single item of food, which
is also the more realistic model. It stays tied to the sight gene, so range
remains evolvable and costly.

Measured on a live trace, this took the share of creature-ticks carrying a terrain
signal (>= 0.05) from ~0% to 51%.

## Running the simulation

### Bootstrap at maximum food, then reduce

The intended workflow is to start a run with food capacity at maximum, let a
stable population establish itself, and only then reduce the capacity to raise
selection pressure. A run started under scarcity mostly dies before evolution has
anything to work with. Early starvation in that situation is the setup, not a
bug. Both the app and the headless runner therefore default to the maximum, and
`--reduce-food-at T C` performs the reduction, repeatably for stepwise steps.

How sharp the threshold is, measured on the default world (2400x1800, 80 starting
creatures, 4000 ticks, no biomes): at capacity 1500 the population died out in 4 of
4 runs, at 2500 in 2 of 6, and at 3000 in 0 of 6. There is not much of a slope
between "reliably extinct" and "reliably at the ceiling".

### Food capacity scales with the square root of area

Capacity is a reference value for an 800x600 world, scaled by `sqrt(area)` so
that doubling the area gives ~1.4x the capacity rather than 2x. This has a
consequence worth knowing: the largest world (4800x3600) has 36 times the
reference area but only a factor of 6 in capacity, so its plant *density* is a
sixth of the default. The UI slider therefore goes to 3000: at that setting the
largest world reaches the same density the default world has at 1500, which is
what makes the bootstrap phase work there too.

## Observability

The simulation is built to be watched, by humans and by automated observers
alike.

- **Death causes.** Every death is classified as starvation, predation or old
  age, with cumulative counters. Population decline is diagnosable rather than
  mysterious.
- **Event stream.** An optional buffer records births and deaths with cause; an
  observer drains it after each tick. Off by default, at zero cost when disabled.
- **Sensor recording.** Optionally stores each creature's last sensor input, which
  makes a network decision explainable as perception -> action. Off by default,
  since it costs `population x 25` floats per tick.
- **The headless runner** (`Tools/Headless/run.sh`) exposes all of this: aggregate
  tables, an ASCII world map, trait histograms, NDJSON snapshots and events, and a
  behaviour trace that follows individual creatures tick by tick.

## Performance

The simulation runs many thousands of ticks per second, which is what makes
observation practical. The load-bearing decisions:

- **Parallel perception.** `sense()` plus network activation runs across all
  cores; each creature reads only its own state and an immutable spatial grid.
  Position and state writes happen sequentially afterwards, because position
  changes affect the same tick.
- **Flat spatial grid.** Cell arrays rather than dictionary buckets, with a
  visitor API so queries allocate nothing. `removeAll(keepingCapacity:)` makes
  `rebuild()` allocation-free once warmed up.
- **Query only what you asked for.** Cell scans cover the bounding box of the
  query circle, not a block of `+/-ceil(radius / cellSize)` cells. The latter
  scanned 3x3 cells for a 12 px eat radius, i.e. 57,600 px2 instead of 452.
- **Summed-area table for plant density.** The olfaction sensor needs a count of
  plants within up to 200 px. Counting them by scanning forced the food pass out
  to the smell radius, which is usually larger than the sight radius, for the sake
  of a single number. A 32 px density raster with a summed-area table, rebuilt in
  O(cells) per tick, makes that query O(1).
- **Allocation-free forward pass.** Flat row-major weight buffers and a stack
  buffer for activations, on the hottest path in the simulation.
- **Squared distances everywhere,** with a dot-product field-of-view test instead
  of `atan2` per candidate.
