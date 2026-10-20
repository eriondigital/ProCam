import CoreImage
import CoreImage.CIFilterBuiltins

/// GPU analysis of viewfinder frames: RGB histogram, focus peaking and zebra stripes.
final class FrameAnalyzer {
    struct Result {
        var histogram: [[Float]]?
        /// Peaking + zebras composited into one transparent image.
        var overlay: CGImage?
    }

    static let bins = 64

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false
    ])

    func analyze(_ image: CIImage, histogram wantHistogram: Bool, peaking wantPeaking: Bool, zebra wantZebra: Bool) -> Result {
        let ext = image.extent
        guard ext.width > 0, ext.width.isFinite else { return Result() }

        let downscale = CIFilter.lanczosScaleTransform()
        downscale.inputImage = image.transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
        downscale.scale = Float(min(720 / ext.width, 1))
        downscale.aspectRatio = 1
        guard let small = downscale.outputImage else { return Result() }

        var result = Result()
        if wantHistogram { result.histogram = histogram(small) }

        if wantPeaking || wantZebra {
            var overlay: CIImage?
            if wantZebra { overlay = zebra(small) }
            if wantPeaking {
                let peak = peaking(small)
                overlay = overlay.map { peak.composited(over: $0) } ?? peak
            }
            if let overlay {
                result.overlay = context.createCGImage(overlay, from: small.extent.integral)
            }
        }
        return result
    }

    private func histogram(_ img: CIImage) -> [[Float]]? {
        let n = Self.bins
        let f = CIFilter.areaHistogram()
        f.inputImage = img
        f.extent = img.extent
        f.count = n
        f.scale = 1
        guard let out = f.outputImage else { return nil }

        var px = [Float](repeating: 0, count: n * 4)
        context.render(out,
                       toBitmap: &px,
                       rowBytes: n * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: 0, y: 0, width: n, height: 1),
                       format: .RGBAf,
                       colorSpace: nil)

        var channels = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
        for i in 0..<n {
            for c in 0..<3 { channels[c][i] = px[i * 4 + c] }
        }
        let peak = max(channels.flatMap { $0 }.max() ?? 0, Float.leastNonzeroMagnitude)
        return channels.map { $0.map { ($0 / peak).squareRoot() } }
    }

    private func peaking(_ img: CIImage) -> CIImage {
        let luma = img.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.1
        ])
        let edges = luma.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 6.0])
        let mask = edges.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.32])
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0.48, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0.1, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ]).cropped(to: img.extent)
    }

    /// Diagonal stripes over blown-out highlights.
    private func zebra(_ img: CIImage) -> CIImage {
        let luma = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let mask = luma.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.96])

        let stripes = CIFilter.stripesGenerator()
        stripes.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0.85)
        stripes.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        stripes.width = 5
        stripes.sharpness = 1
        let pattern = (stripes.outputImage ?? CIImage.empty())
            .transformed(by: CGAffineTransform(rotationAngle: .pi / 4))
            .cropped(to: img.extent)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = pattern
        blend.backgroundImage = CIImage(color: .clear).cropped(to: img.extent)
        blend.maskImage = mask
        return (blend.outputImage ?? CIImage.empty()).cropped(to: img.extent)
    }
}
