#if canImport(AVFoundation)
import AVFoundation
import Core
import CoreVideo
import Foundation

extension VideoTrackRecord {
    /// `presentationTimeValue(of:)` as the `CMTime` AVFoundation speaks --
    /// value and timescale paired here, once, so the writer stamping a sample
    /// and a reader seeking it cannot pair them differently.
    public static func presentationTime(of timestamp: TimeInterval) -> CMTime {
        CMTime(
            value: presentationTimeValue(of: timestamp),
            timescale: CMTimeScale(nanosecondTimescale)
        )
    }
}

/// Hands kept camera frames to `AVAssetWriter`, so the hardware temporal
/// encoder writes one movie file into the container instead of one payload
/// file per frame.
///
/// Feed this the ring's copied pixel buffer, never ARKit's own
/// `capturedImage` buffer: ARKit recycles a small buffer pool, and a buffer
/// retained past the callback -- which is exactly what an encoder queue does
/// -- starves that pool and corrupts the drop measurement this path is
/// gated on. The buffer is appended as delivered, no color conversion: that
/// conversion is a cost only the per-frame JPEG path pays.
///
/// Every sample is stamped by `VideoTrackRecord.presentationTime(of:)`, and
/// both the movie and the input are pinned to the same nanosecond timescale
/// -- left unpinned, AVFoundation may rescale samples to a default timescale,
/// and the exact-match seek contract would fail by rounding while looking
/// correct in design. Frame reordering is disabled, so sample order is
/// append order and sample `i` is `CaptureSession.frames[i]`.
///
/// Deliberately not `Sendable`, like `SessionContainer.Writer`: appends are
/// sequential by contract, so the type that cannot be shared is the honest
/// shape. Create it inside the one task that drains the frame stream.
public final class MovieFrameWriter {
    public enum Failure: Error {
        /// This writer maps named codecs onto `AVVideoCodecType`; a raw
        /// value it has never heard of round-trips a container but cannot
        /// drive an encoder.
        case unsupportedCodec(VideoCodec)
        case startFailed(String)
        case appendFailed(String)
        case finishFailed(String)
        /// A pixel buffer arrived with different dimensions than the first
        /// one. The track's output settings are fixed at start; a resolution
        /// change mid-capture is a fact worth failing on, not resampling
        /// away.
        case dimensionChanged(width: Int, height: Int)
    }

    public let url: URL
    public let codec: VideoCodec
    /// Seconds between movie fragments, or `nil` for an unfragmented file --
    /// the value `VideoTrackRecord.fragmentInterval` records. Measured, not
    /// theoretical: a mid-capture kill left an unfragmented file's
    /// 16,131,338 bytes entirely unrecoverable -- no moov was ever written
    /// -- while 1 s fragments bounded the loss at the last closed fragment
    /// boundary. The harness passes 1 s; `nil` here is a caller's explicit
    /// choice, not a recommendation.
    public let fragmentInterval: TimeInterval?
    public private(set) var appendedSampleCount = 0

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var width = 0
    private var height = 0

    public init(url: URL, codec: VideoCodec = .hevc, fragmentInterval: TimeInterval? = nil) {
        self.url = url
        self.codec = codec
        self.fragmentInterval = fragmentInterval
    }

    /// Appends one frame, stamped at the presentation time derived from
    /// `timestamp` (seconds on the session timeline). The first append fixes
    /// the track's dimensions and starts the movie at the session origin, so
    /// the movie's timeline is the session's.
    ///
    /// Returns how long the append waited for the encoder to accept more
    /// data -- normally zero with a realtime input; a non-zero wait is drain
    /// time the ring pays for, so the caller counts it rather than averaging
    /// it away.
    @discardableResult
    public func append(_ pixelBuffer: CVPixelBuffer, at timestamp: TimeInterval) throws -> TimeInterval {
        let presentationTime = VideoTrackRecord.presentationTime(of: timestamp)
        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        if writer == nil {
            try start(width: bufferWidth, height: bufferHeight, at: presentationTime)
        }
        guard bufferWidth == width, bufferHeight == height else {
            throw Failure.dimensionChanged(width: bufferWidth, height: bufferHeight)
        }
        guard let writer, let input, let adaptor else {
            throw Failure.appendFailed("writer disappeared between start and append")
        }

        var waited: TimeInterval = 0
        if !input.isReadyForMoreMediaData {
            let clock = ContinuousClock()
            let waitStart = clock.now
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw Failure.appendFailed(describeStatus(of: writer))
                }
                usleep(500)
            }
            let elapsed = clock.now - waitStart
            waited = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        }

        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw Failure.appendFailed(describeStatus(of: writer))
        }
        appendedSampleCount += 1
        return waited
    }

    /// Seals the movie and returns its size in bytes. A writer that was
    /// never fed a frame has no file to seal and returns zero.
    public func finish() async throws -> Int {
        guard let writer, let input else { return 0 }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Failure.finishFailed(describeStatus(of: writer))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? Int) ?? 0
    }

    private func start(width: Int, height: Int, at presentationTime: CMTime) throws {
        let videoCodec: AVVideoCodecType
        switch codec {
        case .hevc:
            videoCodec = .hevc
        case .h264:
            videoCodec = .h264
        default:
            throw Failure.unsupportedCodec(codec)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieTimeScale = CMTimeScale(VideoTrackRecord.nanosecondTimescale)
        if let fragmentInterval {
            writer.movieFragmentInterval = CMTime(
                seconds: fragmentInterval,
                preferredTimescale: CMTimeScale(VideoTrackRecord.nanosecondTimescale)
            )
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: false],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.mediaTimeScale = CMTimeScale(VideoTrackRecord.nanosecondTimescale)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: nil
        )
        guard writer.canAdd(input) else {
            throw Failure.startFailed("writer refused the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.startFailed(describeStatus(of: writer))
        }
        // The movie's timeline is the session's, origin included. Starting
        // at the first sample's time instead would shift the asset timeline
        // by that first timestamp, and a reader would need to know it to
        // seek -- an offset the exact-match mapping exists to not have.
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.width = width
        self.height = height
    }

    private func describeStatus(of writer: AVAssetWriter) -> String {
        if let error = writer.error {
            return error.localizedDescription
        }
        return "writer status \(writer.status.rawValue)"
    }
}
#endif
