import Foundation
import simd
import Core
import Replay

public enum UnprojectionError: Error, Equatable {
    /// The depth map carries no confidence plane. Fail-loud, the
    /// `unexpectedIntrinsicsShape` precedent: every observed capture has one,
    /// and a point invented without its confidence is the number this package
    /// exists to refuse.
    case missingConfidence

    /// The confidence plane's sample count disagrees with the depth map's,
    /// so positional pairing would associate values across pixels.
    case confidenceCountMismatch(depths: Int, confidences: Int)

    /// The depth-to-reference ratios differ between axes. Scaling would have
    /// to pick one or average them, and either is a guess about a camera
    /// model nobody documented.
    case anisotropicScale(x: Float, y: Float)
}

/// Pinhole intrinsics rescaled from the resolution they were computed at to
/// the depth map's -- the consumer-side scaling the intrinsics commit
/// deferred, landed where the consumer is.
///
/// The scale is the plain resolution ratio, the one Apple's own scene-depth
/// point-cloud sample applies. Whether depth pixel `x` maps to reference
/// coordinate `x*s` or to `(x + 0.5)*s - 0.5` -- whether the two grids share
/// their origin corner or their pixel centers -- is documented nowhere; the
/// difference is at most half a depth pixel, about 0.28% of the field angle,
/// and is recorded here as an ambiguity rather than resolved by invention.
public struct ScaledIntrinsics: Equatable, Sendable {
    /// Horizontal focal length, in depth-map pixels.
    public let focalLengthX: Float

    /// Vertical focal length, in depth-map pixels.
    public let focalLengthY: Float

    /// The principal point's horizontal offset, in depth-map pixels.
    public let principalPointX: Float

    /// The principal point's vertical offset, in depth-map pixels.
    public let principalPointY: Float

    public init(focalLengthX: Float, focalLengthY: Float, principalPointX: Float, principalPointY: Float) {
        self.focalLengthX = focalLengthX
        self.focalLengthY = focalLengthY
        self.principalPointX = principalPointX
        self.principalPointY = principalPointY
    }

    /// Rescales a record to a depth map's resolution.
    ///
    /// Throws unless the two axes scale by exactly the same factor. Exact
    /// `Float` equality is the honest check here, not a tolerance: IEEE
    /// division is correctly rounded, so two quotients of the same real value
    /// -- 256/1920 and 192/1440 are both 2/15 -- land on the identical
    /// `Float`, and ratios that differ at all are a different camera model.
    public static func scaling(
        _ record: IntrinsicsRecord,
        toWidth width: Int,
        height: Int
    ) throws -> ScaledIntrinsics {
        let scaleX = Float(width) / Float(record.referenceWidth)
        let scaleY = Float(height) / Float(record.referenceHeight)
        guard scaleX == scaleY else {
            throw UnprojectionError.anisotropicScale(x: scaleX, y: scaleY)
        }
        return ScaledIntrinsics(
            focalLengthX: record.focalLengthX * scaleX,
            focalLengthY: record.focalLengthY * scaleY,
            principalPointX: record.principalPointX * scaleX,
            principalPointY: record.principalPointY * scaleY
        )
    }
}

/// One frame's worth of unprojection, and the samples it refused.
public struct UnprojectionResult: Sendable {
    /// Every valid depth sample, as a world-space point paired with its
    /// sensor confidence, emitted row-major in depth-map order.
    public let points: [ConfidencePoint]

    /// Depth samples that were zero, negative or non-finite -- skipped and
    /// counted rather than turned into a point at the camera.
    public let skippedInvalidDepth: Int

    public init(points: [ConfidencePoint], skippedInvalidDepth: Int) {
        self.points = points
        self.skippedInvalidDepth = skippedInvalidDepth
    }
}

