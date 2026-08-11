import Metal

/// The two buffer layouts whose cost the probe measures -- the 32-byte
/// stride as a choice rather than an accident.
public enum PointCloudLayout: String, CaseIterable, Sendable {
    /// `[ConfidencePoint]` bytes as they already are: 32-byte stride, 15 of
    /// them padding. Upload is a straight memcpy; every pass over the cloud
    /// drags the padding through the cache with it.
    case aos32

    /// Packed 12-byte position triples in one buffer, bare confidence bytes
    /// in another -- 13 bytes per point, built by one CPU conversion pass. A
    /// re-shade touches only the confidence plane.
    case soa

    public var bytesPerPoint: Int {
        switch self {
        case .aos32: MemoryLayout<ConfidencePoint>.stride
        case .soa: 13
        }
    }
}

/// One wall-clock and one GPU-clock reading of the same command buffer. The
/// wall number includes commit and the blocking wait -- a latency floor, not
/// a pipelined throughput; the GPU interval is the device's own account of
/// the same work.
public struct GPUTiming: Sendable {
    public let wallSeconds: Double

    /// `gpuEndTime - gpuStartTime`, or nil when the device reports no
    /// interval -- printed as unavailable, never invented.
    public let gpuSeconds: Double?

    static func commitAndMeasure(_ commandBuffer: MTLCommandBuffer) throws -> GPUTiming {
        let clock = ContinuousClock()
        let start = clock.now
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let wall = start.duration(to: clock.now) / .seconds(1)
        if commandBuffer.status == .error {
            throw RenderGPUError.commandBufferFailed(
                commandBuffer.error.map(String.init(describing:)) ?? "unreported command buffer error"
            )
        }
        let gpu = commandBuffer.gpuEndTime - commandBuffer.gpuStartTime
        return GPUTiming(wallSeconds: wall, gpuSeconds: gpu > 0 ? gpu : nil)
    }
}

/// The accumulated cloud, resident in unified memory from the moment it is
/// unprojected. Frames append directly into one `.storageModeShared` buffer
/// in the `aos32` layout, so the 2.43 GB cloud exists once -- there is never
/// a second CPU-side array to copy from.
public final class AccumulatedCloudBuffer {
    /// The cloud in the `aos32` layout -- `ConfidencePoint` bytes verbatim.
    public let aos32: MTLBuffer

    public let capacity: Int

    public private(set) var count = 0

    public init(device: MTLDevice, capacity: Int) throws {
        let bytes = max(capacity, 1) * MemoryLayout<ConfidencePoint>.stride
        guard let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) else {
            throw RenderGPUError.bufferAllocationFailed(bytes: bytes)
        }
        aos32 = buffer
        self.capacity = capacity
    }

    public func append(_ points: [ConfidencePoint]) {
        guard !points.isEmpty else { return }
        precondition(
            count + points.count <= capacity,
            "cloud capacity \(capacity) cannot hold \(count) + \(points.count) points"
        )
        points.withUnsafeBytes { source in
            aos32.contents()
                .advanced(by: count * MemoryLayout<ConfidencePoint>.stride)
                .copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        count += points.count
    }

    public struct SoA {
        /// Packed 12-byte float triples, one per point.
        public let positions: MTLBuffer

        /// One bare byte per point.
        public let confidences: MTLBuffer
    }

    /// The `soa` candidate, converted from the resident `aos32` bytes in one
    /// CPU pass -- run after accumulation, outside every timed window.
    public func makeSoA(device: MTLDevice) throws -> SoA {
        let positionBytes = max(count, 1) * 12
        guard let positions = device.makeBuffer(length: positionBytes, options: .storageModeShared) else {
            throw RenderGPUError.bufferAllocationFailed(bytes: positionBytes)
        }
        let confidenceBytes = max(count, 1)
        guard let confidences = device.makeBuffer(length: confidenceBytes, options: .storageModeShared) else {
            throw RenderGPUError.bufferAllocationFailed(bytes: confidenceBytes)
        }
        let source = aos32.contents().bindMemory(to: ConfidencePoint.self, capacity: count)
        let positionsOut = positions.contents().bindMemory(to: Float.self, capacity: count * 3)
        let confidencesOut = confidences.contents().bindMemory(to: UInt8.self, capacity: count)
        for index in 0..<count {
            let point = source[index]
            positionsOut[index * 3] = point.position.x
            positionsOut[index * 3 + 1] = point.position.y
            positionsOut[index * 3 + 2] = point.position.z
            confidencesOut[index] = point.confidence
        }
        return SoA(positions: positions, confidences: confidences)
    }
}
