#!/bin/bash
# Compiles the UI-free simulation core plus main.swift into a console binary and runs it.
# Only the Foundation/CoreGraphics files — no SwiftUI, no SpriteKit, no Xcode project needed.
#
#   ./Tools/Headless/run.sh --biomes --ticks 20000 --interval 1000
#   ./Tools/Headless/run.sh --csv --ticks 50000 > run.csv
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SIM="$ROOT/Swiftolution/Simulation"
OUT="$DIR/.build"
BIN="$OUT/swiftolution-headless"
mkdir -p "$OUT"

# The UI-free core (order does not matter — Swift resolves within a module by itself)
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

# Only rebuild when a source file is newer than the binary.
needs_build=0
if [[ ! -x "$BIN" ]]; then
  needs_build=1
else
  for f in "${SOURCES[@]}"; do
    if [[ "$f" -nt "$BIN" ]]; then needs_build=1; break; fi
  done
fi

if [[ $needs_build -eq 1 ]]; then
  echo "> building headless binary ..." >&2
  # -wmo: whole-module optimization allows inlining across file boundaries (~16% faster ticks).
  # The app's Release build uses wholemodule anyway; without the flag only the runner was slower.
  swiftc -O -wmo "${SOURCES[@]}" -o "$BIN"
fi

exec "$BIN" "$@"
