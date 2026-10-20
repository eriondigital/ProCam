import CoreMotion
import Foundation

/// Single shared motion source (Apple recommends one CMMotionManager per app).
/// - Integrates gyro roll for SteadyZoom's rotation correction.
/// - Tracks a smoothed "shake level" for the smart shutter.
/// - Feeds gravity to the horizon level.
final class MotionHub {
    static let shared = MotionHub()

    /// Called on the main thread ~33×/s with the gravity vector.
    var onGravity: ((CMAcceleration) -> Void)?

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()
    private let lock = NSLock()
    private var rollAccum = 0.0
    private var shake = 0.0
    private var lastTimestamp: TimeInterval?
    private var sampleCount = 0

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 100
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let r = motion.rotationRate  // bias-corrected, rad/s

            self.lock.lock()
            if let last = self.lastTimestamp {
                let dt = min(motion.timestamp - last, 0.05)
                self.rollAccum += r.z * dt
            }
            self.lastTimestamp = motion.timestamp
            let magnitude = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
            self.shake = self.shake * 0.85 + magnitude * 0.15
            self.lock.unlock()

            self.sampleCount &+= 1
            if self.sampleCount % 3 == 0 {
                let g = motion.gravity
                DispatchQueue.main.async { self.onGravity?(g) }
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
        lock.lock()
        lastTimestamp = nil
        lock.unlock()
    }

    /// Roll (rotation about the screen normal, radians) since the last call.
    func takeRollDelta() -> Double {
        lock.lock()
        defer { lock.unlock() }
        let v = rollAccum
        rollAccum = 0
        return v
    }

    /// Smoothed angular speed in rad/s. Below ~0.03 the phone is basically still.
    var shakeLevel: Double {
        lock.lock()
        defer { lock.unlock() }
        return shake
    }
}
