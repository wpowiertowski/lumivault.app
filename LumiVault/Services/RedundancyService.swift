import Foundation
import os

actor RedundancyService {
    private static let redundancyPercentage: Double = 0.10 // 10% recovery data
    nonisolated(unsafe) private static let metalService: MetalPAR2Service? = MetalPAR2Service()

    // 256x256 GF(2^8) multiplication lookup table — eliminates per-byte loop
    nonisolated private static let mulTable: [[UInt8]] = {
        var table = [[UInt8]](repeating: [UInt8](repeating: 0, count: 256), count: 256)
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
                table[a][b] = UInt8(result & 0xFF)
            }
        }
        return table
    }()

    /// Generate PAR2 off the actor so progress callbacks can reach MainActor.
    /// Pass a cancellation flag to allow stopping from the calling Task.
    nonisolated func generatePAR2(
        for fileURL: URL,
        outputDirectory: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        cancelFlag: OSAllocatedUnfairLock<Bool>? = nil
    ) throws -> URL {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let par2Filename = filename + ".par2"
        let par2URL = outputDirectory.appendingPathComponent(par2Filename)

        // Reed-Solomon encoding using GF(2^8) Vandermonde matrix
        // Adaptive block size: ensure blockCount * redundancy% ≤ 255 (GF(2^8) limit)
        // Max blocks at 10% = 2550, so blockSize = ceil(fileSize / 2550), min 4096, power-of-2
        let maxBlocks = Int(255.0 / Self.redundancyPercentage) // 2550
        let minBlockSize = max(4096, (data.count + maxBlocks - 1) / maxBlocks)
        let blockSize = minBlockSize <= 4096 ? 4096 : Int(pow(2.0, ceil(log2(Double(minBlockSize)))))
        let blockCount = (data.count + blockSize - 1) / blockSize
        let recoveryBlockCount = max(2, Int(Double(blockCount) * Self.redundancyPercentage))

        // Precompute Vandermonde coefficients
        var coefficients = [UInt8](repeating: 0, count: recoveryBlockCount * blockCount)
        for r in 0..<recoveryBlockCount {
            for b in 0..<blockCount {
                coefficients[r * blockCount + b] = vandermondeCoefficient(row: r, col: b)
            }
        }

        // Try GPU (Metal) first, fall back to CPU
        let recoveryData: Data
        if let metal = Self.metalService,
           let gpuResult = metal.generateRecoveryData(
               data: data,
               blockSize: blockSize,
               blockCount: blockCount,
               recoveryBlockCount: recoveryBlockCount,
               coefficients: coefficients,
               onProgress: onProgress
           ) {
            recoveryData = gpuResult
        } else {
            // CPU fallback with limited parallelism
            recoveryData = try generateRecoveryDataCPU(
                data: data,
                blockSize: blockSize,
                blockCount: blockCount,
                recoveryBlockCount: recoveryBlockCount,
                coefficients: coefficients,
                onProgress: onProgress,
                cancelFlag: cancelFlag
            )
        }

        // Write PAR2-style header + recovery data
        var output = Data()
        let headerSize = 4 + 8 + 4 + 4 + 4
        output.reserveCapacity(headerSize + recoveryData.count)

        let magic = "PV2R".data(using: .ascii)!
        output.append(magic)
        var fileSize = UInt64(data.count)
        output.append(Data(bytes: &fileSize, count: 8))
        var bs = UInt32(blockSize)
        output.append(Data(bytes: &bs, count: 4))
        var bc = UInt32(blockCount)
        output.append(Data(bytes: &bc, count: 4))
        var rc = UInt32(recoveryBlockCount)
        output.append(Data(bytes: &rc, count: 4))
        output.append(recoveryData)

        try output.write(to: par2URL, options: .atomic)
        return par2URL
    }

    // MARK: - CPU Fallback

    nonisolated private func generateRecoveryDataCPU(
        data: Data,
        blockSize: Int,
        blockCount: Int,
        recoveryBlockCount: Int,
        coefficients: [UInt8],
        onProgress: (@Sendable (Double) -> Void)?,
        cancelFlag: OSAllocatedUnfairLock<Bool>?
    ) throws -> Data {
        let recoveryBuffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: recoveryBlockCount * blockSize)
        defer { recoveryBuffer.deallocate() }
        recoveryBuffer.initialize(repeating: 0)

        let mulTable = Self.mulTable
        let totalWork = recoveryBlockCount * blockCount
        let completedWork = OSAllocatedUnfairLock(initialState: 0)
        let reportInterval = max(1, totalWork / 50)
        let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        data.withUnsafeBytes { rawData in
            let dataBytes = rawData.bindMemory(to: UInt8.self)

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = maxConcurrency
            queue.qualityOfService = .userInitiated

            for r in 0..<recoveryBlockCount {
                queue.addOperation {
                    if let flag = cancelFlag, flag.withLock({ $0 }) { return }

                    let parityStart = r * blockSize
                    let coeffBase = r * blockCount

                    for b in 0..<blockCount {
                        if b % 64 == 0, let flag = cancelFlag, flag.withLock({ $0 }) { return }

                        let srcStart = b * blockSize
                        let srcEnd = min(srcStart + blockSize, dataBytes.count)
                        let coeff = Int(coefficients[coeffBase + b])
                        let coeffRow = mulTable[coeff]

                        for i in srcStart..<srcEnd {
                            recoveryBuffer[parityStart + (i - srcStart)] ^= coeffRow[Int(dataBytes[i])]
                        }

                        let completed = completedWork.withLock { state -> Int in
                            state += 1
                            return state
                        }
                        if completed % reportInterval == 0 || completed == totalWork {
                            onProgress?(Double(completed) / Double(totalWork))
                        }
                    }
                }
            }
            queue.waitUntilAllOperationsAreFinished()
        }

        if let flag = cancelFlag, flag.withLock({ $0 }) {
            throw CancellationError()
        }

        return Data(UnsafeBufferPointer(start: recoveryBuffer.baseAddress!, count: recoveryBlockCount * blockSize))
    }

    func verify(par2URL: URL, originalFileURL: URL) throws -> Bool {
        let par2Data = try Data(contentsOf: par2URL)
        guard par2Data.count >= 24,
              String(data: par2Data[0..<4], encoding: .ascii) == "PV2R" else {
            return false
        }

        // Verify original file still matches expected size
        let expectedSize = par2Data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let attrs = try FileManager.default.attributesOfItem(atPath: originalFileURL.path)
        let actualSize = (attrs[.size] as? UInt64) ?? 0
        return actualSize == expectedSize
    }

    /// Repair a corrupted file using PAR2 recovery data.
    /// Returns the repaired data, or nil if repair fails.
    /// Supports repairing single-block corruption using cross-verification
    /// across multiple recovery blocks.
    func repair(par2URL: URL, corruptedFileURL: URL) throws -> Data? {
        let par2Data = try Data(contentsOf: par2URL)
        guard par2Data.count >= 24,
              String(data: par2Data[0..<4], encoding: .ascii) == "PV2R" else {
            return nil
        }

        let expectedSize = Int(par2Data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        let blockSize = Int(par2Data[12..<16].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let blockCount = Int(par2Data[16..<20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let recoveryCount = Int(par2Data[20..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })

        guard recoveryCount >= 2 else { return nil }

        let corruptedData = try Data(contentsOf: corruptedFileURL)

        // Load all recovery blocks
        let headerSize = 24
        var recoveryBlocks: [[UInt8]] = []
        for r in 0..<recoveryCount {
            let start = headerSize + r * blockSize
            recoveryBlocks.append(Array(par2Data[start..<(start + blockSize)]))
        }

        // Try each block position as the corrupted block
        for corruptedBlockIndex in 0..<blockCount {
            // Use recovery block 0 to reconstruct the corrupted block
            var partialParity = [UInt8](repeating: 0, count: blockSize)

            for b in 0..<blockCount where b != corruptedBlockIndex {
                let start = b * blockSize
                let end = min(start + blockSize, corruptedData.count)
                let coefficient = vandermondeCoefficient(row: 0, col: b)
                for i in 0..<(end - start) {
                    partialParity[i] ^= galoisMultiply(corruptedData[start + i], coefficient)
                }
            }

            var weightedMissing = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<blockSize {
                weightedMissing[i] = recoveryBlocks[0][i] ^ partialParity[i]
            }

            let corruptedCoeff = vandermondeCoefficient(row: 0, col: corruptedBlockIndex)
            let inverse = galoisInverse(corruptedCoeff)
            var repairedBlock = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<blockSize {
                repairedBlock[i] = galoisMultiply(weightedMissing[i], inverse)
            }

            // Reconstruct the full file with this block replaced
            var repaired = Data(corruptedData)
            if repaired.count < blockCount * blockSize {
                repaired.append(Data(repeating: 0, count: blockCount * blockSize - repaired.count))
            }
            let blockStart = corruptedBlockIndex * blockSize
            let actualEnd = min(blockStart + blockSize, expectedSize)
            let bytesToReplace = actualEnd - blockStart
            for i in 0..<bytesToReplace {
                repaired[blockStart + i] = repairedBlock[i]
            }

            let result = repaired.prefix(expectedSize)

            // Cross-verify against ALL recovery blocks to eliminate false positives
            var allMatch = true
            for r in 0..<recoveryCount {
                var verifyParity = [UInt8](repeating: 0, count: blockSize)
                for b in 0..<blockCount {
                    let start = b * blockSize
                    let end = min(start + blockSize, result.count)
                    let coefficient = vandermondeCoefficient(row: r, col: b)
                    for i in 0..<(end - start) {
                        verifyParity[i] ^= galoisMultiply(result[start + i], coefficient)
                    }
                }
                if verifyParity != recoveryBlocks[r] {
                    allMatch = false
                    break
                }
            }

            if allMatch {
                return Data(result)
            }
        }

        return nil
    }

    // MARK: - GF(2^8) Arithmetic (nonisolated for concurrent access)

    // Vandermonde coefficient: (row+1)^col in GF(2^8)
    // This produces a Vandermonde matrix which is guaranteed non-singular
    // as long as all row values (1, 2, 3, ...) are distinct in GF(2^8).
    nonisolated private func vandermondeCoefficient(row: Int, col: Int) -> UInt8 {
        galoisPow(UInt8(row + 1), col)
    }

    // GF(2^8) exponentiation by squaring
    nonisolated private func galoisPow(_ base: UInt8, _ exp: Int) -> UInt8 {
        guard exp > 0 else { return 1 }
        var result: UInt8 = 1
        var b = base
        var e = exp
        while e > 0 {
            if e & 1 != 0 {
                result = galoisMultiply(result, b)
            }
            b = galoisMultiply(b, b)
            e >>= 1
        }
        return result
    }

    // GF(2^8) multiplication with primitive polynomial 0x11D
    nonisolated private func galoisMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt16 = 0
        var a = UInt16(a)
        var b = UInt16(b)

        for _ in 0..<8 {
            if b & 1 != 0 {
                result ^= a
            }
            let highBit = a & 0x80
            a <<= 1
            if highBit != 0 {
                a ^= 0x11D
            }
            b >>= 1
        }

        return UInt8(result & 0xFF)
    }

    // GF(2^8) multiplicative inverse via brute force (field is small)
    nonisolated private func galoisInverse(_ a: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        for b: UInt16 in 1...255 {
            if galoisMultiply(a, UInt8(b)) == 1 {
                return UInt8(b)
            }
        }
        return 0
    }
}
