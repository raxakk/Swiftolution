import SpriteKit

final class CreatureNode: SKNode {

    // MARK: - Kinder

    private let bodyNode:      SKShapeNode
    private let sightNode:     SKShapeNode
    private let directionLine: SKShapeNode
    private let selectionRing: SKShapeNode
    let radius: CGFloat

    // MARK: - Init

    init(creature: Creature) {
        let radius = CGFloat(creature.dna.size * 8 + 4)
        self.radius = radius
        let aggr   = CGFloat(creature.dna.aggression)

        // Körperfarbe aus DNA + Aggressions-Tint (grün → rot)
        let dnaColor  = NSColor(red: CGFloat(creature.dna.red),
                                green: CGFloat(creature.dna.green),
                                blue: CGFloat(creature.dna.blue), alpha: 1)
        let tintColor = aggr < 0.5
            ? NSColor(red: 0.05, green: 0.85, blue: 0.2,  alpha: 1)   // Pflanzenfresser: grün
            : NSColor(red: 0.90, green: 0.05, blue: 0.05, alpha: 1)   // Fleischfresser: rot
        let tintStrength = min(abs(aggr - 0.5) * 1.6, 0.55)
        let bodyColor = dnaColor.blended(withFraction: tintStrength, of: tintColor) ?? dnaColor

        // Form: viele abgerundete Ecken (≈ Kreis) → wenige spitze Zacken (→ Dreieck)
        // Anzahl Zacken: 8 bei aggr=0, 3 bei aggr=1
        // Innenradius:  0.88·r bei aggr=0 (kaum Einbuchtung), 0.22·r bei aggr=1 (sehr spitzig)
        let numSpikes = max(3, Int((8.0 - aggr * 5.0).rounded()))
        let innerR    = radius * (0.88 - aggr * 0.66)
        let bodyPath  = CreatureNode.spikePath(outerRadius: radius, innerRadius: innerR, spikes: numSpikes)

        bodyNode             = SKShapeNode(path: bodyPath)
        bodyNode.fillColor   = bodyColor
        bodyNode.strokeColor = NSColor(red: 0.3 + aggr * 0.7,
                                       green: 0.55 * (1 - aggr),
                                       blue:  0.25 * (1 - aggr), alpha: 1)
        bodyNode.lineWidth   = 1.0 + aggr * 3.0

        // Sichtradius-Ring
        sightNode             = SKShapeNode(circleOfRadius: creature.sightRadius)
        sightNode.fillColor   = .clear
        sightNode.strokeColor = bodyColor.withAlphaComponent(0.18)
        sightNode.lineWidth   = 0.5
        sightNode.isHidden    = true

        // Auswahlring — standardmäßig versteckt
        selectionRing             = SKShapeNode(circleOfRadius: radius + 5)
        selectionRing.fillColor   = .clear
        selectionRing.strokeColor = .white.withAlphaComponent(0.9)
        selectionRing.lineWidth   = 1.5
        selectionRing.isHidden    = true

        // Richtungslinie: bei Fleischfressern zeigt die Spitze schon die Richtung → ausblenden
        let linePath = CGMutablePath()
        linePath.move(to: .zero)
        linePath.addLine(to: CGPoint(x: radius + 5, y: 0))
        directionLine             = SKShapeNode(path: linePath)
        directionLine.strokeColor = .white.withAlphaComponent(max(0, 0.7 - aggr * 1.4))
        directionLine.lineWidth   = 1.5

        super.init()
        addChild(sightNode)
        addChild(selectionRing)
        addChild(bodyNode)
        addChild(directionLine)

        position = creature.position
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    // MARK: - Update

    func sync(with creature: Creature) {
        position  = creature.position
        zRotation = CGFloat(creature.heading)

        let energyRatio = CGFloat(creature.energy / creature.maxEnergy)
        bodyNode.alpha = 0.35 + energyRatio * 0.65
    }

    func setSelected(_ selected: Bool) {
        selectionRing.isHidden = !selected
        sightNode.isHidden     = !selected
    }

    func showSightRadius(_ visible: Bool) {
        sightNode.isHidden = !visible
    }

    // MARK: - Form-Generator

    // Erzeugt einen Stern-Pfad mit `spikes` Zacken.
    // Erster äußerer Punkt bei Winkel 0 (→ rechts), damit die Spitze mit zRotation=heading zeigt.
    // Bei vielen Zacken mit kleiner Einbuchtung sieht es wie ein Kreis aus.
    // Bei wenigen Zacken mit großer Einbuchtung entsteht ein klarer Stern/Dreieck.
    private static func spikePath(outerRadius: CGFloat, innerRadius: CGFloat, spikes: Int) -> CGPath {
        let path = CGMutablePath()
        let step = (2 * CGFloat.pi) / CGFloat(spikes)

        for i in 0..<spikes {
            let outerAngle = CGFloat(i) * step
            let innerAngle = outerAngle + step / 2

            let outerPt = CGPoint(x: outerRadius * cos(outerAngle),
                                  y: outerRadius * sin(outerAngle))
            let innerPt = CGPoint(x: innerRadius * cos(innerAngle),
                                  y: innerRadius * sin(innerAngle))

            if i == 0 { path.move(to: outerPt) } else { path.addLine(to: outerPt) }
            path.addLine(to: innerPt)
        }
        path.closeSubpath()
        return path
    }
}
