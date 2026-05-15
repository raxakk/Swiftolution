import SpriteKit

final class CreatureNode: SKNode {

    // MARK: - Kinder

    private let bodySprite:    SKSpriteNode   // vorab gerendert → keine SKShapeNode-Rasterisierung pro Frame
    private let directionLine: SKSpriteNode   // einfaches Rechteck
    private let sightNode:     SKShapeNode    // nur bei Selektion sichtbar
    private let selectionRing: SKShapeNode    // nur bei Selektion sichtbar
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

        let strokeColor = NSColor(red: 0.3 + aggr * 0.7,
                                  green: 0.55 * (1 - aggr),
                                  blue:  0.25 * (1 - aggr), alpha: 1)
        let lineWidth: CGFloat = 1.0 + aggr * 3.0
        bodySprite = CreatureNode.makeBodySprite(path: bodyPath,
                                                 fill: bodyColor,
                                                 stroke: strokeColor,
                                                 lineWidth: lineWidth,
                                                 radius: radius)

        // Richtungslinie als einfaches Rechteck — kein Pfad-Rasterizer nötig
        let lineAlpha = max(0, 0.7 - aggr * 1.4)
        directionLine = SKSpriteNode(color: NSColor.white.withAlphaComponent(lineAlpha),
                                     size: CGSize(width: radius + 5, height: 1.5))
        directionLine.anchorPoint = CGPoint(x: 0, y: 0.5)

        // Sichtradius-Ring und Auswahlring — nur bei Selektion sichtbar
        sightNode             = SKShapeNode(circleOfRadius: creature.sightRadius)
        sightNode.fillColor   = .clear
        sightNode.strokeColor = bodyColor.withAlphaComponent(0.18)
        sightNode.lineWidth   = 0.5
        sightNode.isHidden    = true

        selectionRing             = SKShapeNode(circleOfRadius: radius + 5)
        selectionRing.fillColor   = .clear
        selectionRing.strokeColor = .white.withAlphaComponent(0.9)
        selectionRing.lineWidth   = 1.5
        selectionRing.isHidden    = true

        super.init()
        addChild(sightNode)
        addChild(selectionRing)
        addChild(bodySprite)
        addChild(directionLine)

        position = creature.position
    }

    required init?(coder aDecoder: NSCoder) { fatalError() }

    // MARK: - Update

    func sync(with creature: Creature) {
        position  = creature.position
        zRotation = CGFloat(creature.heading)
        bodySprite.alpha = 0.35 + CGFloat(creature.energy / creature.maxEnergy) * 0.65
    }

    func setSelected(_ selected: Bool) {
        selectionRing.isHidden = !selected
        sightNode.isHidden     = !selected
    }

    func showSightRadius(_ visible: Bool) {
        sightNode.isHidden = !visible
    }

    // MARK: - Texture-Generator

    // Rendert den Körperpfad einmalig in eine GPU-Textur — ersetzt per-Frame SKShapeNode-Rasterisierung.
    private static func makeBodySprite(path: CGPath, fill: NSColor, stroke: NSColor,
                                       lineWidth: CGFloat, radius: CGFloat) -> SKSpriteNode {
        let margin  = lineWidth / 2 + 1
        let texSize = Int((radius + margin) * 2) + 2
        guard let ctx = CGContext(data: nil, width: texSize, height: texSize,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return SKSpriteNode() }

        ctx.translateBy(x: CGFloat(texSize) / 2, y: CGFloat(texSize) / 2)

        if let c = fill.usingColorSpace(.deviceRGB)   { ctx.setFillColor(c.cgColor) }
        ctx.addPath(path)
        ctx.fillPath()

        ctx.setLineWidth(lineWidth)
        if let c = stroke.usingColorSpace(.deviceRGB) { ctx.setStrokeColor(c.cgColor) }
        ctx.addPath(path)
        ctx.strokePath()

        guard let img = ctx.makeImage() else { return SKSpriteNode() }
        let size = CGSize(width: texSize, height: texSize)
        return SKSpriteNode(texture: SKTexture(cgImage: img), size: size)
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
