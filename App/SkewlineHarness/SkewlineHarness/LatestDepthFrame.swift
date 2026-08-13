import Foundation
import Sight
import Synchronization

/// The last frame the drain actually wrote, held as bytes so a tap can read it.
///
/// Bytes and not a `CVPixelBuffer`, for the reason `SensorSource` already
/// states at its own copy: retaining an `ARFrame` starves the session's pool
/// and stalls capture, and holding a vended buffer across a yield is the thing
/// that copy exists to avoid. A `Data` is outside that class entirely, and it
/// crosses to the main actor without an `@unchecked` anywhere.
///
/// They are the *written* bytes, which is the point rather than a convenience.
/// `SensorSource` strides frames and drops them under load, so the frame ARKit
/// is showing is frequently one no container will ever hold; a sighting taken
/// from it could never be checked afterwards. These are the samples that go
/// into the container at `index`, so re-deriving the reading is
/// `SightProbe --frame <index> <x>,<y>` and the two must agree.
///
/// They are also tight-packed -- `PixelBufferPacking` stripped the row padding
/// on the way past -- which is what makes `DepthMapGrid.Pixel.index` a valid
/// subscript. A `CVPixelBuffer`'s stride may exceed `width * 4`, and
/// `row * width + column` against one is right on the devices where they agree
/// and silently wrong on the rest.
nonisolated final class LatestDepthFrame: Sendable {
    struct Sample: Sendable {
        /// The frame's index in the container being written, which is what
        /// `SightProbe --frame` takes.
        let index: Int
        let grid: DepthMapGrid
        let depths: Data
        let confidences: Data
    }

    private let slot = Mutex<Sample?>(nil)

    /// One store per kept frame. No main-actor hop: the drain is already
    /// paying a frame's encode here, and a hop per frame at thirty a second
    /// is the cost this whole arrangement avoids.
    func store(
        index: Int,
        width: Int,
        height: Int,
        depths: Data,
        confidences: Data?
    ) {
        // A frame with no confidence map cannot be sighted -- the class is
        // half the question -- so it is not offered rather than offered with
        // a gap. The panel's "no depth on this frame" state is what a caller
        // sees instead.
        guard let confidences,
              let grid = DepthMapGrid(width: width, height: height),
              depths.count == width * height * 4,
              confidences.count == width * height
        else { return }
        slot.withLock {
            $0 = Sample(index: index, grid: grid, depths: depths, confidences: confidences)
        }
    }

    var sample: Sample? {
        slot.withLock { $0 }
    }

    func clear() {
        slot.withLock { $0 = nil }
    }
}

extension LatestDepthFrame.Sample {
    /// The depth and the sensor's class at one pixel.
    ///
    /// `depthMeters` is the depth map's own sample: **planar z**, the pixel's
    /// distance along the optical axis, which is the quantity the model was
    /// fitted on. It is not the length of a viewing ray, and no raycast is
    /// involved anywhere in this path -- an `ARRaycastResult` distance exceeds
    /// planar z by `1 / cos` of the angle off axis, a silent fifteen per cent
    /// at thirty degrees, and would apply the model to a depth it never saw.
    func reading(at pixel: DepthMapGrid.Pixel) -> (depthMeters: Float, rawConfidence: UInt8) {
        let depth = depths.withUnsafeBytes { bytes in
            bytes.loadUnaligned(fromByteOffset: pixel.index * 4, as: Float.self)
        }
        return (depth, confidences[confidences.startIndex + pixel.index])
    }
}
