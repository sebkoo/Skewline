import Testing
import Foundation
import Core
import Replay

/// A session with every sequence populated, so whole-session equality keeps
/// covering all of them.
private func sampleSession(frames: [FrameRecord]) -> CaptureSession {
    CaptureSession(
        observations: [
            PoseObservation(
                timestamp: 1.25,
                transform: .identity,
                covariance: .zero,
                trackingQuality: .limited(.insufficientFeatures)
            )
        ],
        inertialSamples: [
            InertialSample(
                timestamp: 1.2,
                rotationRate: SIMD3(0.1, -0.2, 0.3),
                userAcceleration: SIMD3(0.0, 0.5, -0.5)
            )
        ],
        frames: frames
    )
}

private func temporaryContainerURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(SessionContainer.pathExtension)
}

private func sampleDepthRecord(confidence: Bool) -> DepthRecord {
    DepthRecord(
        width: 4,
        height: 3,
        encoding: .float32,
        compression: .lzfse,
        confidence: confidence
            ? ConfidenceRecord(width: 4, height: 3, encoding: .uint8, compression: .lzfse)
            : nil
    )
}

@Test func containerRoundTripsSessionAndFrameBytes() throws {
    let payloads = [Data([0x00, 0x01]), Data("second".utf8), Data(repeating: 0xAB, count: 1024)]
    let session = sampleSession(frames: payloads.indices.map { index in
        FrameRecord(timestamp: Double(index) * 0.033, width: 4, height: 3, encoding: .jpeg)
    })
    let url = temporaryContainerURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SessionContainer.Writer(creatingAt: url)
    for payload in payloads {
        try writer.append(payload)
    }
    try writer.finalize(session: session)

    let reader = try SessionContainer.Reader(contentsOf: url)
    #expect(reader.session == session)
    for (index, payload) in payloads.enumerated() {
        #expect(try reader.frameData(at: index) == payload)
    }
}

@Test func sessionRecordedBeforeFramesStillDecodes() throws {
    // Built by stripping the key from real encoder output, for the same reason
    // the inertial-samples test above this format change does: a hand-written
    // blob drifts the moment the encoder changes, and the files this protects
    // are captures that already exist.
    let session = CaptureSession(observations: [], inertialSamples: [])
    let encoded = try SessionCodec.encode(session)
    var object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["frames"] != nil)
    object["frames"] = nil

    let decoded = try SessionCodec.decode(try JSONSerialization.data(withJSONObject: object))

    #expect(decoded == session)
    #expect(decoded.frames.isEmpty)
}

@Test func finalizeWithWrongFrameCountThrowsAndWritesNoSessionFile() throws {
    let url = temporaryContainerURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SessionContainer.Writer(creatingAt: url)
    try writer.append(Data([1]))
    try writer.append(Data([2]))
    let session = sampleSession(frames: (0..<3).map { index in
        FrameRecord(timestamp: Double(index), width: 4, height: 3, encoding: .jpeg)
    })

    #expect(throws: SessionContainerError.frameCountMismatch(recorded: 3, appended: 2)) {
        try writer.finalize(session: session)
    }
    let sessionFile = url.appending(path: SessionContainer.sessionFileName)
    #expect(!FileManager.default.fileExists(atPath: sessionFile.path))
}

@Test func readerRefusesContainerWithoutSessionFile() throws {
    let url = temporaryContainerURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

    #expect(throws: SessionContainerError.missingSessionFile(url)) {
        _ = try SessionContainer.Reader(contentsOf: url)
    }
}

@Test func frameDataOutOfRangeThrows() throws {
    let url = temporaryContainerURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SessionContainer.Writer(creatingAt: url)
    try writer.append(Data([7]))
    try writer.finalize(session: sampleSession(frames: [
        FrameRecord(timestamp: 0, width: 4, height: 3, encoding: .jpeg)
    ]))

    let reader = try SessionContainer.Reader(contentsOf: url)
    #expect(throws: SessionContainerError.frameIndexOutOfRange(index: 1, count: 1)) {
        _ = try reader.frameData(at: 1)
    }
}

@Test func containerRoundTripsDepthAndConfidencePayloads() throws {
    // A deliberately mixed hole pattern -- with confidence, without depth,
    // depth alone -- so the round trip covers presence, absence and the
    // partial case in one container.
    let session = sampleSession(frames: [
        FrameRecord(timestamp: 0, width: 4, height: 3, encoding: .jpeg, depth: sampleDepthRecord(confidence: true)),
        FrameRecord(timestamp: 0.033, width: 4, height: 3, encoding: .jpeg),
        FrameRecord(timestamp: 0.066, width: 4, height: 3, encoding: .jpeg, depth: sampleDepthRecord(confidence: false)),
    ])
    let url = temporaryContainerURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SessionContainer.Writer(creatingAt: url)
    try writer.append(Data([1]), depth: .init(depth: Data([10, 11]), confidence: Data([2, 2, 1])))
    try writer.append(Data([2]))
    try writer.append(Data([3]), depth: .init(depth: Data([12])))
    try writer.finalize(session: session)

    let reader = try SessionContainer.Reader(contentsOf: url)
    #expect(reader.session == session)
    #expect(try reader.depthData(at: 0) == Data([10, 11]))
    #expect(try reader.confidenceData(at: 0) == Data([2, 2, 1]))
    #expect(try reader.depthData(at: 2) == Data([12]))
    #expect(throws: SessionContainerError.noDepthRecorded(index: 1)) {
        _ = try reader.depthData(at: 1)
    }
    #expect(throws: SessionContainerError.noConfidenceRecorded(index: 2)) {
        _ = try reader.confidenceData(at: 2)
    }
    #expect(throws: SessionContainerError.frameIndexOutOfRange(index: 3, count: 3)) {
        _ = try reader.depthData(at: 3)
    }
}

