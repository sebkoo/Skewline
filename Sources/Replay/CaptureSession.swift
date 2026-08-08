import Foundation
import Core

/// An ordered, replayable recording of pose observations from one capture
/// session, plus minimal session-level metadata.
public struct CaptureSession: Codable, Equatable, Sendable {
    public var id: UUID
    public var startDate: Date
    public var observations: [PoseObservation]

    public init(id: UUID = UUID(), startDate: Date = Date(), observations: [PoseObservation] = []) {
        self.id = id
        self.startDate = startDate
        self.observations = observations
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
