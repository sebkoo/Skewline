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

    public init(
        id: UUID = UUID(),
        startDate: Date = Date(),
        observations: [PoseObservation] = [],
        inertialSamples: [InertialSample] = []
    ) {
        self.id = id
        self.startDate = startDate
        self.observations = observations
        self.inertialSamples = inertialSamples
    }

    private enum CodingKeys: String, CodingKey {
        case id, startDate, observations, inertialSamples
    }

    /// Hand-written only to let `inertialSamples` be absent.
    ///
    /// Synthesised decoding never falls back to a property's default value -- a
    /// missing key throws `keyNotFound` -- so sessions recorded before this
    /// field existed would stop decoding the moment it was added. Encoding
    /// stays synthesised: everything written from here on has the key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startDate = try container.decode(Date.self, forKey: .startDate)
        observations = try container.decode([PoseObservation].self, forKey: .observations)
        inertialSamples = try container.decodeIfPresent([InertialSample].self, forKey: .inertialSamples) ?? []
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
