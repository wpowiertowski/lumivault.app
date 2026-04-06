import Foundation
import Metal

/// GPU-accelerated PAR2 recovery block generation using Metal compute shaders.
/// Falls back to nil initialization if Metal is unavailable.
final class MetalPAR2Service: @unchecked Sendable {
    private nonisolated(unsafe) let device: MTLDevice
    private nonisolated(unsafe) let pipeline: MTLComputePipelineState
    private nonisolated(unsafe) let commandQueue: MTLCommandQueue
    private nonisolated(unsafe) let mulTableBuffer: MTLBuffer

    /// Returns nil if Metal is unavailable (e.g., VM, old hardware).
    nonisolated init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            return nil
        }

        // Compile shader from source at runtime — avoids Metal Toolchain build requirement
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let function = library.makeFunction(name: "par2Generate"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }

        // Upload the 256x256 GF(2^8) multiplication table once
        let table = Self.buildMulTable()
        guard let mulTableBuffer = device.makeBuffer(bytes: table, length: table.count, options: .storageModeShared) else {
            return nil
        }

        self.device = device
        self.pipeline = pipeline
        self.commandQueue = commandQueue
        self.mulTableBuffer = mulTableBuffer
    }

    struct PAR2Uniforms {
        var blockSize: UInt32
        var blockCount: UInt32
        var recoveryBlockCount: UInt32
        var dataSize: UInt32
    }

    /// Generate PAR2 recovery data on the GPU.
    /// Returns the raw recovery bytes (recoveryBlockCount * blockSize).
    nonisolated func generateRecoveryData(
        data: Data,
        blockSize: Int,
        blockCount: Int,
        recoveryBlockCount: Int,
        coefficients: [UInt8],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> Data? {
        let dataSize = data.count
        let recoverySize = recoveryBlockCount * blockSize

        // Create Metal buffers
        guard let dataBuffer = data.withUnsafeBytes({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: dataSize, options: .storageModeShared)
        }) else { return nil }

        guard let recoveryBuffer = device.makeBuffer(length: recoverySize, options: .storageModeShared) else { return nil }

        guard let coeffBuffer = device.makeBuffer(bytes: coefficients, length: coefficients.count, options: .storageModeShared) else { return nil }

        var uniforms = PAR2Uniforms(
            blockSize: UInt32(blockSize),
            blockCount: UInt32(blockCount),
            recoveryBlockCount: UInt32(recoveryBlockCount),
            dataSize: UInt32(dataSize)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(dataBuffer, offset: 0, index: 0)
        encoder.setBuffer(recoveryBuffer, offset: 0, index: 1)
        encoder.setBuffer(mulTableBuffer, offset: 0, index: 2)
        encoder.setBuffer(coeffBuffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<PAR2Uniforms>.size, index: 4)

        // Thread grid: (blockSize, recoveryBlockCount)
        let gridSize = MTLSize(width: blockSize, height: recoveryBlockCount, depth: 1)
        let threadgroupSize = MTLSize(
            width: min(blockSize, pipeline.maxTotalThreadsPerThreadgroup),
            height: 1,
            depth: 1
        )
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // Report progress at 50% when submitted, 100% when complete
        onProgress?(0.5)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if commandBuffer.status == .error {
            return nil
        }

        onProgress?(1.0)

        // Read back results
        let resultPtr = recoveryBuffer.contents().bindMemory(to: UInt8.self, capacity: recoverySize)
        return Data(bytes: resultPtr, count: recoverySize)
    }

    // MARK: - Metal Shader Source

    nonisolated private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PAR2Uniforms {
        uint blockSize;
        uint blockCount;
        uint recoveryBlockCount;
        uint dataSize;
    };

    kernel void par2Generate(
        device const uint8_t* data          [[buffer(0)]],
        device uint8_t*       recovery      [[buffer(1)]],
        device const uint8_t* mulTable      [[buffer(2)]],
        device const uint8_t* coefficients  [[buffer(3)]],
        constant PAR2Uniforms& uniforms     [[buffer(4)]],
        uint2 tid                           [[thread_position_in_grid]]
    ) {
        uint pos = tid.x;
        uint r   = tid.y;
        if (pos >= uniforms.blockSize || r >= uniforms.recoveryBlockCount) return;

        uint8_t acc = 0;
        uint coeffBase = r * uniforms.blockCount;

        for (uint b = 0; b < uniforms.blockCount; b++) {
            uint srcIndex = b * uniforms.blockSize + pos;
            if (srcIndex >= uniforms.dataSize) break;
            uint8_t coeff = coefficients[coeffBase + b];
            uint8_t dataByte = data[srcIndex];
            acc ^= mulTable[uint(coeff) * 256 + uint(dataByte)];
        }

        recovery[r * uniforms.blockSize + pos] = acc;
    }
    """

    // MARK: - GF(2^8) Multiplication Table

    nonisolated private static func buildMulTable() -> [UInt8] {
        var table = [UInt8](repeating: 0, count: 256 * 256)
        for a in 0..<256 {
            for b in 0..<256 {
                var result: UInt16 = 0
                var av = UInt16(a)
                var bv = UInt16(b)
                for _ in 0..<8 {
                    if bv & 1 != 0 { result ^= av }
                    let highBit = av & 0x80
                    av <<= 1
                    if highBit != 0 { av ^= 0x11D }
                    bv >>= 1
                }
                table[a * 256 + b] = UInt8(result & 0xFF)
            }
        }
        return table
    }
}
