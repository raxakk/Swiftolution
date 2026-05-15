import SwiftUI
import SpriteKit

struct ContentView: View {
    @StateObject private var engine = SimulationEngine()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SimulationView(scene: engine.scene)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)

                Divider()

                SidebarView(engine: engine)
                    .frame(width: 230)
            }

            Divider()

            ChartsPanel(tracker: engine.tracker)
                .frame(height: 190)
                .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

// MARK: - SpriteKit-Canvas

struct SimulationView: NSViewRepresentable {
    let scene: GameScene

    func makeNSView(context: Context) -> SKView {
        let view            = SKView()
        view.showsFPS       = true
        view.showsNodeCount = true
        view.presentScene(scene)
        return view
    }

    func updateNSView(_ nsView: SKView, context: Context) {}
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var engine: SimulationEngine
    @State private var speedMultiplier: Double = 1.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {

                Text("Evolution Simulator")
                    .font(.headline)
                    .padding(.bottom, 2)

                // MARK: Kreatur-Inspektion
                if let snapshot = engine.inspectedCreature {
                    SidebarSection(title: "Ausgewählte Kreatur") {
                        InspectionView(snapshot: snapshot)
                    }
                }

                // MARK: Statistiken
                SidebarSection(title: "Statistiken") {
                    StatRow(label: "Generation",      value: "\(engine.stats.generation)")
                    StatRow(label: "Population",      value: "\(engine.stats.population)")
                    StatRow(label: "Pflanzenfresser", value: "\(engine.stats.herbivores)")
                    StatRow(label: "Fleischfresser",  value: "\(engine.stats.carnivores)")
                    StatRow(label: "Geburten",        value: "\(engine.stats.totalBirths)")
                    StatRow(label: "Pflanzen",        value: "\(engine.stats.foodCount) / \(engine.config.foodCapacity)")
                    StatRow(label: "Ältestes",        value: "\(engine.stats.oldestAge) Ticks")
                    StatRow(label: "Ø Energie",       value: String(format: "%.0f%%", engine.stats.averageEnergy * 100))
                }

                // MARK: Steuerung
                SidebarSection(title: "Steuerung") {
                    Button(engine.isPaused ? "Fortsetzen" : "Pause") {
                        engine.togglePause()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)

                    Button("Neustart") {
                        engine.restart()
                    }
                    .frame(maxWidth: .infinity)

                    ParamSlider(
                        label: "Geschwindigkeit",
                        displayValue: String(format: "%.1f×", speedMultiplier),
                        value: $speedMultiplier,
                        range: 0.1...10.0
                    )
                    .onChange(of: speedMultiplier) { _, v in engine.setSpeed(v) }
                }

                // MARK: Umgebung (sofort wirksam)
                SidebarSection(title: "Umgebung") {
                    ParamSlider(
                        label: "Nahrungskapazität",
                        displayValue: "\(engine.config.foodCapacity)",
                        value: Binding(
                            get: { Double(engine.config.foodCapacity) },
                            set: { engine.config.foodCapacity = Int($0) }
                        ),
                        range: 50...600
                    )

                    ParamSlider(
                        label: "Nahrungswachstum",
                        displayValue: String(format: "%.2f", engine.config.foodGrowthRate),
                        value: Binding(
                            get: { engine.config.foodGrowthRate },
                            set: { engine.config.foodGrowthRate = $0 }
                        ),
                        range: 0.005...0.15
                    )
                }

                // MARK: Evolution (sofort wirksam)
                SidebarSection(title: "Evolution") {
                    ParamSlider(
                        label: "Mutationsrate",
                        displayValue: String(format: "%.2f", engine.config.mutationRate),
                        value: Binding(
                            get: { Double(engine.config.mutationRate) },
                            set: { engine.config.mutationRate = Float($0) }
                        ),
                        range: 0.01...0.30
                    )

                    ParamSlider(
                        label: "Mutationsstärke",
                        displayValue: String(format: "%.2f", engine.config.mutationStrength),
                        value: Binding(
                            get: { Double(engine.config.mutationStrength) },
                            set: { engine.config.mutationStrength = Float($0) }
                        ),
                        range: 0.01...0.50
                    )
                }

                // MARK: Startbedingungen (gilt beim Neustart)
                SidebarSection(title: "Start (nach Neustart)") {
                    ParamSlider(
                        label: "Startpopulation",
                        displayValue: "\(engine.config.initialCreatures)",
                        value: Binding(
                            get: { Double(engine.config.initialCreatures) },
                            set: { engine.config.initialCreatures = Int($0) }
                        ),
                        range: 10...150
                    )

                    ParamSlider(
                        label: "Startnahrung",
                        displayValue: "\(engine.config.initialFood)",
                        value: Binding(
                            get: { Double(engine.config.initialFood) },
                            set: { engine.config.initialFood = Int($0) }
                        ),
                        range: 20...400
                    )
                }

                Spacer(minLength: 8)
            }
            .padding()
        }
    }
}

// MARK: - Hilfsviews

private struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content()
        }
        Divider()
    }
}

private struct ParamSlider: View {
    let label: String
    let displayValue: String
    let value: Binding<Double>
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(displayValue).font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range)
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }
}
