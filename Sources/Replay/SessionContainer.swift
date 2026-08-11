import Foundation
import Core

public enum SessionContainerError: Error, Equatable {
    case directoryAlreadyExists(URL)
    case missingSessionFile(URL)
    case frameCountMismatch(recorded: Int, appended: Int)
    case frameIndexOutOfRange(index: Int, count: Int)
    /// The session's frame at this index disagrees with what was appended
    /// about whether it has a depth payload -- claimed but never written, or
    /// written but never claimed.
    case depthPresenceMismatch(index: Int)
    /// Same disagreement, for the confidence payload.
    case confidencePresenceMismatch(index: Int)
    /// A depth payload was requested for a frame whose record claims none.
    case noDepthRecorded(index: Int)
    /// A confidence payload was requested for a frame whose record claims
    /// none.
    case noConfidenceRecorded(index: Int)
}

/// The on-disk container for a session that carries camera frames:
/// `session.json` beside a `frames/` directory holding one opaque payload per
/// frame, with sibling `depth/` and `confidence/` directories for the frames
/// that captured depth.
///
/// A payload is `Data` to this layer. Encoding pixels -- or depth samples --
/// is the producer's job; decoding pixels is the consumer's, because their
/// decode drags an image framework. Depth's inverse is Foundation-only byte
/// arithmetic, so it lives beside the format in `DepthDecoder` -- the split
/// follows what each half would import, which is what keeps `Replay`
/// depending on `Core` alone.
///
/// A payload is associated with its `FrameRecord` by position: index `i` in
/// `CaptureSession.frames` names the file for `frameData(at: i)`, and the
/// same name in `depth/` and `confidence/` when the record claims them.
/// Nothing in the records repeats that mapping, so it cannot drift from the
/// layout.
///
/// `session.json` is written last, atomically, and is the completeness marker:
/// a directory without one -- a capture that crashed mid-write -- cannot be
/// read as a session, only inspected.
public enum SessionContainer {
    public static let pathExtension = "skewline"
    public static let sessionFileName = "session.json"
    static let framesDirectoryName = "frames"
    static let depthDirectoryName = "depth"
    static let confidenceDirectoryName = "confidence"

    /// One frame's depth payloads: the map, and optionally its confidence.
    ///
    /// `Data` to this layer, like a frame payload. Confidence without depth
    /// is unconstructible here on purpose -- ARKit's confidence annotates a
    /// depth map and the record shape nests it inside the depth record, so
    /// the writer's input mirrors what the format can say.
    public struct DepthPayload: Sendable {
        public let depth: Data
        public let confidence: Data?

        public init(depth: Data, confidence: Data? = nil) {
            self.depth = depth
            self.confidence = confidence
        }
    }

    /// Index `i` becomes `frames/000000`-style, zero-padded so a directory
    /// listing sorts in capture order. No extension: the payload's encoding is
    /// `FrameRecord.encoding`'s claim, and a filename that repeated it could
    /// contradict it.
    static func frameFileName(at index: Int) -> String {
        String(format: "%06d", index)
    }

    static func framesDirectory(in url: URL) -> URL {
        url.appending(path: framesDirectoryName)
    }

    static func depthDirectory(in url: URL) -> URL {
        url.appending(path: depthDirectoryName)
    }

    static func confidenceDirectory(in url: URL) -> URL {
        url.appending(path: confidenceDirectoryName)
    }

    static func sessionFile(in url: URL) -> URL {
        url.appending(path: sessionFileName)
    }

    /// Writes one container, frame by frame, then seals it.
    ///
    /// Deliberately not `Sendable`: indices are sequential, so the format
    /// cannot support concurrent appends, and a type the compiler refuses to
    /// share is the honest way to say so. Create it inside the one task that
    /// drains the frame stream.
    ///
    /// Whether a failed capture's directory is deleted is the caller's policy,
    /// not this type's: no method here removes anything.
    public final class Writer {
        public let url: URL
        public private(set) var appendedFrameCount = 0

        /// The frame indices at which a depth payload was written, and those
        /// at which a confidence payload was. Indices rather than counts:
        /// depth is optional per frame, so only positions can say whether the
        /// records and the files agree about *which* frames have it.
        private var depthIndices: Set<Int> = []
        private var confidenceIndices: Set<Int> = []

        /// Creates the container directory and its `frames/` subdirectory.
        /// Refuses a URL that already exists rather than appending into it.
        ///
        /// `depth/` and `confidence/` are not created here: they appear on
        /// the first payload written into them, so a capture without depth
        /// produces a container laid out exactly as before depth existed.
        public init(creatingAt url: URL) throws {
            if FileManager.default.fileExists(atPath: url.path) {
                throw SessionContainerError.directoryAlreadyExists(url)
            }
            try FileManager.default.createDirectory(
                at: SessionContainer.framesDirectory(in: url),
                withIntermediateDirectories: true
            )
            self.url = url
        }

