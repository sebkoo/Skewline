import Foundation

/// How a frame's pixel payload is represented on disk.
///
/// A struct over a raw string rather than an enum: an enum turns every future
/// encoding into a decode failure for every existing reader, which is the exact
/// failure mode `CaptureSession`'s hand-written decoding exists to prevent. An
/// unknown value round-trips losslessly; the named statics cover what the
/// current producer can write.
public struct FrameEncoding: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let jpeg = FrameEncoding(rawValue: "jpeg")
    public static let heic = FrameEncoding(rawValue: "heic")
}

/// One camera frame's measurement record: when it was captured and what shape
/// its pixel payload takes.
///
/// The pixels themselves are not here. They do not fit the session's JSON — a
/// minute of capture is thousands of frames — so a session stores this record
/// and the payload lives beside the session as opaque bytes, associated by
/// position: the record's index in `CaptureSession.frames` identifies its
/// payload. How that position becomes a file is the storage layer's convention,
/// not this type's.
public struct FrameRecord: Codable, Equatable, Sendable {
    /// Frame capture time, seconds since the owning session's start -- the same
    /// timeline as `PoseObservation.timestamp`, normalised against the same
    /// origin.
    public var timestamp: TimeInterval

    /// Pixel width of the encoded image.
    public var width: Int

    /// Pixel height of the encoded image.
    public var height: Int

    /// How the payload bytes are encoded.
    public var encoding: FrameEncoding

    /// The depth captured from the same `ARFrame`, or `nil` when the frame
    /// carried none. Optional, so synthesized decoding falls back through
    /// `decodeIfPresent` and sessions recorded before depth existed -- or on a
    /// device without the sensor -- keep decoding unchanged.
    public var depth: DepthRecord?

    /// The camera's exposure settings at capture, or `nil` when the frame's
    /// source never queried them. Optional for the same reason as `depth`:
    /// synthesized decoding falls back through `decodeIfPresent`, so sessions
    /// recorded before this field existed keep decoding unchanged, and a
    /// metadata-less capture writes JSON with no `exposure` key at all.
    public var exposure: ExposureRecord?

    /// The camera's pinhole intrinsics at capture, or `nil` when the frame's
    /// source never queried them. Optional for the same reason as
    /// `exposure`: synthesized decoding falls back through
    /// `decodeIfPresent`, so sessions recorded before this field existed
    /// keep decoding unchanged.
    public var intrinsics: IntrinsicsRecord?

    public init(
        timestamp: TimeInterval,
        width: Int,
        height: Int,
        encoding: FrameEncoding,
        depth: DepthRecord? = nil,
        exposure: ExposureRecord? = nil,
        intrinsics: IntrinsicsRecord? = nil
    ) {
        self.timestamp = timestamp
        self.width = width
        self.height = height
        self.encoding = encoding
        self.depth = depth
        self.exposure = exposure
        self.intrinsics = intrinsics
    }
}
