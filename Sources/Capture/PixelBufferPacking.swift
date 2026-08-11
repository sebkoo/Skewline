import CoreVideo
import Foundation

/// Turns a single-plane pixel buffer into tight-packed bytes: rows top to
/// bottom with the row padding stripped, so the result is exactly
/// width × height × bytesPerPixel and can be described without a stride
/// field.
///
/// Outside the ARKit gate deliberately. CoreVideo compiles on macOS, and this
/// is the loop that shears an image whenever two strides disagree -- the
/// hardware-free suite must be able to prove it against a synthetic padded
/// buffer, rather than leaving it in the one component `swift test` never
/// compiles.
public enum PixelBufferPacking {
    public enum Failure: Error, Equatable {
        /// The buffer is planar; this routine packs exactly one plane's rows
        /// and refuses a buffer whose layout it would misread.
        case planarBufferUnsupported
        /// The claimed pixel size makes a row wider than the buffer's own
        /// stride -- the claim is wrong, and reading it would run past the
        /// allocation.
        case bytesPerPixelExceedsStride(bytesPerPixel: Int, bytesPerRow: Int)
        /// The buffer's base address could not be read.
        case baseAddressUnavailable
    }

    /// The buffer's pixels with row padding removed.
    ///
    /// `bytesPerPixel` is the caller's claim about the buffer's pixel format;
    /// this routine checks it against the stride but cannot check it against
    /// the format itself -- verifying the format is the caller's job, done
    /// where the expected formats are known.
    public static func tightlyPackedData(from buffer: CVPixelBuffer, bytesPerPixel: Int) throws -> Data {
        precondition(bytesPerPixel >= 1, "bytesPerPixel must be at least 1")
        guard !CVPixelBufferIsPlanar(buffer) else {
            throw Failure.planarBufferUnsupported
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rowBytes = width * bytesPerPixel
        guard rowBytes <= stride else {
            throw Failure.bytesPerPixelExceedsStride(bytesPerPixel: bytesPerPixel, bytesPerRow: stride)
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw Failure.baseAddressUnavailable
        }

        if stride == rowBytes {
            return Data(bytes: base, count: rowBytes * height)
        }
        var data = Data(capacity: rowBytes * height)
        for row in 0..<height {
            data.append(
                base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self),
                count: rowBytes
            )
        }
        return data
    }
}
