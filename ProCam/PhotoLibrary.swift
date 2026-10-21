import Foundation
import Photos

enum PhotoLibrary {
    /// Saves a HEIF and/or a DNG. When both are given they're stored as one RAW+HEIF photo
    /// (the HEIF shows in Photos, the DNG travels with it for editing).
    static func save(photo: Data?, raw: Data?, completion: @escaping (Bool) -> Void) {
        guard photo != nil || raw != nil else {
            completion(false)
            return
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let rawOptions = PHAssetResourceCreationOptions()
                rawOptions.uniformTypeIdentifier = "com.adobe.raw-image"
                if let photo {
                    request.addResource(with: .photo, data: photo, options: nil)
                    if let raw { request.addResource(with: .alternatePhoto, data: raw, options: rawOptions) }
                } else if let raw {
                    request.addResource(with: .photo, data: raw, options: rawOptions)
                }
            }, completionHandler: { success, _ in
                completion(success)
            })
        }
    }
}
