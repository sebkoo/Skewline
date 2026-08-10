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
