import Testing
import Foundation
import Core
import Replay
import Capture

/// A minimal, test-only conformer standing in for a second real source, for the
/// same reason `FixedObservationsSource` exists: to prove `drainSamples` is
/// polymorphic over `InertialSampleSource` rather than coupled to
/// `ReplaySessionSource`.
private struct FixedSamplesSource: InertialSampleSource {
    let fixed: [InertialSample]

    func inertialSamples() -> AsyncThrowingStream<InertialSample, any Error> {
        AsyncThrowingStream { continuation in
            for sample in fixed {
                continuation.yield(sample)
            }
            continuation.finish()
        }
    }
}

private func drainSamples(_ source: some InertialSampleSource) async throws -> [InertialSample] {
    var result: [InertialSample] = []
    for try await sample in source.inertialSamples() {
        result.append(sample)
    }
    return result
}

private func makeSample(timestamp: TimeInterval) -> InertialSample {
    InertialSample(
        timestamp: timestamp,
        rotationRate: SIMD3(0, 0, 0),
        userAcceleration: SIMD3(0, 0, 0)
    )
}

@Test func drainSamplesConsumesAReplaySessionSourceUnchanged() async throws {
    let samples = [makeSample(timestamp: 0), makeSample(timestamp: 0.005)]
    let session = CaptureSession(inertialSamples: samples)
    let source = ReplaySessionSource(session: session)

    let drained = try await drainSamples(source)

    #expect(drained == samples)
}

@Test func drainSamplesConsumesAnyInertialSampleSourceUnchanged() async throws {
    let samples = [makeSample(timestamp: 0.01)]
    let source = FixedSamplesSource(fixed: samples)

    let drained = try await drainSamples(source)

    #expect(drained == samples)
}

/// The two sequences are independent: a session may carry one and not the
/// other, and a consumer of either must not be surprised by the other's
/// absence.
@Test func aSessionWithOnlyPosesVendsNoSamples() async throws {
    let session = CaptureSession(observations: [
        PoseObservation(timestamp: 0, transform: .identity, covariance: .zero, trackingQuality: .normal)
    ])

    let drained = try await drainSamples(ReplaySessionSource(session: session))

    #expect(drained.isEmpty)
}
