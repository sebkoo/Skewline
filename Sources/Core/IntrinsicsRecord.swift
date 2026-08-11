import Foundation

/// One camera frame's pinhole intrinsics: focal length and principal point,
/// in pixels, at the resolution they were computed for.
///
/// Four numbers, not the full 3x3 matrix `ARCamera.intrinsics` returns. The
/// matrix's other five entries are the pinhole model's own constants -- zero
/// off the diagonal in the first two columns, one in the last -- not
/// per-frame data; `FrameEncoder` verifies that shape before this record is
/// built, so the four fields kept here are the four the matrix ever varies.
///
/// `referenceWidth` and `referenceHeight` ride beside the four numbers
/// because they are meaningless without them: `focalLengthX` and
/// `principalPointX` are pixel counts at a resolution, and a resolution
/// recorded nowhere is a scale nobody can recover. Distinct from
/// `FrameRecord.width`/`height`, which describe the stored payload -- the two
/// agree only while a producer stores frames at full resolution, and a
/// record that borrowed its reference frame from the payload would drift
/// silently the day one does not.
public struct IntrinsicsRecord: Codable, Equatable, Sendable {
    /// `ARCamera.intrinsics[0][0]` -- the horizontal focal length, in pixels.
    public var focalLengthX: Float

    /// `ARCamera.intrinsics[1][1]` -- the vertical focal length, in pixels.
    public var focalLengthY: Float

    /// `ARCamera.intrinsics[2][0]` -- the principal point's horizontal
    /// offset, in pixels.
    public var principalPointX: Float

    /// `ARCamera.intrinsics[2][1]` -- the principal point's vertical offset,
    /// in pixels.
    public var principalPointY: Float

    /// `ARCamera.imageResolution.width`, converted from the whole-pixel
    /// value ARKit already reports -- the resolution the four fields above
    /// are expressed at.
    public var referenceWidth: Int

    /// `ARCamera.imageResolution.height`, converted the same way.
    public var referenceHeight: Int

    public init(
        focalLengthX: Float,
        focalLengthY: Float,
        principalPointX: Float,
        principalPointY: Float,
        referenceWidth: Int,
        referenceHeight: Int
    ) {
        self.focalLengthX = focalLengthX
        self.focalLengthY = focalLengthY
        self.principalPointX = principalPointX
        self.principalPointY = principalPointY
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
    }
}
