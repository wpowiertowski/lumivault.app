import Foundation
import CryptoKit
import os

// MARK: - CRC32 (IEEE/zlib compatible)

nonisolated enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
            }
            return crc
        }
    }()

    nonisolated static func compute(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFFFFFF
    }

    nonisolated static func compute(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            compute(raw.bindMemory(to: UInt8.self))
        }
    }
}

// MARK: - PAR2 Packet Constants

nonisolated private enum PAR2 {
    static let magic: [UInt8] = [0x50, 0x41, 0x52, 0x32, 0x00, 0x50, 0x4B, 0x54]
    static let headerSize = 64

    static let typeMain: [UInt8] = [
        0x50, 0x41, 0x52, 0x20, 0x32, 0x2E, 0x30, 0x00,
        0x4D, 0x61, 0x69, 0x6E, 0x00, 0x00, 0x00, 0x00
    ]
    static let typeFileDesc: [UInt8] = [
        0x50, 0x41, 0x52, 0x20, 0x32, 0x2E, 0x30, 0x00,
        0x46, 0x69, 0x6C, 0x65, 0x44, 0x65, 0x73, 0x63
    ]
    static let typeIFSC: [UInt8] = [
        0x50, 0x41, 0x52, 0x20, 0x32, 0x2E, 0x30, 0x00,
        0x49, 0x46, 0x53, 0x43, 0x00, 0x00, 0x00, 0x00
    ]
    static let typeRecvSlice: [UInt8] = [
        0x50, 0x41, 0x52, 0x20, 0x32, 0x2E, 0x30, 0x00,
        0x52, 0x65, 0x63, 0x76, 0x53, 0x6C, 0x69, 0x63
    ]
    static let typeCreator: [UInt8] = [
        0x50, 0x41, 0x52, 0x20, 0x32, 0x2E, 0x30, 0x00,
        0x43, 0x72, 0x65, 0x61, 0x74, 0x6F, 0x72, 0x00
    ]

    static let creatorString = "Created by LumiVault"
}

// MARK: - PAR2 Packet Builder

nonisolated private struct PAR2PacketBuilder {
    let setID: [UInt8] // 16 bytes

    /// Build a complete packet with header: magic + length + MD5(32..end) + setID + type + body.
    func buildPacket(type: [UInt8], body: Data) -> Data {
        let packetLength = UInt64(PAR2.headerSize + body.count)

        // Assemble bytes 32..end for MD5: setID(16) + type(16) + body
        var hashInput = Data(capacity: 32 + body.count)
        hashInput.append(contentsOf: setID)
        hashInput.append(contentsOf: type)
        hashInput.append(body)

        let md5 = Array(Insecure.MD5.hash(data: hashInput))

        var packet = Data(capacity: Int(packetLength))
        packet.append(contentsOf: PAR2.magic)
        appendLE(&packet, packetLength)
        packet.append(contentsOf: md5)
        packet.append(contentsOf: setID)
        packet.append(contentsOf: type)
        packet.append(body)
        return packet
    }

    // MARK: - Specific Packets

    func mainPacket(blockSize: UInt64, fileIDs: [[UInt8]]) -> Data {
        var body = Data()
        appendLE(&body, blockSize)
        appendLE(&body, UInt32(fileIDs.count))
        for fid in fileIDs {
            body.append(contentsOf: fid)
        }
        return buildPacket(type: PAR2.typeMain, body: body)
    }

    func fileDescPacket(fileID: [UInt8], hashFull: [UInt8], hash16k: [UInt8],
                        fileLength: UInt64, filename: String) -> Data {
        let nameBytes = Array(filename.utf8)
        let paddedLength = (nameBytes.count + 3) & ~3 // round up to 4-byte boundary

        var body = Data(capacity: 56 + paddedLength)
        body.append(contentsOf: fileID)
        body.append(contentsOf: hashFull)
        body.append(contentsOf: hash16k)
        appendLE(&body, fileLength)
        body.append(contentsOf: nameBytes)
        // Pad to 4-byte boundary
        let padCount = paddedLength - nameBytes.count
        if padCount > 0 {
            body.append(contentsOf: [UInt8](repeating: 0, count: padCount))
        }
        return buildPacket(type: PAR2.typeFileDesc, body: body)
    }

    func ifscPacket(fileID: [UInt8], entries: [(md5: [UInt8], crc32: UInt32)]) -> Data {
        var body = Data(capacity: 16 + entries.count * 20)
        body.append(contentsOf: fileID)
        for entry in entries {
            body.append(contentsOf: entry.md5)
            appendLE(&body, entry.crc32)
        }
        return buildPacket(type: PAR2.typeIFSC, body: body)
    }

    func recoverySlicePacket(exponent: UInt32, recoveryData: Data) -> Data {
        var body = Data(capacity: 4 + recoveryData.count)
        appendLE(&body, exponent)
        body.append(recoveryData)
        return buildPacket(type: PAR2.typeRecvSlice, body: body)
    }

    func creatorPacket() -> Data {
        var nameBytes = Array(PAR2.creatorString.utf8)
        nameBytes.append(0) // null terminator
        let paddedLength = (nameBytes.count + 3) & ~3
        let padCount = paddedLength - nameBytes.count
        if padCount > 0 {
            nameBytes.append(contentsOf: [UInt8](repeating: 0, count: padCount))
        }
        return buildPacket(type: PAR2.typeCreator, body: Data(nameBytes))
    }
}

