import ARKit
import Capture
import Core
import Foundation
import QuartzCore
import Replay

/// Owns one `ARSession`, drains its `SensorSource` away from the main thread,
/// and writes what it collected to a session container.
///
/// This is a harness. Its only job is producing a container that
/// `SessionContainer.Reader` can decode on a Mac, and it should not grow a
/// second one.
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
    private(set) var frameCount = 0

    /// The raw timestamps of the sensors, side by side, built once a session
    /// has ended -- plus the frame probe's numbers, every one of them measured
    /// on the run that just happened.
    ///
    /// That `ARFrame.timestamp`, `CMDeviceMotion.timestamp` and
    /// `CACurrentMediaTime()` share a monotonic base is an assumption the
    /// timeline rests on and nothing here has measured, so the raw numbers are
    /// shown rather than trusted. A session whose `inertial t0` is out by
    /// minutes or hours is a file that looks fine and is wrong.
    private(set) var timing: String?

    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    /// Whether this device's world tracking can deliver `sceneDepth` frames.
    ///
    /// The class method is the mandatory gate, not a defensive check: setting
    /// an unsupported frame semantic throws an Objective-C exception Swift
    /// cannot catch. Shown in the UI because the answer is a fact about this
    /// device that decides whether depth capture exists at all.
    static var supportsSceneDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// The session the passthrough view draws, handed to it rather than made
    /// by it: two `ARSession`s cannot both hold the camera, and this one is
    /// already configured with the frame semantics the capture needs.
    let arSession = ARSession()

    /// The last written frame's depth, for a tap. Read on the main actor,
    /// written by the drain, and neither of them waits for the other.
    let latestDepthFrame = LatestDepthFrame()

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
        frameCount = 0
        timing = nil
        status = .recording
        // A frame from the previous run would be sightable and unreachable:
        // its container is finalized under a different name, so its index
        // names nothing a caller could check. Cleared rather than left.
        latestDepthFrame.clear()

        // All three streams have to exist before the session starts: anything
        // delivered before its continuation is installed has nowhere to go.
        let observations = source.observations()
        let samples = source.inertialSamples()
        let frames = source.cameraFrames()
        // Guarded because the guard is mandatory, not defensive: setting an
        // unsupported semantic throws an Objective-C exception Swift cannot
        // catch. An unsupported device still records -- a session without
        // depth is a session, not a failure.
        let configuration = ARWorldTrackingConfiguration()
        let sceneDepthSupported = Self.supportsSceneDepth
        if sceneDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        source.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        let origin = source.timelineOrigin

        // Detached, not `Task {}`. A task started from a `@MainActor` method
        // inherits `MainActor`, which would put encoding and container I/O on
        // the main thread -- work that would present as a tracking problem.
        //
        // `self` is captured strongly and deliberately: nothing stores this
        // task, so there is no cycle, and a recorder released mid-write would
        // abandon the container this harness exists to produce.
        Task.detached(priority: .utility) { [self] in
            let sessionID = UUID()
            let name = "session-\(sessionID.uuidString).skewline"
            let url = URL.documentsDirectory.appending(path: name)

            let collected: [PoseObservation]
            let collectedSamples: [InertialSample]
            let stats: FrameStats
            do {
                // The Writer is deliberately not Sendable. Created here, it is
                // confined to this task for its whole life.
                let writer = try SessionContainer.Writer(creatingAt: url)
                let encoder = FrameEncoder()
                let depthEncoder = DepthEncoder()
                // The storage knob, a constructor-style default like the two
                // encoders above, chosen from device measurements: the movie
                // path held the drop criterion on both full walks, wrote
                // scene-invariant ~36 KiB/frame against JPEG's 68-135, and
                // replays 6x faster sequentially; 1 s fragments were measured
                // to bound a mid-capture kill's video loss at the last closed
                // fragment boundary, where an unfragmented file lost
                // everything. Per-frame files stay behind the knob. See
                // DEVLOG, "the storage default the walks measured."
                let storage = VideoStoragePolicy.movieTrack(fragmentInterval: 1)

                // Two sibling children, each owning its own array; the frame
                // drain runs inline in this task body, concurrent with both,
                // so the Writer never crosses a task boundary. Payloads go to
                // disk the moment they are encoded -- thousands of frames
                // cannot sit in memory -- and only the records accumulate.
                async let poses = collectObservations(observations)
                async let inertial = collectSamples(samples)
                let (records, frameStats, videoTrack) = try await encodeFrames(
                    frames,
                    into: writer,
                    with: encoder,
                    depthEncoder: depthEncoder,
                    storage: storage,
                    origin: origin
                )
                (collected, collectedSamples) = try await (poses, inertial)
                stats = frameStats

                let session = CaptureSession(
                    id: sessionID,
                    observations: collected,
                    inertialSamples: collectedSamples,
                    frames: records,
                    videoTrack: videoTrack
                )
                try writer.finalize(session: session)
            } catch {
                // One policy for all three sequences, the encoder and the
                // writer: a container that looks whole while missing part of a
                // capture is worse than a loud failure, so the whole directory
                // goes.
                try? FileManager.default.removeItem(at: url)
                let message = error.localizedDescription
                await MainActor.run { self.status = .failed(message) }
                return
            }

            // Built after all drains rather than from whichever arrived first:
            // any sequence may be the one that is empty, and an absent sample
            // is reported as absent rather than invented.
            let panel = Self.timingPanel(
                origin: origin,
                firstObservation: collected.first,
                firstSample: collectedSamples.first
            ) + "\n" + Self.framePanel(
                stats: stats,
                kept: source.keptCameraFrames,
                dropped: source.droppedCameraFrames,
                strided: source.stridedCameraFrames,
                sceneDepthSupported: sceneDepthSupported
            )
            print(panel)

            let count = collected.count
            let sampleCount = collectedSamples.count
            print("wrote \(count) observations, \(sampleCount) inertial samples and \(stats.encodedCount) frames to \(name)")
            await MainActor.run {
                self.observationCount = count
                self.inertialCount = sampleCount
                self.frameCount = stats.encodedCount
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

    /// What the frame probe measured on one run. Every field starts at zero
    /// and only ever holds what this capture observed.
    private nonisolated struct FrameStats {
        var encodedCount = 0
        /// Frames encoded to a per-frame payload file. Equal to
        /// `encodedCount` on the per-frame and dual paths, zero on the movie
        /// path -- the divisor and gate for the payload and encode rows, so
        /// a movie run cannot print a JPEG mean it never paid.
        var fileEncodedCount = 0
        var totalBytes = 0
        var totalEncode: Duration = .zero
        var maxEncode: Duration = .zero
        var maxLag: TimeInterval = 0

        /// The panel's `storage` row, or `nil` on the per-frame default --
        /// a per-frame run's panel is exactly the pre-knob panel.
        var storage: String?
        var videoAppendCount = 0
        var totalVideoAppend: Duration = .zero
        var maxVideoAppend: Duration = .zero
        /// Appends that found the encoder's input not ready, and the longest
        /// such wait -- drain time the ring pays for, counted rather than
        /// averaged away.
        var videoWaits = 0
        var maxVideoWait: TimeInterval = 0
        /// The sealed movie's size. One number at finish: per-frame byte
        /// spread has no movie-path equivalent, and is reported as
        /// unavailable rather than derived.
        var videoBytes = 0

        /// Counted in both branches rather than derived from `encodedCount`,
        /// so `withDepth + withoutDepth = encodedCount` stays a check on the
        /// loop and not an identity.
        var withDepth = 0
        var withoutDepth = 0
        var withConfidence = 0
        var depthPackedBytes = 0
        var depthWrittenBytes = 0
        var totalDepthEncode: Duration = .zero
        var maxDepthEncode: Duration = .zero
        var confidenceTally = DepthEncoder.ConfidenceTally()
        /// Every pixel format the run observed, as delivered -- the header
        /// promises none, so the panel reports rather than assumes.
        var depthFormats: Set<OSType> = []
        var confidenceFormats: Set<OSType> = []

        /// The exposure operands `ExposureRecord` carries, the range and
        /// mean this run actually saw -- not stated ahead of the device run
        /// that exercises them.
        var minExposureDuration: TimeInterval = .greatestFiniteMagnitude
        var maxExposureDuration: TimeInterval = 0
        var exposureDurationSum: TimeInterval = 0
        var minExposureOffset: Float = .greatestFiniteMagnitude
        var maxExposureOffset: Float = -.greatestFiniteMagnitude

        /// The intrinsics operands `IntrinsicsRecord` carries, the range
        /// this run actually saw -- whether fx/fy/cx/cy held constant or
        /// moved (focus, stabilization) is a finding, not an assumption.
        var minFocalLengthX: Float = .greatestFiniteMagnitude
        var maxFocalLengthX: Float = -.greatestFiniteMagnitude
        var minFocalLengthY: Float = .greatestFiniteMagnitude
        var maxFocalLengthY: Float = -.greatestFiniteMagnitude
        var minPrincipalPointX: Float = .greatestFiniteMagnitude
        var maxPrincipalPointX: Float = -.greatestFiniteMagnitude
        var minPrincipalPointY: Float = .greatestFiniteMagnitude
        var maxPrincipalPointY: Float = -.greatestFiniteMagnitude
        /// Every reference resolution the run observed, as `"WxH"` -- the
        /// same reporting style as `depthFormats`/`confidenceFormats`: the
        /// header promises nothing, so the panel reports rather than
        /// assumes.
        var intrinsicsReferenceSizes: Set<String> = []
    }

    private nonisolated func encodeFrames(
        _ frames: AsyncThrowingStream<CameraFrame, any Error>,
        into writer: SessionContainer.Writer,
        with encoder: FrameEncoder,
        depthEncoder: DepthEncoder,
        storage: VideoStoragePolicy,
        origin: TimeInterval?
    ) async throws -> ([FrameRecord], FrameStats, VideoTrackRecord?) {
        var records: [FrameRecord] = []
        var stats = FrameStats()
        stats.storage = storage.panelLabel
        let clock = ContinuousClock()
        // Created up front, but the movie itself starts on the first append
        // -- the track's dimensions are the first frame's to fix.
        let movieWriter: MovieFrameWriter? = storage.writesMovie
            ? MovieFrameWriter(
                url: writer.videoFileURL,
                codec: .hevc,
                fragmentInterval: storage.fragmentInterval
            )
            : nil
        for try await frame in frames {
            // How far behind the encoder is running, read before the encode it
            // is about to pay for.
            if let origin {
                stats.maxLag = max(stats.maxLag, CACurrentMediaTime() - (origin + frame.timestamp))
            }
            let frameRecord: FrameRecord
            var data: Data?
            var encodeTime: Duration = .zero
            if storage.writesPayloadFiles {
                let encodeStart = clock.now
                let encoded = try encoder.encode(frame)
                encodeTime = clock.now - encodeStart
                frameRecord = encoded.record
                data = encoded.data
            } else {
                // The hardware encoder owns the bytes; the record still owns
                // the frame's shape, exposure and intrinsics. The encoding is
                // the movie writer's codec, spelled once.
                frameRecord = try FrameEncoder.record(
                    for: frame,
                    encoding: FrameEncoding(rawValue: (movieWriter?.codec ?? .hevc).rawValue)
                )
            }
            if let movieWriter {
                // Append time is the movie path's analogue of the encode
                // time above: what the drain paid before it could move on --
                // the handoff to the hardware encoder, not the encode
                // itself, which runs behind `isReadyForMoreMediaData`.
                let appendStart = clock.now
                let waited = try movieWriter.append(frame.pixelBuffer, at: frame.timestamp)
                let appendTime = clock.now - appendStart
                stats.videoAppendCount += 1
                stats.totalVideoAppend += appendTime
                stats.maxVideoAppend = max(stats.maxVideoAppend, appendTime)
                if waited > 0 {
                    stats.videoWaits += 1
                    stats.maxVideoWait = max(stats.maxVideoWait, waited)
                }
            }

            // Depth encode timed apart from the pixel encode: the drain's
            // budget is one frame-time, and a combined number could not say
            // which encoder spent it.
            var record = frameRecord
            var depthPayload: SessionContainer.DepthPayload?
            var sighted: (depths: Data, confidences: Data?, width: Int, height: Int)?
            if let capturedDepth = frame.depth {
                let depthStart = clock.now
                let encoded = try depthEncoder.encode(capturedDepth)
                let depthTime = clock.now - depthStart
                record.depth = encoded.record
                depthPayload = encoded.payload
                // The same tight-packed bytes that are about to be written,
                // held back for a tap. Not a second pass over the buffer and
                // not a copy of ARKit's: `encode` already produced these on
                // its way to the payload.
                sighted = (
                    encoded.packedDepth, encoded.packedConfidence,
                    encoded.record.width, encoded.record.height
                )

                stats.withDepth += 1
                stats.depthPackedBytes += encoded.packedBytes
                stats.depthWrittenBytes += encoded.payload.depth.count
                    + (encoded.payload.confidence?.count ?? 0)
                stats.totalDepthEncode += depthTime
                stats.maxDepthEncode = max(stats.maxDepthEncode, depthTime)
                stats.depthFormats.insert(encoded.depthFormat)
                if let tally = encoded.tally {
                    stats.withConfidence += 1
                    stats.confidenceTally.merge(tally)
                }
                if let confidenceFormat = encoded.confidenceFormat {
                    stats.confidenceFormats.insert(confidenceFormat)
                }
            } else {
                stats.withoutDepth += 1
            }
            if let exposure = record.exposure {
                stats.minExposureDuration = min(stats.minExposureDuration, exposure.duration)
                stats.maxExposureDuration = max(stats.maxExposureDuration, exposure.duration)
                stats.exposureDurationSum += exposure.duration
                stats.minExposureOffset = min(stats.minExposureOffset, exposure.offset)
                stats.maxExposureOffset = max(stats.maxExposureOffset, exposure.offset)
            }
            if let intrinsics = record.intrinsics {
                stats.minFocalLengthX = min(stats.minFocalLengthX, intrinsics.focalLengthX)
                stats.maxFocalLengthX = max(stats.maxFocalLengthX, intrinsics.focalLengthX)
                stats.minFocalLengthY = min(stats.minFocalLengthY, intrinsics.focalLengthY)
                stats.maxFocalLengthY = max(stats.maxFocalLengthY, intrinsics.focalLengthY)
                stats.minPrincipalPointX = min(stats.minPrincipalPointX, intrinsics.principalPointX)
                stats.maxPrincipalPointX = max(stats.maxPrincipalPointX, intrinsics.principalPointX)
                stats.minPrincipalPointY = min(stats.minPrincipalPointY, intrinsics.principalPointY)
                stats.maxPrincipalPointY = max(stats.maxPrincipalPointY, intrinsics.principalPointY)
                stats.intrinsicsReferenceSizes.insert("\(intrinsics.referenceWidth)x\(intrinsics.referenceHeight)")
            }
            let containerIndex: Int
            if let data {
                containerIndex = try writer.append(data, depth: depthPayload)
                stats.fileEncodedCount += 1
                stats.totalBytes += data.count
                stats.totalEncode += encodeTime
                stats.maxEncode = max(stats.maxEncode, encodeTime)
            } else {
                containerIndex = try writer.appendVideoFrame(depth: depthPayload)
            }
            // Published after the write, under the index the write assigned.
            // A tap can then be re-derived with `SightProbe --frame`, which is
            // the only reason a live sighting is worth anything.
            if let sighted {
                latestDepthFrame.store(
                    index: containerIndex,
                    width: sighted.width,
                    height: sighted.height,
                    depths: sighted.depths,
                    confidences: sighted.confidences
                )
            }

            records.append(record)
            stats.encodedCount += 1
            if stats.encodedCount.isMultiple(of: 30) {
                let count = stats.encodedCount
                await MainActor.run { self.frameCount = count }
            }
        }
        if let movieWriter {
            stats.videoBytes = try await movieWriter.finish()
        }
        // Only the movie-track layout claims the track; a dual capture's
        // movie rides unclaimed beside the canonical per-frame layout, so
        // the schema never describes a mixed state. A movie run that kept
        // zero frames wrote no movie and claims nothing.
        let videoTrack: VideoTrackRecord?
        if case .movieTrack = storage, let movieWriter, movieWriter.appendedSampleCount > 0 {
            videoTrack = VideoTrackRecord(
                codec: movieWriter.codec,
                timescale: VideoTrackRecord.nanosecondTimescale,
                fragmentInterval: movieWriter.fragmentInterval
            )
        } else {
            videoTrack = nil
        }
        return (records, stats, videoTrack)
    }

    /// The frame probe's numbers. The first line is the accounting invariant:
    /// kept, dropped and strided are disjoint and exhaustive over the
    /// callbacks the stream saw, so their sum is the callback count -- if a
    /// ceiling estimate does not close against it, the estimate is wrong, not
    /// the counters.
    private nonisolated static func framePanel(
        stats: FrameStats,
        kept: Int,
        dropped: Int,
        strided: Int,
        sceneDepthSupported: Bool
    ) -> String {
        func milliseconds(_ duration: Duration) -> String {
            let ms = Double(duration.components.seconds) * 1000
                + Double(duration.components.attoseconds) / 1e15
            return String(format: "%.2f ms", ms)
        }
        func megabytes(_ bytes: Int) -> String {
            String(format: "%.1f MB", Double(bytes) / 1_048_576)
        }
        // The observed format, printable: four ASCII characters when the code
        // is one, the raw number when it is not.
        func fourCC(_ type: OSType) -> String {
            let bytes = (0..<4).map { UInt8((type >> ((3 - $0) * 8)) & 0xFF) }
            guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }),
                  let name = String(bytes: bytes, encoding: .ascii) else {
                return String(format: "0x%08X", type)
            }
            return "'\(name)'"
        }
        func formats(_ observed: Set<OSType>) -> String {
            observed.isEmpty ? "none" : observed.map(fourCC).sorted().joined(separator: " ")
        }
        var panel = "frames          \(kept) kept + \(dropped) dropped + \(strided) strided = \(kept + dropped + strided) callbacks"
        if let storage = stats.storage {
            panel += "\nstorage         \(storage)"
        }
        if stats.videoAppendCount > 0 {
            let meanAppend = stats.totalVideoAppend / stats.videoAppendCount
            let meanVideoKilobytes = Double(stats.videoBytes) / Double(stats.videoAppendCount) / 1024
            panel += """

                video append    mean \(milliseconds(meanAppend)), max \(milliseconds(stats.maxVideoAppend))
                video waits     \(stats.videoWaits), max \(String(format: "%.1f ms", stats.maxVideoWait * 1000))
                video payload   \(megabytes(stats.videoBytes)), mean \(String(format: "%.0f KB", meanVideoKilobytes))/frame
                """
        }
        // The payload and encode rows are the per-frame file path's; their
        // divisor and gate is `fileEncodedCount`, so a movie run prints no
        // JPEG numbers it never paid. Drain lag and the metadata ranges
        // belong to every path.
        if stats.fileEncodedCount > 0 {
            let meanKilobytes = Double(stats.totalBytes) / Double(stats.fileEncodedCount) / 1024
            let meanEncode = stats.totalEncode / stats.fileEncodedCount
            panel += """

                payload         \(megabytes(stats.totalBytes)), mean \(String(format: "%.0f KB", meanKilobytes))/frame
                encode          mean \(milliseconds(meanEncode)), max \(milliseconds(stats.maxEncode))
                """
        }
        if stats.encodedCount > 0 {
            panel += "\nencode lag max  \(String(format: "%.1f ms", stats.maxLag * 1000))"
            if stats.exposureDurationSum > 0 || stats.maxExposureDuration > 0 {
                let meanExposureDuration = stats.exposureDurationSum / Double(stats.encodedCount)
                panel += "\nexposure        duration \(String(format: "%.2f", stats.minExposureDuration * 1000))"
                    + "-\(String(format: "%.2f", stats.maxExposureDuration * 1000)) ms"
                    + ", mean \(String(format: "%.2f ms", meanExposureDuration * 1000))"
                    + "; offset \(String(format: "%.2f", stats.minExposureOffset))"
                    + "-\(String(format: "%.2f", stats.maxExposureOffset)) EV"
            }
            if !stats.intrinsicsReferenceSizes.isEmpty {
                panel += "\nintrinsics      fx \(String(format: "%.2f", stats.minFocalLengthX))"
                    + "-\(String(format: "%.2f", stats.maxFocalLengthX))"
                    + ", fy \(String(format: "%.2f", stats.minFocalLengthY))"
                    + "-\(String(format: "%.2f", stats.maxFocalLengthY))"
                    + ", cx \(String(format: "%.2f", stats.minPrincipalPointX))"
                    + "-\(String(format: "%.2f", stats.maxPrincipalPointX))"
                    + ", cy \(String(format: "%.2f", stats.minPrincipalPointY))"
                    + "-\(String(format: "%.2f", stats.maxPrincipalPointY))"
                    + "; reference \(stats.intrinsicsReferenceSizes.sorted().joined(separator: " "))"
            }
        }
        panel += "\nscene depth     \(sceneDepthSupported ? "supported" : "unsupported")"
        if stats.withDepth > 0 {
            let meanDepthKilobytes = Double(stats.depthWrittenBytes) / Double(stats.withDepth) / 1024
            let meanDepthEncode = stats.totalDepthEncode / stats.withDepth
            let ratio = stats.depthPackedBytes > 0
                ? String(format: "%.2f", Double(stats.depthWrittenBytes) / Double(stats.depthPackedBytes))
                : "n/a"
            panel += """

                depth           \(stats.withDepth) with + \(stats.withoutDepth) without = \(stats.withDepth + stats.withoutDepth) encoded; \(stats.withConfidence) confidence
                depth formats   depth \(formats(stats.depthFormats)), confidence \(formats(stats.confidenceFormats))
                depth payload   \(megabytes(stats.depthWrittenBytes)) written, mean \(String(format: "%.0f KB", meanDepthKilobytes))/frame; packed \(megabytes(stats.depthPackedBytes)), ratio \(ratio)
                depth encode    mean \(milliseconds(meanDepthEncode)), max \(milliseconds(stats.maxDepthEncode))
                """
            let tally = stats.confidenceTally
            if tally.total > 0 {
                func percent(_ count: Int) -> String {
                    String(format: "%.1f%%", Double(count) * 100 / Double(tally.total))
                }
                panel += "\nconfidence      low \(percent(tally.low)) / medium \(percent(tally.medium)) / high \(percent(tally.high))"
                if tally.other > 0 {
                    panel += " / other \(percent(tally.other))"
                }
            }
        }
        return panel
    }

    /// The two sensors' raw timestamps beside each other, and the normalised
    /// values derived from them, so a base mismatch is visible rather than
    /// silently baked into the file.
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
