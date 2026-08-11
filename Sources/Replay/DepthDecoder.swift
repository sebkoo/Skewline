import Foundation
import Core

public enum DepthDecodingError: Error, Equatable {
    /// The record names a sample representation this decoder does not know.
    /// Unknown strings round-trip through `Core` losslessly by design, so a
    /// reader will meet them; turning one into samples would be a guess about
    /// bytes, and the decoder refuses instead.
    case unsupportedEncoding(DepthEncoding)

    /// Same refusal, for the confidence payload's representation.
    case unsupportedConfidenceEncoding(ConfidenceEncoding)

    /// Same refusal, for a compression this decoder cannot undo.
    case unsupportedCompression(DepthCompression)

    /// The decompressed depth payload is not exactly
    /// width x height x 4 bytes -- the only size `.float32` can mean.
    case depthSizeMismatch(expected: Int, actual: Int)

    /// The decompressed confidence payload is not exactly
    /// width x height bytes.
    case confidenceSizeMismatch(expected: Int, actual: Int)

    /// The record claims a confidence map and no payload was passed.
    case missingConfidencePayload

    /// A confidence payload was passed for a record that claims none.
    case unclaimedConfidencePayload
}

/// One frame's depth, decompressed and reinterpreted: the form arithmetic
/// consumes, where `DepthRecord` describes the form the container stores.
///
/// Row-major, top row first, exactly `width x height` values -- the packing
/// `DepthEncoding.float32` promises, with the compression already undone.
public struct DecodedDepth: Equatable, Sendable {
    /// Pixel width of the depth map.
    public let width: Int

    /// Pixel height of the depth map.
    public let height: Int

    /// One value per pixel, in meters, as `ARDepthData.depthMap` delivered
    /// them.
    public let depths: [Float]

    /// One `ARConfidenceLevel` raw value per pixel, as observed on the
    /// device, or `nil` when the frame carried no confidence map. The domain
    /// is not guaranteed to be 0/1/2: `ConfidenceRecord` records what the
    /// sensor said, not what the current SDK enumerates.
    public let confidences: [UInt8]?

    public init(width: Int, height: Int, depths: [Float], confidences: [UInt8]?) {
        self.width = width
        self.height = height
        self.depths = depths
        self.confidences = confidences
    }
}

/// The exact inverse of the harness's depth encoder: undo the compression the
/// record names, then reinterpret the tight-packed bytes.
///
/// It lives in `Replay` rather than beside the encoder because the two halves
/// have different dependencies, not different owners: encoding starts from a
/// `CVPixelBuffer` behind the ARKit gate, while decoding is Foundation-only
/// byte arithmetic -- so the format's inverse sits beside the format without
/// costing `Replay` an import.
public enum DepthDecoder {
    /// Decodes one frame's payloads, as `SessionContainer.Reader` returns
    /// them, into samples.
    ///
    /// The confidence payload must match the record's claim in both
    /// directions: a claimed map with no payload and a payload with no claim
    /// each throw, because either mismatch means the caller has paired a
    /// record with the wrong frame's bytes.
    public static func decode(
        record: DepthRecord,
        depthData: Data,
        confidenceData: Data?
    ) throws -> DecodedDepth {
        guard record.encoding == .float32 else {
            throw DepthDecodingError.unsupportedEncoding(record.encoding)
        }
        let rawDepth = try decompressed(depthData, compression: record.compression)
        let sampleCount = record.width * record.height
        guard rawDepth.count == sampleCount * 4 else {
            throw DepthDecodingError.depthSizeMismatch(
                expected: sampleCount * 4,
                actual: rawDepth.count
            )
        }
        let depths = floats(from: rawDepth, count: sampleCount)

        var confidences: [UInt8]?
        if let confidenceRecord = record.confidence {
            guard let confidenceData else {
                throw DepthDecodingError.missingConfidencePayload
            }
            guard confidenceRecord.encoding == .uint8 else {
                throw DepthDecodingError.unsupportedConfidenceEncoding(confidenceRecord.encoding)
            }
            let rawConfidence = try decompressed(confidenceData, compression: confidenceRecord.compression)
            let confidenceCount = confidenceRecord.width * confidenceRecord.height
            guard rawConfidence.count == confidenceCount else {
                throw DepthDecodingError.confidenceSizeMismatch(
                    expected: confidenceCount,
                    actual: rawConfidence.count
                )
            }
            confidences = [UInt8](rawConfidence)
        } else if confidenceData != nil {
            throw DepthDecodingError.unclaimedConfidencePayload
        }

        return DecodedDepth(
            width: record.width,
            height: record.height,
            depths: depths,
            confidences: confidences
        )
    }

    private static func decompressed(_ data: Data, compression: DepthCompression) throws -> Data {
        switch compression {
        case .raw:
            return data
        case .lzfse:
            return try (data as NSData).decompressed(using: .lzfse) as Data
        default:
            throw DepthDecodingError.unsupportedCompression(compression)
        }
    }

    /// Reinterprets tight-packed little-endian binary32 bytes as `[Float]`.
    ///
    /// A byte copy rather than a pointer bind: `Data` promises no alignment
    /// -- least of all a slice, or what `NSData` decompression returns -- and
    /// every host this package supports is little-endian, so a copy is the
    /// whole conversion.
    private static func floats(from data: Data, count: Int) -> [Float] {
        [Float](unsafeUninitializedCapacity: count) { destination, initializedCount in
            data.withUnsafeBytes { source in
                UnsafeMutableRawBufferPointer(destination).copyMemory(from: source)
            }
            initializedCount = count
        }
    }
}
