import Metal
import simd
import Core

/// The camera for the offscreen render, built from values the container
/// already carries -- a captured frame's own intrinsics and pose -- because
/// an invented viewpoint would be the one number in the image nobody
/// measured.
public enum PinholeProjection {
    /// Maps `Unprojector`'s camera space (x right, y up, looking down -z,
    /// image origin top-left with y growing downward) onto Metal clip space
    /// (NDC x and y in [-1, 1], z in [0, 1]).
    ///
    /// Derivation, link by link: a camera point at planar depth `d = -z`
    /// projects to image pixel `u = cx + fx*x/d`, `v = cy - fy*y/d` -- the
    /// exact inverse of `Unprojector.cameraPoint`. Image coordinates map to
    /// NDC as `2u/W - 1` and `1 - 2v/H` (the image-down to NDC-up flip), and
    /// depth maps to NDC z hyperbolically with `near` landing at 0 and `far`
    /// at 1. Multiplying through by clip w = d gives the four columns below.
    /// The lock is a round-trip test against `cameraPoint`, exact in
    /// binary32 -- the `constantDepthMapUnprojectsToConstantCameraZ` pattern.
    public static func projectionMatrix(
        intrinsics: IntrinsicsRecord,
        near: Float,
        far: Float
    ) -> simd_float4x4 {
        let width = Float(intrinsics.referenceWidth)
        let height = Float(intrinsics.referenceHeight)
        let fx = intrinsics.focalLengthX
        let fy = intrinsics.focalLengthY
        let cx = intrinsics.principalPointX
        let cy = intrinsics.principalPointY
        return simd_float4x4(columns: (
            SIMD4(2 * fx / width, 0, 0, 0),
            SIMD4(0, 2 * fy / height, 0, 0),
            SIMD4(1 - 2 * cx / width, 2 * cy / height - 1, -far / (far - near), -1),
            SIMD4(0, 0, -(far * near) / (far - near), 0)
        ))
    }

    /// World -> camera, the inverse of the pose the container stores.
    public static func viewMatrix(cameraToWorld: Transform4x4) -> simd_float4x4 {
        simd_inverse(cameraToWorld.simd)
    }
}

/// The vertex-stage answer to the same cost question: every point transformed
/// and shaded per pass, rasterized as point primitives into an offscreen
/// target a reader can open as an image -- no window, no filming.
public final class PointCloudRenderer {
    public let width: Int
    public let height: Int

    private let colorTexture: MTLTexture
    private let depthTexture: MTLTexture
    private let aos32Pipeline: MTLRenderPipelineState
    private let soaPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let palette: MTLBuffer

    /// Matches the MSL `ShadeUniforms` layout: float4x4 at 0, float at 64.
    private struct ShadeUniforms {
        var viewProjection: simd_float4x4
        var pointSize: Float
    }

    public init(device: MTLDevice, library: MTLLibrary, width: Int, height: Int) throws {
        self.width = width
        self.height = height

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        colorDescriptor.usage = .renderTarget
        // Shared storage so readback is getBytes on unified memory, no blit.
        colorDescriptor.storageMode = .shared
        guard let color = device.makeTexture(descriptor: colorDescriptor) else {
            throw RenderGPUError.bufferAllocationFailed(bytes: width * height * 4)
        }
        colorTexture = color

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false
        )
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let depth = device.makeTexture(descriptor: depthDescriptor) else {
            throw RenderGPUError.bufferAllocationFailed(bytes: width * height * 4)
        }
        depthTexture = depth

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.fragmentFunction = try ShaderLibrary.function("point_fragment", in: library)
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.vertexFunction = try ShaderLibrary.function("point_vertex_aos32", in: library)
        aos32Pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = try ShaderLibrary.function("point_vertex_soa", in: library)
        soaPipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilDescriptor.isDepthWriteEnabled = true
        guard let depthStencil = device.makeDepthStencilState(descriptor: depthStencilDescriptor) else {
            throw RenderGPUError.commandBufferFailed("could not create a depth-stencil state")
        }
        depthState = depthStencil

        palette = try ShaderLibrary.makePaletteBuffer(device: device)
    }

    /// One full-cloud pass, blocking until the GPU finishes -- same timing
    /// contract as `ReshadePass.reshade`.
    ///
    /// `positions` is the `aos32` point buffer for that layout and the packed
    /// position buffer for `soa`, which also requires `confidences`. The
    /// target clears to black: the palette owns every non-background color in
    /// the image.
    public func render(
        positions: MTLBuffer,
        confidences: MTLBuffer? = nil,
        layout: PointCloudLayout,
        count: Int,
        viewProjection: simd_float4x4,
        pointSize: Float,
        queue: MTLCommandQueue
    ) throws -> GPUTiming {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderGPUError.commandBufferFailed("could not create a render command encoder")
        }
        encoder.setRenderPipelineState(layout == .aos32 ? aos32Pipeline : soaPipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(positions, offset: 0, index: 0)
        var uniforms = ShadeUniforms(viewProjection: viewProjection, pointSize: pointSize)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShadeUniforms>.stride, index: 1)
        encoder.setVertexBuffer(palette, offset: 0, index: 2)
        if layout == .soa {
            guard let confidences else {
                encoder.endEncoding()
                throw RenderGPUError.missingConfidenceBuffer
            }
            encoder.setVertexBuffer(confidences, offset: 0, index: 3)
        }
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        encoder.endEncoding()
        return try GPUTiming.commitAndMeasure(commandBuffer)
    }

    /// The rendered target, row-major RGBA8, row 0 at the top.
    public func readbackRGBA() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { destination in
            colorTexture.getBytes(
                destination.baseAddress!,
                bytesPerRow: width * 4,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return pixels
    }
}
