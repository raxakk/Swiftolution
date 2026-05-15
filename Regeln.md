# Swiftolution — Statische Simulationsregeln

Alle fest im Code verankerten Konstanten, Schwellwerte und Berechnungsformeln.
Konfigurierbare Parameter (Schieberegler in der UI) sind separat markiert.

---

## 1. Simulations-Tick (Reihenfolge)

Jeder Tick führt diese Phasen **in dieser Reihenfolge** aus:

1. **Spatial Grid aufbauen** — Raster für schnelle Nachbarschaftssuche
2. **Bewegung** — NN berechnet Ausgabe → Kreatur bewegt sich, Energie wird verbraucht, Wüstenhitze wird abgezogen
3. **Angriff** — alle Angriffe werden gesammelt und simultan angewendet
4. **Fressen** — Nahrung in Reichweite wird aufgenommen
5. **Tod** — energielose oder zu alte Kreaturen sterben, hinterlassen Leiche
6. **Fortpflanzung** — Kandidaten suchen Partner und zeugen Nachwuchs
7. **Nahrungswachstum** — neue Pflanzen erscheinen logistisch
8. **Verfall** — Leichen und Kampfabfall werden zu Pflanzen umgewandelt

---

## 2. DNA — Gene

| Index | Name | Wertebereich | Bedeutung |
|-------|------|-------------|-----------|
| 0 | `speed` | [0, 1] | Geschwindigkeitspotenzial |
| 1 | `sightRadius` | [0, 1] | Sichtweite |
| 2 | `size` | [0, 1] | Körpergröße |
| 3 | `aggression` | [0, 1] | 0 = reiner Pflanzenfresser, 1 = reiner Fleischfresser |
| 4 | `maxAge` | [0, 1] | → `max(1, Int(gene × 1000))` Ticks |
| 5 | `reproductionThreshold` | [0, 1] | Energieschwelle für Fortpflanzung |
| 6 | `brainSize` | [0, 1] | Anzahl versteckter Neuronen (4–16) |
| 7 | `red` | [0, 1] | Körperfarbe Rot-Anteil |
| 8 | `green` | [0, 1] | Körperfarbe Grün-Anteil |
| 9 | `blue` | [0, 1] | Körperfarbe Blau-Anteil |
| 10 | `habitatPreference` | [0, 1] | 0 = Wüste, 0.5 = Generalist, 1 = Wald |
| 11+ | NN-Gewichte | [0, 1] | → auf [-1, 1] remappt: `v × 2 − 1` |

---

## 3. Abgeleitete Eigenschaften aus DNA

| Eigenschaft | Formel | Beispielwerte |
|-------------|--------|--------------|
| Fressradius | `size × 8 + 4` px | 4–12 px |
| Sichtradius | `sightRadius × 120 + 40` px | 40–160 px |
| Angriffsradius | `size × 14 + aggression × 10 + 4` px | 4–28 px |
| Maximale Energie | `size × 150 + 80` | 80–230 |
| Startenergie | `size × 80 + 40` | 40–120 |
| Maximale Geschwindigkeit | `speed × 2.5 × (1.2 − aggression × 0.4) + 0.3` | 0.3–3.3 px/Tick |
| Versteckte Neuronen | `4 + Int(brainSize × 12)` | 4–16 |
| Fortpflanzungsschwelle | `(reproductionThreshold × 0.3 + 0.55) × maxEnergy` | 55%–85% |

**Notiz:** Herbivoren sind durch die Formel bis zu 38% schneller als Fleischfresser bei gleichem `speed`-Gen (`aggression=0` → ×1.2, `aggression=1` → ×0.8).

---

## 4. Energiesystem — Kosten pro Tick

| Kostenart | Formel | Max. Wert |
|-----------|--------|----------|
| Grundkosten | `0.08` | 0.08/Tick |
| Größenkosten | `size × 0.06` | 0.06/Tick |
| Bewegungskosten | `actualSpeed × maxSpeed × 0.025` | ~0.08/Tick |
| Aggressionskosten | `aggression × 0.09` | 0.09/Tick |
| Gehirnkosten | `brainSize × 0.02` | 0.02/Tick |
| Wüstenhitze | `0.03 + habitatPreference × 0.05` (nur Wüste) | 0.08/Tick |

**Summe** bei Extremwerten (alle Gene = 1, Vollgas, Wüste): ~0.41 Energie/Tick

**Tod** tritt ein wenn: `energy ≤ 0` **oder** `age ≥ maxAge`

---

## 5. Nahrungsaufnahme

- Fressen möglich wenn: Abstand zur Nahrung < `eatRadius`
- **Fleischfresser** (`aggression > 0.45`) ignorieren Pflanzen vollständig
- **Verdaulichkeit** von Pflanzen: `1.0 − aggression × 0.7`
  - Pflanzenfresser (aggr=0): 100% Effizienz
  - Fleischfresser (aggr=1): 30% Effizienz (aber sie ignorieren Pflanzen, greift daher nicht)