@Test func finalizeWithDepthAtWrongIndexThrowsAndWritesNoSessionFile() throws {
    // One depth payload against one depth record -- the counts agree -- but
    // the payload sits at index 0 and the record at index 1. Only a
    // positional check refuses this container; a count check would seal it
    // and leave the mismatch for a reader to find.
    let url = temporaryContainerURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SessionContainer.Writer(creatingAt: url)
    try writer.append(Data([1]), depth: .init(depth: Data([9])))
    try writer.append(Data([2]))
    let session = sampleSession(frames: [
        FrameRecord(timestamp: 0, width: 4, height: 3, encoding: .jpeg),
        FrameRecord(timestamp: 0.033, width: 4, height: 3, encoding: .jpeg, depth: sampleDepthRecord(confidence: false)),
    ])

    #expect(throws: SessionContainerError.depthPresenceMismatch(index: 0)) {
        try writer.finalize(session: session)
    }
    let sessionFile = url.appending(path: SessionContainer.sessionFileName)
    #expect(!FileManager.default.fileExists(atPath: sessionFile.path))
}

@Test func finalizeWithUnclaimedConfidenceThrows() throws {
    // The confidence payload was written; the record claims depth without
    // confidence. Same positional discipline, one level down.
    let url = temporaryContainerURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SessionContainer.Writer(creatingAt: url)
    try writer.append(Data([1]), depth: .init(depth: Data([9]), confidence: Data([1])))
    let session = sampleSession(frames: [
        FrameRecord(timestamp: 0, width: 4, height: 3, encoding: .jpeg, depth: sampleDepthRecord(confidence: false)),
    ])

    #expect(throws: SessionContainerError.confidencePresenceMismatch(index: 0)) {
        try writer.finalize(session: session)
    }
}

@Test func depthlessWriterCreatesNoDepthDirectories() throws {
    // The directory names are spelled out rather than read from the type:
    // this test pins the on-disk layout, and a shared constant would follow a
    // rename instead of catching it.
    let url = temporaryContainerURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let writer = try SessionContainer.Writer(creatingAt: url)
    try writer.append(Data([7]))
    try writer.finalize(session: sampleSession(frames: [
        FrameRecord(timestamp: 0, width: 4, height: 3, encoding: .jpeg)
    ]))

    #expect(!FileManager.default.fileExists(atPath: url.appending(path: "depth").path))
    #expect(!FileManager.default.fileExists(atPath: url.appending(path: "confidence").path))
}

@Test func frameRecordedBeforeDepthStillDecodes() throws {
    // Built by stripping the key from real encoder output, like the session
    // test above: the files this protects are captures that already exist.
    let record = FrameRecord(
        timestamp: 0.5, width: 8, height: 6, encoding: .jpeg,
        depth: sampleDepthRecord(confidence: true)
    )
    let encoded = try JSONEncoder().encode(record)
    var object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(object["depth"] != nil)
    object["depth"] = nil

    let decoded = try JSONDecoder().decode(
        FrameRecord.self,
        from: try JSONSerialization.data(withJSONObject: object)
    )

    #expect(decoded == FrameRecord(timestamp: 0.5, width: 8, height: 6, encoding: .jpeg))
    #expect(decoded.depth == nil)
}

@Test func unknownDepthEncodingAndCompressionRoundTrip() throws {
    // Same property as `FrameEncoding`, extended to both depth fields: values
    // this code has never heard of survive decode and encode untouched.
    let json = Data(#"{"width":4,"height":3,"encoding":"future-samples","compression":"future-codec"}"#.utf8)

    let decoded = try JSONDecoder().decode(DepthRecord.self, from: json)
    #expect(decoded.encoding == DepthEncoding(rawValue: "future-samples"))
    #expect(decoded.compression == DepthCompression(rawValue: "future-codec"))

    let reencoded = try JSONEncoder().encode(decoded)
    let object = try #require(
        try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
    )
    #expect(object["encoding"] as? String == "future-samples")
    #expect(object["compression"] as? String == "future-codec")
}

@Test func unknownFrameEncodingRoundTrips() throws {
    // The reason `FrameEncoding` is a raw-string struct and not an enum: a
    // value this code has never heard of must survive decode and encode
    // untouched, or every future encoding breaks every existing reader.
    let json = Data(#"{"timestamp":0.5,"width":8,"height":6,"encoding":"future-codec"}"#.utf8)

    let decoded = try JSONDecoder().decode(FrameRecord.self, from: json)
    #expect(decoded.encoding == FrameEncoding(rawValue: "future-codec"))

    let reencoded = try JSONEncoder().encode(decoded)
    let object = try #require(
        try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
    )
    #expect(object["encoding"] as? String == "future-codec")
}
