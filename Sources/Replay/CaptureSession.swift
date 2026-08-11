import Foundation
import Core

/// An ordered, replayable recording of one capture session: what the tracker
/// reported about where the device was, what the inertial sensors reported
/// about how it was moving, and minimal session-level metadata.
///
/// The two sequences are independent. They are aligned only by both being
/// measured from the same timeline origin, so neither indexes into the other
/// and neither needs resampling to be read.
public struct CaptureSession: Codable, Equatable, Sendable {
    public var id: UUID
    public var startDate: Date
    public var observations: [PoseObservation]
    public var inertialSamples: [InertialSample]

    /// Metadata for the camera frames captured alongside the other sequences.
    /// The pixel payloads do not fit here; a container stores them beside the
    /// session, associated by position in this array.
    public var frames: [FrameRecord]

    /// How the frame payloads are stored when they live in one movie file
    /// rather than one file per frame, or `nil` for the per-frame layout --
    /// including every session recorded before this field existed.
    public var videoTrack: VideoTrackRecord?

    public init(
        id: UUID = UUID(),
        startDate: Date = Date(),
        observations: [PoseObservation] = [],
        inertialSamples: [InertialSample] = [],
        frames: [FrameRecord] = [],
        videoTrack: VideoTrackRecord? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.observations = observations
        self.inertialSamples = inertialSamples
        self.frames = frames
        self.videoTrack = videoTrack
    }

    private enum CodingKeys: String, CodingKey {
        case id, startDate, observations, inertialSamples, frames, videoTrack
    }

    /// Hand-written only to let `inertialSamples` and `frames` be absent.
    ///
    /// Synthesised decoding never falls back to a property's default value -- a
    /// missing key throws `keyNotFound` -- so sessions recorded before these
    /// fields existed would stop decoding the moment one was added. Encoding
    /// stays synthesised: everything written from here on has the keys.
    /// (`videoTrack` is optional, so its `decodeIfPresent` fallback is what
    /// synthesis would do anyway; it rides here because the initializer is
    /// already hand-written.)
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startDate = try container.decode(Date.self, forKey: .startDate)
        observations = try container.decode([PoseObservation].self, forKey: .observations)
        inertialSamples = try container.decodeIfPresent([InertialSample].self, forKey: .inertialSamples) ?? []
        frames = try container.decodeIfPresent([FrameRecord].self, forKey: .frames) ?? []
        videoTrack = try container.decodeIfPresent(VideoTrackRecord.self, forKey: .videoTrack)
    }
}

/// Reads and writes `CaptureSession` to/from JSON, on disk or in memory.
public enum SessionCodec {
    public static func encode(_ session: CaptureSession) throws -> Data {
        try JSONEncoder().encode(session)
    }

    public static func decode(_ data: Data) throws -> CaptureSession {
        try JSONDecoder().decode(CaptureSession.self, from: data)
    }

    public static func write(_ session: CaptureSession, to url: URL) throws {
        try encode(session).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> CaptureSession {
        try decode(Data(contentsOf: url))
    }
}
