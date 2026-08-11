import Foundation

/// How a depth payload's samples are represented, before compression.
///
/// A struct over a raw string for the same reason as `FrameEncoding`: an enum
/// turns every future representation into a decode failure for every existing
/// reader. An unknown value round-trips losslessly.
public struct DepthEncoding: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// One IEEE 754 binary32 value per pixel, little-endian, in meters -- the
    /// unit `ARDepthData.depthMap` documents. Rows are tight-packed top to
    /// bottom with no padding, so the uncompressed payload is exactly
    /// width × height × 4 bytes and needs no stride field to be read back.
    public static let float32 = DepthEncoding(rawValue: "float32")
}

/// How a confidence payload's samples are represented, before compression.
public struct ConfidenceEncoding: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// One byte per pixel, holding the value ARKit's `confidenceMap` delivered
    /// for that pixel -- its `ARConfidenceLevel` raw value, recorded as
    /// observed rather than remapped here, which is what keeps this module
    /// free of a framework it cannot import to check. Rows are tight-packed
    /// top to bottom: the uncompressed payload is exactly width × height
    /// bytes.
    public static let uint8 = ConfidenceEncoding(rawValue: "uint8")
}

/// How a depth or confidence payload's bytes are compressed on disk.
///
/// Its own field rather than a variant of the encoding string: the sample
/// representation and the byte compression vary independently, and folding
/// them together would mint a new opaque string for every combination.
public struct DepthCompression: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The encoded bytes as they are. Explicit rather than an absent key:
    /// absence-as-meaning is a decode ambiguity no reader should inherit.
    public static let raw = DepthCompression(rawValue: "raw")

    /// Apple's LZFSE, as Foundation's `compressed(using:)` writes it and
    /// `decompressed(using:)` reads it back.
    public static let lzfse = DepthCompression(rawValue: "lzfse")
}

/// The shape of one frame's confidence payload: ARKit's per-pixel estimate of
/// its own depth values, kept because a depth without a confidence beside it
/// is exactly the kind of number this package exists to refuse.
public struct ConfidenceRecord: Codable, Equatable, Sendable {
    /// Pixel width of the confidence map, as observed on the device.
    public var width: Int

    /// Pixel height of the confidence map, as observed on the device.
    public var height: Int

    /// How the payload's samples are represented.
    public var encoding: ConfidenceEncoding

    /// How the payload's bytes are compressed.
    public var compression: DepthCompression

    public init(width: Int, height: Int, encoding: ConfidenceEncoding, compression: DepthCompression) {
        self.width = width
        self.height = height
        self.encoding = encoding
        self.compression = compression
    }
}

/// The shape of one frame's depth payload, stored beside the frame's pixels.
///
/// No timestamp, deliberately: depth comes from the same `ARFrame` as the
/// camera frame it annotates, so the owning `FrameRecord`'s timestamp is the
/// depth's, and a second copy here could only drift from it. Same clock, no
/// new timeline.
///
/// Width and height are what the device delivered, not expectations: ARKit
/// documents neither the resolution nor the pixel format of a depth map, so
/// the record holds the observed values and promises nothing else.
public struct DepthRecord: Codable, Equatable, Sendable {
    /// Pixel width of the depth map, as observed on the device.
    public var width: Int

    /// Pixel height of the depth map, as observed on the device.
    public var height: Int

    /// How the payload's samples are represented.
    public var encoding: DepthEncoding

    /// How the payload's bytes are compressed.
    public var compression: DepthCompression

    /// The confidence payload's shape, or `nil` when ARKit delivered no
    /// confidence map for this frame -- its `confidenceMap` is nullable, and
    /// an absence is recorded as one rather than invented.
    public var confidence: ConfidenceRecord?

    public init(
        width: Int,
        height: Int,
        encoding: DepthEncoding,
        compression: DepthCompression,
        confidence: ConfidenceRecord? = nil
    ) {
        self.width = width
        self.height = height
        self.encoding = encoding
        self.compression = compression
        self.confidence = confidence
    }
}
