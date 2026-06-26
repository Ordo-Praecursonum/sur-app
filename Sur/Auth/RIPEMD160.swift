//
//  RIPEMD160.swift
//  Sur
//
//  RIPEMD-160 hash implementation for Bitcoin and Cosmos address generation
//  Reference: https://homes.esat.kuleuven.be/~bosselae/ripemd160.html
//

import Foundation

/// RIPEMD-160 hash implementation
/// Used for Bitcoin (P2PKH) and Cosmos address generation
struct RIPEMD160 {

    /// Compute RIPEMD-160 hash of input data
    /// - Parameter data: Input data to hash
    /// - Returns: 20-byte RIPEMD-160 hash
    static func hash(_ data: Data) -> Data {
        var ctx = Context()
        ctx.update([UInt8](data))
        return Data(ctx.finalize())
    }

    // MARK: - Internal context

    fileprivate struct Context {
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0
        var buf: [UInt8] = []
        var count: UInt64 = 0

        mutating func update(_ bytes: [UInt8]) {
            count += UInt64(bytes.count)
            buf.append(contentsOf: bytes)
            while buf.count >= 64 {
                compress(Array(buf.prefix(64)))
                buf.removeFirst(64)
            }
        }

        mutating func finalize() -> [UInt8] {
            // Length in bits before padding
            let bitLen = count * 8

            // Append 0x80
            var tmp: [UInt8] = [0x80]
            // Append zeros until buf+tmp ≡ 56 (mod 64)
            let remaining = (56 - Int((count + 1) % 64) + 64) % 64
            tmp.append(contentsOf: [UInt8](repeating: 0, count: remaining))
            // Append 64-bit length little-endian
            for i in 0..<8 {
                tmp.append(UInt8((bitLen >> (i * 8)) & 0xFF))
            }
            update(tmp)
            // buf should now be empty
            precondition(buf.isEmpty, "RIPEMD160: leftover bytes after finalize")

            var result = [UInt8](repeating: 0, count: 20)
            let words: [UInt32] = [h0, h1, h2, h3, h4]
            for i in 0..<5 {
                let v = words[i]
                result[i * 4]     = UInt8(v & 0xFF)
                result[i * 4 + 1] = UInt8((v >> 8) & 0xFF)
                result[i * 4 + 2] = UInt8((v >> 16) & 0xFF)
                result[i * 4 + 3] = UInt8((v >> 24) & 0xFF)
            }
            return result
        }

        mutating func compress(_ block: [UInt8]) {
            // Load 16 little-endian 32-bit words
            var X = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let b = i * 4
                X[i] = UInt32(block[b])
                    | (UInt32(block[b + 1]) << 8)
                    | (UInt32(block[b + 2]) << 16)
                    | (UInt32(block[b + 3]) << 24)
            }

            var al = h0, bl = h1, cl = h2, dl = h3, el = h4
            var ar = h0, br = h1, cr = h2, dr = h3, er = h4

            // 80 rounds — left and right lines run in parallel
            for j in 0..<80 {
                let rnd = j / 16

                // Left line
                var tl = al &+ fL(rnd, bl, cl, dl) &+ X[RL[j]] &+ KL[rnd]
                tl = rotl(tl, SL[j]) &+ el
                al = el; el = dl; dl = rotl(cl, 10); cl = bl; bl = tl

                // Right line
                var tr = ar &+ fR(rnd, br, cr, dr) &+ X[RR[j]] &+ KR[rnd]
                tr = rotl(tr, SR[j]) &+ er
                ar = er; er = dr; dr = rotl(cr, 10); cr = br; br = tr
            }

            // Combine
            let t  = h1 &+ cl &+ dr
            h1 = h2 &+ dl &+ er
            h2 = h3 &+ el &+ ar
            h3 = h4 &+ al &+ br
            h4 = h0 &+ bl &+ cr
            h0 = t
        }
    }

    // MARK: - Boolean functions

    /// Left-line boolean function for round 0-4
    private static func fL(_ rnd: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch rnd {
        case 0: return x ^ y ^ z                      // f1: XOR
        case 1: return (x & y) | (~x & z)             // f2: IF
        case 2: return (x | ~y) ^ z                   // f3: OR-XOR
        case 3: return (x & z) | (y & ~z)             // f4: AND-OR
        default: return x ^ (y | ~z)                  // f5: XOR-OR
        }
    }

    /// Right-line boolean function for round 0-4 (reversed order from left)
    private static func fR(_ rnd: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        switch rnd {
        case 0: return x ^ (y | ~z)                   // f5
        case 1: return (x & z) | (y & ~z)             // f4
        case 2: return (x | ~y) ^ z                   // f3
        case 3: return (x & y) | (~x & z)             // f2
        default: return x ^ y ^ z                     // f1
        }
    }

    @inline(__always)
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x << n) | (x >> (32 &- n))
    }

    // MARK: - Round constants

    private static let KL: [UInt32] = [
        0x00000000, // rounds  0–15
        0x5A827999, // rounds 16–31  (2^30 * sqrt(2))
        0x6ED9EBA1, // rounds 32–47  (2^30 * sqrt(3))
        0x8F1BBCDC, // rounds 48–63  (2^30 * sqrt(5))
        0xA953FD4E  // rounds 64–79  (2^30 * sqrt(7))
    ]

    private static let KR: [UInt32] = [
        0x50A28BE6, // rounds  0–15  (2^30 * cbrt(2))
        0x5C4DD124, // rounds 16–31  (2^30 * cbrt(3))
        0x6D703EF3, // rounds 32–47  (2^30 * cbrt(5))
        0x7A6D76E9, // rounds 48–63  (2^30 * cbrt(7))
        0x00000000  // rounds 64–79
    ]

    // MARK: - Message word selection

    private static let RL: [Int] = [
        0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11, 12, 13, 14, 15,
        7,  4, 13,  1, 10,  6, 15,  3, 12,  0,  9,  5,  2, 14, 11,  8,
        3, 10, 14,  4,  9, 15,  8,  1,  2,  7,  0,  6, 13, 11,  5, 12,
        1,  9, 11, 10,  0,  8, 12,  4, 13,  3,  7, 15, 14,  5,  6,  2,
        4,  0,  5,  9,  7, 12,  2, 10, 14,  1,  3,  8, 11,  6, 15, 13
    ]

    private static let RR: [Int] = [
        5, 14,  7,  0,  9,  2, 11,  4, 13,  6, 15,  8,  1, 10,  3, 12,
        6, 11,  3,  7,  0, 13,  5, 10, 14, 15,  8, 12,  4,  9,  1,  2,
       15,  5,  1,  3,  7, 14,  6,  9, 11,  8, 12,  2, 10,  0,  4, 13,
        8,  6,  4,  1,  3, 11, 15,  0,  5, 12,  2, 13,  9,  7, 10, 14,
       12, 15, 10,  4,  1,  5,  8,  7,  6,  2, 13, 14,  0,  3,  9, 11
    ]

    // MARK: - Rotation amounts

    private static let SL: [UInt32] = [
        11, 14, 15, 12,  5,  8,  7,  9, 11, 13, 14, 15,  6,  7,  9,  8,
         7,  6,  8, 13, 11,  9,  7, 15,  7, 12, 15,  9, 11,  7, 13, 12,
        11, 13,  6,  7, 14,  9, 13, 15, 14,  8, 13,  6,  5, 12,  7,  5,
        11, 12, 14, 15, 14, 15,  9,  8,  9, 14,  5,  6,  8,  6,  5, 12,
         9, 15,  5, 11,  6,  8, 13, 12,  5, 12, 13, 14, 11,  8,  5,  6
    ]

    private static let SR: [UInt32] = [
         8,  9,  9, 11, 13, 15, 15,  5,  7,  7,  8, 11, 14, 14, 12,  6,
         9, 13, 15,  7, 12,  8,  9, 11,  7,  7, 12,  7,  6, 15, 13, 11,
         9,  7, 15, 11,  8,  6,  6, 14, 12, 13,  5, 14, 13, 13,  7,  5,
        15,  5,  8, 11, 14, 14,  6, 14,  6,  9, 12,  9, 12,  5, 15,  8,
         8,  5, 12,  9, 12,  5, 14,  6,  8, 13,  6,  5, 15, 13, 11, 11
    ]
}

// MARK: - Context helpers (calling static methods from mutating context)

private extension RIPEMD160.Context {
    func fL(_ rnd: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        return RIPEMD160.fL(rnd, x, y, z)
    }
    func fR(_ rnd: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        return RIPEMD160.fR(rnd, x, y, z)
    }
    func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return RIPEMD160.rotl(x, n)
    }
    var KL: [UInt32] { RIPEMD160.KL }
    var KR: [UInt32] { RIPEMD160.KR }
    var RL: [Int] { RIPEMD160.RL }
    var RR: [Int] { RIPEMD160.RR }
    var SL: [UInt32] { RIPEMD160.SL }
    var SR: [UInt32] { RIPEMD160.SR }
}