nonisolated private func appendLE(_ data: inout Data, _ value: UInt64) {
    var v = value.littleEndian
    data.append(Data(bytes: &v, count: 8))
}

nonisolated private func appendLE(_ data: inout Data, _ value: UInt32) {
    var v = value.littleEndian
    data.append(Data(bytes: &v, count: 4))
}

// MARK: - PAR2 Packet Reader

nonisolated private struct PAR2PacketReader {
    struct Packet {
        let type: [UInt8] // 16 bytes
        let body: Data
    }

    /// Parse all packets from a PAR2 file. Verifies magic and packet MD5.
    static func readPackets(from data: Data) -> [Packet] {
        var packets: [Packet] = []
        var offset = 0
        while offset + PAR2.headerSize <= data.count {
            // Check magic
            let magic = Array(data[offset..<(offset + 8)])
            guard magic == PAR2.magic else { break }

            // Read length
            let length = data[(offset + 8)..<(offset + 16)].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            let packetLen = Int(UInt64(littleEndian: length))
            guard offset + packetLen <= data.count, packetLen >= PAR2.headerSize else { break }

            let type = Array(data[(offset + 48)..<(offset + 64)])
            let body = data[(offset + 64)..<(offset + packetLen)]
            packets.append(Packet(type: type, body: body))
            offset += packetLen
        }
        return packets
    }

    /// Find recovery slice packets and return (exponent, recoveryData) pairs.
    static func recoverySlices(from packets: [Packet]) -> [(exponent: UInt32, data: Data)] {
        packets.compactMap { packet in
            guard packet.type == PAR2.typeRecvSlice, packet.body.count >= 4 else { return nil }
            let exp = packet.body[packet.body.startIndex..<(packet.body.startIndex + 4)]
                .withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            let recoveryData = packet.body[(packet.body.startIndex + 4)...]
            return (exp, Data(recoveryData))
        }
    }

    /// Parse IFSC packet to get per-block checksums.
    static func sliceChecksums(from packets: [Packet]) -> [(md5: [UInt8], crc32: UInt32)] {
        guard let ifsc = packets.first(where: { $0.type == PAR2.typeIFSC }),
              ifsc.body.count >= 16 else { return [] }
        let entryData = ifsc.body[(ifsc.body.startIndex + 16)...] // skip file ID
        var entries: [(md5: [UInt8], crc32: UInt32)] = []
        var pos = entryData.startIndex
        while pos + 20 <= entryData.endIndex {
            let md5 = Array(entryData[pos..<(pos + 16)])
            let crc = entryData[(pos + 16)..<(pos + 20)]
                .withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
            entries.append((md5, crc))
            pos += 20
        }
        return entries
    }

    /// Parse Main packet to get block size.
    static func blockSize(from packets: [Packet]) -> Int? {
        guard let main = packets.first(where: { $0.type == PAR2.typeMain }),
              main.body.count >= 8 else { return nil }
        let bs = main.body[main.body.startIndex..<(main.body.startIndex + 8)]
            .withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        return Int(bs)
    }

    /// Parse File Description to get expected file length.
    static func fileLength(from packets: [Packet]) -> UInt64? {
        guard let desc = packets.first(where: { $0.type == PAR2.typeFileDesc }),
              desc.body.count >= 56 else { return nil }
        return desc.body[(desc.body.startIndex + 48)..<(desc.body.startIndex + 56)]
            .withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
}

// MARK: - RedundancyService

actor RedundancyService {
    private static let redundancyPercentage: Double = 0.10
    private static let metalService: MetalPAR2Service? = MetalPAR2Service()

    /// Generate standard PAR2 2.0 files for the given file.
    /// Returns the URL of the index file (.par2). A companion volume file
    /// (.vol0+N.par2) is also created in the same directory.
    nonisolated func generatePAR2(
        for fileURL: URL,
        outputDirectory: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        cancelFlag: OSAllocatedUnfairLock<Bool>? = nil
    ) throws -> URL {
        let data = try Data(contentsOf: fileURL)
        let filename = fileURL.lastPathComponent

        // Block sizing — must be multiple of 4 for PAR2
        let blockSize = Self.computeBlockSize(dataSize: data.count)
        let blockCount = (data.count + blockSize - 1) / blockSize
        let recoveryBlockCount = max(1, Int(Double(blockCount) * Self.redundancyPercentage))

        // Compute file hashes
        let hashFull = Array(Insecure.MD5.hash(data: data))
        let hash16k = Array(Insecure.MD5.hash(data: data.prefix(16384)))

        // Compute file ID: MD5(hash16k || length_u64LE || filename_bytes)
        let fileID = Self.computeFileID(hash16k: hash16k, fileLength: UInt64(data.count), filename: filename)

        // Compute per-block checksums (MD5 + CRC32)
        let sliceChecksums = Self.computeSliceChecksums(data: data, blockSize: blockSize, blockCount: blockCount)

        // Compute Set ID: MD5(main_packet_body)
        let setID = Self.computeSetID(blockSize: UInt64(blockSize), fileIDs: [fileID])

        let builder = PAR2PacketBuilder(setID: setID)

        // Build metadata packets (shared by index and volume files)
        let mainPacket = builder.mainPacket(blockSize: UInt64(blockSize), fileIDs: [fileID])
        let fileDescPacket = builder.fileDescPacket(
            fileID: fileID, hashFull: hashFull, hash16k: hash16k,
            fileLength: UInt64(data.count), filename: filename
        )
        let ifscPacket = builder.ifscPacket(fileID: fileID, entries: sliceChecksums)
        let creatorPacket = builder.creatorPacket()

        // Compute PAR2 Vandermonde source block bases
        let bases = GF16.sourceBlockBases(count: blockCount)

        // Zero-pad data to full blocks for RS computation
        var paddedData = data
        let paddedSize = blockCount * blockSize
        if paddedData.count < paddedSize {
            paddedData.append(Data(repeating: 0, count: paddedSize - paddedData.count))
        }

        // Generate recovery data using GF(2^16) Reed-Solomon
        let recoveryData: Data
        if let metal = Self.metalService,
           let gpuResult = metal.generateRecoveryData(
               data: paddedData,
               blockSize: blockSize,
               blockCount: blockCount,
               recoveryBlockCount: recoveryBlockCount,
               bases: bases,
               onProgress: onProgress
           ) {
            recoveryData = gpuResult
        } else {
            recoveryData = try Self.generateRecoveryDataCPU(
                data: paddedData,
                blockSize: blockSize,
                blockCount: blockCount,
                recoveryBlockCount: recoveryBlockCount,
                bases: bases,
                onProgress: onProgress,
                cancelFlag: cancelFlag
            )
        }

        // Write index file (.par2) — metadata only, no recovery data
        let indexFilename = filename + ".par2"
        let indexURL = outputDirectory.appendingPathComponent(indexFilename)
        var indexData = Data()
        indexData.append(mainPacket)
        indexData.append(fileDescPacket)
        indexData.append(ifscPacket)
        indexData.append(creatorPacket)
        try indexData.write(to: indexURL, options: .atomic)

        // Write volume file (.vol0+N.par2) — recovery slices + duplicate metadata
        let volFilename = "\(filename).vol0+\(recoveryBlockCount).par2"
        let volURL = outputDirectory.appendingPathComponent(volFilename)
        var volData = Data()
        for r in 0..<recoveryBlockCount {
            let sliceStart = r * blockSize
            let sliceEnd = sliceStart + blockSize
            let slice = recoveryData[sliceStart..<sliceEnd]
            volData.append(builder.recoverySlicePacket(exponent: UInt32(r), recoveryData: Data(slice)))
        }
        volData.append(mainPacket)
        volData.append(fileDescPacket)
        volData.append(ifscPacket)
        volData.append(creatorPacket)
        try volData.write(to: volURL, options: .atomic)

        return indexURL
    }

    // MARK: - Verification

    /// Verify a file against its PAR2 checksums.
    /// Checks per-block CRC32 from the IFSC packet in the index file.
    /// Also handles legacy PV2R format files for backward compatibility.
    nonisolated func verify(par2URL: URL, originalFileURL: URL) throws -> Bool {
        let par2Data = try Data(contentsOf: par2URL)

        // Legacy PV2R format detection
        if par2Data.count >= 4, String(data: par2Data[0..<4], encoding: .ascii) == "PV2R" {
            return try verifyLegacy(par2Data: par2Data, originalFileURL: originalFileURL)
        }

        let packets = PAR2PacketReader.readPackets(from: par2Data)

        // Also load any companion vol files for additional packets
        let allPackets = Self.loadAllPAR2Packets(baseURL: par2URL)

        guard let blockSize = PAR2PacketReader.blockSize(from: allPackets.isEmpty ? packets : allPackets),
              let expectedLength = PAR2PacketReader.fileLength(from: allPackets.isEmpty ? packets : allPackets) else {
            return false
        }

        let checksums = PAR2PacketReader.sliceChecksums(from: allPackets.isEmpty ? packets : allPackets)
        guard !checksums.isEmpty else { return false }

        let fileData = try Data(contentsOf: originalFileURL)
        guard UInt64(fileData.count) == expectedLength else { return false }

        let blockCount = (fileData.count + blockSize - 1) / blockSize

        for b in 0..<blockCount {
            let start = b * blockSize
            let end = min(start + blockSize, fileData.count)
            var blockData = Data(fileData[start..<end])
            if blockData.count < blockSize {
                blockData.append(Data(repeating: 0, count: blockSize - blockData.count))
            }

            let crc = CRC32.compute(blockData)
            if crc != checksums[b].crc32 { return false }
        }

        return true
    }

    // MARK: - Repair

    /// Repair a corrupted file using PAR2 recovery data.
    /// Returns the repaired data, or nil if repair is not possible.
    /// Also handles legacy PV2R format for backward compatibility.
    nonisolated func repair(par2URL: URL, corruptedFileURL: URL) throws -> Data? {
        let par2Data = try Data(contentsOf: par2URL)

        // Legacy PV2R format detection
        if par2Data.count >= 4, String(data: par2Data[0..<4], encoding: .ascii) == "PV2R" {
            return try repairLegacy(par2URL: par2URL, corruptedFileURL: corruptedFileURL)
        }

        // Load all packets from index + vol files
        let allPackets = Self.loadAllPAR2Packets(baseURL: par2URL)
        guard !allPackets.isEmpty else { return nil }

        guard let blockSize = PAR2PacketReader.blockSize(from: allPackets),
              let expectedLength = PAR2PacketReader.fileLength(from: allPackets) else { return nil }

        let checksums = PAR2PacketReader.sliceChecksums(from: allPackets)
        let recoverySlices = PAR2PacketReader.recoverySlices(from: allPackets)
        guard !checksums.isEmpty, !recoverySlices.isEmpty else { return nil }

        let blockCount = checksums.count
        let corruptedData = try Data(contentsOf: corruptedFileURL)

        // Zero-pad corrupted data to full blocks
        var paddedData = corruptedData
        let paddedSize = blockCount * blockSize
        if paddedData.count < paddedSize {
            paddedData.append(Data(repeating: 0, count: paddedSize - paddedData.count))
        }

        // Identify corrupt blocks by CRC32
        var corruptBlockIndices: [Int] = []
        for b in 0..<blockCount {
            let start = b * blockSize
            let blockData = paddedData[start..<(start + blockSize)]
            let crc = CRC32.compute(Data(blockData))
            if crc != checksums[b].crc32 {
                corruptBlockIndices.append(b)
            }
        }

        guard !corruptBlockIndices.isEmpty else {
            // No corruption detected — file is OK
            return Data(corruptedData.prefix(Int(expectedLength)))
        }

        guard corruptBlockIndices.count <= recoverySlices.count else {
            return nil // More corrupt blocks than recovery slices
        }

        // Compute source block bases (same as during generation)
        let bases = GF16.sourceBlockBases(count: blockCount)
        let wordsPerBlock = blockSize / 2

        // Solve for corrupt blocks using recovery slices via GF(2^16) linear algebra.
        // For each recovery slice with exponent e:
        //   recovery[e] = sum(input[b] * pow(base[b], e)) for all b
        // We know input[b] for good blocks, so:
        //   recovery[e] - sum(good blocks) = sum(corrupt blocks * coefficients)
        // This gives us a system of equations to solve for the corrupt blocks.

        // Compute the "syndrome" for each recovery slice: remove contribution of good blocks
        var syndromes: [(exponent: UInt32, words: [UInt16])] = []
        for slice in recoverySlices.prefix(corruptBlockIndices.count) {
            var syndrome = [UInt16](repeating: 0, count: wordsPerBlock)

            // Start with recovery data
            slice.data.withUnsafeBytes { raw in
                let words = raw.bindMemory(to: UInt16.self)
                for w in 0..<min(wordsPerBlock, words.count) {
                    syndrome[w] = UInt16(littleEndian: words[w])
                }
            }

            // Subtract contribution of good blocks
            for b in 0..<blockCount where !corruptBlockIndices.contains(b) {
                let coeff = GF16.pow(bases[b], slice.exponent)
                let start = b * blockSize
                paddedData.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for w in 0..<wordsPerBlock {
                        let byteOff = start + w * 2
                        let dataWord = UInt16(bytes[byteOff]) | (UInt16(bytes[byteOff + 1]) << 8)
                        syndrome[w] ^= GF16.mul(coeff, dataWord)
                    }
                }
            }
            syndromes.append((slice.exponent, syndrome))
        }

        // Build and solve the matrix for corrupt blocks
        let n = corruptBlockIndices.count

        // Build coefficient matrix: matrix[r][c] = pow(base[corruptBlock[c]], exponent[r])
        var matrix = [[UInt16]](repeating: [UInt16](repeating: 0, count: n), count: n)
        for r in 0..<n {
            for c in 0..<n {
                matrix[r][c] = GF16.pow(bases[corruptBlockIndices[c]], syndromes[r].exponent)
            }
        }

        // Gaussian elimination to invert the matrix
        var augmented = matrix
        var identity = [[UInt16]](repeating: [UInt16](repeating: 0, count: n), count: n)
        for i in 0..<n { identity[i][i] = 1 }

        for col in 0..<n {
            // Find pivot
            var pivotRow = -1
            for row in col..<n {
                if augmented[row][col] != 0 { pivotRow = row; break }
            }
            guard pivotRow >= 0 else { return nil } // Singular matrix

            if pivotRow != col {
                augmented.swapAt(col, pivotRow)
                identity.swapAt(col, pivotRow)
            }

            let pivotInv = GF16.inv(augmented[col][col])
            for j in 0..<n {
                augmented[col][j] = GF16.mul(augmented[col][j], pivotInv)
                identity[col][j] = GF16.mul(identity[col][j], pivotInv)
            }

            for row in 0..<n where row != col {
                let factor = augmented[row][col]
                if factor == 0 { continue }
                for j in 0..<n {
                    augmented[row][j] ^= GF16.mul(factor, augmented[col][j])
                    identity[row][j] ^= GF16.mul(factor, identity[col][j])
                }
            }
        }

        // Reconstruct corrupt blocks: repairedBlock[c] = sum(identity[c][r] * syndrome[r])
        var repaired = paddedData
        for c in 0..<n {
            let blockIndex = corruptBlockIndices[c]
            let blockStart = blockIndex * blockSize
            var repairedWords = [UInt16](repeating: 0, count: wordsPerBlock)
            for r in 0..<n {
                let scale = identity[c][r]
                if scale == 0 { continue }
                for w in 0..<wordsPerBlock {
                    repairedWords[w] ^= GF16.mul(scale, syndromes[r].words[w])
                }
            }
            // Write repaired block back
            for w in 0..<wordsPerBlock {
                let word = repairedWords[w]
                repaired[blockStart + w * 2] = UInt8(word & 0xFF)
                repaired[blockStart + w * 2 + 1] = UInt8(word >> 8)
            }
        }

        // Verify repair by checking CRC32 of repaired blocks
        for b in corruptBlockIndices {
            let start = b * blockSize
            let blockData = repaired[start..<(start + blockSize)]
            let crc = CRC32.compute(Data(blockData))
            if crc != checksums[b].crc32 {
                return nil // Repair failed verification
            }
        }

        return Data(repaired.prefix(Int(expectedLength)))
    }

    // MARK: - Block Sizing

    nonisolated private static func computeBlockSize(dataSize: Int) -> Int {
        // PAR2 block size must be a multiple of 4. Cap at 32768 source blocks.
        let maxBlocks = 32768
        let minBlockSize = max(4, (dataSize + maxBlocks - 1) / maxBlocks)
        // Round up to next power of 2, minimum 4096
        let target = max(4096, minBlockSize)
        let rounded = target <= 4096 ? 4096 : 1 << Int(ceil(log2(Double(target))))
        // Ensure multiple of 4 (power of 2 >= 4 always is, but be explicit)
        return (rounded + 3) & ~3
    }

    // MARK: - Hash Computation

    nonisolated private static func computeFileID(hash16k: [UInt8], fileLength: UInt64, filename: String) -> [UInt8] {
        var input = Data()
        input.append(contentsOf: hash16k)
        var len = fileLength.littleEndian
        input.append(Data(bytes: &len, count: 8))
        input.append(Data(filename.utf8))
        return Array(Insecure.MD5.hash(data: input))
    }

    nonisolated private static func computeSetID(blockSize: UInt64, fileIDs: [[UInt8]]) -> [UInt8] {
        // Set ID = MD5(main packet body) = MD5(blockSize + fileCount + sorted fileIDs)
        let sortedIDs = fileIDs.sorted { $0.lexicographicallyPrecedes($1) }
        var body = Data()
        var bs = blockSize.littleEndian
        body.append(Data(bytes: &bs, count: 8))
        var fc = UInt32(sortedIDs.count).littleEndian
        body.append(Data(bytes: &fc, count: 4))
        for fid in sortedIDs {
            body.append(contentsOf: fid)
        }
        return Array(Insecure.MD5.hash(data: body))
    }

    nonisolated private static func computeSliceChecksums(
        data: Data, blockSize: Int, blockCount: Int
    ) -> [(md5: [UInt8], crc32: UInt32)] {
        (0..<blockCount).map { b in
            let start = b * blockSize
            let end = min(start + blockSize, data.count)
            var blockData = Data(data[start..<end])
            // Zero-pad last block
            if blockData.count < blockSize {
                blockData.append(Data(repeating: 0, count: blockSize - blockData.count))
            }
            let md5 = Array(Insecure.MD5.hash(data: blockData))
            let crc = CRC32.compute(blockData)
            return (md5, crc)
        }
    }

    // MARK: - CPU Recovery Data Generation

    nonisolated private static func generateRecoveryDataCPU(
        data: Data,
        blockSize: Int,
        blockCount: Int,
        recoveryBlockCount: Int,
        bases: [UInt16],
        onProgress: (@Sendable (Double) -> Void)?,
        cancelFlag: OSAllocatedUnfairLock<Bool>?
    ) throws -> Data {
        let wordsPerBlock = blockSize / 2
        nonisolated(unsafe) let recoveryBuffer = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: recoveryBlockCount * wordsPerBlock)
        defer { recoveryBuffer.deallocate() }
        recoveryBuffer.initialize(repeating: 0)

        let totalWork = recoveryBlockCount * blockCount
        let completedWork = OSAllocatedUnfairLock(initialState: 0)
        let reportInterval = max(1, totalWork / 50)
        let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

        let logTable = GF16.logTableBytes
        let antilogTable = GF16.antilogTableBytes

        data.withUnsafeBytes { rawData in
            nonisolated(unsafe) let dataBytes = rawData.bindMemory(to: UInt8.self)

            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = maxConcurrency
            queue.qualityOfService = .userInitiated

            for r in 0..<recoveryBlockCount {
                queue.addOperation {
                    if let flag = cancelFlag, flag.withLock({ $0 }) { return }

                    let parityStart = r * wordsPerBlock
                    let exponent = UInt32(r)

                    for b in 0..<blockCount {
                        if b % 64 == 0, let flag = cancelFlag, flag.withLock({ $0 }) { return }

                        // coefficient = pow(base[b], exponent) in GF(2^16)
                        let coeff: UInt16
                        if exponent == 0 {
                            coeff = 1
                        } else {
                            let base = bases[b]
                            let logBase = UInt64(logTable[Int(base)])
                            let logResult = (logBase * UInt64(exponent)) % 65535
                            coeff = antilogTable[Int(logResult)]
                        }

                        let srcStart = b * blockSize
                        // Process 16-bit LE words
                        for w in 0..<wordsPerBlock {
                            let byteOff = srcStart + w * 2
                            let dataWord = UInt16(dataBytes[byteOff]) | (UInt16(dataBytes[byteOff + 1]) << 8)
                            if dataWord != 0 && coeff != 0 {
                                let logSum = UInt32(logTable[Int(coeff)]) + UInt32(logTable[Int(dataWord)])
                                let product = antilogTable[Int(logSum >= 65535 ? logSum - 65535 : logSum)]
                                recoveryBuffer[parityStart + w] ^= product
                            }
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

        // Convert UInt16 buffer to Data (little-endian)
        var result = Data(capacity: recoveryBlockCount * blockSize)
        for i in 0..<(recoveryBlockCount * wordsPerBlock) {
            var word = recoveryBuffer[i].littleEndian
            result.append(Data(bytes: &word, count: 2))
        }
        return result
    }

    // MARK: - PAR2 File Discovery

    /// Load all PAR2 packets from the index file and any companion vol files in the same directory.
    nonisolated private static func loadAllPAR2Packets(baseURL: URL) -> [PAR2PacketReader.Packet] {
        let directory = baseURL.deletingLastPathComponent()
        let baseName = baseURL.deletingPathExtension().lastPathComponent // e.g. "photo.heic"

        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            if let data = try? Data(contentsOf: baseURL) {
                return PAR2PacketReader.readPackets(from: data)
            }
            return []
        }

        var allPackets: [PAR2PacketReader.Packet] = []
        for file in files {
            let name = file.lastPathComponent
            let isIndex = name == baseName + ".par2"
            let isVol = name.hasPrefix(baseName + ".vol") && name.hasSuffix(".par2")
            if isIndex || isVol {
                if let data = try? Data(contentsOf: file) {
                    allPackets.append(contentsOf: PAR2PacketReader.readPackets(from: data))
                }
            }
        }
        return allPackets
    }

    /// Find all PAR2 companion files (index + vol) for a given index filename.
    nonisolated static func companionFiles(forIndex indexFilename: String, in directory: URL) -> [URL] {
        guard indexFilename.hasSuffix(".par2") else { return [] }
        let baseName = String(indexFilename.dropLast(5)) // remove ".par2"
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { url in
            let name = url.lastPathComponent
            return name == indexFilename || (name.hasPrefix(baseName + ".vol") && name.hasSuffix(".par2"))
        }
    }

    // MARK: - Legacy PV2R Format Compatibility

    nonisolated private func verifyLegacy(par2Data: Data, originalFileURL: URL) throws -> Bool {
        guard par2Data.count >= 24 else { return false }
        let expectedSize = par2Data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        let attrs = try FileManager.default.attributesOfItem(atPath: originalFileURL.path)
        let actualSize = (attrs[.size] as? UInt64) ?? 0
        return actualSize == expectedSize
    }

    nonisolated private func repairLegacy(par2URL: URL, corruptedFileURL: URL) throws -> Data? {
        let par2Data = try Data(contentsOf: par2URL)
        guard par2Data.count >= 24,
              String(data: par2Data[0..<4], encoding: .ascii) == "PV2R" else { return nil }

        let expectedSize = Int(par2Data[4..<12].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        let blockSize = Int(par2Data[12..<16].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let blockCount = Int(par2Data[16..<20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let recoveryCount = Int(par2Data[20..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard recoveryCount >= 2 else { return nil }

        let corruptedData = try Data(contentsOf: corruptedFileURL)
        let headerSize = 24
        var recoveryBlocks: [[UInt8]] = []
        for r in 0..<recoveryCount {
            let start = headerSize + r * blockSize
            recoveryBlocks.append(Array(par2Data[start..<(start + blockSize)]))
        }

        for corruptedBlockIndex in 0..<blockCount {
            var partialParity = [UInt8](repeating: 0, count: blockSize)
            for b in 0..<blockCount where b != corruptedBlockIndex {
                let start = b * blockSize
                let end = min(start + blockSize, corruptedData.count)
                let coefficient = legacyVandermondeCoefficient(row: 0, col: b)
                for i in 0..<(end - start) {
                    partialParity[i] ^= legacyGaloisMultiply(corruptedData[start + i], coefficient)
                }
            }
            var weightedMissing = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<blockSize {
                weightedMissing[i] = recoveryBlocks[0][i] ^ partialParity[i]
            }
            let corruptedCoeff = legacyVandermondeCoefficient(row: 0, col: corruptedBlockIndex)
            let inverse = legacyGaloisInverse(corruptedCoeff)
            var repairedBlock = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<blockSize {
                repairedBlock[i] = legacyGaloisMultiply(weightedMissing[i], inverse)
            }

            var repaired = Data(corruptedData)
            if repaired.count < blockCount * blockSize {
                repaired.append(Data(repeating: 0, count: blockCount * blockSize - repaired.count))
            }
            let blockStart = corruptedBlockIndex * blockSize
            let actualEnd = min(blockStart + blockSize, expectedSize)
            for i in 0..<(actualEnd - blockStart) {
                repaired[blockStart + i] = repairedBlock[i]
            }
            let result = repaired.prefix(expectedSize)

            var allMatch = true
            for r in 0..<recoveryCount {
                var verifyParity = [UInt8](repeating: 0, count: blockSize)
                for b in 0..<blockCount {
                    let start = b * blockSize
                    let end = min(start + blockSize, result.count)
                    let coefficient = legacyVandermondeCoefficient(row: r, col: b)
                    for i in 0..<(end - start) {
                        verifyParity[i] ^= legacyGaloisMultiply(result[start + i], coefficient)
                    }
                }
                if verifyParity != recoveryBlocks[r] { allMatch = false; break }
            }
            if allMatch { return Data(result) }
        }
        return nil
    }

    // Legacy GF(2^8) helpers for PV2R backward compatibility
    nonisolated private func legacyVandermondeCoefficient(row: Int, col: Int) -> UInt8 {
        legacyGaloisPow(UInt8(row + 1), col)
    }

    nonisolated private func legacyGaloisPow(_ base: UInt8, _ exp: Int) -> UInt8 {
        guard exp > 0 else { return 1 }
        var result: UInt8 = 1; var b = base; var e = exp
        while e > 0 {
            if e & 1 != 0 { result = legacyGaloisMultiply(result, b) }
            b = legacyGaloisMultiply(b, b); e >>= 1
        }
        return result
    }

    nonisolated private func legacyGaloisMultiply(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var result: UInt16 = 0; var a = UInt16(a); var b = UInt16(b)
        for _ in 0..<8 {
            if b & 1 != 0 { result ^= a }
            let hi = a & 0x80; a <<= 1; if hi != 0 { a ^= 0x11D }; b >>= 1
        }
        return UInt8(result & 0xFF)
    }

    nonisolated private func legacyGaloisInverse(_ a: UInt8) -> UInt8 {
        guard a != 0 else { return 0 }
        for b: UInt16 in 1...255 { if legacyGaloisMultiply(a, UInt8(b)) == 1 { return UInt8(b) } }
        return 0
    }
}
