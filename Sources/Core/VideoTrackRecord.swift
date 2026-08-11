import Foundation

/// The codec a session's video track was encoded with.
///
/// A struct over a raw string for the same reason as `FrameEncoding`: an enum
/// turns every future codec into a decode failure for every existing reader.
/// An unknown value round-trips losslessly; the named statics cover what the
/// current producer can write.
public struct VideoCodec: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let hevc = VideoCodec(rawValue: "hevc")

    /// The registered contingency codec: measured only if HEVC fails the
    /// drop criterion on device.
    public static let h264 = VideoCodec(rawValue: "h264")
}

/// Session-level metadata for camera frames stored as one movie file rather
/// than one payload file per frame.
///
/// Which file holds the track, and where it sits in the container, stays the
/// storage layer's convention -- the positional philosophy `FrameRecord`
/// already follows. This record says only how the samples inside it are to be
/// interpreted: what encoded them, the timescale their presentation times are
/// expressed in, and whether the file was written in fragments.
///
/// Association between a sample and its `FrameRecord` is exact, never
/// nearest-neighbour: sample `i` carries the presentation time
/// `presentationTimeValue(of:)` derives from `frames[i].timestamp`, so a
/// reader recomputes the same value from the record it wants and matches by
/// equality.
public struct VideoTrackRecord: Codable, Equatable, Sendable {
    /// The nanosecond timescale every video track is written at. An `Int32`
    /// because that is what a `CMTime` timescale is; 1e9 fits.
    public static let nanosecondTimescale: Int32 = 1_000_000_000

    /// The presentation time of a frame captured at `timestamp` (seconds on
    /// the session timeline), in `nanosecondTimescale` units.
    ///
    /// One pure function used by the writer to stamp samples and by a reader
    /// to seek them, so the two cannot round differently. Collisions would
    /// need two kept frames within half a nanosecond; the camera delivers
    /// them no closer than 16.67 ms.
    public static func presentationTimeValue(of timestamp: TimeInterval) -> Int64 {
        Int64((timestamp * Double(nanosecondTimescale)).rounded())
    }

    /// What encoded the track's samples.
    public var codec: VideoCodec

    /// The timescale presentation times are expressed in. Recorded rather
    /// than assumed from `nanosecondTimescale`: the file on disk is the
    /// authority, and a reader that trusts a constant over the record cannot
    /// notice a writer that failed to pin it.
    public var timescale: Int32

    /// Seconds between movie fragments, or `nil` when the file was written
    /// unfragmented. Kept because it is the crash story: an unfragmented
    /// movie killed mid-write loses everything, a fragmented one loses at
    /// most the tail past the last fragment.
    public var fragmentInterval: Double?

    public init(codec: VideoCodec, timescale: Int32, fragmentInterval: Double? = nil) {
        self.codec = codec
        self.timescale = timescale
        self.fragmentInterval = fragmentInterval
    }
}
