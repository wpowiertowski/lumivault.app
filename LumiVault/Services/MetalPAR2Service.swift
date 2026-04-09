import Foundation
import Metal

/// GPU-accelerated PAR2 2.0 recovery block generation using Metal compute shaders.
/// Uses GF(2^16) arithmetic with log/antilog tables for PAR2-standard Reed-Solomon coding.
/// Falls back to nil initialization if Metal is unavailable.
final class MetalPAR2Service: @unchecked Sendable {
    private nonisolated(unsafe) let device: MTLDevice
    private nonisolated(unsafe) let pipeline: MTLComputePipelineState
    private nonisolated(unsafe) let commandQueue: MTLCommandQueue
    private nonisolated(unsafe) let logTableBuffer: MTLBuffer
    private nonisolated(unsafe) let antilogTableBuffer: MTLBuffer

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

        // Upload GF(2^16) log and antilog tables (65536 × UInt16 = 128 KB each)
        let logTable = GF16.logTableBytes
        let antilogTable = GF16.antilogTableBytes

        guard let logBuf = logTable.withUnsafeBufferPointer({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count * 2, options: .storageModeShared)
        }) else { return nil }

        guard let antilogBuf = antilogTable.withUnsafeBufferPointer({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count * 2, options: .storageModeShared)
        }) else { return nil }

        self.device = device
        self.pipeline = pipeline
        self.commandQueue = commandQueue
        self.logTableBuffer = logBuf
        self.antilogTableBuffer = antilogBuf
    }

    struct PAR2Uniforms {
        var blockSize: UInt32       // in bytes (must be multiple of 2)
        var blockCount: UInt32
        var recoveryBlockCount: UInt32
        var symbolsPerBlock: UInt32 // blockSize / 2
    }

    /// Generate PAR2 2.0 recovery data on the GPU using GF(2^16) Reed-Solomon.
    /// `bases` contains the Vandermonde base values for each source block (one per block).
    /// Returns the raw recovery bytes (recoveryBlockCount * blockSize).
    nonisolated func generateRecoveryData(
        data: Data,
        blockSize: Int,
        blockCount: Int,
        recoveryBlockCount: Int,
        bases: [UInt16],
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) -> Data? {
        let symbolsPerBlock = blockSize / 2
        let recoverySize = recoveryBlockCount * blockSize

        // Create Metal buffers
        guard let dataBuffer = data.withUnsafeBytes({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: data.count, options: .storageModeShared)
        }) else { return nil }

        guard let recoveryBuffer = device.makeBuffer(length: recoverySize, options: .storageModeShared) else { return nil }

        guard let basesBuffer = bases.withUnsafeBufferPointer({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: ptr.count * 2, options: .storageModeShared)
        }) else { return nil }

        var uniforms = PAR2Uniforms(
            blockSize: UInt32(blockSize),
            blockCount: UInt32(blockCount),
            recoveryBlockCount: UInt32(recoveryBlockCount),
            symbolsPerBlock: UInt32(symbolsPerBlock)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(dataBuffer, offset: 0, index: 0)
        encoder.setBuffer(recoveryBuffer, offset: 0, index: 1)
        encoder.setBuffer(logTableBuffer, offset: 0, index: 2)
        encoder.setBuffer(antilogTableBuffer, offset: 0, index: 3)
        encoder.setBuffer(basesBuffer, offset: 0, index: 4)
        encoder.setBytes(&uniforms, length: MemoryLayout<PAR2Uniforms>.size, index: 5)

        // Thread grid: (symbolsPerBlock, recoveryBlockCount)
        // Each thread computes one UInt16 symbol in one recovery block
        let gridSize = MTLSize(width: symbolsPerBlock, height: recoveryBlockCount, depth: 1)
        let threadgroupSize = MTLSize(
            width: min(symbolsPerBlock, pipeline.maxTotalThreadsPerThreadgroup),
            height: 1,
            depth: 1
        )
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

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
        uint symbolsPerBlock;
    };

    // GF(2^16) multiply using log/antilog tables
    static inline ushort gf16_mul(ushort a, ushort b,
                                   device const ushort* logTable,
                                   device const ushort* antilogTable) {
        if (a == 0 || b == 0) return 0;
        uint sum = uint(logTable[a]) + uint(logTable[b]);
        if (sum >= 65535) sum -= 65535;
        return antilogTable[sum];
    }

    // GF(2^16) pow using log/antilog tables
    static inline ushort gf16_pow(ushort base, uint exp,
                                   device const ushort* logTable,
                                   device const ushort* antilogTable) {
        if (base == 0) return 0;
        if (exp == 0) return 1;
        ulong logBase = ulong(logTable[base]);
        ulong logResult = (logBase * ulong(exp)) % 65535;
        return antilogTable[uint(logResult)];
    }

    kernel void par2Generate(
        device const ushort* data          [[buffer(0)]],
        device ushort*       recovery      [[buffer(1)]],
        device const ushort* logTable      [[buffer(2)]],
        device const ushort* antilogTable  [[buffer(3)]],
        device const ushort* bases         [[buffer(4)]],
        constant PAR2Uniforms& uniforms    [[buffer(5)]],
        uint2 tid                          [[thread_position_in_grid]]
    ) {
        uint symbolPos = tid.x;   // symbol position within a block
        uint r = tid.y;           // recovery block index
        if (symbolPos >= uniforms.symbolsPerBlock || r >= uniforms.recoveryBlockCount) return;

        uint exponent = r;         // PAR2 exponents are 0-based (matches stored value)
        ushort acc = 0;

        for (uint b = 0; b < uniforms.blockCount; b++) {
            ushort coeff = gf16_pow(bases[b], exponent, logTable, antilogTable);
            ushort srcSymbol = data[b * uniforms.symbolsPerBlock + symbolPos];
            acc ^= gf16_mul(coeff, srcSymbol, logTable, antilogTable);
        }

        recovery[r * uniforms.symbolsPerBlock + symbolPos] = acc;
    }
    """
}
