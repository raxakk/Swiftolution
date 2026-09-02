#!/bin/bash
# Kompiliert den UI-freien Simulationskern + main.swift zu einem Konsolen-Binary und startet es.
# Nur die Foundation/CoreGraphics-Dateien — kein SwiftUI/SpriteKit, kein Xcode-Projekt nötig.
#
#   ./Tools/Headless/run.sh --biomes --ticks 20000 --interval 1000
#   ./Tools/Headless/run.sh --csv --ticks 50000 > lauf.csv
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SIM="$ROOT/Swiftolution/Simulation"
OUT="$DIR/.build"
BIN="$OUT/swiftolution-headless"
mkdir -p "$OUT"

# UI-freier Kern (Reihenfolge egal — Swift löst innerhalb eines Moduls selbst auf)
SOURCES=(
  "$SIM/DNA.swift"
  "$SIM/FoodSource.swift"
  "$SIM/NeuralNetwork.swift"
  "$SIM/SpatialGrid.swift"
  "$SIM/Biome.swift"
  "$SIM/Creature.swift"
  "$SIM/World.swift"
  "$DIR/main.swift"
)

# Nur neu bauen, wenn eine Quelldatei neuer ist als das Binary.
needs_build=0
if [[ ! -x "$BIN" ]]; then
  needs_build=1
else
  for f in "${SOURCES[@]}"; do
    if [[ "$f" -nt "$BIN" ]]; then needs_build=1; break; fi
  done
fi

if [[ $needs_build -eq 1 ]]; then
  echo "» kompiliere headless-Binary …" >&2
  # -wmo: modulweite Optimierung erlaubt Inlining über Dateigrenzen (~16% schnellere Ticks).
  # Die App baut Release ohnehin mit wholemodule — ohne das Flag war nur der Runner langsamer.
  swiftc -O -wmo "${SOURCES[@]}" -o "$BIN"
fi

exec "$BIN" "$@"