- Leichen und Kampfabfall: 100% Verdaulichkeit für alle
- Energie wird auf `maxEnergy` gekappt

---

## 6. Kampfsystem

### Voraussetzungen für einen Angriff
1. `wantsToAttack > 0.5` (NN-Ausgabe)
2. `aggression > 0.45` (nur echte Räuber)
3. Opfer innerhalb `attackRadius`
4. Angreifer-Größe ≥ `victim.size × 0.6` (Größenvorteil nötig)

### Schadensberechnung
```
rawDamage = (size × 0.6 + aggression × 0.4) × 50
defense   = min(victim.aggression × 0.9, 0.92)
damage    = rawDamage × (1 − defense)
stolen    = min(damage, victim.currentEnergy)
```

### Energiebilanz des Angreifers
```
Kosten:  aggression × 6
Gewinn:  stolen × 0.45
```

| Szenario | Netto bei typischen Werten |
|----------|--------------------------|
| Fleischfresser (0.8) → Pflanzenfresser (0.1) | ≈ +9 Energie |
| Fleischfresser (0.8) → Fleischfresser (0.8) | ≈ −2 Energie |
| Fleischfresser (0.9) → Fleischfresser (0.9) | ≈ −4 Energie |

**Kampfabfall:** 55% des gestohlenen Wertes (`stolen × 0.55`) erscheint als `.waste`-Nahrung am Kampfort, sofern > 3 Energie.

### Simultane Auflösung
Alle Energieveränderungen eines Ticks werden in einem Dictionary gesammelt und erst am Ende gleichzeitig angewendet — kein Reihenfolgevorteil.

---

## 7. Tod und Leichen

- Toter Körper erzeugt `.corpse`-Nahrung mit Energie: `size × 45 + 12`
- Leiche erscheint an der Sterbeposition
- Leiche verfällt nach **600 Ticks** zu einer Pflanze
- Kampfabfall verfällt nach **200 Ticks** zu einer Pflanze
- Energie bleibt vollständig im Kreislauf erhalten (Nährstoffzyklus)

---

## 8. Fortpflanzung

### Voraussetzungen
- Energie ≥ Fortpflanzungsschwelle (55%–85% je nach Gen)
- Alter > **60 Ticks**
- `wantsToReproduce > 0.5` (NN-Ausgabe)
- Population < `maxPopulation` (konfigurierbar, skaliert mit Weltfläche)

### Sexuelle Fortpflanzung (bevorzugt)
- Partner muss ebenfalls `canReproduce` und `wantsToReproduce > 0.5` haben
- Maximaler Abstand zum Partner: **40 px**
- Artkompatibilität: `|aggression_A − aggression_B| < 0.3`
- Kind-DNA: Crossover beider Eltern + Mutation
- Energiekosten: **25%** `maxEnergy` pro Elternteil
- Kind spawnt zwischen den Eltern (±10–30 px Streuung)

### Asexuelle Fortpflanzung (Fallback)
- Wenn kein kompatibler Partner in Reichweite gefunden
- Kind-DNA: nur Mutation
- Energiekosten: **40%** `maxEnergy`

### Mutation
| Parameter | Standard | Konfigurierbar |
|-----------|---------|---------------|
| Rate | 0.05 (5% der Gene) | ✓ |
| Stärke | ±0.10 je mutiertem Gen | ✓ |

---

## 9. Nahrungssystem

### Logistisches Pflanzenwachstum
```
newPlants = round(growthRate × (1 − plantCount / maxFood) × maxFood)
```
- Wächst schnell wenn leer, verlangsamt wenn voll
- Nur **Pflanzen** zählen zur Kapazitätsgrenze (nicht Leichen/Abfall)

### Terrain-Gewichtung neuer Pflanzen
| Terrain | Wahrscheinlichkeit |
|---------|------------------|
| Wald | 100% (Referenz) |
| Grasland | 55% |
| Wüste | 5% |

### Nahrungstypen
| Typ | Energie | Verfall | Entsteht durch |
|-----|---------|---------|---------------|
| `.plant` | 30 | nie | Wachstum, Verfall |
| `.corpse` | `size × 45 + 12` | 600 Ticks → Pflanze | Tod |
| `.waste` | `stolen × 0.55` | 200 Ticks → Pflanze | Kampf |

---

## 10. Terrain

### Typen und Basiseffekte
| Terrain | Geschwindigkeit | Nahrung | Farbe |
|---------|----------------|---------|-------|
| Grasland | ×1.0 | mittel | dunkelgrün |
| Wald | ×0.55–0.85* | üppig | sehr dunkelgrün |
| Wüste | ×0.80–1.15* | karg | sandfarben |

*Abhängig von `habitatPreference`

