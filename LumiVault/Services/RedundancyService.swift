import Foundation

actor RedundancyService {
    private static let redundancyPercentage: Double = 0.10 // 10% recovery data

    func generatePAR2(for fileURL: URL, outputDirectory: URL) throws -> URL {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let par2Filename = filename + ".par2"
        let par2URL = outputDirectory.appendingPathComponent(par2Filename)

        // Reed-Solomon encoding using GF(2^8) Vandermonde matrix
        let blockSize = 4096
        let blockCount = (data.count + blockSize - 1) / blockSize
        let recoveryBlockCount = max(2, Int(Double(blockCount) * Self.redundancyPercentage))

        var recoveryData = Data()

        // Generate recovery blocks using Vandermonde coefficients: α^(r*b)
        // where α = (r+1) and exponent = b, giving coefficient = galoisPow(r+1, b)
        for r in 0..<recoveryBlockCount {
            var parityBlock = Data(repeating: 0, count: blockSize)

            for b in 0..<blockCount {
                let start = b * blockSize
                let end = min(start + blockSize, data.count)
                let block = data[start..<end]

                let coefficient = vandermondeCoefficient(row: r, col: b)
                for (i, byte) in block.enumerated() {
                    parityBlock[i] ^= galoisMultiply(byte, coefficient)
                }
            }

            recoveryData.append(parityBlock)
        }

        // Write PAR2-style header + recovery data
        var output = Data()
        // Header: magic + original file size + block size + block count + recovery count
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

    // Vandermonde coefficient: (row+1)^col in GF(2^8)
    // This produces a Vandermonde matrix which is guaranteed non-singular
    // as long as all row values (1, 2, 3, ...) are distinct in GF(2^8).
    private func vandermondeCoefficient(row: Int, col: Int) -> UInt8 {
        galoisPow(UInt8(row + 1), col)
    }

    // GF(2^8) exponentiation by squaring
    private func galoisPow(_ base: UInt8, _ exp: Int) -> UInt8 {
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
    private func galoisMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
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
    private func galoisInverse(_ a: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        for b: UInt16 in 1...255 {
            if galoisMultiply(a, UInt8(b)) == 1 {
                return UInt8(b)
            }
        }
        return 0
    }
}
