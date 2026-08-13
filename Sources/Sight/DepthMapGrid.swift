/// A depth map's dimensions, and the one piece of a tap that is arithmetic.
///
/// Turning a point somebody touched into a depth sample has two halves. One is
/// the platform's: `ARFrame.displayTransform(for:viewportSize:)` maps the
/// camera image onto the viewport it is being drawn into, and only ARKit knows
/// that transform. The other is this -- a point in normalized image space
/// becoming a sample index -- and it is the half that can be wrong silently,
/// off by a row, or off by one at an edge, with a plausible number still coming
/// out the far side. So it lives where `swift test` can reach it.
///
/// Normalized image space is the platform's: `(0, 0)` at the image's top-left
/// corner, `(1, 1)` at its bottom-right, x across the sensor's rows.
public struct DepthMapGrid: Sendable, Equatable {
    public let width: Int
    public let height: Int

    /// `nil` for a map with no pixels in it.
    ///
    /// Failable rather than throwing: there is no wire here and no artifact to
    /// reject, only a buffer whose dimensions came from the sensor, and a nil
    /// is the whole story a caller needs.
    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    /// One sample's place in the map: where it sits, and where it sits in a
    /// row-major buffer of `width * height` samples.
    public struct Pixel: Sendable, Equatable {
        public let column: Int
        public let row: Int
        public let index: Int
    }

    /// The pixel under a point in normalized image space, or `nil` when the
    /// point is not on the map.
    ///
    /// Half-open on both axes, `0 <= x < 1`, and truncating: the same rule the
    /// depth domain gets from `Range<Double>` and the bands get from
    /// `low <= d < high`, now on the image plane. A point exactly on the far
    /// edge belongs to the next map, not to this one's last pixel, which is
    /// the convention this repository has already made twice.
    ///
    /// Not-a-number fails both comparisons and lands here as `nil`, which is
    /// the truthful answer: a tap nobody can locate is not on the map.
    public func pixel(atNormalizedX x: Double, y: Double) -> Pixel? {
        guard let column = Self.coordinate(x, extent: width),
              let row = Self.coordinate(y, extent: height) else { return nil }
        return Pixel(column: column, row: row, index: row * width + column)
    }

    private static func coordinate(_ normalized: Double, extent: Int) -> Int? {
        guard normalized >= 0, normalized < 1 else { return nil }
        // The product is rounded, so a normalized value a hair under 1 can
        // round up to the extent itself and truncate to an index one past the
        // end. The clamp is what makes the half-open rule true of the result
        // rather than only of the input.
        return min(Int((normalized * Double(extent)).rounded(.down)), extent - 1)
    }
}
