import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Live preview + processed (stabilised / Look) layer on top, with gestures and hardware shutter.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let renderer: ViewfinderRenderer
    var showProcessed: Bool
    /// (device point from the preview layer, view point, view point normalised 0…1)
    var onTap: (CGPoint, CGPoint, CGPoint) -> Void
    var onLongPress: (CGPoint, CGPoint, CGPoint) -> Void
    /// (scale, began)
    var onPinch: (CGFloat, Bool) -> Void
    /// Volume buttons / Camera Control
    var onHardwareShutter: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        renderer.attach(view.processedView.displayLayer)
        context.coordinator.view = view

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(pinch)

        if #available(iOS 17.2, *) {
            let coordinator = context.coordinator
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .ended { coordinator.onHardwareShutter?() }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onPinch = onPinch
        context.coordinator.onHardwareShutter = onHardwareShutter
        view.processedView.isHidden = !showProcessed
    }

    final class Coordinator: NSObject {
        weak var view: PreviewUIView?
        var onTap: ((CGPoint, CGPoint, CGPoint) -> Void)?
        var onLongPress: ((CGPoint, CGPoint, CGPoint) -> Void)?
        var onPinch: ((CGFloat, Bool) -> Void)?
        var onHardwareShutter: (() -> Void)?

        private func points(_ g: UIGestureRecognizer) -> (CGPoint, CGPoint, CGPoint)? {
            guard let view else { return nil }
            let p = g.location(in: view)
            let n = CGPoint(x: p.x / max(view.bounds.width, 1), y: p.y / max(view.bounds.height, 1))
            return (view.previewLayer.captureDevicePointConverted(fromLayerPoint: p), p, n)
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let pts = points(g) else { return }
            onTap?(pts.0, pts.1, pts.2)
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let pts = points(g) else { return }
            onLongPress?(pts.0, pts.1, pts.2)
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: onPinch?(g.scale, true)
            case .changed: onPinch?(g.scale, false)
            default: break
            }
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    let processedView = SampleBufferView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        processedView.isUserInteractionEnabled = false
        processedView.isHidden = true
        processedView.backgroundColor = .black
        addSubview(processedView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        processedView.frame = bounds
        if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
            c.videoRotationAngle = 90
        }
    }
}
