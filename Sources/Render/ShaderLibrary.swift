import Foundation
import Metal

public enum RenderGPUError: Error {
    /// The bundled `.metal` source is missing from the module's resources.
    case shaderSourceMissing

    /// The compiled library has no function by this name.
    case functionMissing(String)

    /// `makeBuffer` or `makeTexture` returned nil for this many bytes --
    /// reported with the size so an allocation refusal reads as what it is.
    case bufferAllocationFailed(bytes: Int)

    /// A render pass over the SoA layout was given no confidence buffer.
    case missingConfidenceBuffer

    /// The command buffer could not be created, or completed with an error.
    case commandBufferFailed(String)
}

/// Loads and compiles `ConfidenceShaders.msl` at runtime.
///
/// Runtime compilation is not a convenience but the only path `swift build`
/// offers: SwiftPM's native build system copies the resource into the bundle
/// verbatim -- observed with both `.copy` and `.process`, neither invokes the
/// Metal compiler. The extension is `.msl` rather than `.metal` because
/// xcodebuild claims a `.metal` file for build-time compilation even when it
/// is declared `.copy` -- a toolchain this machine and possibly CI's would
/// each have to download, producing a bundle that differs between the two
/// build systems. One source file no build system claims, compiled at first
/// use, behaves identically under every command in the gate; the test suite
/// compiles and executes it on every run.
public enum ShaderLibrary {
    public static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        guard let url = Bundle.module.url(forResource: "ConfidenceShaders", withExtension: "msl") else {
            throw RenderGPUError.shaderSourceMissing
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        return try device.makeLibrary(source: source, options: nil)
    }

    static func function(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else {
            throw RenderGPUError.functionMissing(name)
        }
        return function
    }

    /// The palette as the 16-byte buffer every shader reads -- built from
    /// `ConfidencePalette.table` so the constants exist in one place.
    static func makePaletteBuffer(device: MTLDevice) throws -> MTLBuffer {
        try ConfidencePalette.table.withUnsafeBytes { bytes in
            guard let buffer = device.makeBuffer(
                bytes: bytes.baseAddress!,
                length: bytes.count,
                options: .storageModeShared
            ) else {
                throw RenderGPUError.bufferAllocationFailed(bytes: bytes.count)
            }
            return buffer
        }
    }
}
