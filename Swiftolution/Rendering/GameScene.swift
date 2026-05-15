import SpriteKit

final class GameScene: SKScene {

    // MARK: - Node-Pool

    private var creatureNodes: [UUID: CreatureNode] = [:]
    private var foodNodes:     [UUID: SKShapeNode]  = [:]

    // MARK: - Selektion

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
        size        = world.size
        scaleMode   = .aspectFit
        anchorPoint = .zero
        backgroundColor = NSColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        drawTerrain(world.terrain)
    }

    func reset(world: World) {
        removeAllChildren()
        creatureNodes.removeAll()
        foodNodes.removeAll()
        setup(world: world)
    }

    private func drawTerrain(_ map: TerrainMap) {
        map.forEachCell { col, row, type in
            let node = SKShapeNode(rect: map.cellRect(col: col, row: row))
            node.fillColor   = type.color
            node.strokeColor = .clear
            node.zPosition   = -10
            addChild(node)
        }
    }

    // MARK: - Update (von SimulationEngine aufgerufen — nur lesen, nicht verändern!)

    func update(world: World) {
        syncCreatureNodes(world.creatures)
        syncFoodNodes(world.foodSources)
    }

    // MARK: - Lebewesen

    private func syncCreatureNodes(_ creatures: [Creature]) {
        let aliveIDs = Set(creatures.map { $0.id })

        // Gestorbene entfernen
        for id in creatureNodes.keys where !aliveIDs.contains(id) {
            creatureNodes.removeValue(forKey: id)?.removeFromParent()
        }

        // Vorhandene aktualisieren, neue hinzufügen
        for creature in creatures {
            if let node = creatureNodes[creature.id] {
                node.sync(with: creature)
            } else {
                let node = CreatureNode(creature: creature)
                addChild(node)
                creatureNodes[creature.id] = node
            }
            creatureNodes[creature.id]?.setSelected(creature.id == selectedCreatureID)
        }
    }

    // MARK: - Maus

    override func mouseDown(with event: NSEvent) {
        let loc = event.location(in: self)
        var nearestID:   UUID?    = nil
        var nearestDist: CGFloat  = 20   // Klick-Toleranz in Pixeln

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

    // MARK: - Nahrung

    private func syncFoodNodes(_ foods: [FoodSource]) {
        let foodIDs = Set(foods.map { $0.id })

        // Gefressene entfernen
        for id in foodNodes.keys where !foodIDs.contains(id) {
            foodNodes.removeValue(forKey: id)?.removeFromParent()
        }

        // Neue hinzufügen
        for food in foods where foodNodes[food.id] == nil {
            let radius: CGFloat
            let color: NSColor
            switch food.type {
            case .plant:
                radius = 2.5
                color  = NSColor(red: 0.30, green: 0.85, blue: 0.40, alpha: 0.9)
            case .corpse:
                // Radius skaliert mit Energiewert — große Tiere hinterlassen mehr
                radius = min(CGFloat(food.energyValue / 10), 6)
                color  = NSColor(red: 0.75, green: 0.55, blue: 0.20, alpha: 0.85)
            case .waste:
                radius = 1.8
                color  = NSColor(red: 0.80, green: 0.15, blue: 0.15, alpha: 0.70)
            }
            let node         = SKShapeNode(circleOfRadius: radius)
            node.fillColor   = color
            node.strokeColor = .clear
            node.position    = food.position
            addChild(node)
            foodNodes[food.id] = node
        }
    }
}
