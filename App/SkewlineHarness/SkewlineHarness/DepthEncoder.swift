import ARKit
import Capture
import Core
import CoreVideo
import Foundation
import Replay

/// Turns one `CapturedDepth` into the payloads the container stores and the
/// `DepthRecord` describing them.
///
/// The observed pixel format is verified before a record is written about it:
/// an unexpected format fails the capture loudly rather than letting a record
/// describe bytes it never looked at. The formats named here are claims the
/// compiler checked against the SDK; whether the device delivers them is what
/// the verification observes.
///
/// The compression knob is decided, not a starting point. LZFSE compresses
/// packed depth+confidence bytes to 0.18-0.20 of their size, reproduced
/// across three separate captures with different walks (see DEVLOG) --
/// cross-condition reproduction v0.4 judged stronger evidence than one more
/// same-walk measurement could add, so this knob was decided without a
/// matrix cell of its own. What was never isolated: the raw-vs-lzfse
/// encode-time delta -- every measurement bundles packing, tallying and
/// compression as one number, and the whole bundle sits well inside the
/// frame budget regardless, so speed was never the question this default
/// answers.
///
/// `nonisolated` for the same reason as `FrameEncoder`: this type belongs to
/// the drain task, not the UI.
nonisolated struct DepthEncoder {
    enum Failure: Error {
        case unexpectedDepthFormat(OSType)
        case unexpectedConfidenceFormat(OSType)
        case unsupportedCompression(DepthCompression)
    }

    /// Pixel counts per confidence level, tallied against
    /// `ARConfidenceLevel`'s own raw values -- this target imports ARKit, so
    /// the mapping is read from the framework rather than written down as
    /// numerals somewhere ARKit cannot check them.
    struct ConfidenceTally {
        var low = 0
        var medium = 0
        var high = 0
        /// Pixels matching no `ARConfidenceLevel` case. Counted rather than
        /// folded into a neighbour: a value the enum does not name is a fact
        /// about the device, not noise.
        var other = 0

        var total: Int { low + medium + high + other }

        mutating func merge(_ tally: ConfidenceTally) {
            low += tally.low
            medium += tally.medium
            high += tally.high
            other += tally.other
        }
    }

    /// One frame's depth, encoded: the record, the payloads, and what the
    /// encoding observed on the way.
    struct EncodedDepth {
        let record: DepthRecord
        let payload: SessionContainer.DepthPayload
        /// Tight-packed bytes before compression, depth and confidence
        /// together -- the baseline the compression ratio is measured
        /// against.
        let packedBytes: Int
        let tally: ConfidenceTally?
        let depthFormat: OSType
        let confidenceFormat: OSType?
    }

    /// How payload bytes are compressed on disk.
    let compression: DepthCompression

    init(compression: DepthCompression = .lzfse) {
        self.compression = compression
    }

    func encode(_ depth: CapturedDepth) throws -> EncodedDepth {
        let depthFormat = CVPixelBufferGetPixelFormatType(depth.depthMap)
        guard depthFormat == kCVPixelFormatType_DepthFloat32 else {
            throw Failure.unexpectedDepthFormat(depthFormat)
        }
        let packedDepth = try PixelBufferPacking.tightlyPackedData(from: depth.depthMap, bytesPerPixel: 4)
        var packedBytes = packedDepth.count

        var confidenceRecord: ConfidenceRecord?
        var confidenceData: Data?
        var tally: ConfidenceTally?
        var confidenceFormat: OSType?
        if let confidenceMap = depth.confidenceMap {
            let format = CVPixelBufferGetPixelFormatType(confidenceMap)
            guard format == kCVPixelFormatType_OneComponent8 else {
                throw Failure.unexpectedConfidenceFormat(format)
            }
            confidenceFormat = format
            let packed = try PixelBufferPacking.tightlyPackedData(from: confidenceMap, bytesPerPixel: 1)
            packedBytes += packed.count
            tally = Self.tally(packed)
            confidenceData = try compress(packed)
            confidenceRecord = ConfidenceRecord(
                width: CVPixelBufferGetWidth(confidenceMap),
                height: CVPixelBufferGetHeight(confidenceMap),
                encoding: .uint8,
                compression: compression
            )
        }

        let record = DepthRecord(
            width: CVPixelBufferGetWidth(depth.depthMap),
            height: CVPixelBufferGetHeight(depth.depthMap),
            encoding: .float32,
            compression: compression,
            confidence: confidenceRecord
        )
        return EncodedDepth(
            record: record,
            payload: SessionContainer.DepthPayload(depth: try compress(packedDepth), confidence: confidenceData),
            packedBytes: packedBytes,
            tally: tally,
            depthFormat: depthFormat,
            confidenceFormat: confidenceFormat
        )
    }

    private func compress(_ data: Data) throws -> Data {
        switch compression {
        case .raw:
            return data
        case .lzfse:
            return try (data as NSData).compressed(using: .lzfse) as Data
        default:
            throw Failure.unsupportedCompression(compression)
        }
    }

    private static func tally(_ confidence: Data) -> ConfidenceTally {
        var tally = ConfidenceTally()
        for byte in confidence {
            switch Int(byte) {
            case ARConfidenceLevel.low.rawValue:
                tally.low += 1
            case ARConfidenceLevel.medium.rawValue:
                tally.medium += 1
            case ARConfidenceLevel.high.rawValue:
                tally.high += 1
            default:
                tally.other += 1
            }
        }
        return tally
    }
}
