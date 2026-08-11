#if canImport(AVFoundation)
import Testing
import AVFoundation
import CoreVideo
import Foundation
import Capture
import Core
import Replay

/// A tiny bi-planar 4:2:0 frame -- ARKit's capture format -- with one luma
/// value everywhere, so successive frames are distinguishable to the encoder
/// without any drawing machinery.
private func makeFrameBuffer(width: Int, height: Int, luma: UInt8) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        nil,
        &buffer
    )
    let created = try #require(buffer, "CVPixelBufferCreate status \(status)")
    CVPixelBufferLockBaseAddress(created, [])
    defer { CVPixelBufferUnlockBaseAddress(created, []) }
    for plane in 0..<CVPixelBufferGetPlaneCount(created) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(created, plane) else { continue }
        let bytes = CVPixelBufferGetBytesPerRowOfPlane(created, plane)
            * CVPixelBufferGetHeightOfPlane(created, plane)
        memset(base, plane == 0 ? Int32(luma) : 128, bytes)
    }
    return created
}

private func writeMovie(to url: URL, codec: VideoCodec, timestamps: [TimeInterval]) async throws {
    let writer = MovieFrameWriter(url: url, codec: codec, fragmentInterval: nil)
    for (index, timestamp) in timestamps.enumerated() {
        let buffer = try makeFrameBuffer(width: 320, height: 240, luma: UInt8(index * 16))
        try writer.append(buffer, at: timestamp)
    }
    _ = try await writer.finish()
}

/// The write-then-seek contract with the real machinery, on the host this
/// suite runs on: every sample fetched back by the exact presentation time
/// its timestamp derives, in and out of order, and the pinned nanosecond
/// timescale surviving the file.
///
/// HEVC first, H.264 only if this host's encoder refuses it -- the contract
/// under test is the timestamp mapping, not the codec.
@Test func movieRoundTripsFrameExactSeeks() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(SessionContainer.videoFileName)

    // A stride-2 60 Hz walk's timestamp shape, not frame numbers: the
    // mapping under test is seconds-to-nanoseconds, and integer seconds
    // would let a rescaling bug pass.
    let timestamps = (0..<8).map { 0.052 + Double($0) * (2.0 / 60.0) }
    do {
        try await writeMovie(to: url, codec: .hevc, timestamps: timestamps)
    } catch {
        try? FileManager.default.removeItem(at: url)
        try await writeMovie(to: url, codec: .h264, timestamps: timestamps)
    }

    let reader = try await MovieFrameReader(contentsOf: url)
    #expect(reader.timescale == CMTimeScale(VideoTrackRecord.nanosecondTimescale))

    // Out of order on purpose: a sequential fetch pattern could pass by
    // accident of decode order.
    for timestamp in timestamps.reversed() {
        let sample = try reader.frame(at: timestamp)
        #expect(sample.presentationTime == VideoTrackRecord.presentationTime(of: timestamp))
        #expect(CVPixelBufferGetWidth(sample.pixelBuffer) == 320)
        #expect(CVPixelBufferGetHeight(sample.pixelBuffer) == 240)
    }

    var index = 0
    try reader.forEachFrame { sample in
        #expect(index < timestamps.count)
        if index < timestamps.count {
            #expect(sample.presentationTime == VideoTrackRecord.presentationTime(of: timestamps[index]))
        }
        index += 1
    }
    #expect(index == timestamps.count)
}

@Test func movieWriterWithoutAppendsSealsNothing() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent(SessionContainer.videoFileName)

    let writer = MovieFrameWriter(url: url)
    #expect(try await writer.finish() == 0)
    #expect(!FileManager.default.fileExists(atPath: url.path))
}
#endif
