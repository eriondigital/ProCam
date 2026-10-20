import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

// MARK: - One-Euro filter

/// Adaptive low-pass filter (Casiez et al., 2012).
/// Slow movement (hand shake) is smoothed heavily; fast, sustained movement
/// (an intentional pan) raises the cutoff so the frame follows without lag.
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var derivativeCutoff: Double = 1

    private var previous: Double?
    private var previousDerivative = 0.0

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    mutating func filter(_ x: Double, dt: Double) -> Double {
        guard let prev = previous, dt > 0 else {
            previous = x
            return x
        }
        let dx = (x - prev) / dt
        let smoothedDx = previousDerivative + Self.alpha(derivativeCutoff, dt) * (dx - previousDerivative)
        previousDerivative = smoothedDx

        let cutoff = minCutoff + beta * abs(smoothedDx)
        let y = prev + Self.alpha(cutoff, dt) * (x - prev)
        previous = y
        return y
    }

    /// Force the filter's state (used when the correction hits the crop margin).
    mutating func reset(to value: Double) {
        previous = value
        previousDerivative = 0
    }

    mutating func reset() {
        previous = nil
        previousDerivative = 0
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

// MARK: - SteadyZoom engine

/// Electronic image stabilisation for zoomed shots.
///
/// The device zooms slightly *less* than the user asked for, leaving a hidden margin.
/// Each frame we:
///  1. Measure frame-to-frame translation with Vision image registration (on a 320 px greyscale copy).
///  2. Read roll from the gyroscope.
///  3. Accumulate those into a raw camera path, smooth it with One-Euro filters,
///     and shift/rotate the frame by (raw − smooth) so only the intended motion remains.
///  4. Clamp to the margin and feed the clamp back into the filters so the frame never shows edges.
/// With lock-on, the target becomes "keep the tracked subject centred" instead.
///
/// All methods run on the analysis queue, except `frameNormalizedPoint(fromView:)`.
final class SteadyZoomEngine {
    struct Output {
        let image: CIImage
        /// Tracked subject in viewfinder coordinates (0…1, top-left origin).
        let lockBox: CGRect?
        let lostLock: Bool
    }

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false
    ])
    private let registrationHandler = VNSequenceRequestHandler()
    private var trackingHandler = VNSequenceRequestHandler()
    private let smallWidth = 320.0

    // Raw camera path (full-res pixels / radians)
    private var previousSmall: CIImage?
    private var accX = 0.0
    private var accY = 0.0
    private var accRoll = 0.0
    private var lastTime: Double?
    private var lastWidth = 1.0

    // Smoothed path (normalised by frame width)
    private var smoothX = OneEuroFilter(minCutoff: 0.25, beta: 3)
    private var smoothY = OneEuroFilter(minCutoff: 0.25, beta: 3)
    private var smoothRoll = OneEuroFilter(minCutoff: 0.25, beta: 0.5)
    private var lockX = OneEuroFilter(minCutoff: 1.0, beta: 1.5)
    private var lockY = OneEuroFilter(minCutoff: 1.0, beta: 1.5)

    private var correction = CGPoint.zero

    // Lock-on
    private var tracked: VNDetectedObjectObservation?
    private var pendingLock: CGRect?

    // Mapping for taps (read from main)
    private let mapLock = NSLock()
    private var mapTransform = CGAffineTransform.identity
    private var mapCrop = CGRect.zero
    private var mapSize = CGSize.zero

    func reset() {
        previousSmall = nil
        accX = 0
        accY = 0
        accRoll = 0
        lastTime = nil
        correction = .zero
        smoothX.reset()
        smoothY.reset()
        smoothRoll.reset()
        lockX.reset()
        lockY.reset()
        tracked = nil
        pendingLock = nil
        _ = MotionHub.shared.takeRollDelta()
        mapLock.lock()
        mapSize = .zero
        mapLock.unlock()
    }

    /// `point` is in frame coordinates (0…1, bottom-left origin); `size` is a fraction of frame width.
    func startLock(atFramePoint point: CGPoint, size: CGFloat) {
        mapLock.lock()
        let frameSize = mapSize
        mapLock.unlock()
        let aspect = frameSize.height > 0 ? frameSize.width / frameSize.height : 0.75
        let w = max(min(size, 0.5), 0.04)
        let h = w * aspect
        pendingLock = CGRect(x: min(max(point.x - w / 2, 0), 1 - w),
                             y: min(max(point.y - h / 2, 0), 1 - h),
                             width: w, height: h)
    }

    func unlock() {
        guard tracked != nil || pendingLock != nil else { return }
        tracked = nil
        pendingLock = nil
        resyncSmoothPath()
    }

    // MARK: Per-frame

    func process(_ frame: CIImage, time: Double, softCrop: CGFloat) -> Output {
        let W = Double(frame.extent.width)
        let H = Double(frame.extent.height)
        guard W > 0, H > 0 else { return Output(image: frame, lockBox: nil, lostLock: false) }
        lastWidth = W
        let c = Double(max(softCrop, 1))

        let prevTime = lastTime ?? (time - 1.0 / 30)
        let dt = min(max(time - prevTime, 1.0 / 240), 0.1)
        lastTime = time

        // 1. Measure motion
        let s = smallWidth / W
        let small = makeSmall(frame, scale: s)
        if let prev = previousSmall, let cur = small {
            let request = VNTranslationalImageRegistrationRequest(targetedCIImage: cur)
            if (try? registrationHandler.perform([request], on: prev)) != nil,
               let observation = request.results?.first {
                // alignmentTransform moves the current frame onto the previous one.
                let dx = Double(observation.alignmentTransform.tx) / s
                let dy = Double(observation.alignmentTransform.ty) / s
                if abs(dx) < W * 0.15, abs(dy) < H * 0.15 {  // reject bad matches
                    accX += dx
                    accY += dy
                }
            }
        }
        if let small { previousSmall = small }
        accRoll += MotionHub.shared.takeRollDelta()

        // 2. Lock-on tracking
        var lost = false
        var subject: CGRect?
        if let pending = pendingLock, small != nil {
            tracked = VNDetectedObjectObservation(boundingBox: pending)
            trackingHandler = VNSequenceRequestHandler()
            pendingLock = nil
            lockX.reset(to: Double(correction.x) / W)
            lockY.reset(to: Double(correction.y) / W)
        }
        if let observation = tracked, let cur = small {
            let request = VNTrackObjectRequest(detectedObjectObservation: observation)
            request.trackingLevel = .accurate
            if (try? trackingHandler.perform([request], on: cur)) != nil,
               let result = request.results?.first as? VNDetectedObjectObservation,
               result.confidence > 0.3 {
                tracked = result
                subject = result.boundingBox
            } else {
                tracked = nil
                lost = true
                resyncSmoothPath()
            }
        }

        // 3. Target correction
        var cx: Double
        var cy: Double
        if let box = subject {
            let wantX = (0.5 - Double(box.midX)) * W
            let wantY = (0.5 - Double(box.midY)) * H
            cx = lockX.filter(wantX / W, dt: dt) * W
            cy = lockY.filter(wantY / W, dt: dt) * W
        } else {
            let sx = smoothX.filter(accX / W, dt: dt) * W
            let sy = smoothY.filter(accY / W, dt: dt) * W
            cx = accX - sx
            cy = accY - sy
        }
        let sr = smoothRoll.filter(accRoll, dt: dt)
        let wantedRoll = accRoll - sr
        var theta = max(min(wantedRoll, 0.06), -0.06)

        // 4. Clamp to the margin (rotation eats into it, so shrink rotation first if needed)
        let hw = W / c / 2
        let hh = H / c / 2
        func margins(_ t: Double) -> (Double, Double) {
            let ct = abs(cos(t)), st = abs(sin(t))
            return (W / 2 - (hw * ct + hh * st), H / 2 - (hw * st + hh * ct))
        }
        var (mx, my) = margins(theta)
        var tries = 0
        while (mx < 0 || my < 0) && tries < 12 {
            theta *= 0.6
            (mx, my) = margins(theta)
            tries += 1
        }
        if mx < 0 || my < 0 {
            theta = 0
            (mx, my) = margins(0)
        }
        mx = max(mx, 0)
        my = max(my, 0)

        let clampedX = max(min(cx, mx), -mx)
        let clampedY = max(min(cy, my), -my)
        if subject == nil {
            if clampedX != cx { smoothX.reset(to: (accX - clampedX) / W) }
            if clampedY != cy { smoothY.reset(to: (accY - clampedY) / W) }
        }
        if theta != wantedRoll { smoothRoll.reset(to: accRoll - theta) }
        correction = CGPoint(x: clampedX, y: clampedY)

        // 5. Apply: rotate about centre, translate, crop the centre window
        let T = CGAffineTransform(translationX: CGFloat(-W / 2), y: CGFloat(-H / 2))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(theta)))
            .concatenating(CGAffineTransform(translationX: CGFloat(W / 2 + clampedX), y: CGFloat(H / 2 + clampedY)))
        let crop = CGRect(x: (W - W / c) / 2, y: (H - H / c) / 2, width: W / c, height: H / c)
        let output = frame.clampedToExtent()
            .transformed(by: T)
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        mapLock.lock()
        mapTransform = T
        mapCrop = crop
        mapSize = CGSize(width: W, height: H)
        mapLock.unlock()

        var viewBox: CGRect?
        if let box = subject {
            let center = CGPoint(x: box.midX * CGFloat(W), y: box.midY * CGFloat(H)).applying(T)
            let vx = (center.x - crop.minX) / crop.width
            let vy = 1 - (center.y - crop.minY) / crop.height
            let vw = box.width * CGFloat(W) / crop.width
            let vh = box.height * CGFloat(H) / crop.height
            viewBox = CGRect(x: vx - vw / 2, y: vy - vh / 2, width: vw, height: vh)
        }

        return Output(image: output, lockBox: viewBox, lostLock: lost)
    }

    /// Converts a viewfinder point (0…1, top-left origin) to raw frame coordinates (0…1, bottom-left).
    /// Safe to call from the main thread.
    func frameNormalizedPoint(fromView p: CGPoint) -> CGPoint {
        mapLock.lock()
        let T = mapTransform, crop = mapCrop, size = mapSize
        mapLock.unlock()
        guard size.width > 0, crop.width > 0 else { return CGPoint(x: p.x, y: 1 - p.y) }
        let q = CGPoint(x: crop.minX + p.x * crop.width,
                        y: crop.minY + (1 - p.y) * crop.height).applying(T.inverted())
        return CGPoint(x: min(max(q.x / size.width, 0), 1),
                       y: min(max(q.y / size.height, 0), 1))
    }

    // MARK: Helpers

    /// After lock-on ends, continue smoothing from where the frame currently is (no jump).
    private func resyncSmoothPath() {
        smoothX.reset(to: (accX - Double(correction.x)) / lastWidth)
        smoothY.reset(to: (accY - Double(correction.y)) / lastWidth)
    }

    private func makeSmall(_ frame: CIImage, scale: Double) -> CIImage? {
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = frame
        f.scale = Float(scale)
        f.aspectRatio = 1
        guard let scaled = f.outputImage else { return nil }
        let gray = scaled.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let cg = context.createCGImage(gray, from: gray.extent.integral) else { return nil }
        return CIImage(cgImage: cg)
    }
}
