import SpriteKit

// MARK: - Shared textures (rendered once, then cached on the GPU)

private enum SharedTextures {
    static let plant:  SKTexture = makeCircle(radius: 2.5,
        color: NSColor(red: 0.30, green: 0.85, blue: 0.40, alpha: 0.9))
    static let corpse: SKTexture = makeCircle(radius: 7,
        color: NSColor(red: 0.75, green: 0.55, blue: 0.20, alpha: 0.85))

    private static func makeCircle(radius: CGFloat, color: NSColor) -> SKTexture {
        let size = max(1, Int((radius + 1) * 2))
        guard let ctx = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let c = color.usingColorSpace(.deviceRGB) else { return SKTexture() }
        ctx.translateBy(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        ctx.setFillColor(c.cgColor)
        ctx.fillEllipse(in: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
        guard let img = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: img)
    }
}

final class GameScene: SKScene {

    // MARK: - Node pool

    private var creatureNodes: [UUID: CreatureNode] = [:]
    private var foodNodes:     [UUID: SKSpriteNode] = [:]

    // MARK: - Selection

    var selectedCreatureID: UUID? {
        didSet {
            for (id, node) in creatureNodes {
                node.setSelected(id == selectedCreatureID)
            }
        }
    }
    var onCreatureSelected: ((UUID?) -> Void)?

    // MARK: - Setup

    func setup(world: World) {
        size            = world.size
        scaleMode       = .aspectFit
        anchorPoint     = .zero
        backgroundColor = NSColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        drawBiomes(world: world)
    }

    // Static biome tiles as a background layer (zPosition -10, behind everything). Drawn once
    // per world; reset() clears them via removeAllChildren().
    private func drawBiomes(world: World) {
        guard world.biomesEnabled else { return }
        let map = world.biomeMap
        for row in 0..<map.rows {
            for col in 0..<map.cols {
                let (r, g, b) = map.biomeAt(col: col, row: row).color
                let node = SKSpriteNode(color: NSColor(red: r, green: g, blue: b, alpha: 1),
                                        size: CGSize(width: map.tileSize, height: map.tileSize))
                node.anchorPoint = .zero
                node.position = CGPoint(x: CGFloat(col) * map.tileSize,
                                        y: CGFloat(row) * map.tileSize)
                node.zPosition = -10
                addChild(node)
            }
        }
    }

    func reset(world: World) {
        removeAllChildren()
        creatureNodes.removeAll()
        foodNodes.removeAll()
        setup(world: world)
    }

    // MARK: - Update (called by SimulationEngine — read only, never mutate!)

    func update(world: World) {
        syncCreatureNodes(world.creatures)
        syncFoodNodes(world.foodSources)
    }

    // MARK: - Creatures

    private func syncCreatureNodes(_ creatures: [Creature]) {
        let aliveIDs = Set(creatures.map { $0.id })

        // Remove the dead
        for id in creatureNodes.keys where !aliveIDs.contains(id) {
            creatureNodes.removeValue(forKey: id)?.removeFromParent()
        }

        // Update the existing ones, add the new
        for creature in creatures {
            if let node = creatureNodes[creature.id] {
                node.sync(with: creature)
            } else {
                let node = CreatureNode(creature: creature)
                node.setSelected(creature.id == selectedCreatureID)
                addChild(node)
                creatureNodes[creature.id] = node
            }
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let loc = event.location(in: self)
        var nearestID:   UUID?    = nil
        var nearestDist: CGFloat  = 20   // click tolerance in pixels

        for (id, node) in creatureNodes {
            let d = hypot(node.position.x - loc.x, node.position.y - loc.y)
            if d < node.radius + 6 && d < nearestDist {
                nearestID   = id
                nearestDist = d
            }
        }

        selectedCreatureID = nearestID
        onCreatureSelected?(nearestID)
    }

    // MARK: - Food

    private func syncFoodNodes(_ foods: [FoodSource]) {
        let foodIDs = Set(foods.map { $0.id })

        // Remove what has been eaten
        for id in foodNodes.keys where !foodIDs.contains(id) {
            foodNodes.removeValue(forKey: id)?.removeFromParent()
        }

        // Add the new ones — all plants share one texture, hence a single GPU draw call
        for food in foods where foodNodes[food.id] == nil {
            let node: SKSpriteNode
            switch food.type {
            case .plant:
                node = SKSpriteNode(texture: SharedTextures.plant)
            case .corpse:
                let diameter = min(CGFloat(food.energyValue / 14), 7) * 2
                node = SKSpriteNode(texture: SharedTextures.corpse,
                                    size: CGSize(width: diameter, height: diameter))
            }
            node.position = food.position
            addChild(node)
            foodNodes[food.id] = node
        }
    }
}
