import Foundation

/// How a capture stores its kept frames' pixels -- the knob the v0.4 storage
/// walks measured: `.movieTrack(fragmentInterval: 1)` is the default those
/// walks chose, and `.perFrameFiles` stays behind the knob because keeping
/// it costs `Replay` nothing. Toggled by editing the default in
/// `SessionRecorder.start()`, the same practice as the capture matrix; a
/// settings UI would be a second job the harness must not grow.
///
/// `.dual` is a measurement shape, not a shipping format: it writes the
/// canonical per-frame container -- `session.json` claims no video track --
/// with `video.mov` riding along unclaimed, so one walk scores both paths'
/// bytes and timing on identical frames.
///
/// `nonisolated`: the app target defaults to `MainActor`, and this value
/// belongs to the drain task.
nonisolated enum VideoStoragePolicy {
    case perFrameFiles
    case movieTrack(fragmentInterval: TimeInterval?)
    case dual(fragmentInterval: TimeInterval?)

    /// Whether the drain encodes per-frame payload files.
    var writesPayloadFiles: Bool {
        switch self {
        case .perFrameFiles, .dual: true
        case .movieTrack: false
        }
    }

    /// Whether the drain appends frames to a movie writer.
    var writesMovie: Bool {
        switch self {
        case .perFrameFiles: false
        case .movieTrack, .dual: true
        }
    }

    var fragmentInterval: TimeInterval? {
        switch self {
        case .perFrameFiles: nil
        case .movieTrack(let interval), .dual(let interval): interval
        }
    }

    /// The panel's `storage` row, or `nil` for the per-frame path -- the
    /// panel a per-frame run prints is exactly the one it printed before
    /// this knob existed.
    var panelLabel: String? {
        switch self {
        case .perFrameFiles: nil
        case .movieTrack: "movie"
        case .dual: "dual"
        }
    }
}
