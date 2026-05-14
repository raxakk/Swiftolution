import SpriteKit

final class GameScene: SKScene {

    // MARK: - Node-Pool

    private var creatureNodes: [UUID: CreatureNode] = [:]
    private var foodNodes:     [UUID: SKShapeNode]  = [:]

    // MARK: - Setup

    func setup(world: World) {
        size       = world.size
        scaleMode  = .aspectFit
        anchorPoint = .zero
        backgroundColor = NSColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
    }

    func reset(world: World) {
        removeAllChildren()
        creatureNodes.removeAll()
        foodNodes.removeAll()
        setup(world: world)
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
        }
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
            let node             = SKShapeNode(circleOfRadius: 2.5)
            node.fillColor       = NSColor(red: 0.3, green: 0.85, blue: 0.4, alpha: 0.9)
            node.strokeColor     = .clear
            node.position        = food.position
            addChild(node)
            foodNodes[food.id]   = node
        }
    }
}
