import Testing
import Foundation
import Core
import Replay

/// A 3x2 map's worth of samples, values chosen to be exact in binary32 so
/// equality needs no tolerance.
private let sampleDepths: [Float] = [0.5, 1.25, 2.0, 3.5, 0.75, 4.0]
private let sampleConfidences: [UInt8] = [0, 1, 2, 2, 1, 0]

private func packed(_ values: [Float]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

/// The harness encoder's exact compression call, so the round trip inverts
/// what the device actually writes rather than a re-implementation of it.
private func lzfse(_ data: Data) throws -> Data {
    try (data as NSData).compressed(using: .lzfse) as Data
}

private func depthRecord(
    compression: DepthCompression = .lzfse,
    encoding: DepthEncoding = .float32,
    confidence: ConfidenceRecord? = ConfidenceRecord(
        width: 3, height: 2, encoding: .uint8, compression: .lzfse
    )
) -> DepthRecord {
    DepthRecord(width: 3, height: 2, encoding: encoding, compression: compression, confidence: confidence)
}

@Test func decoderInvertsWhatTheHarnessEncoderWrites() throws {
    let decoded = try DepthDecoder.decode(
        record: depthRecord(),
        depthData: lzfse(packed(sampleDepths)),
        confidenceData: lzfse(Data(sampleConfidences))
    )
    #expect(decoded == DecodedDepth(width: 3, height: 2, depths: sampleDepths, confidences: sampleConfidences))
}

@Test func decoderPassesRawCompressionThrough() throws {
    let decoded = try DepthDecoder.decode(
        record: depthRecord(
            compression: .raw,
            confidence: ConfidenceRecord(width: 3, height: 2, encoding: .uint8, compression: .raw)
        ),
        depthData: packed(sampleDepths),
        confidenceData: Data(sampleConfidences)
    )
    #expect(decoded == DecodedDepth(width: 3, height: 2, depths: sampleDepths, confidences: sampleConfidences))
}

@Test func decoderRefusesUnknownCompression() {
    let compression = DepthCompression(rawValue: "zstd")
    #expect(throws: DepthDecodingError.unsupportedCompression(compression)) {
        try DepthDecoder.decode(
            record: depthRecord(compression: compression, confidence: nil),
            depthData: packed(sampleDepths),
            confidenceData: nil
        )
    }
}

@Test func decoderRefusesUnknownDepthEncoding() {
    let encoding = DepthEncoding(rawValue: "float16")
    #expect(throws: DepthDecodingError.unsupportedEncoding(encoding)) {
        try DepthDecoder.decode(
            record: depthRecord(encoding: encoding, confidence: nil),
            depthData: packed(sampleDepths),
            confidenceData: nil
        )
    }
}

@Test func decoderRefusesUnknownConfidenceEncoding() {
    let encoding = ConfidenceEncoding(rawValue: "uint4")
    #expect(throws: DepthDecodingError.unsupportedConfidenceEncoding(encoding)) {
        try DepthDecoder.decode(
            record: depthRecord(
                compression: .raw,
                confidence: ConfidenceRecord(width: 3, height: 2, encoding: encoding, compression: .raw)
            ),
            depthData: packed(sampleDepths),
            confidenceData: Data(sampleConfidences)
        )
    }
}

@Test func truncatedDepthPayloadThrowsSizeMismatch() {
    #expect(throws: DepthDecodingError.depthSizeMismatch(expected: 24, actual: 23)) {
        try DepthDecoder.decode(
            record: depthRecord(compression: .raw, confidence: nil),
            depthData: packed(sampleDepths).dropLast(),
            confidenceData: nil
        )
    }
}

@Test func truncatedConfidencePayloadThrowsSizeMismatch() {
    #expect(throws: DepthDecodingError.confidenceSizeMismatch(expected: 6, actual: 5)) {
        try DepthDecoder.decode(
            record: depthRecord(
                compression: .raw,
                confidence: ConfidenceRecord(width: 3, height: 2, encoding: .uint8, compression: .raw)
            ),
            depthData: packed(sampleDepths),
            confidenceData: Data(sampleConfidences).dropLast()
        )
    }
}

@Test func claimedConfidenceWithoutPayloadThrows() {
    #expect(throws: DepthDecodingError.missingConfidencePayload) {
        try DepthDecoder.decode(
            record: depthRecord(compression: .raw),
            depthData: packed(sampleDepths),
            confidenceData: nil
        )
    }
}

@Test func unclaimedConfidencePayloadThrows() {
    #expect(throws: DepthDecodingError.unclaimedConfidencePayload) {
        try DepthDecoder.decode(
            record: depthRecord(compression: .raw, confidence: nil),
            depthData: packed(sampleDepths),
            confidenceData: Data(sampleConfidences)
        )
    }
}

/// Guards the decoder's byte-copy reinterpretation: a slice that no longer
/// starts on a 4-byte boundary must decode identically, because nothing
/// about `Data` -- least of all what decompression returns -- promises
/// alignment.
@Test func decoderReadsMisalignedPayloadBytes() throws {
    var shifted = Data([0xFF])
    shifted.append(packed(sampleDepths))
    let misaligned = shifted.dropFirst()

    let decoded = try DepthDecoder.decode(
        record: depthRecord(compression: .raw, confidence: nil),
        depthData: misaligned,
        confidenceData: nil
    )
    #expect(decoded.depths == sampleDepths)
    #expect(decoded.confidences == nil)
}
