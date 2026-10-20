import AVFoundation
import CoreImage
import CoreMedia
import Metal
import UIKit

/// View backed by an AVSampleBufferDisplayLayer: shows processed frames
/// (stabilised and/or with a Look) on top of the normal preview.
final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Renders CIImages into pixel buffers and enqueues them for display.
/// `render` is called from the analysis queue; `attach`/`flush` from main.
final class ViewfinderRenderer {
    static let outputSize = CGSize(width: 1080, height: 1440)

    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let lock = NSLock()
    private var videoRenderer: AVSampleBufferVideoRenderer?

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(Self.outputSize.width),
            kCVPixelBufferHeightKey as String: Int(Self.outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        layer.videoGravity = .resizeAspectFill
        lock.lock()
        videoRenderer = layer.sampleBufferRenderer
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let r = videoRenderer
        lock.unlock()
        r?.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func render(_ image: CIImage) {
        lock.lock()
        let r = videoRenderer
        lock.unlock()
        guard let r, let pool else { return }

        let ext = image.extent
        guard ext.width > 0, ext.height > 0, ext.width.isFinite, ext.height.isFinite else { return }

        var bufferOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut) == kCVReturnSuccess,
              let buffer = bufferOut else { return }

        // Aspect-fill into the output buffer
        let size = Self.outputSize
        let scale = max(size.width / ext.width, size.height / ext.height)
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -ext.minX, y: -ext.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: (size.width - ext.width * scale) / 2,
                                               y: (size.height - ext.height * scale) / 2))
        context.render(placed, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)

        if formatDescription == nil
            || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: buffer) {
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &fd)
            formatDescription = fd
        }
        guard let fd = formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleOut: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil,
                                                 imageBuffer: buffer,
                                                 formatDescription: fd,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sampleOut)
        guard let sample = sampleOut else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if r.status == .failed { r.flush() }
        if r.isReadyForMoreMediaData { r.enqueue(sample) }
    }
}
