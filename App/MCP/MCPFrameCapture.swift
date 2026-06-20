import CoreImage
import Foundation
import WebRTC

/// Receives decoded video frames from an RTCVideoTrack and exposes a
/// JPEG snapshot on demand. Conforms to RTCVideoRenderer so it can be
/// added directly to a track with `track.add(frameCapture)`.
///
/// RTCVideoRenderer callbacks arrive on WebRTC's internal queue;
/// we hop to @MainActor before mutating any stored state.
@MainActor
final class MCPFrameCapture: NSObject, RTCVideoRenderer {
    private(set) var currentSize: CGSize = .zero
    private var latestPixelBuffer: CVPixelBuffer?

    // CIContext is expensive to create; share one instance.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Track lifecycle

    func attach(to track: RTCVideoTrack) {
        track.add(self)
    }

    func detach(from track: RTCVideoTrack) {
        track.remove(self)
        latestPixelBuffer = nil
        currentSize = .zero
    }

    // MARK: - RTCVideoRenderer (nonisolated — called on WebRTC queue)

    nonisolated func setSize(_ size: CGSize) {
        Task { @MainActor [weak self] in
            self?.currentSize = size
        }
    }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let cvBuf = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else { return }
        Task { @MainActor [weak self] in
            self?.latestPixelBuffer = cvBuf
        }
    }

    // MARK: - Snapshot

    /// Encode the latest frame as JPEG.
    /// - Parameters:
    ///   - quality: Compression quality 1–100. Default 65.
    ///   - maxWidth: Downscale to this width (0 = full resolution). Default 1280.
    /// - Returns: JPEG data, or nil if no frame has been received yet.
    func captureJPEG(quality: Int = 65, maxWidth: Int = 1280) -> Data? {
        guard let pb = latestPixelBuffer else { return nil }
        var ci = CIImage(cvPixelBuffer: pb)
        if maxWidth > 0, ci.extent.width > CGFloat(maxWidth) {
            let scale = CGFloat(maxWidth) / ci.extent.width
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let clampedQuality = Double(min(100, max(1, quality))) / 100.0
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return Self.ciContext.jpegRepresentation(
            of: ci,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: clampedQuality]
        )
    }
}
