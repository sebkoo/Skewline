import Foundation
import Core

public enum SessionContainerError: Error, Equatable {
    case directoryAlreadyExists(URL)
    case missingSessionFile(URL)
    case frameCountMismatch(recorded: Int, appended: Int)
    case frameIndexOutOfRange(index: Int, count: Int)
}

/// The on-disk container for a session that carries camera frames:
/// `session.json` beside a `frames/` directory holding one opaque payload per
/// frame.
///
/// A frame payload is `Data` to this layer. Encoding pixels is the producer's
/// job and decoding them is the consumer's; keeping both out of here is what
/// keeps `Replay` depending on `Core` alone.
///
/// A payload is associated with its `FrameRecord` by position: index `i` in
/// `CaptureSession.frames` names the file for `frameData(at: i)`. Nothing in
/// the records repeats that mapping, so it cannot drift from the layout.
///
/// `session.json` is written last, atomically, and is the completeness marker:
/// a directory without one -- a capture that crashed mid-write -- cannot be
/// read as a session, only inspected.
public enum SessionContainer {
    public static let pathExtension = "skewline"
    public static let sessionFileName = "session.json"
    static let framesDirectoryName = "frames"

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

        /// Creates the container directory and its `frames/` subdirectory.
        /// Refuses a URL that already exists rather than appending into it.
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

        /// Writes one frame payload and returns the index it was stored at --
        /// the index its `FrameRecord` must occupy in the finalized session.
        @discardableResult
        public func append(_ frameData: Data) throws -> Int {
            let index = appendedFrameCount
            let file = SessionContainer.framesDirectory(in: url)
                .appending(path: SessionContainer.frameFileName(at: index))
            try frameData.write(to: file)
            appendedFrameCount += 1
            return index
        }

        /// Seals the container by writing `session.json`.
        ///
        /// Throws without writing if the session's `frames` count does not
        /// match what was appended: a session claiming payloads that are not
        /// there -- or silently ignoring payloads that are -- is exactly what
        /// the completeness marker exists to rule out.
        public func finalize(session: CaptureSession) throws {
            guard session.frames.count == appendedFrameCount else {
                throw SessionContainerError.frameCountMismatch(
                    recorded: session.frames.count,
                    appended: appendedFrameCount
                )
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
    }
}
