import Testing
import Metal
import simd
import Render

/// The memcpy contract: `AccumulatedCloudBuffer.append` copies
/// `[ConfidencePoint]` bytes verbatim into a buffer the `aos32` shaders read
/// through a mirrored MSL struct, so the Swift layout is load-bearing --
/// a stride or offset change would silently shear every point.
@Test func confidencePointKeepsTheDocumentedLayout() {
    #expect(MemoryLayout<ConfidencePoint>.stride == 32)
    #expect(MemoryLayout<ConfidencePoint>.offset(of: \.confidence) == 16)
}

@Test func bytesPerPointMatchEachLayout() {
    #expect(PointCloudLayout.aos32.bytesPerPoint == 32)
    #expect(PointCloudLayout.soa.bytesPerPoint == 13)
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
func appendAndSoAConversionPreserveEveryValue() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let points = [
        ConfidencePoint(position: SIMD3(1, 2, 3), confidence: 0),
        ConfidencePoint(position: SIMD3(-4, 5.5, -6.25), confidence: 2),
        ConfidencePoint(position: SIMD3(0.125, -0.5, 7), confidence: 200),
    ]
    let cloud = try AccumulatedCloudBuffer(device: device, capacity: 4)
    cloud.append(Array(points[0..<2]))
    cloud.append([points[2]])
    #expect(cloud.count == 3)

    let stored = cloud.aos32.contents().bindMemory(to: ConfidencePoint.self, capacity: 3)
    for (index, point) in points.enumerated() {
        #expect(stored[index] == point)
    }

    let soa = try cloud.makeSoA(device: device)
    let positions = soa.positions.contents().bindMemory(to: Float.self, capacity: 9)
    let confidences = soa.confidences.contents().bindMemory(to: UInt8.self, capacity: 3)
    for (index, point) in points.enumerated() {
        #expect(positions[index * 3] == point.position.x)
        #expect(positions[index * 3 + 1] == point.position.y)
        #expect(positions[index * 3 + 2] == point.position.z)
        #expect(confidences[index] == point.confidence)
    }
}
