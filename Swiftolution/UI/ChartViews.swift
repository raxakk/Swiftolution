import SwiftUI
import Charts

// MARK: - Panel (two charts side by side)

struct ChartsPanel: View {
    @ObservedObject var tracker: StatisticsTracker

    var body: some View {
        HStack(spacing: 0) {
            ChartBox(title: "Population") {
                PopulationChart(snapshots: tracker.snapshots)
            }
            Divider()
            ChartBox(title: "Traits (avg.)") {
                TraitsChart(snapshots: tracker.snapshots)
            }
        }
    }
}

// MARK: - Population time series

struct PopulationChart: View {
    let snapshots: [StatSnapshot]

    private struct Point: Identifiable {
        let id: String
        let tick: Int; let count: Int; let series: String
    }

    // The series label is both the plotted category and the legend text, so it is localized
    // once here and reused as the key of the color scale below.
    private enum Series {
        static let herbivores = String(localized: "Herbivores")
        static let omnivores  = String(localized: "Omnivores")
        static let carnivores = String(localized: "Carnivores")
        static let plants     = String(localized: "Plants")
    }

    private var points: [Point] {
        snapshots.flatMap { s in [
            Point(id: "\(s.tick)-H", tick: s.tick, count: s.herbivores, series: Series.herbivores),
            Point(id: "\(s.tick)-O", tick: s.tick, count: s.omnivores,  series: Series.omnivores),
            Point(id: "\(s.tick)-C", tick: s.tick, count: s.carnivores, series: Series.carnivores),
            Point(id: "\(s.tick)-F", tick: s.tick, count: s.plantFood,  series: Series.plants),
        ]}
    }

    var body: some View {
        if snapshots.isEmpty {
            emptyState
        } else {
            Chart(points) { p in
                LineMark(
                    x: .value("Tick", p.tick),
                    y: .value("Count", p.count),
                    series: .value("Group", p.series)
                )
                .foregroundStyle(by: .value("Group", p.series))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartForegroundStyleScale([
                Series.herbivores: Color.green,
                Series.omnivores:  Color.orange,
                Series.carnivores: Color.red,
                Series.plants:     Color.teal,
            ])
            .chartXAxis(.hidden)
            .chartLegend(position: .overlay, alignment: .topLeading, spacing: 4)
        }
    }

    private var emptyState: some View {
        Text("No data yet").font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Trait time series

struct TraitsChart: View {
    let snapshots: [StatSnapshot]

    private struct Point: Identifiable {
        let id: String
        let tick: Int; let value: Double; let trait: String
    }

    private enum Trait {
        static let aggression = String(localized: "Aggression")
        static let speed      = String(localized: "Speed")
        static let size       = String(localized: "Size")
        static let brain      = String(localized: "Brain")
        static let longevity  = String(localized: "Longevity")
        static let litterSize = String(localized: "Litter size")
        static let energy     = String(localized: "Avg. energy")
    }

    private var points: [Point] {
        snapshots.flatMap { s in [
            Point(id: "\(s.tick)-A", tick: s.tick, value: s.avgAggression, trait: Trait.aggression),
            Point(id: "\(s.tick)-S", tick: s.tick, value: s.avgSpeed,      trait: Trait.speed),
            Point(id: "\(s.tick)-Z", tick: s.tick, value: s.avgSize,       trait: Trait.size),
            Point(id: "\(s.tick)-B", tick: s.tick, value: s.avgBrainSize,  trait: Trait.brain),
            Point(id: "\(s.tick)-M", tick: s.tick, value: s.avgMaxAge,     trait: Trait.longevity),
            Point(id: "\(s.tick)-L", tick: s.tick, value: s.avgLitterSize, trait: Trait.litterSize),
            Point(id: "\(s.tick)-E", tick: s.tick, value: s.avgEnergy,     trait: Trait.energy),
        ]}
    }

    var body: some View {
        if snapshots.isEmpty {
            Text("No data yet").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(points) { p in
                LineMark(
                    x: .value("Tick", p.tick),
                    y: .value("Value", p.value),
                    series: .value("Trait", p.trait)
                )
                .foregroundStyle(by: .value("Trait", p.trait))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            .chartForegroundStyleScale([
                Trait.aggression: Color.red,
                Trait.speed:      Color.blue,
                Trait.size:       Color.orange,
                Trait.brain:      Color.indigo,
                Trait.longevity:  Color.mint,
                Trait.litterSize: Color.yellow,
                Trait.energy:     Color.cyan,
            ])
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartLegend(position: .overlay, alignment: .topLeading, spacing: 4)
        }
    }
}

// MARK: - Helper view

private struct ChartBox<Content: View>: View {
    let title: LocalizedStringKey
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
