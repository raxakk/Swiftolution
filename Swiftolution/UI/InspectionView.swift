import SwiftUI

struct InspectionView: View {
    let snapshot: CreatureSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Diet badge
            Text(snapshot.isHerbivore ? "Herbivore" : "Carnivore")
                .font(.caption.bold())
                .foregroundStyle(snapshot.isHerbivore ? Color.green : Color.red)

            // The current biome (only when biomes are on)
            if let biome = snapshot.biomeName {
                HStack {
                    Text("Biome").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    // The engine reports biomes as stable English identifiers.
                    Text(LocalizedStringKey(biome)).font(.caption2.bold())
                }
            }

            // State
            TraitBar(label: "Energy",
                     value: snapshot.energyRatio,
                     color: energyColor(snapshot.energyRatio))
            TraitBar(label: "Body mass",
                     value: snapshot.bodyMassRatio,
                     color: .brown)
            HStack {
                Text("Age").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.age) / \(snapshot.maxAge)")
                    .font(.caption2.monospacedDigit())
            }
            if snapshot.senescence > 0 {
                TraitBar(label: "Senescence",
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

            TraitBar(label: "Size",              value: snapshot.size,          color: .orange)
            TraitBar(label: "Speed",             value: snapshot.speed,         color: .blue)
            TraitBar(label: "Aggression",        value: snapshot.aggression,    color: .red)
            TraitBar(label: "Sight range",       value: snapshot.sightRadiusGene, color: .purple,
                     displayOverride: String(format: "%.0f px", snapshot.sightRadiusPx))
            TraitBar(label: "Sight angle",       value: snapshot.sightAngleGene,  color: .purple,
                     displayOverride: "\(snapshot.sightAngleDeg)°")
            TraitBar(label: "Agility",           value: snapshot.turnRateGene,    color: .cyan,
                     displayOverride: String(format: String(localized: "%.1f deg/tick"), snapshot.turnRateDeg))
            TraitBar(label: "Life expectancy",   value: snapshot.maxAgeGene,    color: .mint,
                     displayOverride: String(localized: "\(snapshot.maxAge) ticks"))
            TraitBar(label: "Repro. threshold",  value: snapshot.reproThreshold, color: .teal)
            TraitBar(label: "Litter size",       value: Float(snapshot.litterSize - 1) / 3.0, color: .yellow,
                     displayOverride: "\(snapshot.litterSize)")
            TraitBar(label: "Brain",             value: snapshot.brainSize,     color: .indigo,
                     displayOverride: String(localized: "\(snapshot.hiddenCount) neurons"))
            TraitBar(label: "Olfaction",         value: snapshot.olfaction,     color: .green,
                     displayOverride: String(format: "%.0f px", snapshot.olfaction * 170 + 30))

            Divider()

            // Current behaviour
            Text("Behaviour (current)")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TraitBar(label: "Current speed",   value: snapshot.actionSpeed,      color: .cyan)
            TraitBar(label: "Reproduction",    value: snapshot.actionReproduce,  color: .teal)
            TraitBar(label: "Urge to attack",  value: snapshot.actionAttack,     color: .red)
            TraitBar(label: "Eats plants",     value: snapshot.actionEatPlant,   color: .green)
            TraitBar(label: "Eats carrion",    value: snapshot.actionEatCorpse,  color: .orange)
        }
    }

    private func energyColor(_ ratio: Float) -> Color {
        ratio > 0.5 ? .green : ratio > 0.25 ? .yellow : .red
    }
}

// MARK: - Helper view

private struct TraitBar: View {
    let label: LocalizedStringKey
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
