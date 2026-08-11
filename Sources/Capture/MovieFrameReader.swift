#if canImport(AVFoundation)
import AVFoundation
import Core
import CoreVideo
import Foundation

/// One decoded sample from a session's video track: the presentation time as
/// stored, and the pixels it decoded to.
public struct MovieFrameSample {
    public let presentationTime: CMTime
    public let pixelBuffer: CVPixelBuffer

    public init(presentationTime: CMTime, pixelBuffer: CVPixelBuffer) {
        self.presentationTime = presentationTime
        self.pixelBuffer = pixelBuffer
    }
}

/// Frame-exact read-back of a session's video track: fetch the sample for
/// one `FrameRecord`, or walk them all in order.
///
/// Exactness is the contract, enforced rather than assumed: a fetch computes
/// the record's presentation time with the same pure function the writer
/// stamped it with, and a sample that comes back at any other time is an
/// error, never a nearest-neighbour answer.
///
/// Decode output is pinned to one pixel format, ARKit's bi-planar full-range
/// 4:2:0 -- the format the samples went in as -- so two decodes of the same
/// file are comparable byte for byte and a determinism check measures the
/// decoder, not a format conversion lottery.
///
/// TODO(owner): this type lives in `Capture` because the app target is
/// unreachable from the test suite and `Replay` is deliberately
/// Foundation-only, but `Render` must never import `Capture` -- the day a
/// Render-side consumer decodes RGB, this reader has to move.
public final class MovieFrameReader {
    public enum Failure: Error {
        case noVideoTrack(URL)
        case readFailed(String)
        /// No sample sits at the requested presentation time.
        case sampleNotFound(CMTime)
        /// A sample came back at a different presentation time than the
        /// record derives -- the exact-match contract's loud failure.
        case presentationTimeMismatch(expected: CMTime, found: CMTime)
        case missingImageBuffer(CMTime)
    }

    public let url: URL

    /// The track's timescale as stored in the file -- the writer pins it to
    /// `VideoTrackRecord.nanosecondTimescale`, and the probe asserts the pin
    /// held rather than trusting it.
    public let timescale: CMTimeScale

    private let asset: AVURLAsset
    private let track: AVAssetTrack

    public init(contentsOf url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideoTrack(url)
        }
        self.url = url
        self.timescale = try await track.load(.naturalTimeScale)
        self.asset = asset
        self.track = track
    }

    /// The decoded sample for a frame captured at `timestamp` (seconds on
    /// the session timeline), fetched by exact presentation time.
    public func frame(at timestamp: TimeInterval) throws -> MovieFrameSample {
        let expected = VideoTrackRecord.presentationTime(of: timestamp)
        let reader = try AVAssetReader(asset: asset)
        // One tick past the sample's own time: the range holds exactly the
        // sample stamped at `expected`, and the reader still decodes from
        // the preceding sync frame on its own.
        reader.timeRange = CMTimeRange(
            start: expected,
            duration: CMTime(value: 1, timescale: expected.timescale)
        )
        let output = makeOutput()
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.readFailed(describeStatus(of: reader))
        }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer() else {
            throw Failure.sampleNotFound(expected)
        }
        let found = CMSampleBufferGetPresentationTimeStamp(sample)
        guard found == expected else {
            throw Failure.presentationTimeMismatch(expected: expected, found: found)
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw Failure.missingImageBuffer(found)
        }
        return MovieFrameSample(presentationTime: found, pixelBuffer: pixelBuffer)
    }

    /// Decodes every written sample in presentation order. The samples were
    /// written with frame reordering disabled, so the `i`th call is
    /// `CaptureSession.frames[i]`.
    ///
    /// The movie starts at the session origin and the first kept frame sits
    /// later, so the track opens with an empty edit -- and the reader
    /// materialises that gap as a synthesized frame stamped `CMTime.zero`,
    /// timescale 1. Written samples all carry the pinned nanosecond
    /// timescale, so a sample on any other timescale is an edit realisation,
    /// not a frame anyone recorded, and is skipped. The probe's
    /// pts-verification pass checks every surviving sample against its
    /// record, so a skip rule that ever ate a real frame would fail there
    /// loudly, not silently.
    public func forEachFrame(_ body: (MovieFrameSample) throws -> Void) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = makeOutput()
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.readFailed(describeStatus(of: reader))
        }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard presentationTime.timescale == timescale else { continue }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                throw Failure.missingImageBuffer(presentationTime)
            }
            try body(MovieFrameSample(presentationTime: presentationTime, pixelBuffer: pixelBuffer))
        }
        if reader.status == .failed {
            throw Failure.readFailed(describeStatus(of: reader))
        }
    }

    private func makeOutput() -> AVAssetReaderTrackOutput {
        AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
        )
    }

    private func describeStatus(of reader: AVAssetReader) -> String {
        if let error = reader.error {
            return error.localizedDescription
        }
        return "reader status \(reader.status.rawValue)"
    }
}
#endif
