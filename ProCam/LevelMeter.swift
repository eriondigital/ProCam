import CoreMotion
import Foundation

/// Device roll in degrees, for the on-screen horizon level.
final class LevelMeter: ObservableObject {
    @Published private(set) var roll: Double = 0
    @Published private(set) var isFlat = false

    init() {
        MotionHub.shared.onGravity = { [weak self] g in
            self?.isFlat = abs(g.z) > 0.85
            self?.roll = atan2(g.x, -g.y) * 180 / .pi
        }
    }

    func start() { MotionHub.shared.start() }
    func stop() { MotionHub.shared.stop() }
}
