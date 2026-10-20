import CoreImage

/// Colour looks, applied live in the viewfinder and baked into HEIF photos.
enum Look: String, CaseIterable, Identifiable {
    case natural = "Natural"
    case vivid = "Vivid"
    case warmFilm = "Warm Film"
    case coolMatte = "Cool Matte"
    case mono = "Mono"
    case noir = "Noir"

    var id: String { rawValue }

    func apply(_ image: CIImage) -> CIImage {
        switch self {
        case .natural:
            return image

        case .vivid:
            return image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.5])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.08,
                    kCIInputSaturationKey: 1.05
                ])

        case .warmFilm:
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.06, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.88, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0.015, y: 0.01, z: 0, w: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.9,
                    kCIInputContrastKey: 0.96
                ])

        case .coolMatte:
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.94, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.06, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputBiasVector": CIVector(x: 0.02, y: 0.02, z: 0.025, w: 0)
                ])
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.82,
                    kCIInputContrastKey: 0.94
                ])

        case .mono:
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.12
            ])

        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        }
    }
}
