import AVFoundation
import CoreImage
import ImageIO
import UIKit

// MARK: - Models

enum CaptureFormat: String, CaseIterable, Identifiable {
    case heif = "HEIF"
    case proRAW = "ProRAW"
    case raw = "RAW"
    var id: String { rawValue }
}

enum ShootMode: String, CaseIterable, Identifiable {
    case photo = "PHOTO"
    case night = "NIGHT"
    var id: String { rawValue }
}

enum ManualControl: String, CaseIterable, Identifiable {
    case ev = "EV"
    case iso = "ISO"
    case shutter = "SHUTTER"
    case focus = "FOCUS"
    case wb = "WB"
    var id: String { rawValue }
}

struct Lens: Identifiable, Equatable {
    let id: String
    let label: String
    let zoom: Double
    let device: AVCaptureDevice
    static func == (l: Lens, r: Lens) -> Bool { l.id == r.id }
}

// MARK: - Camera controller

/// Owns the capture session and the processing pipeline.
/// Threads: AVFoundation config on `sessionQueue`, per-frame work on `analysisQueue`,
/// photo post-processing on `processingQueue`, @Published state on main.
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    let renderer = ViewfinderRenderer()

    static let steadyMargin: CGFloat = 1.35
    static let wbRange: ClosedRange<Float> = 2500...10000

    // Permission / devices
    @Published private(set) var permissionDenied = false
    @Published private(set) var lenses: [Lens] = []
    @Published private(set) var currentDeviceID: String?
    @Published private(set) var currentLensZoom: Double = 1
    @Published private(set) var isFront = false

    // Format / mode
    @Published private(set) var format: CaptureFormat = .heif
    @Published private(set) var mode: ShootMode = .photo
    @Published private(set) var supportsProRAW = false
    @Published private(set) var supportsBayerRAW = false

    // Live / manual values
    @Published private(set) var iso: Float = 100
    @Published private(set) var shutter: Double = 1.0 / 60
    @Published private(set) var focus: Float = 0.5
    @Published private(set) var temperature: Float = 5500
    @Published private(set) var evBias: Float = 0
    @Published private(set) var meterOffset: Float = 0

    @Published private(set) var isoManual = false
    @Published private(set) var shutterManual = false
    @Published private(set) var focusManual = false { didSet { pushPipeline() } }
    @Published private(set) var wbManual = false

    @Published private(set) var isoRange: ClosedRange<Float> = 32...3200
    @Published private(set) var shutterRange: ClosedRange<Double> = (1.0 / 8000)...1.0
    @Published private(set) var evRange: ClosedRange<Float> = -3...3
    @Published private(set) var manualFocusSupported = true

    // Zoom & SteadyZoom
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 1
    @Published private(set) var steadyActive = false
    @Published private(set) var softCrop: CGFloat = 1
    @Published private(set) var lockBox: CGRect?
    @Published private(set) var aeafLocked = false
    @Published var steadyEnabled = true { didSet { updateZoomPipeline() } }

    // Looks & overlays
    @Published var look: Look = .natural { didSet { pushPipeline() } }
    @Published var showPeaking = false { didSet { pushPipeline() } }
    @Published var showHistogram = true { didSet { pushPipeline() } }
    @Published var showZebras = false { didSet { pushPipeline() } }
    @Published private(set) var metalActive = false
    @Published private(set) var histogram: [[Float]] = []
    @Published private(set) var overlayImage: CGImage?

    // Shutter helpers
    @Published var smartShutter = true
    @Published var timerSeconds = 0
    @Published private(set) var countdown: Int?
    @Published private(set) var holdingSteady = false
    @Published private(set) var nightProgress: Int?
    @Published private(set) var nightTotal = 8
    @Published private(set) var nightPlan: String?
    @Published private(set) var isMerging = false

    // Processing
    @Published var processing: ProcessingStyle = ProcessingStyle(
        rawValue: UserDefaults.standard.string(forKey: "procam.processing") ?? "") ?? .natural {
        didSet { UserDefaults.standard.set(processing.rawValue, forKey: "procam.processing") }
    }

    // Feedback
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var shutterTick = 0
    @Published private(set) var toast: String?

    var peakingActive: Bool { showPeaking || focusManual }
    var exposureIsManual: Bool { isoManual || shutterManual }
    var effectiveZoom: Double { currentLensZoom * Double(zoom) }
    var isBusy: Bool { nightProgress != nil || isMerging || holdingSteady }

    // Queues
    private let sessionQueue = DispatchQueue(label: "procam.session")
    private let analysisQueue = DispatchQueue(label: "procam.analysis", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "procam.processing", qos: .userInitiated)

    // Session state (sessionQueue)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var backLenses: [Lens] = []
    private var sessionFormat: CaptureFormat = .heif
    private var nightDimensions: CMVideoDimensions?
    private var observers: [NSKeyValueObservation] = []
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var isConfigured = false

    // Pipeline state (analysisQueue)
    private struct PipelineConfig {
        var steady = false
        var softCrop: CGFloat = 1
        var look: Look = .natural
        var histogram = true
        var peaking = false
        var zebra = false
        var processed: Bool { steady || look != .natural }
    }
    private var pipeline = PipelineConfig()
    private let analyzer = FrameAnalyzer()
    private let steadyEngine = SteadyZoomEngine()
    private var frameIndex = 0
    private var lastLockBox: CGRect?

    // Capture bookkeeping (kindsLock)
    private enum CaptureKind {
        case single(crop: CGFloat, look: Look, style: ProcessingStyle)
        case night
    }
    private let kindsLock = NSLock()
    private var captureKinds: [Int64: CaptureKind] = [:]
    private var nightReceived = 0
    private var nightTarget = 0
    private var nightCrop: CGFloat = 1
    private var nightLook: Look = .natural
    private var nightStyle: ProcessingStyle = .natural

    // Night merge state (processingQueue)
    private var nightAccumulator: NightAccumulator?

    // Main-thread helpers
    private var pinchBase: CGFloat = 1
    private var countdownTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.configureIfNeeded() }
                else { DispatchQueue.main.async { self.permissionDenied = true } }
            }
        default:
            permissionDenied = true
        }
    }

    func resume() {
        sessionQueue.async {
            if self.isConfigured, !self.session.isRunning { self.session.startRunning() }
        }
    }

    func pause() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() {
        sessionQueue.async {
            guard !self.isConfigured else {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            let back = Self.discoverBackLenses()
            self.backLenses = back
            guard let initial = back.first(where: { $0.zoom == 1 })?.device
                    ?? back.first?.device
                    ?? AVCaptureDevice.default(for: .video) else {
                self.showToast("No camera available")
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .photo
            if let input = try? AVCaptureDeviceInput(device: initial), self.session.canAddInput(input) {
                self.session.addInput(input)
                self.deviceInput = input
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.analysisQueue)
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }
            self.configurePhotoOutput()
            self.configureConnections()
            self.session.commitConfiguration()
            self.isConfigured = true
            self.session.startRunning()
            self.deviceDidChange(initial)

            DispatchQueue.main.async { self.lenses = back }
        }
    }

    // MARK: - Lenses

    private static func discoverBackLenses() -> [Lens] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices

        let wideFOV = devices.first(where: { $0.deviceType == .builtInWideAngleCamera })?.activeFormat.videoFieldOfView

        return devices.map { d -> Lens in
            var z = 1.0
            if let wideFOV, d.deviceType != .builtInWideAngleCamera {
                let ratio = tan(Double(wideFOV) * .pi / 360) / tan(Double(d.activeFormat.videoFieldOfView) * .pi / 360)
                z = max((ratio * 2).rounded() / 2, 0.5)
            }
            return Lens(id: d.uniqueID, label: zoomLabel(z), zoom: z, device: d)
        }
        .sorted { $0.zoom < $1.zoom }
    }

    private static func zoomLabel(_ z: Double) -> String {
        z == z.rounded() ? "\(Int(z))×" : String(format: "%.1f×", z)
    }

    func select(_ lens: Lens) {
        sessionQueue.async { self.switchTo(lens.device) }
    }

    func flipCamera() {
        sessionQueue.async {
            let toFront = self.deviceInput?.device.position != .front
            let target = toFront
                ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                : (self.backLenses.first(where: { $0.zoom == 1 })?.device ?? self.backLenses.first?.device)
            if let target { self.switchTo(target) }
        }
    }

    private func switchTo(_ newDevice: AVCaptureDevice) {
        guard newDevice.uniqueID != deviceInput?.device.uniqueID,
              let newInput = try? AVCaptureDeviceInput(device: newDevice) else { return }

        session.beginConfiguration()
        let old = deviceInput
        if let old { session.removeInput(old) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            deviceInput = newInput
        } else if let old, session.canAddInput(old) {
            session.addInput(old)
        }
        configurePhotoOutput()
        configureConnections()
        session.commitConfiguration()

        if let d = deviceInput?.device { deviceDidChange(d) }
    }

    // MARK: - Output configuration (sessionQueue)

    private func configurePhotoOutput() {
        guard let device = deviceInput?.device else { return }

        photoOutput.maxPhotoQualityPrioritization = .quality
        let dims = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height)
        }
        if let largest = dims.last { photoOutput.maxPhotoDimensions = largest }
        // Night Stack works on ~12 MP frames: fast to capture and merge.
        nightDimensions = dims.first(where: { Int($0.width) * Int($0.height) >= 8_000_000 }) ?? dims.last

        photoOutput.isAppleProRAWEnabled = false
        let bayer = photoOutput.availableRawPhotoPixelFormatTypes.contains { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }
        let proRAW = photoOutput.isAppleProRAWSupported

        if sessionFormat == .proRAW && !proRAW { sessionFormat = .heif }
        if sessionFormat == .raw && !bayer { sessionFormat = .heif }
        photoOutput.isAppleProRAWEnabled = sessionFormat == .proRAW

        let fmt = sessionFormat
        DispatchQueue.main.async {
            self.supportsProRAW = proRAW
            self.supportsBayerRAW = bayer
            self.format = fmt
            self.updateZoomPipeline()
        }
    }

    private func configureConnections() {
        let front = deviceInput?.device.position == .front
        if let c = videoOutput.connection(with: .video) {
            if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
            if c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = front
            }
        }
    }

    func setFormat(_ f: CaptureFormat) {
        format = f
        updateZoomPipeline()
        sessionQueue.async {
            self.sessionFormat = f
            self.session.beginConfiguration()
            self.configurePhotoOutput()
            self.session.commitConfiguration()
        }
    }

    func setMode(_ m: ShootMode) {
        guard !isBusy else { return }
        mode = m
        if m == .night && format != .heif { setFormat(.heif) }
    }

    // MARK: - Device state

    private func deviceDidChange(_ d: AVCaptureDevice) {
        observers.removeAll()
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: d, previewLayer: nil)

        if (try? d.lockForConfiguration()) != nil {
            if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            d.setExposureTargetBias(0, completionHandler: nil)
            d.videoZoomFactor = 1
            d.unlockForConfiguration()
        }

        let f = d.activeFormat
        let isoR = f.minISO...max(f.minISO, f.maxISO)
        let minS = f.minExposureDuration.seconds
        let maxS = max(minS, min(f.maxExposureDuration.seconds, 1.0))
        let evLo = max(d.minExposureTargetBias, -3)
        let evR = evLo...max(evLo, min(d.maxExposureTargetBias, 3))
        let manualFocus = d.isLockingFocusWithCustomLensPositionSupported
        let zoomCap = min(d.maxAvailableVideoZoomFactor, 15)
        let lensZoom = backLenses.first(where: { $0.id == d.uniqueID })?.zoom ?? 1

        observers = [
            d.observe(\.iso, options: [.initial, .new]) { [weak self] dev, _ in
                let v = dev.iso
                DispatchQueue.main.async { if self?.isoManual == false { self?.iso = v } }
            },
            d.observe(\.exposureDuration, options: [.initial, .new]) { [weak self] dev, _ in
                let v = dev.exposureDuration.seconds
                DispatchQueue.main.async { if self?.shutterManual == false { self?.shutter = v } }
            },
            d.observe(\.lensPosition, options: [.initial, .new]) { [weak self] dev, _ in
                let v = dev.lensPosition
                DispatchQueue.main.async { if self?.focusManual == false { self?.focus = v } }
            },
            d.observe(\.deviceWhiteBalanceGains, options: [.initial, .new]) { [weak self] dev, _ in
                let t = dev.temperatureAndTintValues(for: dev.deviceWhiteBalanceGains).temperature
                DispatchQueue.main.async { if self?.wbManual == false { self?.temperature = t } }
            },
            d.observe(\.exposureTargetOffset, options: [.initial, .new]) { [weak self] dev, _ in
                let v = dev.exposureTargetOffset
                DispatchQueue.main.async { self?.meterOffset = v }
            }
        ]

        analysisQueue.async { self.steadyEngine.reset() }

        DispatchQueue.main.async {
            self.isoRange = isoR
            self.shutterRange = minS...maxS
            self.evRange = evR
            self.manualFocusSupported = manualFocus
            self.isoManual = false
            self.shutterManual = false
            self.focusManual = false
            self.wbManual = false
            self.aeafLocked = false
            self.evBias = 0
            self.zoom = 1
            self.maxZoom = zoomCap
            self.currentDeviceID = d.uniqueID
            self.currentLensZoom = lensZoom
            self.isFront = d.position == .front
            self.updateZoomPipeline()
        }
    }

    // MARK: - Zoom & processing pipeline (main)

    func pinch(scale: CGFloat, began: Bool) {
        if began { pinchBase = zoom }
        zoom = min(max(pinchBase * scale, 1), maxZoom)
        updateZoomPipeline()
    }

    /// SteadyZoom: the lens zooms to zoom/1.35 and the last 1.35× is a moving
    /// crop window, giving the stabiliser room to shift the frame.
    private func updateZoomPipeline() {
        let allowed = steadyEnabled && !isFront && format == .heif
        let active = allowed && zoom >= 1.1
        let deviceZoom = active ? max(1, zoom / Self.steadyMargin) : zoom
        steadyActive = active
        softCrop = active ? zoom / deviceZoom : 1

        sessionQueue.async {
            guard let d = self.deviceInput?.device, (try? d.lockForConfiguration()) != nil else { return }
            d.videoZoomFactor = min(max(deviceZoom, 1), d.maxAvailableVideoZoomFactor)
            d.unlockForConfiguration()
        }
        pushPipeline()
    }

    private func pushPipeline() {
        var cfg = PipelineConfig()
        cfg.steady = steadyActive
        cfg.softCrop = softCrop
        cfg.look = look
        cfg.histogram = showHistogram
        cfg.peaking = peakingActive
        cfg.zebra = showZebras

        let wasProcessed = metalActive
        metalActive = cfg.processed
        if wasProcessed && !cfg.processed { renderer.flush() }
        if !cfg.steady { lockBox = nil }
        if !cfg.peaking && !cfg.zebra { overlayImage = nil }

        analysisQueue.async {
            if !cfg.steady && self.pipeline.steady { self.steadyEngine.reset() }
            self.pipeline = cfg
        }
    }

    // MARK: - Taps & long-press (main)

    func handleTap(devicePoint: CGPoint, viewNormalized: CGPoint) {
        if lockBox != nil {
            lockBox = nil
            analysisQueue.async { self.steadyEngine.unlock() }
            return
        }
        aeafLocked = false
        focusAndExpose(at: mappedDevicePoint(devicePoint, viewNormalized))
    }

    /// Long-press: lock-on tracking while SteadyZoom is active, otherwise AE/AF lock.
    func handleLongPress(devicePoint: CGPoint, viewNormalized: CGPoint) {
        if steadyActive {
            let p = steadyEngine.frameNormalizedPoint(fromView: viewNormalized)
            let size = 0.22 / softCrop
            analysisQueue.async { self.steadyEngine.startLock(atFramePoint: p, size: size) }
        } else {
            lockFocusAndExposure(at: mappedDevicePoint(devicePoint, viewNormalized))
        }
    }

    /// In SteadyZoom the viewfinder is a moving crop, so map through the stabiliser.
    private func mappedDevicePoint(_ layerPoint: CGPoint, _ viewNormalized: CGPoint) -> CGPoint {
        guard steadyActive else { return layerPoint }
        let fp = steadyEngine.frameNormalizedPoint(fromView: viewNormalized)
        return CGPoint(x: 1 - fp.y, y: 1 - fp.x)  // portrait frame → sensor coordinates
    }

    private func focusAndExpose(at point: CGPoint) {
        let lockFocus = focusManual, lockExposure = exposureIsManual
        sessionQueue.async {
            guard let d = self.deviceInput?.device, (try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() }
            if !lockFocus, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusPointOfInterest = point
                d.focusMode = .continuousAutoFocus
            }
            if !lockExposure, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.continuousAutoExposure) {
                d.exposurePointOfInterest = point
                d.exposureMode = .continuousAutoExposure
            }
        }
    }

    private func lockFocusAndExposure(at point: CGPoint) {
        let manualFocus = focusManual, manualExposure = exposureIsManual
        aeafLocked = true
        sessionQueue.async {
            guard let d = self.deviceInput?.device, (try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() }
            if !manualFocus, d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus) {
                d.focusPointOfInterest = point
                d.focusMode = .autoFocus  // focuses once, then holds
            }
            if !manualExposure, d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose) {
                d.exposurePointOfInterest = point
                d.exposureMode = .autoExpose  // meters once, then holds
            }
        }
    }

    // MARK: - Manual controls (main)

    func label(for c: ManualControl) -> String {
        c == .ev && exposureIsManual ? "METER" : c.rawValue
    }

    func isManual(_ c: ManualControl) -> Bool {
        switch c {
        case .ev: return abs(evBias) > 0.01
        case .iso: return isoManual
        case .shutter: return shutterManual
        case .focus: return focusManual
        case .wb: return wbManual
        }
    }

    func displayValue(for c: ManualControl) -> String {
        switch c {
        case .ev: return String(format: "%+.1f", exposureIsManual ? meterOffset : evBias)
        case .iso: return "\(Int(iso.rounded()))"
        case .shutter: return Self.shutterString(shutter)
        case .focus: return focus >= 0.99 ? "∞" : String(format: "%.2f", focus)
        case .wb: return "\(Int((temperature / 50).rounded() * 50))K"
        }
    }

    static func shutterString(_ s: Double) -> String {
        if s >= 0.95 { return String(format: "%.0f\"", s) }
        if s >= 0.3 { return String(format: "%.1f\"", s) }
        return "1/\(Int((1 / max(s, 0.00001)).rounded()))"
    }

    func progress(for c: ManualControl) -> Double {
        switch c {
        case .ev:
            let span = max(evRange.upperBound - evRange.lowerBound, 0.001)
            return Double((evBias - evRange.lowerBound) / span)
        case .iso:
            return Self.logProgress(Double(iso), Double(isoRange.lowerBound), Double(isoRange.upperBound))
        case .shutter:
            return Self.logProgress(shutter, shutterRange.lowerBound, shutterRange.upperBound)
        case .focus:
            return Double(focus)
        case .wb:
            return Double((temperature - Self.wbRange.lowerBound) / (Self.wbRange.upperBound - Self.wbRange.lowerBound))
        }
    }

    func setProgress(_ raw: Double, for c: ManualControl) {
        let p = min(max(raw, 0), 1)
        switch c {
        case .ev:
            evBias = evRange.lowerBound + Float(p) * (evRange.upperBound - evRange.lowerBound)
            applyExposure()
        case .iso:
            isoManual = true
            iso = Float(Self.logValue(p, Double(isoRange.lowerBound), Double(isoRange.upperBound)))
            applyExposure()
        case .shutter:
            shutterManual = true
            shutter = Self.logValue(p, shutterRange.lowerBound, shutterRange.upperBound)
            applyExposure()
        case .focus:
            guard manualFocusSupported else { return }
            focusManual = true
            focus = Float(p)
            applyFocus()
        case .wb:
            wbManual = true
            temperature = Self.wbRange.lowerBound + Float(p) * (Self.wbRange.upperBound - Self.wbRange.lowerBound)
            applyWhiteBalance()
        }
    }

    func setAuto(_ c: ManualControl) {
        switch c {
        case .ev: evBias = 0; applyExposure()
        case .iso: isoManual = false; applyExposure()
        case .shutter: shutterManual = false; applyExposure()
        case .focus: focusManual = false; applyFocus()
        case .wb: wbManual = false; applyWhiteBalance()
        }
    }

    func resetAll() {
        evBias = 0
        isoManual = false
        shutterManual = false
        focusManual = false
        wbManual = false
        aeafLocked = false
        applyExposure()
        applyFocus()
        applyWhiteBalance()
    }

    private static func logProgress(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        guard hi > lo, lo > 0, v > 0 else { return 0 }
        return min(max(log(v / lo) / log(hi / lo), 0), 1)
    }

    private static func logValue(_ p: Double, _ lo: Double, _ hi: Double) -> Double {
        guard lo > 0, hi > lo else { return lo }
        return lo * pow(hi / lo, p)
    }

    private func applyExposure() {
        let isoM = isoManual, sM = shutterManual, isoV = iso, s = shutter, ev = evBias
        sessionQueue.async {
            guard let d = self.deviceInput?.device, (try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() }

            if isoM || sM, d.isExposureModeSupported(.custom) {
                let f = d.activeFormat
                let isoTarget = min(max(isoM ? isoV : d.iso, f.minISO), f.maxISO)
                let secs = min(max(sM ? s : d.exposureDuration.seconds, f.minExposureDuration.seconds),
                               f.maxExposureDuration.seconds)
                d.setExposureModeCustom(duration: CMTime(seconds: secs, preferredTimescale: 1_000_000_000),
                                        iso: isoTarget,
                                        completionHandler: nil)
            } else {
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                d.setExposureTargetBias(min(max(ev, d.minExposureTargetBias), d.maxExposureTargetBias),
                                        completionHandler: nil)
            }
        }
    }

    private func applyFocus() {
        let manual = focusManual, pos = focus
        sessionQueue.async {
            guard let d = self.deviceInput?.device, (try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() }
            if manual, d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: pos, completionHandler: nil)
            } else if d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
            }
        }
    }

    private func applyWhiteBalance() {
        let manual = wbManual, temp = temperature
        sessionQueue.async {
            guard let d = self.deviceInput?.device, (try? d.lockForConfiguration()) != nil else { return }
            defer { d.unlockForConfiguration() }
            if manual, d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                var g = d.deviceWhiteBalanceGains(for: .init(temperature: temp, tint: 0))
                let maxG = d.maxWhiteBalanceGain
                g.redGain = min(max(g.redGain, 1), maxG)
                g.greenGain = min(max(g.greenGain, 1), maxG)
                g.blueGain = min(max(g.blueGain, 1), maxG)
                d.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
            } else if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    // MARK: - Shutter flow (main)

    /// On-screen shutter, volume buttons and Camera Control all land here.
    func shutterPressed() {
        if countdownTimer != nil {
            cancelCountdown()
            return
        }
        guard !isBusy else { return }

        if timerSeconds > 0 {
            countdown = timerSeconds
            countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                let next = (self.countdown ?? 1) - 1
                if next <= 0 {
                    t.invalidate()
                    self.countdownTimer = nil
                    self.countdown = nil
                    self.proceedToCapture()
                } else {
                    self.countdown = next
                    Haptics.tap()
                }
            }
        } else {
            proceedToCapture()
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    private func proceedToCapture() {
        let needsStill = smartShutter && (effectiveZoom >= 3 || mode == .night)
        if needsStill {
            waitForStillness { [weak self] in self?.fire() }
        } else {
            fire()
        }
    }

    /// Smart shutter: at long zoom, wait (max 1.5 s) for a calm moment in the gyro signal.
    private func waitForStillness(_ done: @escaping () -> Void) {
        let threshold = effectiveZoom >= 10 ? 0.025 : 0.04
        if MotionHub.shared.shakeLevel < threshold {
            done()
            return
        }
        holdingSteady = true
        let start = Date()
        _ = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] t in
            if MotionHub.shared.shakeLevel < threshold || Date().timeIntervalSince(start) > 1.5 {
                t.invalidate()
                self?.holdingSteady = false
                done()
            }
        }
    }

    private func fire() {
        if mode == .night {
            startNightStack()
        } else {
            captureSingle()
        }
    }

    // MARK: - Capture (session queue)

    private func captureSingle() {
        let crop: CGFloat = (steadyActive && format == .heif) ? softCrop : 1
        let look = self.look
        let style = processing
        sessionQueue.async {
            guard self.isConfigured else { return }
            let settings = self.makeSettings()
            self.register(settings.uniqueID, .single(crop: crop, look: look, style: style))
            self.applyCaptureRotation()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: Night mode
    //
    // 1. Plan: take the auto-exposure the camera picked and push it +1.3 EV, putting as much of it
    //    as possible into exposure *time* (cleaner than ISO). Handheld frames are capped at 1/8 s to
    //    avoid blur; on a tripod (gyro says still) up to 1/2 s.
    // 2. Lock exposure, focus and white balance so every frame matches.
    // 3. Shoot the burst one frame after another; each frame is aligned and folded into a running
    //    average immediately (NightAccumulator), so memory stays low.
    // 4. Denoise, auto-brighten, lift shadows, ProCam Detail, Look → HEIF.

    private func startNightStack() {
        let crop: CGFloat = steadyActive ? softCrop : 1
        let look = self.look
        let style = processing
        let manualExposure = exposureIsManual, manualFocus = focusManual, manualWB = wbManual
        let still = MotionHub.shared.shakeLevel < 0.02
        let frames = still ? 6 : 10
        nightTotal = frames
        nightProgress = 0

        processingQueue.async { self.nightAccumulator = NightAccumulator() }

        sessionQueue.async {
            guard self.isConfigured, let d = self.deviceInput?.device else {
                DispatchQueue.main.async { self.nightProgress = nil }
                return
            }
            self.kindsLock.lock()
            self.nightReceived = 0
            self.nightTarget = frames
            self.nightCrop = crop
            self.nightLook = look
            self.nightStyle = style
            self.kindsLock.unlock()

            guard (try? d.lockForConfiguration()) != nil else {
                self.captureNightFrame()
                return
            }
            if !manualFocus, d.isFocusModeSupported(.locked) { d.focusMode = .locked }
            if !manualWB, d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }

            if !manualExposure, d.isExposureModeSupported(.custom) {
                let f = d.activeFormat
                let minDur = f.minExposureDuration.seconds
                let maxDur = max(minDur, min(f.maxExposureDuration.seconds, still ? 0.5 : 0.125))
                let minISO = Double(f.minISO), maxISO = Double(f.maxISO)
                // Exposure "amount" = ISO × seconds. Target: what AE chose, +1.3 EV.
                let target = Double(d.iso) * d.exposureDuration.seconds * pow(2, 1.3)
                let duration = min(max(target / minISO, minDur), maxDur)
                let iso = min(max(target / duration, minISO), maxISO)
                let plan = "\(CameraController.shutterString(duration)) · ISO \(Int(iso)) · \(frames) frames"
                DispatchQueue.main.async { self.nightPlan = plan }

                d.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000_000),
                                        iso: Float(iso)) { _ in
                    // Wait one more frame so the new exposure is in effect.
                    self.sessionQueue.asyncAfter(deadline: .now() + duration + 0.05) {
                        self.captureNightFrame()
                    }
                }
                d.unlockForConfiguration()
            } else {
                if d.isExposureModeSupported(.locked) && !manualExposure { d.exposureMode = .locked }
                d.unlockForConfiguration()
                DispatchQueue.main.async { self.nightPlan = "\(frames) frames" }
                self.sessionQueue.asyncAfter(deadline: .now() + 0.1) { self.captureNightFrame() }
            }
        }
    }

    private func captureNightFrame() {
        let s = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        s.photoQualityPrioritization = .speed
        s.maxPhotoDimensions = nightDimensions ?? photoOutput.maxPhotoDimensions
        register(s.uniqueID, .night)
        applyCaptureRotation()
        photoOutput.capturePhoto(with: s, delegate: self)
    }

    private func finishNight() {
        kindsLock.lock()
        let crop = nightCrop, look = nightLook, style = nightStyle, total = nightTarget
        kindsLock.unlock()

        DispatchQueue.main.async {
            self.nightProgress = nil
            self.nightPlan = nil
            self.isMerging = true
            self.applyExposure()
            self.applyFocus()
            self.applyWhiteBalance()
        }

        // Queued after every frame's add(), so all frames are merged by the time this runs.
        processingQueue.async {
            defer { DispatchQueue.main.async { self.isMerging = false } }
            let acc = self.nightAccumulator
            self.nightAccumulator = nil
            guard let acc, acc.count > 0 else {
                self.showToast("Night mode failed: no usable frames")
                return
            }
            guard let data = acc.finish(crop: crop, look: look, style: style) else {
                self.showToast("Night mode failed while saving")
                return
            }
            let used = acc.count
            let thumb = Self.makeThumbnail(data)
            DispatchQueue.main.async { self.lastThumbnail = thumb }
            PhotoLibrary.save(photo: data, raw: nil) { [weak self] ok in
                self?.showToast(ok ? "Night photo saved · \(used)/\(total) frames merged"
                                   : "Couldn't save. Allow Photos access in Settings.")
            }
        }
    }

    private func applyCaptureRotation() {
        guard let c = photoOutput.connection(with: .video) else { return }
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        if c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
    }

    private func makeSettings() -> AVCapturePhotoSettings {
        let rawTypes = photoOutput.availableRawPhotoPixelFormatTypes

        switch sessionFormat {
        case .proRAW:
            if photoOutput.isAppleProRAWEnabled,
               let t = rawTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                let s = AVCapturePhotoSettings(rawPixelFormatType: t)
                s.photoQualityPrioritization = .quality
                s.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                return s
            }
        case .raw:
            if let t = rawTypes.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) }) {
                let s = AVCapturePhotoSettings(rawPixelFormatType: t)
                s.photoQualityPrioritization = .speed
                return s
            }
        case .heif:
            break
        }

        let s = photoOutput.availablePhotoCodecTypes.contains(.hevc)
            ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            : AVCapturePhotoSettings()
        s.photoQualityPrioritization = .quality
        s.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        return s
    }

    private func register(_ id: Int64, _ kind: CaptureKind) {
        kindsLock.lock()
        captureKinds[id] = kind
        kindsLock.unlock()
    }

    private func kind(for id: Int64) -> CaptureKind? {
        kindsLock.lock()
        defer { kindsLock.unlock() }
        return captureKinds[id]
    }

    static func makeThumbnail(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.toast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if self.toast == text { self.toast = nil }
            }
        }
    }
}

