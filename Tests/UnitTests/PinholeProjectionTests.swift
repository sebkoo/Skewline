import Testing
import Metal
import simd
import Core
import Render

/// The projection is the unprojection run backwards, and with dyadic
/// intrinsics -- powers of two throughout -- binary32 arithmetic is exact at
/// every step, so the round trip must land on the source pixel to the bit.
/// The `constantDepthMapUnprojectsToConstantCameraZ` pattern: a convention
/// error of any kind fails by whole pixels, not by ulps.
@Test func projectionRoundTripsTheUnprojectionExactly() throws {
    let record = IntrinsicsRecord(
        focalLengthX: 1024,
        focalLengthY: 512,
        principalPointX: 512,
        principalPointY: 256,
        referenceWidth: 2048,
        referenceHeight: 1024
    )
    let scaled = try ScaledIntrinsics.scaling(record, toWidth: 2048, height: 1024)
    let projection = PinholeProjection.projectionMatrix(intrinsics: record, near: 2, far: 4)

    let pixels: [(x: Int, y: Int, depth: Float)] = [(3, 1, 2), (100, 700, 2.5), (2047, 1023, 4)]
    for pixel in pixels {
        let camera = Unprojector.cameraPoint(
            x: pixel.x, y: pixel.y, depth: pixel.depth, intrinsics: scaled
        )
        let clip = projection * SIMD4(camera.x, camera.y, camera.z, 1)
        #expect(clip.w == pixel.depth)
        #expect((clip.x / clip.w + 1) / 2 * 2048 == Float(pixel.x))
        #expect((1 - clip.y / clip.w) / 2 * 1024 == Float(pixel.y))
    }
}

@Test func nearAndFarLandExactlyOnTheClipBounds() {
    let record = IntrinsicsRecord(
        focalLengthX: 1024,
        focalLengthY: 512,
        principalPointX: 512,
        principalPointY: 256,
        referenceWidth: 2048,
        referenceHeight: 1024
    )
    let projection = PinholeProjection.projectionMatrix(intrinsics: record, near: 2, far: 4)
    let nearClip = projection * SIMD4<Float>(0, 0, -2, 1)
    #expect(nearClip.z / nearClip.w == 0)
    let farClip = projection * SIMD4<Float>(0, 0, -4, 1)
    #expect(farClip.z / farClip.w == 1)
}

@Test func viewMatrixInvertsATranslationExactly() {
    let cameraToWorld = Transform4x4(
        column0: SIMD4(1, 0, 0, 0),
        column1: SIMD4(0, 1, 0, 0),
        column2: SIMD4(0, 0, 1, 0),
        column3: SIMD4(1, 2, 3, 1)
    )
    let view = PinholeProjection.viewMatrix(cameraToWorld: cameraToWorld)
    let camera = SIMD4<Float>(0.5, -0.25, -2, 1)
    let world = cameraToWorld.simd * camera
    #expect(view * world == camera)
}

/// Three points constructed at pixel centers, rendered, and read back --
/// the whole chain: projection, rasterization, palette, depth-tested target.
/// The positions are dyadic so each point's window coordinate is exactly the
/// pixel center it was built for.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil), arguments: PointCloudLayout.allCases)
func renderedPointsLandOnTheirPixelsInTheirColors(layout: PointCloudLayout) throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let library = try ShaderLibrary.makeLibrary(device: device)
    let queue = try #require(device.makeCommandQueue())

    let record = IntrinsicsRecord(
        focalLengthX: 32,
        focalLengthY: 16,
        principalPointX: 16,
        principalPointY: 8,
        referenceWidth: 64,
        referenceHeight: 32
    )

    /// Camera-space position whose projection is exactly the center of the
    /// given texel: the inverse of the projection at continuous image
    /// coordinates (x + 0.5, y + 0.5), depth 2.
    func pointAt(_ x: Int, _ y: Int, confidence: UInt8) -> ConfidencePoint {
        let depth: Float = 2
        let u = Float(x) + 0.5
        let v = Float(y) + 0.5
        return ConfidencePoint(
            position: SIMD3(
                (u - record.principalPointX) * depth / record.focalLengthX,
                -(v - record.principalPointY) * depth / record.focalLengthY,
                -depth
            ),
            confidence: confidence
        )
    }

    let targets: [(x: Int, y: Int, confidence: UInt8)] = [(10, 20, 0), (40, 5, 1), (55, 25, 2)]
    let cloud = try AccumulatedCloudBuffer(device: device, capacity: targets.count)
    cloud.append(targets.map { pointAt($0.x, $0.y, confidence: $0.confidence) })
    let soa = try cloud.makeSoA(device: device)

    let renderer = try PointCloudRenderer(
        device: device, library: library, width: record.referenceWidth, height: record.referenceHeight
    )
    let projection = PinholeProjection.projectionMatrix(intrinsics: record, near: 1, far: 8)
    _ = try renderer.render(
        positions: layout == .aos32 ? cloud.aos32 : soa.positions,
        confidences: layout == .soa ? soa.confidences : nil,
        layout: layout,
        count: cloud.count,
        viewProjection: projection,
        pointSize: 1,
        queue: queue
    )

    let pixels = renderer.readbackRGBA()
    func texel(_ x: Int, _ y: Int) -> SIMD4<UInt8> {
        let base = (y * record.referenceWidth + x) * 4
        return SIMD4(pixels[base], pixels[base + 1], pixels[base + 2], pixels[base + 3])
    }
    for target in targets {
        #expect(texel(target.x, target.y) == ConfidencePalette.color(for: target.confidence))
    }
    #expect(texel(0, 0) == SIMD4(0, 0, 0, 255))
}
