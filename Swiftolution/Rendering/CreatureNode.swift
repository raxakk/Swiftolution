import SpriteKit

final class CreatureNode: SKNode {

    // MARK: - Children

    private let bodySprite:    SKSpriteNode   // pre-rendered, so no SKShapeNode rasterization per frame
    private let directionLine: SKSpriteNode   // a plain rectangle
    private let sightNode:     SKShapeNode    // only visible while selected
    private let selectionRing: SKShapeNode    // only visible while selected
    let radius: CGFloat

    // MARK: - Init

    init(creature: Creature) {
        let radius = CGFloat(creature.dna.size * 8 + 4)
        self.radius = radius
        let aggr   = CGFloat(creature.dna.aggression)

        // Body color from DNA plus an aggression tint (green -> red)
        let dnaColor  = NSColor(red: CGFloat(creature.dna.red),
                                green: CGFloat(creature.dna.green),
                                blue: CGFloat(creature.dna.blue), alpha: 1)
        let tintColor = aggr < 0.5
            ? NSColor(red: 0.05, green: 0.85, blue: 0.2,  alpha: 1)   // herbivore: green
            : NSColor(red: 0.90, green: 0.05, blue: 0.05, alpha: 1)   // carnivore: red
        let tintStrength = min(abs(aggr - 0.5) * 1.6, 0.55)
        let bodyColor = dnaColor.blended(withFraction: tintStrength, of: tintColor) ?? dnaColor

        // Shape: many rounded corners (nearly a circle) shading into few sharp spikes (a
        // triangle). Spike count: 8 at aggr=0, 3 at aggr=1.
        // Inner radius: 0.88r at aggr=0 (barely indented), 0.22r at aggr=1 (very spiky).
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

        // The heading line as a plain rectangle; no path rasterizer needed
        let lineAlpha = max(0, 0.7 - aggr * 1.4)
        directionLine = SKSpriteNode(color: NSColor.white.withAlphaComponent(lineAlpha),
                                     size: CGSize(width: radius + 5, height: 1.5))
        directionLine.anchorPoint = CGPoint(x: 0, y: 0.5)

        // The sight cone, only visible while selected; its path is refreshed in sync()
        sightNode             = SKShapeNode(path: CreatureNode.fovPath(radius: creature.sightRadius,
                                                                        angle: creature.sightAngle))
        sightNode.fillColor   = bodyColor.withAlphaComponent(0.07)
        sightNode.strokeColor = bodyColor.withAlphaComponent(0.30)
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
        if !sightNode.isHidden {
            sightNode.path = CreatureNode.fovPath(radius: creature.sightRadius, angle: creature.sightAngle)
        }
    }

    func setSelected(_ selected: Bool) {
        selectionRing.isHidden = !selected
        sightNode.isHidden     = !selected
    }

    func showSightRadius(_ visible: Bool) {
        sightNode.isHidden = !visible
    }

    // MARK: - Texture generation

    // Renders the body path once into a GPU texture, replacing per-frame SKShapeNode rasterization.
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

    // MARK: - Shape generation

    // Builds the sight cone path: a pie slice along the +X axis (the heading). The parent node
    // is rotated by zRotation=heading, so the cone always points forward. At 360 degrees or more
    // a full circle is drawn instead.
    static func fovPath(radius: CGFloat, angle: CGFloat) -> CGPath {
        let path = CGMutablePath()
        if angle >= 2 * .pi * 0.995 {
            path.addEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        } else {
            let half = angle / 2
            path.move(to: .zero)
            // An arc from -half to +half around the +X axis (the heading at zRotation=0)
            path.addArc(center: .zero, radius: radius,
                        startAngle: -half, endAngle: half, clockwise: false)
            path.closeSubpath()
        }
        return path
    }

    // Builds a star path with `spikes` points.
    // The first outer point sits at angle 0 (pointing right) so the tip follows zRotation=heading.
    // Many spikes with a shallow indent read as a circle; few spikes with a deep indent give a
    // distinct star or triangle.
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
