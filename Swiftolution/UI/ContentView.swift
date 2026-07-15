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
                    StatRow(label: "Tick",          value: "\(engine.stats.tickCount)")
                    StatRow(label: "Generation",    value: "\(engine.stats.generation)")
                    StatRow(label: "Population",    value: "\(engine.stats.population)")

                    StatRow(label: "Herbivore",     value: "\(engine.stats.herbivores)",
                            color: .green)
                    StatRow(label: "Omnivore",      value: "\(engine.stats.omnivores)",
                            color: .orange)
                    StatRow(label: "Carnivore",     value: "\(engine.stats.carnivores)",
                            color: .red)
                    StatRow(label: "Ø Aggression",  value: String(format: "%.2f", engine.stats.avgAggression))

                    if engine.config.speciationEnabled {
                        StatRow(label: "Arten",     value: "\(engine.stats.speciesCount)",
                                color: .cyan)
                    }

                    StatRow(label: "Geburten",      value: "\(engine.stats.totalBirths)")
                    StatRow(label: "Tode",          value: "\(engine.stats.totalDeaths)")

                    StatRow(label: "Pflanzen",      value: "\(engine.stats.plantCount) / \(engine.stats.maxFood)")
                    StatRow(label: "Leichen",       value: "\(engine.stats.corpseCount)")

                    StatRow(label: "Ø Alter",       value: String(format: "%.0f Ticks", engine.stats.averageAge))
                    StatRow(label: "Ältestes",      value: "\(engine.stats.oldestAge) Ticks")
                    StatRow(label: "Ø Energie",     value: String(format: "%.0f%%", engine.stats.averageEnergy * 100))

                    if engine.config.seasonEnabled {
                        StatRow(label: "Jahreszeit",
                                value: "\(engine.stats.currentSeason) (\(Int(engine.stats.seasonFactor * 100))%)")
                    }
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
                        range: 100...1500
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

                    Toggle("Jahreszeiten", isOn: Binding(
                        get: { engine.config.seasonEnabled },
                        set: { engine.config.seasonEnabled = $0 }
                    ))
                    .font(.caption)
                    .toggleStyle(.switch)

                    if engine.config.seasonEnabled {
                        ParamSlider(
                            label: "Jahreslänge",
                            displayValue: "\(engine.config.seasonLength) Ticks",
                            value: Binding(
                                get: { Double(engine.config.seasonLength) },
                                set: { engine.config.seasonLength = Int($0) }
                            ),
                            range: 500...10000
                        )
                        ParamSlider(
                            label: "Saisonalität",
                            displayValue: String(format: "%.0f%%", Double(engine.config.seasonAmplitude) * 100),
                            value: Binding(
                                get: { Double(engine.config.seasonAmplitude) },
                                set: { engine.config.seasonAmplitude = Float($0) }
                            ),
                            range: 0.1...1.0
                        )
                    }

                    Toggle("Mindest-Spawn", isOn: Binding(
                        get: { engine.config.minSpawnEnabled },
                        set: { engine.config.minSpawnEnabled = $0 }
                    ))
                    .font(.caption)
                    .toggleStyle(.switch)

                    if engine.config.minSpawnEnabled {
                        ParamSlider(
                            label: "Schwellenwert",
                            displayValue: "\(engine.config.minSpawnThreshold) Kreaturen",
                            value: Binding(
                                get: { Double(engine.config.minSpawnThreshold) },
                                set: { engine.config.minSpawnThreshold = Int($0) }
                            ),
                            range: 1...30
                        )
                    }

                    Toggle("Äquator-Gradient", isOn: Binding(
                        get: { engine.config.latitudeGradientEnabled },
                        set: { engine.config.latitudeGradientEnabled = $0 }
                    ))
                    .font(.caption)
                    .toggleStyle(.switch)
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

                    Toggle("Artbildung", isOn: Binding(
                        get: { engine.config.speciationEnabled },
                        set: { engine.config.speciationEnabled = $0 }
                    ))
                    .font(.caption)
                    .toggleStyle(.switch)

                    if engine.config.speciationEnabled {
                        ParamSlider(
                            label: "Paarungsschwelle",
                            displayValue: String(format: "%.2f", engine.config.speciationThreshold),
                            value: Binding(
                                get: { Double(engine.config.speciationThreshold) },
                                set: { engine.config.speciationThreshold = Float($0) }
                            ),
                            range: 0.10...1.00
                        )
                    }

                    Toggle("Pflanzengift", isOn: Binding(
                        get: { engine.config.plantToxinEnabled },
                        set: { engine.config.plantToxinEnabled = $0 }
                    ))
                    .font(.caption)
                    .toggleStyle(.switch)

                    if engine.config.plantToxinEnabled {
                        ParamSlider(
                            label: "Giftstärke",
                            displayValue: String(format: "%.2f", engine.config.plantToxinFactor),
                            value: Binding(
                                get: { Double(engine.config.plantToxinFactor) },
                                set: { engine.config.plantToxinFactor = Float($0) }
                            ),
                            range: 0.00...1.50
                        )
                        ParamSlider(
                            label: "Giftschwelle (aggr)",
                            displayValue: String(format: "%.2f", engine.config.plantToxinThreshold),
                            value: Binding(
                                get: { Double(engine.config.plantToxinThreshold) },
                                set: { engine.config.plantToxinThreshold = Float($0) }
                            ),
                            range: 0.00...1.00
                        )
                    }
                }

                // MARK: Startbedingungen (gilt beim Neustart)
                SidebarSection(title: "Start (nach Neustart)") {
                    ParamSlider(
                        label: "Weltbreite",
                        displayValue: "\(engine.config.worldWidth) px",
                        value: Binding(
                            get: { Double(engine.config.worldWidth) },
                            set: { engine.config.worldWidth = Int($0) }
                        ),
                        range: 600...4800
                    )
                    ParamSlider(
                        label: "Welthöhe",
                        displayValue: "\(engine.config.worldHeight) px",
                        value: Binding(
                            get: { Double(engine.config.worldHeight) },
                            set: { engine.config.worldHeight = Int($0) }
                        ),
                        range: 400...3600
                    )
                    ParamSlider(
                        label: "Startpopulation",
                        displayValue: "\(engine.config.initialCreatures)",
                        value: Binding(
                            get: { Double(engine.config.initialCreatures) },
                            set: { engine.config.initialCreatures = Int($0) }
                        ),
                        range: 10...1000
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
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text(value).font(.caption.monospacedDigit()).foregroundStyle(color)
        }
    }
}
