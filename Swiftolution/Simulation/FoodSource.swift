import Foundation
import CoreGraphics

enum FoodType {
    case plant    // natürlich gewachsen — wächst logistisch nach
    case corpse   // Überreste eines gestorbenen Lebewesens — verfällt nach einiger Zeit
    case waste    // Energie die beim Kampf "verspritzt" wird — verfällt schnell
}

struct FoodSource {
    let id = UUID()
    var position: CGPoint
    var energyValue: Float
    var type: FoodType
    let spawnedAt: Int   // Tick der Entstehung — für Verfall von corpse/waste

    init(position: CGPoint, energyValue: Float = 25, type: FoodType = .plant, spawnedAt: Int = 0) {
        self.position    = position
        self.energyValue = energyValue
        self.type        = type
        self.spawnedAt   = spawnedAt
    }
}
