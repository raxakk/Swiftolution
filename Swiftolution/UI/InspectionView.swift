import SwiftUI

struct InspectionView: View {
    let snapshot: CreatureSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Diet badge
            Text(snapshot.isHerbivore ? "Pflanzenfresser" : "Fleischfresser")
                .font(.caption.bold())
                .foregroundStyle(snapshot.isHerbivore ? Color.green : Color.red)

            // The current biome (only when biomes are on)
            if let biome = snapshot.biomeName {
                HStack {
                    Text("Biom").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(biome).font(.caption2.bold())
                }
            }

            // State
            TraitBar(label: "Energie",
                     value: snapshot.energyRatio,
                     color: energyColor(snapshot.energyRatio))
            TraitBar(label: "Körpermasse",
                     value: snapshot.bodyMassRatio,
                     color: .brown)
            HStack {
                Text("Alter").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.age) / \(snapshot.maxAge)")
                    .font(.caption2.monospacedDigit())
            }
            if snapshot.senescence > 0 {
                TraitBar(label: "Seneszenz",
                         value: snapshot.senescence,
                         color: .gray,
                         displayOverride: String(format: "%.0f%%", snapshot.senescence * 100))
            }

            Divider()

            // DNA
            Text("DNA")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TraitBar(label: "Größe",             value: snapshot.size,          color: .orange)
            TraitBar(label: "Tempo",             value: snapshot.speed,         color: .blue)
            TraitBar(label: "Aggression",        value: snapshot.aggression,    color: .red)
            TraitBar(label: "Sichtweite",        value: snapshot.sightRadiusGene, color: .purple,
                     displayOverride: String(format: "%.0f px", snapshot.sightRadiusPx))
            TraitBar(label: "Sichtwinkel",       value: snapshot.sightAngleGene,  color: .purple,
                     displayOverride: "\(snapshot.sightAngleDeg)°")
            TraitBar(label: "Wendigkeit",        value: snapshot.turnRateGene,    color: .cyan,
                     displayOverride: String(format: "%.1f°/Tick", snapshot.turnRateDeg))
            TraitBar(label: "Lebenserwartung",   value: snapshot.maxAgeGene,    color: .mint,
                     displayOverride: "\(snapshot.maxAge) Ticks")
            TraitBar(label: "Fortpfl.-Schwelle", value: snapshot.reproThreshold, color: .teal)
            TraitBar(label: "Wurfgröße",         value: Float(snapshot.litterSize - 1) / 3.0, color: .yellow,
                     displayOverride: "\(snapshot.litterSize)")
            TraitBar(label: "Gehirn",            value: snapshot.brainSize,     color: .indigo,
                     displayOverride: "\(snapshot.hiddenCount) Neuronen")
            TraitBar(label: "Olfaktion",          value: snapshot.olfaction,     color: .green,
                     displayOverride: String(format: "%.0f px", snapshot.olfaction * 170 + 30))

            Divider()

            // Current behaviour
            Text("Verhalten (aktuell)")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TraitBar(label: "Geschwindigkeit", value: snapshot.actionSpeed,      color: .cyan)
            TraitBar(label: "Fortpflanzung",   value: snapshot.actionReproduce,  color: .teal)
            TraitBar(label: "Angriffsdrang",   value: snapshot.actionAttack,     color: .red)
            TraitBar(label: "Frisst Pflanzen", value: snapshot.actionEatPlant,   color: .green)
            TraitBar(label: "Frisst Aas",      value: snapshot.actionEatCorpse,  color: .orange)
        }
    }

    private func energyColor(_ ratio: Float) -> Color {
        ratio > 0.5 ? .green : ratio > 0.25 ? .yellow : .red
    }
}

// MARK: - Helper view

private struct TraitBar: View {
    let label: String
    let value: Float
    let color: Color
    var displayOverride: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(displayOverride ?? String(format: "%.2f", value)).font(.caption2.monospacedDigit())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(value))
                }
            }
            .frame(height: 4)
        }
    }
}