        /// Writes one frame payload -- and its depth payloads, when the frame
        /// has them -- and returns the index they were stored at: the index
        /// the frame's `FrameRecord` must occupy in the finalized session.
        @discardableResult
        public func append(_ frameData: Data, depth: DepthPayload? = nil) throws -> Int {
            let index = appendedFrameCount
            let name = SessionContainer.frameFileName(at: index)
            let file = SessionContainer.framesDirectory(in: url).appending(path: name)
            try frameData.write(to: file)
            if let depth {
                try write(depth.depth, named: name, in: SessionContainer.depthDirectory(in: url))
                depthIndices.insert(index)
                if let confidence = depth.confidence {
                    try write(confidence, named: name, in: SessionContainer.confidenceDirectory(in: url))
                    confidenceIndices.insert(index)
                }
            }
            appendedFrameCount += 1
            return index
        }

        private func write(_ data: Data, named name: String, in directory: URL) throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: name))
        }

        /// Seals the container by writing `session.json`.
        ///
        /// Throws without writing if the session's `frames` count does not
        /// match what was appended, or if any frame disagrees with the files
        /// about having a depth or confidence payload. The depth check is
        /// positional, not a count: counts can match while the holes sit at
        /// the wrong indices, and a sealed container whose records point at
        /// missing files is exactly what the completeness marker exists to
        /// rule out.
        public func finalize(session: CaptureSession) throws {
            guard session.frames.count == appendedFrameCount else {
                throw SessionContainerError.frameCountMismatch(
                    recorded: session.frames.count,
                    appended: appendedFrameCount
                )
            }
            for (index, frame) in session.frames.enumerated() {
                guard (frame.depth != nil) == depthIndices.contains(index) else {
                    throw SessionContainerError.depthPresenceMismatch(index: index)
                }
                guard (frame.depth?.confidence != nil) == confidenceIndices.contains(index) else {
                    throw SessionContainerError.confidencePresenceMismatch(index: index)
                }
            }
            try SessionCodec.write(session, to: SessionContainer.sessionFile(in: url))
        }
    }

    /// Reads a finalized container: the session eagerly, frame payloads on
    /// demand.
    ///
    /// Lazy on purpose -- validating thousands of payload files at `init`
    /// would be one stat per frame duplicating what `frameData(at:)` reports
    /// anyway.
    public struct Reader: Sendable {
        public let url: URL
        public let session: CaptureSession

        public init(contentsOf url: URL) throws {
            let sessionFile = SessionContainer.sessionFile(in: url)
            guard FileManager.default.fileExists(atPath: sessionFile.path) else {
                throw SessionContainerError.missingSessionFile(url)
            }
            self.url = url
            self.session = try SessionCodec.read(from: sessionFile)
        }

        /// The payload for `session.frames[index]`, as written.
        public func frameData(at index: Int) throws -> Data {
            guard session.frames.indices.contains(index) else {
                throw SessionContainerError.frameIndexOutOfRange(index: index, count: session.frames.count)
            }
            let file = SessionContainer.framesDirectory(in: url)
                .appending(path: SessionContainer.frameFileName(at: index))
            return try Data(contentsOf: file)
        }

        /// The depth payload for `session.frames[index]`, as written.
        ///
        /// Three failures stay distinct: an index outside the session throws
        /// `frameIndexOutOfRange`; a frame whose record claims no depth
        /// throws `noDepthRecorded` -- a question the session already
        /// answers; a record that claims depth whose file is missing -- a
        /// container the writer's checks would have refused to seal -- throws
        /// the underlying file error.
        public func depthData(at index: Int) throws -> Data {
            guard session.frames.indices.contains(index) else {
                throw SessionContainerError.frameIndexOutOfRange(index: index, count: session.frames.count)
            }
            guard session.frames[index].depth != nil else {
                throw SessionContainerError.noDepthRecorded(index: index)
            }
            let file = SessionContainer.depthDirectory(in: url)
                .appending(path: SessionContainer.frameFileName(at: index))
            return try Data(contentsOf: file)
        }

        /// The confidence payload for `session.frames[index]`, as written.
        /// Failure modes as in `depthData(at:)`.
        public func confidenceData(at index: Int) throws -> Data {
            guard session.frames.indices.contains(index) else {
                throw SessionContainerError.frameIndexOutOfRange(index: index, count: session.frames.count)
            }
            guard session.frames[index].depth?.confidence != nil else {
                throw SessionContainerError.noConfidenceRecorded(index: index)
            }
            let file = SessionContainer.confidenceDirectory(in: url)
                .appending(path: SessionContainer.frameFileName(at: index))
            return try Data(contentsOf: file)
        }
    }
}