### Habitatpräferenz-Effekte
**Im Wald:**
```
speedMod = 0.55 + habitatPreference × 0.30
```
- Waldtier (pref=1.0): ×0.85 Geschwindigkeit
- Wüstentier (pref=0.0): ×0.55 Geschwindigkeit

**In der Wüste:**
```
speedMod   = 1.15 − habitatPreference × 0.35
heatCost   = 0.03 + habitatPreference × 0.05  (Energie/Tick)
```
- Wüstentier (pref=0.0): ×1.15 Geschwindigkeit, 0.03/Tick Hitzekosten
- Waldtier (pref=1.0): ×0.80 Geschwindigkeit, 0.08/Tick Hitzekosten

### Generierung
Voronoi-basiert mit 18 zufälligen Biom-Samen pro Simulation.
Biom-Verteilung der Samen: 44% Grasland, 33% Wald, 22% Wüste.

---

## 11. Neuronales Netz

### Architektur
```
8 Inputs → [4–16 versteckte Neuronen] → 4 Outputs
```
- Hidden Layer: **tanh**-Aktivierung
- Output Layer: **sigmoid**-Aktivierung → alle Ausgaben in [0, 1]
- Gewichte: DNA-Gene [0,1] → remappt auf [-1, 1]

### Sensor-Inputs (8)
| Nr. | Input | Wertebereich |
|----|-------|-------------|
| 1 | Winkel zur nächsten Nahrung (relativ zur Blickrichtung) | [−1, +1] |
| 2 | Distanz zur nächsten Nahrung | [0, 1] |
| 3 | Winkel zur nächsten Kreatur | [−1, +1] |
| 4 | Distanz zur nächsten Kreatur | [0, 1] |
| 5 | Eigene Energie | [0, 1] |
| 6 | Eigenes Alter | [0, 1] |
| 7 | Lokale Dichte (Artgenossen in 55 px) | [0, 1] = 0–8+ Nachbarn |
| 8 | Aggression der nächsten Kreatur | [0, 1] |

Alle Sensoren haben nur Zugang zu Objekten **innerhalb des Sichtradius**.

### Aktions-Outputs (4)
| Nr. | Output | Verwendung |
|----|--------|-----------|
| 1 | `turnAngle` | sigmoid → `(v − 0.5) × 2 × 0.2` rad/Tick (max ±11.5°) |
| 2 | `speed` | sigmoid → 0–100% der Maximalgeschwindigkeit |
| 3 | `wantsToReproduce` | > 0.5 = Bereitschaft zur Fortpflanzung |
| 4 | `wantsToAttack` | > 0.5 = Angriff wenn Voraussetzungen erfüllt |

---

## 12. Welt und Performance

### Standardwerte (konfigurierbar)
| Parameter | Standard | Wirksam |
|-----------|---------|---------|
| Weltgröße | 2400 × 1800 px | Neustart |
| Nahrungskapazität | 250 (Dichte-Referenz) | sofort |
| Nahrungswachstum | 3% pro Tick | sofort |
| Startkreaturen | 80 | Neustart |
| Startnahrung | 250 | Neustart |

### Automatische Skalierung mit Weltgröße
```
scale         = √(Weltfläche / (800 × 600))
maxFood       = foodCapacity × scale
maxPopulation = 300 × scale
```
Beispiel: 2400×1800 → scale=3 → maxFood=750, maxPopulation=900

### Performance-Strukturen
- **Spatial Grid**: 80 px Zellgröße, O(n) Nachbarschaftssuche statt O(n²)
- **Terrain-Karte**: 60 px Zellgröße, statisch pro Simulation
- **Simultane Angriffe**: Dictionary statt sequenzielle Anwendung

### Physik
- **Toroidale Welt**: Kanten verbinden sich (Kreaturen laufen an einer Seite raus, erscheinen gegenüber)
- **Distanzberechnung**: Euklidisch (keine toroidale Distanz — Kreaturen nahe gegenüberliegender Kanten "sehen" sich nicht)
- **Nachwuchs-Streuung**: 10–30 px zufällig vom Entstehungsort

---

## 13. Artgrenzen (emergent)

Artgrenzen entstehen **nicht durch Code-Regeln**, sondern durch zwei Mechanismen:

1. **Paarungskompatibilität**: `|aggression_A − aggression_B| < 0.3` — Fleischfresser und Pflanzenfresser können sich nicht fortpflanzen
2. **Nährstoffspezialisierung**: Pflanzenfresser (aggr ≤ 0.45) fressen Pflanzen, Fleischfresser ignorieren sie

Die Schwelle `aggression = 0.45` taucht an drei Stellen auf:
- Darf angreifen (> 0.45)
- Ignoriert Pflanzen (> 0.45)
- Paarungskompatibilität (Differenz < 0.3 → de-facto-Trennung bei extremen Werten)
