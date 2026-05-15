# Verbesserungsvorschläge für Swiftolution

Ideen zur Erweiterung der Evolutionssimulation für mehr Realismus, emergente Dynamik und langfristig interessante Evolution.

---

# 1. Tiefere Nahrungskette

## Problem

Aktuell existieren effektiv nur:

* Pflanzen
* Pflanzenfresser
* Fleischfresser

Dadurch bleibt die ökologische Struktur relativ flach.

---

## Verbesserung: Energieverluste zwischen trophischen Ebenen

In echten Ökosystemen geht bei jeder Ebene ein Großteil der Energie verloren.

### Vorschlag

| Übergang                  | Energieeffizienz |
| ------------------------- | ---------------- |
| Pflanze → Herbivore       | 35%              |
| Herbivore → Carnivore     | 18%              |
| Carnivore → Spitzenräuber | 10%              |

Dadurch entstehen automatisch:

* wenige Spitzenräuber
* viele Pflanzenfresser
* stabile Populationszyklen

---

## Zusätzlich

Leichen könnten:

* teilweise verrotten
* Energie verlieren
* Insekten/Aasfresser anziehen

---

# 2. Realistischere Gehirne

## Problem

Große Gehirne sind aktuell relativ günstig.

Dadurch könnten große neuronale Netze langfristig fast immer dominant werden.

---

## Verbesserung: Nichtlineare Gehirnkosten

### Aktuell

```text
brainCost = brainSize × 0.02
```

### Vorschlag

```text
brainCost = brainSize² × 0.08
```

Große Gehirne werden dadurch selten und evolutionär teuer.

---

## Verbesserung: Entscheidungsrauschen

Große Gehirne könnten instabiler werden.

### Beispiel

```text
noise = random(-ε, +ε) × brainSize
```

Dadurch entstehen:

* Fehlentscheidungen
* weniger perfekte Optimierer
* realistischere Evolution

---

# 3. Komplexere Mutation

## Problem

Mutationen sind aktuell:

* unabhängig
* gleich stark
* immer klein

Das erzeugt eher lineare Optimierung statt evolutionärer Sprünge.

---

## Verbesserung: Unterschiedliche Mutationsgrößen

### Vorschlag

| Wahrscheinlichkeit | Mutation |
| ------------------ | -------- |
| 95%                | ±0.05    |
| 4%                 | ±0.2     |
| 1%                 | ±0.5     |

Dadurch entstehen:

* neue Strategien
* plötzliche evolutionäre Experimente
* stärkere Diversifikation

---

## Verbesserung: Genkopplung

Einige Gene könnten schwach gekoppelt sein.

### Beispiele

* große Tiere → höhere Sichtweite
* aggressive Tiere → höhere Geschwindigkeit
* große Tiere → längere Lebensdauer

Das erzeugt realistischere Evolutionspfade.

---

# 4. Unscharfe Wahrnehmung

## Problem

Kreaturen kennen aktuell:

* exakte Winkel
* exakte Distanzen
* exakte Aggression anderer Kreaturen

Das ist biologisch unrealistisch.

---

## Verbesserung: Wahrnehmungsfehler

### Distanzrauschen

```text
perceivedDistance = realDistance + noise
```

### Winkelrauschen

```text
perceivedAngle = realAngle + random(-δ, +δ)
```

---

## Verbesserung: Keine direkte Aggressions-Erkennung

Stattdessen könnten Kreaturen nur sehen:

* Größe
* Farbe
* Bewegung
* Geschwindigkeit

Dadurch könnten entstehen:

* Tarnung
* Warnfarben
* Mimikry
* Einschüchterung

---

# 5. Evolvierbare Farben

## Problem

RGB-Gene sind aktuell rein kosmetisch.

---

## Verbesserungsideen

## Tarnung

Farbabweichung vom Terrain beeinflusst Sichtbarkeit.

### Beispiel

```text
visibility = colorDifferenceToTerrain
```

---

## Warnfarben

Sehr aggressive Tiere könnten auffällige Farben entwickeln.

---

## Partnerwahl

Kreaturen könnten ähnliche Farben bevorzugen.

Dadurch entstehen:

* Unterarten
* Balzverhalten
* sexuelle Selektion

---

# 6. Jahreszeiten und Klimazyklen

## Problem

Die Umwelt ist aktuell statisch.

Dadurch stabilisieren sich dominante Strategien zu stark.

---

# Verbesserung: Jahreszeiten

| Jahreszeit | Effekt           |
| ---------- | ---------------- |
| Frühling   | viele Pflanzen   |
| Sommer     | hohe Aktivität   |
| Herbst     | sinkende Nahrung |
| Winter     | kaum Pflanzen    |

---

## Auswirkungen

Dadurch entstehen:

* langlebige Arten
* Vorratsstrategien
* schnelle Reproduktion
* Migration
* zyklische Evolution

---

# 7. Realistischere Jagd

## Problem

