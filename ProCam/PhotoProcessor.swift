import CoreImage
import ImageIO
import Vision

/// Post-processing for captured HEIF photos: SteadyZoom crop + Look.
enum PhotoProcessor {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Returns the original data untouched when there's nothing to do.
    static func process(_ data: Data, crop: CGFloat, look: Look) -> Data {
        guard crop > 1.001 || look != .natural,
              let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else { return data }
        return render(image, properties: image.properties, crop: crop, look: look) ?? data
    }

    static func render(_ input: CIImage, properties: [String: Any], crop: CGFloat, look: Look) -> Data? {
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
        image = look.apply(image).cropped(to: extent)

        // Pixels are now upright, so reset the orientation tags.
        var props = properties
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        image = image.settingProperties(props)

        let colorSpace = input.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: [quality: 0.92])
    }
}

/// Night Stack: aligns a burst of frames and averages them.
/// Averaging N aligned frames cuts random noise by about √N (8 frames ≈ 2.8× cleaner).
enum NightStacker {
    static func merge(_ frames: [Data]) -> (image: CIImage, properties: [String: Any])? {
        let images = frames.compactMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
        guard let reference = images.first else { return nil }
        guard images.count > 1 else { return (reference, reference.properties) }

        let extent = reference.extent
        let s = 512 / max(extent.width, 1)
        func small(_ i: CIImage) -> CIImage {
            i.transformed(by: CGAffineTransform(scaleX: s, y: s))
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        }

        let others = Array(images.dropFirst())
        let requests = others.map { VNTranslationalImageRegistrationRequest(targetedCIImage: small($0)) }
        let handler = VNImageRequestHandler(ciImage: small(reference), options: [:])
        try? handler.perform(requests)

        var aligned: [CIImage] = [reference]
        for (image, request) in zip(others, requests) {
            guard let t = request.results?.first?.alignmentTransform else { continue }
            let dx = t.tx / s
            let dy = t.ty / s
            // Skip frames that moved too far (probably a bad match or a bump)
            guard abs(dx) < extent.width * 0.08, abs(dy) < extent.height * 0.08 else { continue }
            aligned.append(image.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: extent))
        }

        let k = CGFloat(1) / CGFloat(aligned.count)
        func weighted(_ i: CIImage) -> CIImage {
            i.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: k),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        }

        var sum = weighted(aligned[0])
        for image in aligned.dropFirst() {
            sum = weighted(image).applyingFilter("CIAdditionCompositing",
                                                 parameters: [kCIInputBackgroundImageKey: sum])
        }

        let result = sum.cropped(to: extent)
            .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.3])
            .cropped(to: extent)
        return (result, reference.properties)
    }
}