// MARK: - Photo delegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if case .night? = kind(for: resolvedSettings.uniqueID) { return }
        DispatchQueue.main.async { self.shutterTick += 1 }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let kind = self.kind(for: photo.resolvedSettings.uniqueID)
        let data = error == nil ? photo.fileDataRepresentation() : nil

        if case .night? = kind {
            if let data {
                processingQueue.async { self.nightAccumulator?.add(data) }
            }
            kindsLock.lock()
            nightReceived += 1
            let received = nightReceived, target = nightTarget
            kindsLock.unlock()
            DispatchQueue.main.async { self.nightProgress = received }
            if received < target {
                sessionQueue.async { self.captureNightFrame() }
            } else {
                finishNight()
            }
            return
        }

        guard let data else {
            showToast("Capture failed: " + (error?.localizedDescription ?? "no image data"))
            return
        }

        let isRaw = photo.isRawPhoto
        var crop: CGFloat = 1
        var look: Look = .natural
        var style: ProcessingStyle = .apple
        if case .single(let c, let l, let st)? = kind {
            crop = c
            look = l
            style = st
        }

        processingQueue.async {
            var heif: Data?
            var raw: Data?
            if isRaw {
                raw = data
                // ProCam develops its own HEIF from the RAW; the DNG is kept alongside it.
                if style != .apple {
                    heif = PhotoProcessor.develop(raw: data, look: look, style: style)
                    if heif == nil { self.showToast("RAW develop failed. Saved the DNG only.") }
                }
            } else {
                heif = PhotoProcessor.process(data, crop: crop, look: look, style: style)
            }
            let thumb = Self.makeThumbnail(heif ?? data)
            DispatchQueue.main.async { self.lastThumbnail = thumb }
            PhotoLibrary.save(photo: heif, raw: raw) { [weak self] ok in
                if !ok { self?.showToast("Couldn't save. Allow Photos access in Settings.") }
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        kindsLock.lock()
        captureKinds[resolvedSettings.uniqueID] = nil
        kindsLock.unlock()
    }
}

// MARK: - Per-frame pipeline

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let cfg = pipeline
        let frame = CIImage(cvPixelBuffer: pb)
        var display = frame

        if cfg.steady {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let out = steadyEngine.process(frame, time: time, softCrop: cfg.softCrop)
            display = out.image
            if out.lockBox != lastLockBox || out.lostLock {
                lastLockBox = out.lockBox
                let box = out.lockBox, lost = out.lostLock
                DispatchQueue.main.async {
                    self.lockBox = box
                    if lost { self.showToast("Subject lost") }
                }
            }
        }

        if cfg.processed {
            renderer.render(cfg.look == .natural ? display : cfg.look.apply(display))
        }

        frameIndex &+= 1
        guard frameIndex % 2 == 0, cfg.histogram || cfg.peaking || cfg.zebra else { return }
        let result = analyzer.analyze(display, histogram: cfg.histogram, peaking: cfg.peaking, zebra: cfg.zebra)
        DispatchQueue.main.async {
            if let h = result.histogram { self.histogram = h }
            self.overlayImage = (self.peakingActive || self.showZebras) ? result.overlay : nil
        }
    }
}