Kampf ist aktuell sehr deterministisch.

Es gibt:

* kein Ausweichen
* keine Jagd
* keine Überraschungsangriffe

---

## Verbesserung: Trefferwahrscheinlichkeit

### Beispiel

```text
hitChance =
 predatorSpeed /
 (predatorSpeed + preySpeed)
```

---

## Erweiterungen

* Überraschungsbonus
* Sichtlinien
* Rudelbonus
* Ausdauer

Dadurch entstehen:

* Hetzjäger
* Hinterhaltjäger
* schnelle Fluchttiere

---

# 8. Sozialverhalten

## Problem

Alle Kreaturen verhalten sich komplett individuell.

---

# Verbesserungsideen

## Herdenverhalten

Neuer Input:

```text
averageDirectionNearby
```

Dadurch entstehen:

* Schwärme
* Herden
* Fischschulen

---

## Verwandtenerkennung

Ähnliche DNA/Farbe reduziert Aggression.

Dadurch entstehen:

* Rudel
* Kolonien
* kooperative Gruppen

---

# 9. Lokale Ressourcenerschöpfung

## Problem

Pflanzen wachsen aktuell global-logistisch.

Dadurch entstehen kaum Wanderbewegungen.

---

## Verbesserung: Bodenfruchtbarkeit

Jede Terrainzelle besitzt:

```text
fertility ∈ [0,1]
```

Pflanzenwachstum hängt davon ab:

```text
plantGrowth = baseGrowth × fertility
```

---

## Überweidung

Viele Pflanzenfresser senken lokal:

```text
fertility -= grazingPressure
```

Langsame Regeneration:

```text
fertility += regenerationRate
```

Dadurch entstehen:

* Migration
* Nomadenverhalten
* ökologische Nischen

---

# 10. Krankheiten und Parasiten

## Problem

Große Populationen haben aktuell kaum Nachteile.

---

## Verbesserung

Infektionswahrscheinlichkeit steigt mit:

* lokaler Dichte
* genetischer Ähnlichkeit
* Alter

---

## Auswirkungen

Dadurch werden:

* Monokulturen instabil
* genetische Vielfalt wertvoll
* Populationen zyklisch

---

# 11. Realistischere Geographie

## Problem

Toroidale Welten wirken biologisch oft künstlich.

Außerdem können Kreaturen über Kartenränder nicht sehen.

---

## Verbesserungsideen

### Option A

Toroidale Distanzberechnung ebenfalls toroidal machen.

---

### Option B

Echte Geographie:

* Inseln
* Gebirge
* Flüsse
* Seen

Dadurch entstehen:

* Isolation
* Artbildung
* regionale Evolution

---

# 12. Evolvierbare Sinnesorgane

## Problem

Alle Kreaturen besitzen identische Sensorik.

---

# Verbesserung: Sensor-Gene

| Gen         | Effekt                 |
| ----------- | ---------------------- |
| smell       | großer Radius, ungenau |
| vision      | präzise Richtung       |
| hearing     | Bewegungserkennung     |
| nightVision | besser im Dunkeln      |

---

## Auswirkungen

Dadurch entstehen:

* nachtaktive Arten
* Aasfresser
* Hinterhaltjäger
* Fernsucher

---

# 13. Nichtlineare Formeln

## Problem

Viele aktuelle Formeln sind linear.

Dadurch entstehen oft zu glatte Fitnesslandschaften.

---

# Verbesserung: Nichtlinearitäten

## Beispiele

### Größenkosten

```text
energyCost ~ size²
```

### Angriffsstärke

```text
attackPower ~ size^1.3
```

### Gehirnkosten

```text
brainCost ~ neurons²
```

---

## Wirkung

Nichtlineare Systeme erzeugen:

* stärkere Tradeoffs
* spezialisierte Strategien
* instabilere Gleichgewichte
* interessantere Evolution

---

# 14. Wichtigste Prioritäten

Wenn nur wenige Erweiterungen umgesetzt werden sollen:

## Höchste Priorität

### 1. Unscharfe Wahrnehmung

Verhindert perfekte Optimierer.

### 2. Jahreszeiten/Klimazyklen

Hält Evolution dauerhaft dynamisch.

### 3. Lokale Ressourcenerschöpfung

Erzeugt Migration und ökologische Nischen.

---

# Zusammenfassung

Das aktuelle Regelwerk ist bereits ungewöhnlich stark für eine Evolutionssimulation.

Besonders positiv:

* emergente Artbildung
* echte Tradeoffs
* Energieerhaltung
* simultane Kampfauflösung
* Habitat-Spezialisierung

Die größten Potenziale liegen jetzt in:

* dynamischer Umwelt
* unperfekter Wahrnehmung
* komplexeren Ressourcenzyklen
* evolvierbarer Sensorik
* Sozialverhalten
* nichtlinearen Kostenfunktionen

Diese Erweiterungen würden die Simulation deutlich lebendiger, instabiler und biologisch realistischer machen.
