import SwiftUI

struct InspectionView: View {
    let snapshot: CreatureSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Typ-Badge
            Text(snapshot.isHerbivore ? "Pflanzenfresser" : "Fleischfresser")
                .font(.caption.bold())
                .foregroundStyle(snapshot.isHerbivore ? Color.green : Color.red)

            // Energie & Alter
            TraitBar(label: "Energie",
                     value: snapshot.energyRatio,
                     color: energyColor(snapshot.energyRatio))
            HStack {
                Text("Alter").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("\(snapshot.age) / \(snapshot.maxAge)")
                    .font(.caption2.monospacedDigit())
            }

            Divider()

            // DNA
            Text("DNA")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TraitBar(label: "Größe",           value: snapshot.size,           color: .orange)
            TraitBar(label: "Tempo (Potenzial)", value: snapshot.speed,         color: .blue)
            TraitBar(label: "Aggression",       value: snapshot.aggression,     color: .red)
            TraitBar(label: "Sichtweite",       value: snapshot.sightRadius,    color: .purple)
            TraitBar(label: "Fortpfl.-Schwelle", value: snapshot.reproThreshold, color: .teal)
            TraitBar(label: "Gehirngröße",
                     value: snapshot.brainSize,
                     color: .indigo,
                     displayOverride: "\(snapshot.hiddenCount) Neuronen")

            Divider()

            // Aktuelles Verhalten
            Text("Verhalten (aktuell)")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            TraitBar(label: "Geschwindigkeit", value: snapshot.actionSpeed,    color: .cyan)
            TraitBar(label: "Fortpflanzung",   value: snapshot.actionReproduce, color: .teal)
            TraitBar(label: "Angriffsdrang",   value: snapshot.actionAttack,   color: .red)
        }
    }

    private func energyColor(_ ratio: Float) -> Color {
        ratio > 0.5 ? .green : ratio > 0.25 ? .yellow : .red
    }
}

// MARK: - Hilfsview

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
