import Foundation
import Photos

enum PhotoLibrary {
    /// Saves HEIF or DNG data straight into the Photos library.
    static func save(_ data: Data, isRaw: Bool, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(false)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                if isRaw { options.uniformTypeIdentifier = "com.adobe.raw-image" } // DNG
                request.addResource(with: .photo, data: data, options: options)
            }, completionHandler: { success, _ in
                completion(success)
            })
        }
    }
}
