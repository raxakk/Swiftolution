import SwiftUI
import Charts

// MARK: - Panel (zwei Charts nebeneinander)

struct ChartsPanel: View {
    @ObservedObject var tracker: StatisticsTracker

    var body: some View {
        HStack(spacing: 0) {
            ChartBox(title: "Population") {
                PopulationChart(snapshots: tracker.snapshots)
            }
            Divider()
            ChartBox(title: "Merkmale (Ø)") {
                TraitsChart(snapshots: tracker.snapshots)
            }
        }
    }
}

// MARK: - Populations-Zeitreihe

struct PopulationChart: View {
    let snapshots: [StatSnapshot]

    private struct Point: Identifiable {
        let id: String
        let tick: Int; let count: Int; let series: String
    }

    private var points: [Point] {
        snapshots.flatMap { s in [
            Point(id: "\(s.tick)-H", tick: s.tick, count: s.herbivores, series: "Herbivore"),
            Point(id: "\(s.tick)-O", tick: s.tick, count: s.omnivores,  series: "Omnivore"),
            Point(id: "\(s.tick)-C", tick: s.tick, count: s.carnivores, series: "Carnivore"),
            Point(id: "\(s.tick)-F", tick: s.tick, count: s.plantFood,  series: "Pflanzen"),
        ]}
    }

    var body: some View {
        if snapshots.isEmpty {
            emptyState
        } else {
            Chart(points) { p in
                LineMark(
                    x: .value("Tick", p.tick),
                    y: .value("Anzahl", p.count),
                    series: .value("Art", p.series)
                )
                .foregroundStyle(by: .value("Art", p.series))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartForegroundStyleScale([
                "Herbivore": Color.green,
                "Omnivore":  Color.orange,
                "Carnivore": Color.red,
                "Pflanzen":  Color.teal,
            ])
            .chartXAxis(.hidden)
            .chartLegend(position: .overlay, alignment: .topLeading, spacing: 4)
        }
    }

    private var emptyState: some View {
        Text("Noch keine Daten").font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Trait-Zeitreihe

struct TraitsChart: View {
    let snapshots: [StatSnapshot]

    private struct Point: Identifiable {
        let id: String
        let tick: Int; let value: Double; let trait: String
    }

    private var points: [Point] {
        snapshots.flatMap { s in [
            Point(id: "\(s.tick)-A", tick: s.tick, value: s.avgAggression, trait: "Aggression"),
            Point(id: "\(s.tick)-S", tick: s.tick, value: s.avgSpeed,      trait: "Tempo"),
            Point(id: "\(s.tick)-Z", tick: s.tick, value: s.avgSize,       trait: "Größe"),
            Point(id: "\(s.tick)-B", tick: s.tick, value: s.avgBrainSize,  trait: "Gehirn"),
            Point(id: "\(s.tick)-M", tick: s.tick, value: s.avgMaxAge,     trait: "Langlebigkeit"),
            Point(id: "\(s.tick)-L", tick: s.tick, value: s.avgLitterSize, trait: "Wurfgröße"),
            Point(id: "\(s.tick)-E", tick: s.tick, value: s.avgEnergy,     trait: "Ø Energie"),
        ]}
    }

    var body: some View {
        if snapshots.isEmpty {
            Text("Noch keine Daten").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(points) { p in
                LineMark(
                    x: .value("Tick", p.tick),
                    y: .value("Wert", p.value),
                    series: .value("Merkmal", p.trait)
                )
                .foregroundStyle(by: .value("Merkmal", p.trait))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartForegroundStyleScale([
                "Aggression":    Color.red,
                "Tempo":         Color.blue,
                "Größe":         Color.orange,
                "Gehirn":        Color.indigo,
                "Langlebigkeit": Color.mint,
                "Wurfgröße":     Color.yellow,
                "Ø Energie":     Color.cyan,
            ])
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartLegend(position: .overlay, alignment: .topLeading, spacing: 4)
        }
    }
}

// MARK: - Hilfsview

private struct ChartBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            content()
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
