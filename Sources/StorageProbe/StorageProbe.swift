import Core
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Replay

#if canImport(AVFoundation)
import AVFoundation
import Capture
#endif

/// Measures what replay pays for a container's frame storage: frame-exact
/// random access, cold and warm, for the video-track path against the
/// per-frame file path -- the registered replay-contract criterion of the
/// storage decision -- plus the two checks the movie path must pass to be a
/// candidate at all: every sample sits at exactly the presentation time its
/// `FrameRecord` derives, and two decodes of the same file byte-reproduce.
///
/// A per-frame fetch ends at decoded pixels, not at `Data`: a movie fetch
/// necessarily decodes, so a comparison that stopped at file bytes would
/// flatter the file path. Runs on the analysis Mac, which is where replay
/// actually happens; cross-device decode stability is a question this probe
/// does not answer.
///
/// `@main` on a struct rather than top-level code in `main.swift`, like
/// `RenderProbe`: top-level code is `MainActor`-isolated, and nothing here
/// wants an actor.
@main
struct StorageProbe {
    static let defaultSeed: UInt64 = 0x536B_6577_6C69_6E65  // "Skewline"
    static let defaultFetchCount = 32

    static func main() async {
        var paths: [String] = []
        var seed = defaultSeed
        var fetchCount = defaultFetchCount
        var selected: Set<String> = []
        let known: Set<String> = ["seek", "verify-pts", "determinism"]
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        var usageError = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--seed" || argument == "--fetches" {
                index += 1
                if index < arguments.count, let value = UInt64(arguments[index]) {
                    if argument == "--seed" { seed = value } else { fetchCount = Int(value) }
                } else {
                    usageError = true
                }
            } else if argument.hasPrefix("--"), known.contains(String(argument.dropFirst(2))) {
                selected.insert(String(argument.dropFirst(2)))
            } else if argument.hasPrefix("--") {
                usageError = true
            } else {
                paths.append(argument)
            }
            index += 1
        }
        guard !paths.isEmpty, !usageError else {
            FileHandle.standardError.write(Data(
                "usage: StorageProbe [--seek] [--verify-pts] [--determinism] [--seed N] [--fetches N] <capture.skewline> ...\n".utf8
            ))
            exit(64)
        }
        // No flag selects everything applicable to the container's layout.
        let passes = selected.isEmpty ? known : selected
        #if DEBUG
        print("warning: debug build -- the timing below is the optimizer's absence, not the storage's bill")
        #endif
        var failed = false
        for path in paths {
            do {
                try await report(
                    on: URL(filePath: path),
                    passes: passes,
                    seed: seed,
                    fetchCount: fetchCount
                )
            } catch {
                FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
                failed = true
            }
        }
        if failed {
            exit(1)
        }
    }

    enum ProbeError: Error {
        case noFrames
        case jpegDecodeFailed(index: Int)
        /// The video track holds a different sample count than the session
        /// holds frame records -- positional association is broken.
        case sampleCountMismatch(samples: Int, frames: Int)
        /// A sample's stored presentation time is not the one its record
        /// derives -- the exact-match contract's loud failure.
        case presentationTimeMismatch(index: Int)
        /// The track's stored timescale is not the pinned nanosecond
        /// timescale the exact-match mapping is defined over.
        case timescaleMismatch(found: Int32, expected: Int32)
        /// Two decodes of the same movie disagreed at this frame.
        case decodeNotReproducible(index: Int)
    }

    static func report(on url: URL, passes: Set<String>, seed: UInt64, fetchCount: Int) async throws {
        let reader = try SessionContainer.Reader(contentsOf: url)
        let session = reader.session
        guard !session.frames.isEmpty else {
            throw ProbeError.noFrames
        }

        let hasVideoFile = FileManager.default.fileExists(atPath: reader.videoFileURL.path)
        // A dual-write capture carries an unclaimed movie beside a canonical
        // per-frame layout; both sides get measured from the one container.
        let hasPerFrameFiles = session.videoTrack == nil

        print("session \(session.id.uuidString)  \(url.path)")
        let storage = session.videoTrack != nil
            ? "video track (\(session.videoTrack?.codec.rawValue ?? "?"))"
            : hasVideoFile ? "per-frame files + unclaimed video.mov (dual capture)" : "per-frame files"
        print(row("storage", storage))
        print(row("frames", "\(session.frames.count)"))

        // One fetch set for both storage paths, so the two cold means are
        // over identical indices.
        let indices = randomIndices(count: fetchCount, upperBound: session.frames.count, seed: seed)
        print(row("cold fetch set", "\(indices.count) indices, seed \(seed), splitmix64"))
        print(row("cache note", "cold = fresh open per fetch; the OS file cache is not purged"))

        #if canImport(AVFoundation)
        if hasVideoFile {
            if passes.contains("verify-pts") {
                try await verifyPresentationTimes(movieURL: reader.videoFileURL, session: session)
            }
            if passes.contains("seek") {
                try await seekMovie(movieURL: reader.videoFileURL, session: session, indices: indices)
            }
            if passes.contains("determinism") {
                try await verifyDeterminism(movieURL: reader.videoFileURL, frameCount: session.frames.count)
            }
        }
        #else
        if hasVideoFile {
            print(row("video track", "AVFoundation unavailable on this host -- skipped"))
        }
        #endif

        if hasPerFrameFiles, passes.contains("seek") {
            try seekPerFrameFiles(reader: reader, session: session, indices: indices)
        }
        print("")
    }

    // MARK: - Movie passes

    #if canImport(AVFoundation)

    /// The exact-association check: as many samples as records, every sample
    /// at exactly the presentation time its record derives, and the track's
    /// timescale still the pinned nanosecond one.
    static func verifyPresentationTimes(movieURL: URL, session: CaptureSession) async throws {
        let movie = try await MovieFrameReader(contentsOf: movieURL)
        let expectedTimescale = session.videoTrack?.timescale ?? VideoTrackRecord.nanosecondTimescale
        guard movie.timescale == CMTimeScale(expectedTimescale) else {
            throw ProbeError.timescaleMismatch(found: Int32(movie.timescale), expected: expectedTimescale)
        }
        var index = 0
        try movie.forEachFrame { sample in
            guard index < session.frames.count else {
                index += 1
                return
            }
            let expected = VideoTrackRecord.presentationTime(of: session.frames[index].timestamp)
            guard sample.presentationTime == expected else {
                throw ProbeError.presentationTimeMismatch(index: index)
            }
            index += 1
        }
        guard index == session.frames.count else {
            throw ProbeError.sampleCountMismatch(samples: index, frames: session.frames.count)
        }
        print(row("verify-pts", "\(index) samples exact · timescale \(movie.timescale)"))
    }

    /// Cold: a fresh asset open plus one exact-time fetch per index. Warm:
    /// one sequential decode of the whole track.
    static func seekMovie(movieURL: URL, session: CaptureSession, indices: [Int]) async throws {
        let clock = ContinuousClock()
        var coldMilliseconds: [Double] = []
        for index in indices {
            let start = clock.now
            let movie = try await MovieFrameReader(contentsOf: movieURL)
            let sample = try movie.frame(at: session.frames[index].timestamp)
            coldMilliseconds.append(milliseconds(start.duration(to: clock.now)))
            _ = sample
        }
        print(row("movie cold seek", summary(of: coldMilliseconds)))

        let movie = try await MovieFrameReader(contentsOf: movieURL)
        var frameCount = 0
        let start = clock.now
        try movie.forEachFrame { _ in frameCount += 1 }
        let total = milliseconds(start.duration(to: clock.now))
        print(row(
            "movie warm pass",
            String(format: "%d frames · total %.1f ms · mean %.2f ms/frame", frameCount, total, total / Double(max(frameCount, 1)))
        ))
    }

    /// Decodes the whole track twice and requires the two passes to
    /// byte-reproduce, frame by frame, over tightly packed plane rows.
    /// Same-machine only: cross-device decode stability is untested here and
    /// stays untested.
    static func verifyDeterminism(movieURL: URL, frameCount: Int) async throws {
        func digests() async throws -> [SHA256Digest] {
            let movie = try await MovieFrameReader(contentsOf: movieURL)
            var collected: [SHA256Digest] = []
            collected.reserveCapacity(frameCount)
            try movie.forEachFrame { sample in
                collected.append(try digest(of: sample.pixelBuffer))
            }
            return collected
        }
        let first = try await digests()
        let second = try await digests()
        guard first.count == second.count else {
            throw ProbeError.decodeNotReproducible(index: min(first.count, second.count))
        }
        for (index, pair) in zip(first, second).enumerated() where pair.0 != pair.1 {
            throw ProbeError.decodeNotReproducible(index: index)
        }
        print(row("determinism", "\(first.count) frames byte-reproduce across two decodes (this machine)"))
    }

    /// SHA-256 over each plane's rows trimmed to their tight width -- row
    /// padding is the allocator's, not the image's.
    static func digest(of pixelBuffer: CVPixelBuffer) throws -> SHA256Digest {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var hasher = SHA256()
        let planeCount = max(CVPixelBufferGetPlaneCount(pixelBuffer), 1)
        for plane in 0..<planeCount {
            guard let base = CVPixelBufferGetPlaneCount(pixelBuffer) == 0
                ? CVPixelBufferGetBaseAddress(pixelBuffer)
                : CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
            let height = CVPixelBufferGetPlaneCount(pixelBuffer) == 0
                ? CVPixelBufferGetHeight(pixelBuffer)
                : CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
            let rowBytes = CVPixelBufferGetPlaneCount(pixelBuffer) == 0
                ? CVPixelBufferGetBytesPerRow(pixelBuffer)
                : CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let width = CVPixelBufferGetPlaneCount(pixelBuffer) == 0
                ? CVPixelBufferGetWidth(pixelBuffer)
                : CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
            // The decode output is pinned to 420f: one byte per pixel on the
            // luma plane, two on the interleaved chroma plane.
            let tightRowBytes = min(rowBytes, width * (plane == 0 ? 1 : 2))
            for rowIndex in 0..<height {
                let rowPointer = base.advanced(by: rowIndex * rowBytes)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(start: rowPointer, count: tightRowBytes))
            }
        }
        return hasher.finalize()
    }

    #endif

    // MARK: - Per-frame pass

    /// The like-for-like baseline: file read plus JPEG decode to pixels,
    /// forced eager so the clock covers the decode and not a lazy handle.
    static func seekPerFrameFiles(reader: SessionContainer.Reader, session: CaptureSession, indices: [Int]) throws {
        let clock = ContinuousClock()
        var coldMilliseconds: [Double] = []
        for index in indices {
            let start = clock.now
            let data = try reader.frameData(at: index)
            _ = try decodedImage(from: data, index: index)
            coldMilliseconds.append(milliseconds(start.duration(to: clock.now)))
        }
        print(row("files cold seek", summary(of: coldMilliseconds)))

        var frameCount = 0
        let start = clock.now
        for index in session.frames.indices {
            let data = try reader.frameData(at: index)
            _ = try decodedImage(from: data, index: index)
            frameCount += 1
        }
        let total = milliseconds(start.duration(to: clock.now))
        print(row(
            "files warm pass",
            String(format: "%d frames · total %.1f ms · mean %.2f ms/frame", frameCount, total, total / Double(max(frameCount, 1)))
        ))
    }

    static func decodedImage(from data: Data, index: Int) throws -> CGImage {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            throw ProbeError.jpegDecodeFailed(index: index)
        }
        return image
    }

    // MARK: - Shared

    /// splitmix64 -- deterministic for a given seed, so the second operator
    /// reproduces the exact fetch set from the printed seed.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomIndices(count: Int, upperBound: Int, seed: UInt64) -> [Int] {
        var generator = SplitMix64(state: seed)
        return (0..<count).map { _ in Int.random(in: 0..<upperBound, using: &generator) }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    static func summary(of milliseconds: [Double]) -> String {
        let sorted = milliseconds.sorted()
        guard !sorted.isEmpty else { return "no fetches" }
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        return String(
            format: "ms %.2f/%.2f/%.2f min/mean/max over %d fetches",
            sorted.first ?? 0, mean, sorted.last ?? 0, sorted.count
        )
    }

    static func row(_ label: String, _ value: String) -> String {
        "  " + label.padding(toLength: 26, withPad: " ", startingAt: 0) + value
    }
}
