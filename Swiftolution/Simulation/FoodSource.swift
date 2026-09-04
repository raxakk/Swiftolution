import Foundation
import CoreGraphics

enum FoodType {
    case plant    // grown naturally; regrows logistically
    case corpse   // the remains of a dead creature; decays after a while
}

struct FoodSource {
    let id = UUID()
    var position: CGPoint
    var energyValue: Float
    var type: FoodType
    let spawnedAt: Int   // the tick it came into being; drives corpse decay

    init(position: CGPoint, energyValue: Float = 30, type: FoodType = .plant, spawnedAt: Int = 0) {
        self.position    = position
        self.energyValue = energyValue
        self.type        = type
        self.spawnedAt   = spawnedAt
    }
}
