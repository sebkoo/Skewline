import Testing
import Foundation
import simd
import Core
import Replay
import Render

/// Intrinsics whose values are powers of two, so every expectation below is
/// exact in binary32 and equality needs no tolerance.
private func handIntrinsics() -> ScaledIntrinsics {
    ScaledIntrinsics(focalLengthX: 8, focalLengthY: 8, principalPointX: 2, principalPointY: 1)
}

/// A record whose reference resolution matches the map it is used on, so the
/// scale is exactly 1 and tests exercise the arithmetic, not the scaling.
private func unscaledRecord(width: Int, height: Int) -> IntrinsicsRecord {
    IntrinsicsRecord(
        focalLengthX: 8,
        focalLengthY: 8,
        principalPointX: 2,
        principalPointY: 1,
        referenceWidth: width,
        referenceHeight: height
    )
}

private func constantDepthMap(width: Int, height: Int, depth: Float) -> DecodedDepth {
    DecodedDepth(
        width: width,
        height: height,
        depths: [Float](repeating: depth, count: width * height),
        confidences: [UInt8](repeating: 2, count: width * height)
    )
}

@Test func unprojectionMatchesAHandComputedPoint() throws {
    let intrinsics = handIntrinsics()

    // Right of the principal point, on its row: (3-2)*2/8 = 0.25 rightward,
    // no vertical offset, two meters out along -z.
    #expect(Unprojector.cameraPoint(x: 3, y: 1, depth: 2, intrinsics: intrinsics) == SIMD3(0.25, 0, -2))

    // Below the principal point in image coordinates -- larger y -- which is
    // *downward*, so camera-space y must come out negative. This pixel is
    // the sign-flip's witness.
    #expect(Unprojector.cameraPoint(x: 2, y: 3, depth: 2, intrinsics: intrinsics) == SIMD3(0, -0.5, -2))

    // The same two samples through the whole path, identity pose: world
    // equals camera space.
    let depths: [Float] = [2, 2, 2, 2, 2, 2, 2, 2]
    let map = DecodedDepth(width: 4, height: 2, depths: depths, confidences: [0, 1, 2, 0, 1, 2, 0, 1])
    let result = try Unprojector.unproject(
        depth: map,
        intrinsics: unscaledRecord(width: 4, height: 2),
        cameraToWorld: .identity
    )
    #expect(result.points[1 * 4 + 3].position == SIMD3(0.25, 0, -2))
    #expect(result.skippedInvalidDepth == 0)
}

@Test func intrinsicsScaleByTheDepthToReferenceRatio() throws {
    let record = IntrinsicsRecord(
        focalLengthX: 1410,
        focalLengthY: 1410,
        principalPointX: 960,
        principalPointY: 720,
        referenceWidth: 1920,
        referenceHeight: 1440
    )
    let scale = Float(256) / Float(1920)
    let scaled = try ScaledIntrinsics.scaling(record, toWidth: 256, height: 192)
    #expect(scaled == ScaledIntrinsics(
        focalLengthX: 1410 * scale,
        focalLengthY: 1410 * scale,
        principalPointX: 960 * scale,
        principalPointY: 720 * scale
    ))
}

@Test func anisotropicReferenceRatioThrows() {
    let record = unscaledRecord(width: 1920, height: 1440)
    #expect(throws: UnprojectionError.anisotropicScale(
        x: Float(256) / Float(1920),
        y: Float(144) / Float(1440)
    )) {
        try ScaledIntrinsics.scaling(record, toWidth: 256, height: 144)
    }
}

