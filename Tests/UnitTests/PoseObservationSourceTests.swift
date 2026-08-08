import Testing
import Foundation
import simd
import Core
import Replay
import Capture

/// A minimal, test-only conformer standing in for a second real source. Its
/// only purpose is to prove `drain` is genuinely polymorphic over
/// `PoseObservationSource`, not accidentally coupled to `ReplaySessionSource`.
private struct FixedObservationsSource: PoseObservationSource {
    let fixed: [PoseObservation]

    func observations() -> AsyncThrowingStream<PoseObservation, any Error> {
        AsyncThrowingStream { continuation in
            for observation in fixed {
                continuation.yield(observation)
            }
            continuation.finish()
        }
    }
}

private func drain(_ source: some PoseObservationSource) async throws -> [PoseObservation] {
    var result: [PoseObservation] = []
    for try await observation in source.observations() {
        result.append(observation)
    }
    return result
}

private func makeObservation(timestamp: TimeInterval) -> PoseObservation {
    PoseObservation(
        timestamp: timestamp,
        transform: .identity,
        covariance: .zero,
        trackingQuality: .normal
    )
}

@Test func drainConsumesAReplaySessionSourceUnchanged() async throws {
    let observations = [makeObservation(timestamp: 0), makeObservation(timestamp: 1)]
    let session = CaptureSession(observations: observations)
    let source = ReplaySessionSource(session: session)

    let drained = try await drain(source)

    #expect(drained == observations)
}

@Test func drainConsumesAnyPoseObservationSourceUnchanged() async throws {
    let observations = [makeObservation(timestamp: 2)]
    let source = FixedObservationsSource(fixed: observations)

    let drained = try await drain(source)

    #expect(drained == observations)
}