/// Depth pixel -> camera ray -> world point, the rung's first arithmetic.
public enum Unprojector {
    /// The camera-space point for one depth sample, with the convention
    /// chain stated link by link because no single Apple document states it:
    ///
    /// 1. A depth value is planar z -- the pixel's distance along the
    ///    optical axis, not along its viewing ray. ARKit's headers say only
    ///    "per-pixel depth data (in meters)"; the deciding source is Apple's
    ///    sample *Displaying a Point Cloud Using Scene Depth*, whose shader
    ///    computes `xrw = (x - cx) * depth / fx`, `yrw = (y - cy) * depth / fy`
    ///    and uses `depth` directly, unnormalized, as the third camera-space
    ///    coordinate. A ray-distance reading would normalize the ray first.
    /// 2. Image coordinates have their origin at the upper-left pixel with y
    ///    growing downward -- the frame `ARCamera.intrinsics` is expressed in.
    /// 3. ARKit camera space has x right, y up, and the camera looking along
    ///    -z. Hence the two sign flips: image-down becomes camera-up, and a
    ///    positive depth lands at negative z.
    public static func cameraPoint(
        x: Int,
        y: Int,
        depth: Float,
        intrinsics: ScaledIntrinsics
    ) -> SIMD3<Float> {
        let rightward = (Float(x) - intrinsics.principalPointX) * depth / intrinsics.focalLengthX
        let downward = (Float(y) - intrinsics.principalPointY) * depth / intrinsics.focalLengthY
        return SIMD3(rightward, -downward, -depth)
    }

    /// The pixel a camera-space point images at -- the inverse of
    /// `cameraPoint`, written out in prose beside
    /// `PinholeProjection.projectionMatrix` since the render commit and
    /// landed as arithmetic by the calibration commit that needs it per
    /// pixel: `u = cx + fx*x/d`, `v = cy - fy*y/d` with planar depth
    /// `d = -z`. Returns nil at or behind the camera plane (`d <= 0`, or a
    /// non-finite z), where the pinhole maps nothing.
    public static func imagePoint(
        camera: SIMD3<Float>,
        intrinsics: ScaledIntrinsics
    ) -> (x: Float, y: Float, depth: Float)? {
        let depth = -camera.z
        guard depth > 0, depth.isFinite else { return nil }
        let x = intrinsics.principalPointX + intrinsics.focalLengthX * camera.x / depth
        let y = intrinsics.principalPointY - intrinsics.focalLengthY * camera.y / depth
        return (x, y, depth)
    }

    /// Unprojects every valid sample of one frame's depth map into world
    /// space through the frame's intrinsics and the pose that shares its
    /// timestamp.
    ///
    /// `cameraToWorld` is applied as `Core.Transform4x4` documents itself:
    /// camera-in-world, translation in `column3`, no perspective divide.
    public static func unproject(
        depth: DecodedDepth,
        intrinsics: IntrinsicsRecord,
        cameraToWorld: Transform4x4
    ) throws -> UnprojectionResult {
        guard let confidences = depth.confidences else {
            throw UnprojectionError.missingConfidence
        }
        guard confidences.count == depth.depths.count else {
            throw UnprojectionError.confidenceCountMismatch(
                depths: depth.depths.count,
                confidences: confidences.count
            )
        }
        let scaled = try ScaledIntrinsics.scaling(intrinsics, toWidth: depth.width, height: depth.height)
        let transform = cameraToWorld.simd

        var points: [ConfidencePoint] = []
        points.reserveCapacity(depth.depths.count)
        var skipped = 0
        for y in 0..<depth.height {
            for x in 0..<depth.width {
                let index = y * depth.width + x
                let sample = depth.depths[index]
                guard sample > 0, sample.isFinite else {
                    skipped += 1
                    continue
                }
                let camera = cameraPoint(x: x, y: y, depth: sample, intrinsics: scaled)
                let world = transform * SIMD4(camera.x, camera.y, camera.z, 1)
                points.append(ConfidencePoint(
                    position: SIMD3(world.x, world.y, world.z),
                    confidence: confidences[index]
                ))
            }
        }
        return UnprojectionResult(points: points, skippedInvalidDepth: skipped)
    }
}
