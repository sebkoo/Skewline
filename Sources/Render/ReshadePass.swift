import Metal

/// The compute-stage answer to "what does re-shading the cloud cost": one
/// dispatch mapping every point's confidence through the palette into an
/// RGBA8 color buffer.
///
/// The layout decides the traffic, not the arithmetic: over `aos32` the
/// kernel strides through the full 32 bytes per point for one useful byte;
/// over `soa` it reads the bare confidence plane. Same output either way,
/// which is what makes the pair a measurement of the layouts.
public final class ReshadePass {
    private let device: MTLDevice
    private let aos32Pipeline: MTLComputePipelineState
    private let soaPipeline: MTLComputePipelineState
    private let palette: MTLBuffer

    public init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        aos32Pipeline = try device.makeComputePipelineState(
            function: ShaderLibrary.function("reshade_aos32", in: library)
        )
        soaPipeline = try device.makeComputePipelineState(
            function: ShaderLibrary.function("reshade_soa", in: library)
        )
        palette = try ShaderLibrary.makePaletteBuffer(device: device)
    }

    /// One RGBA8 color per point.
    public func makeColorBuffer(count: Int) throws -> MTLBuffer {
        let bytes = max(count, 1) * 4
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw RenderGPUError.bufferAllocationFailed(bytes: bytes)
        }
        return buffer
    }

    /// One re-shade dispatch, blocking until the GPU finishes so the wall
    /// clock brackets the whole round trip.
    ///
    /// `source` is the `aos32` point buffer for that layout and the bare
    /// confidence buffer for `soa`.
    public func reshade(
        source: MTLBuffer,
        layout: PointCloudLayout,
        count: Int,
        into colors: MTLBuffer,
        queue: MTLCommandQueue
    ) throws -> GPUTiming {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw RenderGPUError.commandBufferFailed("could not create a compute command encoder")
        }
        let pipeline = layout == .aos32 ? aos32Pipeline : soaPipeline
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(source, offset: 0, index: 0)
        encoder.setBuffer(colors, offset: 0, index: 1)
        encoder.setBuffer(palette, offset: 0, index: 2)
        var pointCount = UInt32(count)
        encoder.setBytes(&pointCount, length: MemoryLayout<UInt32>.size, index: 3)
        // dispatchThreadgroups with an in-kernel bounds check, not
        // dispatchThreads: nothing here assumes non-uniform threadgroup
        // support, so the same dispatch runs on CI's paravirtual device.
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let groups = (count + width - 1) / width
        encoder.dispatchThreadgroups(
            MTLSize(width: max(groups, 1), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        return try GPUTiming.commitAndMeasure(commandBuffer)
    }
}
