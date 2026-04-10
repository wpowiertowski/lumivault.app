import Foundation

/// GF(2^16) arithmetic for PAR2 2.0 compatible Reed-Solomon coding.
/// Primitive polynomial: x^16 + x^12 + x^3 + x + 1 (0x1100B).
/// Uses log/antilog tables for O(1) multiplication.
nonisolated enum GF16 {
    static let fieldSize = 65536
    static let maxExponent: UInt32 = 65535

    // MARK: - Tables

    /// Combined log and antilog tables, computed once.
    /// antilog[i] = 2^i in GF(2^16), log[x] = i such that 2^i = x.
    private static let tables: (log: [UInt16], antilog: [UInt16]) = {
        var log = [UInt16](repeating: 0, count: 65536)
        var antilog = [UInt16](repeating: 0, count: 65536)
        var val: UInt32 = 1
        for i in 0..<65535 {
            antilog[i] = UInt16(val)
            log[Int(val)] = UInt16(i)
            val <<= 1
            if val & 0x10000 != 0 {
                val ^= 0x1100B
            }
        }
        log[0] = 65535 // sentinel: log(0) is undefined
        antilog[65535] = 0
        return (log, antilog)
    }()

    // MARK: - Arithmetic

    /// Multiply two GF(2^16) elements.
    static func mul(_ a: UInt16, _ b: UInt16) -> UInt16 {
        guard a != 0, b != 0 else { return 0 }
        let sum = UInt32(tables.log[Int(a)]) + UInt32(tables.log[Int(b)])
        return tables.antilog[Int(sum >= 65535 ? sum - 65535 : sum)]
    }

    /// Compute base^exp in GF(2^16) using log/antilog.
    static func pow(_ base: UInt16, _ exp: UInt32) -> UInt16 {
        guard base != 0 else { return 0 }
        if exp == 0 { return 1 }
        let logBase = UInt64(tables.log[Int(base)])
        let logResult = (logBase * UInt64(exp)) % 65535
        return tables.antilog[Int(logResult)]
    }

    /// Multiplicative inverse: a^(-1) in GF(2^16).
    static func inv(_ a: UInt16) -> UInt16 {
        guard a != 0 else { return 0 }
        let logA = UInt32(tables.log[Int(a)])
        // a^(-1) = 2^(65535 - logA). Handle logA == 0 (a == 1) → inv = 1.
        let invLog = logA == 0 ? 0 : 65535 - logA
        return tables.antilog[Int(invLog)]
    }

    // MARK: - PAR2 Source Block Bases

    /// Compute the Vandermonde base values for PAR2 source blocks.
    /// PAR2 uses antilog[logbase] where logbase iterates over values coprime to 65535.
    /// 65535 = 3 × 5 × 17 × 257, so coprime means not divisible by 3, 5, 17, or 257.
    static func sourceBlockBases(count: Int) -> [UInt16] {
        var bases = [UInt16]()
        bases.reserveCapacity(count)
        var logbase = 0
        while bases.count < count {
            if logbase == 0 || gcd(65535, logbase) != 1 {
                logbase += 1
                continue
            }
            bases.append(tables.antilog[logbase])
            logbase += 1
        }
        return bases
    }

    private nonisolated static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a, b = b
        while b != 0 {
            let t = b
            b = a % b
            a = t
        }
        return a
    }

    // MARK: - Table Access for Metal

    /// Raw log table for GPU upload (65536 × UInt16 = 128 KB).
    static var logTableBytes: [UInt16] { tables.log }

    /// Raw antilog table for GPU upload (65536 × UInt16 = 128 KB).
    static var antilogTableBytes: [UInt16] { tables.antilog }
}
