import Foundation

actor RedundancyService {
    private static let redundancyPercentage: Double = 0.10 // 10% recovery data

    func generatePAR2(for fileURL: URL, outputDirectory: URL) throws -> URL {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent
        let par2Filename = filename + ".par2"
        let par2URL = outputDirectory.appendingPathComponent(par2Filename)

        // Reed-Solomon encoding using GF(2^8) arithmetic
        let blockSize = 4096
        let blockCount = (data.count + blockSize - 1) / blockSize
        let recoveryBlockCount = max(1, Int(Double(blockCount) * Self.redundancyPercentage))

        var recoveryData = Data()

        // Generate recovery blocks using XOR-based parity (simplified RS)
        for r in 0..<recoveryBlockCount {
            var parityBlock = Data(repeating: 0, count: blockSize)

            for b in 0..<blockCount {
                let start = b * blockSize
                let end = min(start + blockSize, data.count)
                let block = data[start..<end]

                // XOR with coefficient weighting
                let coefficient = UInt8((r + 1) * (b + 1) % 255)
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
        let expectedSize = par2Data[4..<12].withUnsafeBytes { $0.load(as: UInt64.self) }
        let attrs = try FileManager.default.attributesOfItem(atPath: originalFileURL.path)
        let actualSize = (attrs[.size] as? UInt64) ?? 0
        return actualSize == expectedSize
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
}
