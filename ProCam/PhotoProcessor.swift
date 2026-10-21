import CoreImage
import ImageIO
import Vision

// MARK: - Processing style

enum ProcessingStyle: String, CaseIterable, Identifiable {
    case apple = "Apple"
    case natural = "ProCam Natural"
    case strong = "ProCam Strong"

    var id: String { rawValue }

    /// Strength of the ProCam Detail pass (0 = off).
    var detail: Float {
        switch self {
        case .apple: return 0
        case .natural: return 0.55
        case .strong: return 1.0
        }
    }
}

// MARK: - ProCam Detail

/// ProCam's own finishing pass:
///  1. Local tone: lift shadows, pull back highlights.
///  2. Clarity: large-radius unsharp mask = local (mid-tone) contrast, the "3D pop".
///  3. Edge-aware fine detail: sharpen only where there are real edges, so skies,
///     skin and noise in flat areas stay clean instead of getting crunchy.
///  4. A touch of vibrance.
/// Radii scale with resolution so 12 MP and 48 MP photos look the same.
enum DetailEngine {
    static func enhance(_ input: CIImage, strength raw: Float) -> CIImage {
        let s = max(0, min(raw, 1.5))
        guard s > 0.01 else { return input }
        let extent = input.extent
        let k = Float(max(extent.width, extent.height) / 4032)

        // 1. Local tone
        var img = input.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputRadius": 12 * k,
            "inputShadowAmount": 0.22 * s,
            "inputHighlightAmount": 1 - 0.12 * s
        ]).cropped(to: extent)

        // 2. Clarity
        img = img.clampedToExtent()
            .applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 28 * k,
                kCIInputIntensityKey: 0.3 * s
            ])
            .cropped(to: extent)

        // 3. Edge-aware fine detail
        let sharpened = img.clampedToExtent()
            .applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 1.4 * k,
                kCIInputIntensityKey: 0.75 * s
            ])
            .cropped(to: extent)
        let edgeMask = img
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 5])
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.5 * k])
            .applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
            .cropped(to: extent)
        img = sharpened.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: img,
            kCIInputMaskImageKey: edgeMask
        ]).cropped(to: extent)

        // 4. Vibrance
        img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.18 * s])
        return img.cropped(to: extent)
    }
}

// MARK: - Photo processing

enum PhotoProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// HEIF from the camera → SteadyZoom crop + ProCam Detail + Look. Returns the original when there's nothing to do.
    static func process(_ data: Data, crop: CGFloat, look: Look, style: ProcessingStyle) -> Data {
        guard crop > 1.001 || look != .natural || style.detail > 0,
              let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }
        return render(image, properties: image.properties, crop: crop, look: look, detail: style.detail) ?? data
    }

    /// RAW / ProRAW DNG → ProCam's own development → HEIF.
    static func develop(raw: Data, look: Look, style: ProcessingStyle) -> Data? {
        guard let f = CIRAWFilter(imageData: raw, identifierHint: "com.adobe.raw-image") else { return nil }
        let properties = CIImage(data: raw)?.properties ?? [:]
        let s = style.detail

        // Higher ISO → more noise reduction
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let iso = Float((exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first?.floatValue ?? 100)
        let noise = min(max((iso - 80) / 3000, 0), 1)

        if f.isLocalToneMapSupported { f.localToneMapAmount = 0.45 + 0.25 * s }
        if f.isLuminanceNoiseReductionSupported { f.luminanceNoiseReductionAmount = 0.12 + 0.55 * noise }
        if f.isColorNoiseReductionSupported { f.colorNoiseReductionAmount = 0.45 + 0.35 * noise }
        if f.isSharpnessSupported { f.sharpnessAmount = 0.45 }
        if f.isDetailSupported { f.detailAmount = 0.5 + 0.3 * s }
        if f.isMoireReductionSupported { f.moireReductionAmount = 0.5 }
        if f.isLensCorrectionSupported { f.isLensCorrectionEnabled = true }

        guard let developed = f.outputImage else { return nil }
        let normalized = developed.transformed(by: CGAffineTransform(translationX: -developed.extent.minX,
                                                                     y: -developed.extent.minY))
        return render(normalized, properties: properties, crop: 1, look: look, detail: s * 0.7)
    }

    static func render(_ input: CIImage, properties: [String: Any], crop: CGFloat, look: Look, detail: Float) -> Data? {
        var image = input
        if crop > 1.001 {
            let e = image.extent
            let w = e.width / crop
            let h = e.height / crop
            let rect = CGRect(x: e.midX - w / 2, y: e.midY - h / 2, width: w, height: h).integral
            image = image.cropped(to: rect)
                .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        let extent = image.extent
        image = DetailEngine.enhance(image, strength: detail)
        image = look.apply(image).cropped(to: extent)

        // Pixels are upright now, so reset the orientation tags.
        var props = properties
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        props.removeValue(forKey: kCGImagePropertyDNGDictionary as String)
        image = image.settingProperties(props)

        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: [quality: 0.93])
    }
}

