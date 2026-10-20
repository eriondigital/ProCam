import SwiftUI

@main
struct ProCamApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
