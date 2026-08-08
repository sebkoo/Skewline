import Testing
import Foundation
import simd
import Core
import Replay

@Test func captureSessionRoundTripsThroughDisk() throws {
    let observation = PoseObservation(
        timestamp: 12.5,
        transform: Transform4x4(simd_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0.25, -1.5, 3.0, 1)
        )),
        covariance: PoseCovariance6x6(values: (0..<36).map { Double($0) * 0.001 }),
        trackingQuality: .limited(.excessiveMotion)
    )
    let session = CaptureSession(observations: [observation])

    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }

    try SessionCodec.write(session, to: url)
    let decoded = try SessionCodec.read(from: url)

    // Whole-session equality rather than field-by-field: it covers `id`,
    // `startDate` and `timestamp`, which the per-field version silently
    // skipped, and it cannot drift out of date as fields are added.
    #expect(decoded == session)
}