// MARK: - Night mode

/// Streaming night merge: each frame is aligned to the first one and folded into a
/// running average as soon as it arrives, so only ~2 full-size buffers are ever in memory.
/// Averaging N aligned frames cuts random noise by about √N.
/// Use from a single serial queue.
final class NightAccumulator {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private var accum: CGImage?
    private var referenceSmall: CIImage?
    private var extent = CGRect.zero
    private var smallScale: CGFloat = 1
    private(set) var count = 0
    private(set) var properties: [String: Any] = [:]

    func add(_ data: Data) {
        guard let decoded = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return }
        let frame = decoded.transformed(by: CGAffineTransform(translationX: -decoded.extent.minX,
                                                              y: -decoded.extent.minY))

        guard let previous = accum, let reference = referenceSmall else {
            extent = frame.extent
            properties = decoded.properties
            smallScale = 640 / max(extent.width, extent.height)
            referenceSmall = small(frame)
            accum = materialize(frame)
            count = accum == nil ? 0 : 1
            return
        }
        guard frame.extent.size == extent.size else { return }

        // Align to the first frame
        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: small(frame) ?? frame)
        try? VNImageRequestHandler(ciImage: reference, options: [:]).perform([request])
        guard let t = request.results?.first?.alignmentTransform else { return }
        let dx = t.tx / smallScale
        let dy = t.ty / smallScale
        guard abs(dx) < extent.width * 0.06, abs(dy) < extent.height * 0.06 else { return }  // bumped: skip
        let aligned = frame.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: extent)

        // Running average: avg = avg·(n−1)/n + frame/n
        let n = CGFloat(count + 1)
        let blended = scaled(aligned, 1 / n)
            .applyingFilter("CIAdditionCompositing", parameters: [
                kCIInputBackgroundImageKey: scaled(CIImage(cgImage: previous), (n - 1) / n)
            ])
            .cropped(to: extent)
        if let next = materialize(blended) {
            accum = next
            count += 1
        }
    }

    /// Final image: denoise, auto-brighten towards a natural night exposure, lift shadows, Detail, Look.
    func finish(crop: CGFloat, look: Look, style: ProcessingStyle) -> Data? {
        guard let accum else { return nil }
        var img = CIImage(cgImage: accum)

        img = img.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.012,
            "inputSharpness": 0.5
        ]).cropped(to: extent)

        // Brighten dark results (up to +1.6 EV). Clean, stacked frames can take the push.
        let luma = averageLuminance(img)
        let ev = max(0, min(log2(0.13 / max(luma, 0.0005)), 1.6))
        if ev > 0.05 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        }
        img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputShadowAmount": 0.3,
            "inputHighlightAmount": 0.75
        ]).cropped(to: extent)

        return PhotoProcessor.render(img, properties: properties, crop: crop, look: look,
                                     detail: max(style.detail, 0.3) * 0.6)
    }

    // MARK: Helpers

    private func materialize(_ image: CIImage) -> CGImage? {
        context.createCGImage(image, from: extent, format: .RGBAh, colorSpace: linear, deferred: false)
            ?? context.createCGImage(image, from: extent, format: .RGBA8,
                                     colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, deferred: false)
    }

    private func small(_ image: CIImage) -> CIImage? {
        let gray = image
            .transformed(by: CGAffineTransform(scaleX: smallScale, y: smallScale))
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let cg = context.createCGImage(gray, from: gray.extent.integral) else { return nil }
        return CIImage(cgImage: cg)
    }

    private func scaled(_ image: CIImage, _ k: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    /// Mean linear luminance (0…1).
    private func averageLuminance(_ image: CIImage) -> Double {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ])
        var px = [Float](repeating: 0, count: 4)
        context.render(avg, toBitmap: &px, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
        return Double(0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2])
    }
}
