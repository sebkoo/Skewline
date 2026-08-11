import Capture
import Core
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd

/// Turns one `CameraFrame` into the payload the container stores and the
/// `FrameRecord` describing it.
///
/// Owns its `CIContext`, created once: a context per frame would be setup cost
/// masquerading as encode cost in the probe's numbers.
///
/// The knobs are chosen from device measurements, not left as starting
/// points. v0.4 ran a device matrix against the frame-drop criterion in
/// `VideoCaptureConfiguration`'s doc comment: HEIC failed it chronically --
/// its own encode cost exceeds the keep budget -- so JPEG held. Quality is
/// chosen on bytes per frame and a visual check of extracted frames, not a
/// render-adequacy check -- nothing downstream decodes these pixels today,
/// so this default is provisional by consumer absence, worth revisiting the
/// day something reads them. See DEVLOG, "the knobs get their defaults."
///
/// `nonisolated` because the app target defaults to `MainActor`, and this
/// type belongs to the drain task, not the UI.
nonisolated struct FrameEncoder {
    enum Failure: Error {
        case encodeFailed(FrameEncoding)
        case unsupportedEncoding(FrameEncoding)
        /// `CameraFrame.intrinsics` did not match the pinhole model's shape
        /// -- a non-zero entry where the model guarantees zero, or a last
        /// diagonal entry other than one. `IntrinsicsRecord` keeps only the
        /// four entries the model lets vary, so a matrix that fails this
        /// check is a matrix nothing here should describe.
        case unexpectedIntrinsicsShape(simd_float3x3)
    }

    let encoding: FrameEncoding
    /// Lossy compression quality handed to ImageIO, 0...1.
    let quality: Double

    private let context = CIContext()
    private let colorSpace: CGColorSpace

    init(encoding: FrameEncoding = .jpeg, quality: Double = 0.5) {
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
            exposure: ExposureRecord(duration: frame.exposureDuration, offset: frame.exposureOffset),
            intrinsics: try intrinsicsRecord(from: frame.intrinsics, referenceSize: frame.intrinsicsReferenceSize)
        )
        return (record, data)
    }

    /// Verifies `intrinsics` matches the pinhole model's shape -- the entries
    /// `IntrinsicsRecord` does not keep are checked here rather than assumed,
    /// the same move `DepthEncoder` makes for pixel format -- and returns the
    /// four entries that vary, at the resolution they were computed for.
    private func intrinsicsRecord(
        from intrinsics: simd_float3x3,
        referenceSize: CGSize
    ) throws -> IntrinsicsRecord {
        guard intrinsics[0][1] == 0, intrinsics[0][2] == 0,
              intrinsics[1][0] == 0, intrinsics[1][2] == 0,
              intrinsics[2][2] == 1 else {
            throw Failure.unexpectedIntrinsicsShape(intrinsics)
        }
        return IntrinsicsRecord(
            focalLengthX: intrinsics[0][0],
            focalLengthY: intrinsics[1][1],
            principalPointX: intrinsics[2][0],
            principalPointY: intrinsics[2][1],
            referenceWidth: Int(referenceSize.width),
            referenceHeight: Int(referenceSize.height)
        )
    }
}