/// The convention lock. A depth value is planar z -- the sample's distance
/// along the optical axis -- so a constant-depth map must unproject to a
/// plane of constant camera-space z, exactly: z is a passthrough negation of
/// the sample. An implementation that read depth as distance along each
/// pixel's viewing ray would place corner pixels nearer the camera plane
/// than center ones, and this test would go red.
@Test func constantDepthMapUnprojectsToConstantCameraZ() throws {
    let result = try Unprojector.unproject(
        depth: constantDepthMap(width: 8, height: 6, depth: 1.5),
        intrinsics: IntrinsicsRecord(
            focalLengthX: 4,
            focalLengthY: 4,
            principalPointX: 3,
            principalPointY: 2,
            referenceWidth: 8,
            referenceHeight: 6
        ),
        cameraToWorld: .identity
    )
    #expect(result.points.count == 48)
    #expect(result.points.allSatisfy { $0.position.z == -1.5 })
}

@Test func cameraToWorldTransformMovesPointsIntoWorld() throws {
    let map = constantDepthMap(width: 4, height: 2, depth: 2)
    let record = unscaledRecord(width: 4, height: 2)

    // Pure translation: every world point is its camera point, shifted.
    let translation = Transform4x4(
        column0: SIMD4(1, 0, 0, 0),
        column1: SIMD4(0, 1, 0, 0),
        column2: SIMD4(0, 0, 1, 0),
        column3: SIMD4(10, 20, 30, 1)
    )
    let translated = try Unprojector.unproject(depth: map, intrinsics: record, cameraToWorld: translation)
    #expect(translated.points[1 * 4 + 3].position == SIMD3(10.25, 20, 28))

    // A 90-degree rotation about world y, all sines and cosines exact in
    // Float: camera x lands on world -z, camera -z lands on world -x. The
    // handedness witness -- a reflected or transposed transform fails it.
    let rotated = try Unprojector.unproject(
        depth: map,
        intrinsics: record,
        cameraToWorld: Transform4x4(
            column0: SIMD4(0, 0, -1, 0),
            column1: SIMD4(0, 1, 0, 0),
            column2: SIMD4(1, 0, 0, 0),
            column3: SIMD4(0, 0, 0, 1)
        )
    )
    #expect(rotated.points[1 * 4 + 3].position == SIMD3(-2, 0, -0.25))
}

@Test func invalidDepthSamplesAreSkippedAndCounted() throws {
    let map = DecodedDepth(
        width: 3,
        height: 2,
        depths: [0, -1, .nan, .infinity, 2, 3],
        confidences: [0, 0, 0, 0, 1, 2]
    )
    let result = try Unprojector.unproject(
        depth: map,
        intrinsics: unscaledRecord(width: 3, height: 2),
        cameraToWorld: .identity
    )
    #expect(result.skippedInvalidDepth == 4)
    #expect(result.points.count == 2)
    #expect(result.points.allSatisfy { $0.position.z < 0 })
}

@Test func depthWithoutConfidenceThrows() {
    let map = DecodedDepth(width: 2, height: 1, depths: [1, 2], confidences: nil)
    #expect(throws: UnprojectionError.missingConfidence) {
        try Unprojector.unproject(
            depth: map,
            intrinsics: unscaledRecord(width: 2, height: 1),
            cameraToWorld: .identity
        )
    }
}

@Test func mismatchedConfidenceCountThrows() {
    let map = DecodedDepth(width: 2, height: 1, depths: [1, 2], confidences: [0])
    #expect(throws: UnprojectionError.confidenceCountMismatch(depths: 2, confidences: 1)) {
        try Unprojector.unproject(
            depth: map,
            intrinsics: unscaledRecord(width: 2, height: 1),
            cameraToWorld: .identity
        )
    }
}

@Test func confidenceRidesEachPointUnchanged() throws {
    let confidences: [UInt8] = [0, 1, 2, 200, 1, 0]
    let map = DecodedDepth(
        width: 3,
        height: 2,
        depths: [1, 2, 3, 4, 5, 6],
        confidences: confidences
    )
    let result = try Unprojector.unproject(
        depth: map,
        intrinsics: unscaledRecord(width: 3, height: 2),
        cameraToWorld: .identity
    )
    #expect(result.points.map(\.confidence) == confidences)
}
