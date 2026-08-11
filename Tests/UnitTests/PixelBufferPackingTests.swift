import Testing
import CoreVideo
import Foundation
import Capture

/// A single-plane buffer created with a row alignment chosen to force
/// padding, so the packer meets the stride disagreement it exists to strip.
private func makeBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        format,
        [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary,
        &created
    )
    return try #require(status == kCVReturnSuccess ? created : nil)
}

/// Fills the buffer's pixels with a deterministic pattern and returns the
/// tight-packed bytes the packer must reproduce. The padding is poisoned with
/// a sentinel, so a packer that reads past a row's pixels produces bytes no
/// pattern contains.
private func fill(_ buffer: CVPixelBuffer, rowBytes: Int) -> Data {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddress(buffer)!
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var expected = Data()
    for row in 0..<CVPixelBufferGetHeight(buffer) {
        let start = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
        for column in 0..<rowBytes {
            let value = UInt8((row * 31 + column * 7) % 256)
            start[column] = value
            expected.append(value)
        }
        for padding in rowBytes..<stride {
            start[padding] = 0xEE
        }
    }
    return expected
}

@Test func packingStripsFloat32RowPadding() throws {
    // Three pixels of four bytes leave a 12-byte row against a 64-byte
    // alignment: padding is guaranteed, and the premise is asserted rather
    // than assumed.
    let buffer = try makeBuffer(width: 3, height: 4, format: kCVPixelFormatType_DepthFloat32)
    let rowBytes = 3 * 4
    #expect(CVPixelBufferGetBytesPerRow(buffer) > rowBytes)
    let expected = fill(buffer, rowBytes: rowBytes)

    let packed = try PixelBufferPacking.tightlyPackedData(from: buffer, bytesPerPixel: 4)

    #expect(packed == expected)
    #expect(packed.count == 3 * 4 * 4)
}

@Test func packingStripsSingleByteRowPadding() throws {
    let buffer = try makeBuffer(width: 5, height: 3, format: kCVPixelFormatType_OneComponent8)
    let rowBytes = 5
    #expect(CVPixelBufferGetBytesPerRow(buffer) > rowBytes)
    let expected = fill(buffer, rowBytes: rowBytes)

    let packed = try PixelBufferPacking.tightlyPackedData(from: buffer, bytesPerPixel: 1)

    #expect(packed == expected)
    #expect(packed.count == 5 * 3)
}

@Test func packingRefusesBytesPerPixelWiderThanStride() throws {
    // A claimed pixel size that makes a row wider than the buffer's own
    // stride is a wrong claim, and honouring it would read past the
    // allocation.
    let buffer = try makeBuffer(width: 5, height: 3, format: kCVPixelFormatType_OneComponent8)
    let stride = CVPixelBufferGetBytesPerRow(buffer)

    #expect(throws: PixelBufferPacking.Failure.bytesPerPixelExceedsStride(
        bytesPerPixel: stride,
        bytesPerRow: stride
    )) {
        _ = try PixelBufferPacking.tightlyPackedData(from: buffer, bytesPerPixel: stride)
    }
}

@Test func packingRefusesPlanarBuffers() throws {
    let buffer = try makeBuffer(
        width: 8,
        height: 8,
        format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    )

    #expect(throws: PixelBufferPacking.Failure.planarBufferUnsupported) {
        _ = try PixelBufferPacking.tightlyPackedData(from: buffer, bytesPerPixel: 1)
    }
}
