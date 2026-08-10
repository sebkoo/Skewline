import ARKit
import Capture
import Core
import Foundation
import QuartzCore
import Replay

/// Owns one `ARSession`, drains its `SensorSource` away from the main thread,
/// and writes what it collected to a session file.
///
/// This is a harness. Its only job is producing a file that `SessionCodec.read`
/// can decode on a Mac, and it should not grow a second one.
@MainActor
@Observable
final class SessionRecorder {
    enum Status: Equatable {
        case idle
        case recording
        case writing
        case wrote(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var observationCount = 0
    private(set) var inertialCount = 0

    /// The raw timestamps of both sensors, side by side, built once a session
    /// has ended.
    ///
    /// That `ARFrame.timestamp`, `CMDeviceMotion.timestamp` and
    /// `CACurrentMediaTime()` share a monotonic base is an assumption the
    /// timeline rests on and nothing here has measured, so the raw numbers are
    /// shown rather than trusted. A session whose `inertial t0` is out by
    /// minutes or hours is a file that looks fine and is wrong.
    private(set) var timing: String?

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    private let arSession = ARSession()
    private let source: SensorSource

    init() {
        // Delegate callbacks land on the main queue unless told otherwise, and
        // they arrive up to sixty times a second.
        arSession.delegateQueue = DispatchQueue(label: "dev.skewline.harness.session")
        // `ARSession.delegate` is weak, so this object owns the source.
        source = SensorSource(session: arSession)
    }

    func start() {
        guard status != .recording else { return }
        observationCount = 0
        inertialCount = 0
        timing = nil
        status = .recording

        // Both streams have to exist before the session starts: anything
        // delivered before its continuation is installed has nowhere to go.
        let observations = source.observations()
        let samples = source.inertialSamples()
        source.run(
            ARWorldTrackingConfiguration(),
            options: [.resetTracking, .removeExistingAnchors]
        )
        let origin = source.timelineOrigin

        // Detached, not `Task {}`. A task started from a `@MainActor` method
        // inherits `MainActor`, which would put `SessionCodec.write` on the
        // main thread -- I/O that would present as a tracking problem.
        //
        // `self` is captured strongly and deliberately: nothing stores this
        // task, so there is no cycle, and a recorder released mid-write would
        // abandon the file this harness exists to produce.
        Task.detached(priority: .utility) { [self] in
            let collected: [PoseObservation]
            let collectedSamples: [InertialSample]
            do {
                // Two sibling children, each owning its own array. The two
                // sensors arrive on two threads at two rates and share no
                // mutable state on this side of the boundary either.
                async let poses = collectObservations(observations)
                async let inertial = collectSamples(samples)
                (collected, collectedSamples) = try await (poses, inertial)
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.status = .failed(message) }
                return
            }

            // Built after both drains rather than from whichever arrived first:
            // either sequence may be the one that is empty, and an absent
            // sample is reported as absent rather than invented.
            let panel = Self.timingPanel(
                origin: origin,
                firstObservation: collected.first,
                firstSample: collectedSamples.first
            )
            print(panel)

            let session = CaptureSession(observations: collected, inertialSamples: collectedSamples)
            let name = "session-\(session.id.uuidString).json"
            do {
                try SessionCodec.write(session, to: URL.documentsDirectory.appending(path: name))
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.status = .failed(message) }
                return
            }

            let count = collected.count
            let sampleCount = collectedSamples.count
            print("wrote \(count) observations and \(sampleCount) inertial samples to \(name)")
            await MainActor.run {
                self.observationCount = count
                self.inertialCount = sampleCount
                self.timing = panel
                self.status = .wrote(name)
            }
        }
    }

    func stop() {
        guard status == .recording else { return }
        status = .writing
        arSession.pause()
        source.finish()
    }

    private nonisolated func collectObservations(
        _ observations: AsyncThrowingStream<PoseObservation, any Error>
    ) async throws -> [PoseObservation] {
        var collected: [PoseObservation] = []
        for try await observation in observations {
            collected.append(observation)
            let count = collected.count
            if count.isMultiple(of: 30) {
                await MainActor.run { self.observationCount = count }
            }
        }
        return collected
    }

    private nonisolated func collectSamples(
        _ samples: AsyncThrowingStream<InertialSample, any Error>
    ) async throws -> [InertialSample] {
        var collected: [InertialSample] = []
        for try await sample in samples {
            collected.append(sample)
            let count = collected.count
            if count.isMultiple(of: 100) {
                await MainActor.run { self.inertialCount = count }
            }
        }
        return collected
    }

    /// The whole point of this commit: the two sensors' raw timestamps beside
    /// each other, and the normalised values derived from them, so a base
    /// mismatch is visible rather than silently baked into the file.
    private nonisolated static func timingPanel(
        origin: TimeInterval?,
        firstObservation: PoseObservation?,
        firstSample: InertialSample?
    ) -> String {
        func raw(_ timestamp: TimeInterval?) -> String {
            guard let timestamp, let origin else { return "none" }
            return "\(timestamp + origin)"
        }
        func relative(_ timestamp: TimeInterval?) -> String {
            guard let timestamp else { return "none" }
            return "\(timestamp)"
        }
        return """
            run origin      \(origin.map(String.init(describing:)) ?? "none")
            first frame     \(raw(firstObservation?.timestamp))
            first motion    \(raw(firstSample?.timestamp))
            now             \(CACurrentMediaTime())
            pose t0         \(relative(firstObservation?.timestamp))
            inertial t0     \(relative(firstSample?.timestamp))
            """
    }
}
