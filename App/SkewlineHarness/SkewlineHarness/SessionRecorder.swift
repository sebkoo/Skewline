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

    /// Set once, from the first observation of a session.
    ///
    /// That `ARFrame.timestamp` and `CACurrentMediaTime()` share a monotonic
    /// base is an assumption the timeline rests on and nothing here has
    /// measured, so the raw numbers are shown rather than trusted.
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
        timing = nil
        status = .recording

        // The stream has to exist before the session starts: a frame delivered
        // before the continuation is installed has nowhere to go.
        let observations = source.observations()
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
            var collected: [PoseObservation] = []
            var timing: String?

            do {
                for try await observation in observations {
                    if collected.isEmpty, let origin {
                        let line = """
                            run origin      \(origin)
                            first frame     \(observation.timestamp + origin)
                            now             \(CACurrentMediaTime())
                            """
                        print(line)
                        timing = line
                    }
                    collected.append(observation)

                    let count = collected.count
                    if count.isMultiple(of: 30) {
                        await MainActor.run { self.observationCount = count }
                    }
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.status = .failed(message) }
                return
            }

            let session = CaptureSession(observations: collected)
            let name = "session-\(session.id.uuidString).json"
            do {
                try SessionCodec.write(session, to: URL.documentsDirectory.appending(path: name))
            } catch {
                let message = error.localizedDescription
                await MainActor.run { self.status = .failed(message) }
                return
            }

            let count = collected.count
            let measured = timing
            print("wrote \(count) observations to \(name)")
            await MainActor.run {
                self.observationCount = count
                self.timing = measured
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
}
