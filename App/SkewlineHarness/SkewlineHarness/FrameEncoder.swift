import Capture
import Core
import CoreImage
import CoreVideo
import Foundation
import ImageIO

/// Turns one `CameraFrame` into the payload the container stores and the
/// `FrameRecord` describing it.
///
/// Owns its `CIContext`, created once: a context per frame would be setup cost
/// masquerading as encode cost in the probe's numbers.
///
/// The knobs are configuration values, not decisions. What they cost -- encode
/// time, bytes per frame -- is not measured yet; the probe run measures it,
/// and v0.4 sets the defaults from what it finds.
///
/// `nonisolated` because the app target defaults to `MainActor`, and this
/// type belongs to the drain task, not the UI.
nonisolated struct FrameEncoder {
    enum Failure: Error {
        case encodeFailed(FrameEncoding)
        case unsupportedEncoding(FrameEncoding)
    }

    let encoding: FrameEncoding
    /// Lossy compression quality handed to ImageIO, 0...1.
    let quality: Double

    private let context = CIContext()
    private let colorSpace: CGColorSpace

    init(encoding: FrameEncoding = .jpeg, quality: Double = 0.7) {
        self.encoding = encoding
        // The output file's color space, not a claim about the camera's.
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.quality = quality
    }

    func encode(_ frame: CameraFrame) throws -> (record: FrameRecord, data: Data) {
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let options = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]

        let data: Data?
        switch encoding {
        case .jpeg:
            data = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
        case .heic:
            data = context.heifRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace, options: options)
        default:
            throw Failure.unsupportedEncoding(encoding)
        }
        guard let data else {
            throw Failure.encodeFailed(encoding)
        }

        let record = FrameRecord(
            timestamp: frame.timestamp,
            width: CVPixelBufferGetWidth(frame.pixelBuffer),
            height: CVPixelBufferGetHeight(frame.pixelBuffer),
            encoding: encoding,
            exposure: ExposureRecord(duration: frame.exposureDuration, offset: frame.exposureOffset)
        )
        return (record, data)
    }
}
