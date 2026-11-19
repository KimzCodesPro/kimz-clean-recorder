import ScreenCaptureKit
import AppKit

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let pixelWidth: Int
    let pixelHeight: Int
    var thumbnail: CGImage?

    static func == (a: DisplayInfo, b: DisplayInfo) -> Bool {
        a.id == b.id && a.pixelWidth == b.pixelWidth && a.thumbnail === b.thumbnail
    }

    static func make(from display: SCDisplay) -> DisplayInfo {
        let (w, h) = pixelSize(display)
        return DisplayInfo(id: display.displayID, name: name(for: display.displayID),
                           pixelWidth: w, pixelHeight: h, thumbnail: nil)
    }

    /// Native pixel size (Retina), rounded to even numbers for the encoder.
    static func pixelSize(_ display: SCDisplay) -> (Int, Int) {
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            return (mode.pixelWidth & ~1, mode.pixelHeight & ~1)
        }
        return (display.width * 2, display.height * 2)
    }

    static func name(for id: CGDirectDisplayID) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? "Display \(id)"
    }
}

/// Streams one display as video frames (420v, BT.709) on the host clock.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onError: (@Sendable (Error) -> Void)?

    private var stream: SCStream?
    private var onFrame: (@Sendable (CMSampleBuffer) -> Void)?
    private let queue = DispatchQueue(label: "clean-recorder.screen", qos: .userInitiated)

    func start(filter: SCContentFilter, width: Int, height: Int, fps: Int, showsCursor: Bool,
               onFrame: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = showsCursor
        cfg.queueDepth = 6

        self.onFrame = onFrame
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        onFrame = nil
    }

    static func thumbnail(of display: SCDisplay) async -> CGImage? {
        let cfg = SCStreamConfiguration()
        cfg.width = 320
        cfg.height = max(2, Int(320 * Double(display.height) / Double(max(display.width, 1))))
        cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: cfg)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete else { return }
        onFrame?(sb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}
