import Testing
import Metal
import simd
import Render

/// Both kernels against the CPU reference, byte for byte, over a cloud that
/// includes the boundary value 3 and the out-of-domain witness 200 the
/// existing tests use -- the two layouts must be different costs for the
/// same answer, never different answers.
@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil), arguments: PointCloudLayout.allCases)
func reshadeKernelMatchesTheCPUMap(layout: PointCloudLayout) throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let library = try ShaderLibrary.makeLibrary(device: device)
    let queue = try #require(device.makeCommandQueue())

    let confidences: [UInt8] = [0, 1, 2, 3, 200, 255]
    let points = confidences.enumerated().map { index, confidence in
        ConfidencePoint(position: SIMD3(Float(index), 0, 0), confidence: confidence)
    }
    let cloud = try AccumulatedCloudBuffer(device: device, capacity: points.count)
    cloud.append(points)
    let soa = try cloud.makeSoA(device: device)

    let pass = try ReshadePass(device: device, library: library)
    let colors = try pass.makeColorBuffer(count: cloud.count)
    let source = layout == .aos32 ? cloud.aos32 : soa.confidences
    _ = try pass.reshade(
        source: source,
        layout: layout,
        count: cloud.count,
        into: colors,
        queue: queue
    )

    let shaded = colors.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: cloud.count)
    for (index, confidence) in confidences.enumerated() {
        #expect(shaded[index] == ConfidencePalette.color(for: confidence))
    }
}
