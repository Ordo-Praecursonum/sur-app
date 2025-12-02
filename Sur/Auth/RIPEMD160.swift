//
//  RIPEMD160.swift
//  Sur
//
//  RIPEMD-160 hash implementation for Bitcoin and Cosmos address generation
//

import Foundation

/// RIPEMD-160 hash implementation
/// Used for Bitcoin (P2PKH) and Cosmos address generation
struct RIPEMD160 {
    
    /// Compute RIPEMD-160 hash of input data
    /// - Parameter data: Input data to hash
    /// - Returns: 20-byte RIPEMD-160 hash
    static func hash(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        return Data(ripemd160(&bytes, bytes.count))
    }
    
    /// RIPEMD-160 implementation
    private static func ripemd160(_ message: UnsafePointer<UInt8>, _ length: Int) -> [UInt8] {
        // Initialize state
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0
        
        // Prepare message padding
        var paddedMessage = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            paddedMessage[i] = message[i]
        }
        
        // Append padding
        paddedMessage.append(0x80)
        
        // Calculate padding length
        let messageLength = length
        let paddingLength = (448 - ((messageLength * 8 + 1) % 512) + 512) % 512
        let zeroPadCount = (paddingLength - 7) / 8
        
        paddedMessage.append(contentsOf: [UInt8](repeating: 0, count: zeroPadCount))
        
        // Append length as 64-bit little-endian
        let bitLength = UInt64(messageLength * 8)
        for i in 0..<8 {
            paddedMessage.append(UInt8((bitLength >> (i * 8)) & 0xFF))
        }
        
        // Process 512-bit chunks
        let chunkCount = paddedMessage.count / 64
        for chunk in 0..<chunkCount {
            let offset = chunk * 64
            var X = [UInt32](repeating: 0, count: 16)
            
            // Convert chunk to 16 32-bit words (little-endian)
            for i in 0..<16 {
                let base = offset + i * 4
                X[i] = UInt32(paddedMessage[base])
                    | (UInt32(paddedMessage[base + 1]) << 8)
                    | (UInt32(paddedMessage[base + 2]) << 16)
                    | (UInt32(paddedMessage[base + 3]) << 24)
            }
            
            // Initialize working variables
            var AL = h0, BL = h1, CL = h2, DL = h3, EL = h4
            var AR = h0, BR = h1, CR = h2, DR = h3, ER = h4
            
            // Left line
            for j in 0..<80 {
                var T = AL &+ f(j, BL, CL, DL) &+ X[r[j]] &+ K(j)
                T = rotateLeft(T, s[j]) &+ EL
                AL = EL
                EL = DL
                DL = rotateLeft(CL, 10)
                CL = BL
                BL = T
            }
            
            // Right line
            for j in 0..<80 {
                var T = AR &+ f(79 - j, BR, CR, DR) &+ X[rPrime[j]] &+ KPrime(j)
                T = rotateLeft(T, sPrime[j]) &+ ER
                AR = ER
                ER = DR
                DR = rotateLeft(CR, 10)
                CR = BR
                BR = T
            }
            
            // Update state
            let T = h1 &+ CL &+ DR
            h1 = h2 &+ DL &+ ER
            h2 = h3 &+ EL &+ AR
            h3 = h4 &+ AL &+ BR
            h4 = h0 &+ BL &+ CR
            h0 = T
        }
        
        // Produce final hash (little-endian)
        var result = [UInt8](repeating: 0, count: 20)
        for i in 0..<5 {
            let value = [h0, h1, h2, h3, h4][i]
            result[i * 4] = UInt8(value & 0xFF)
            result[i * 4 + 1] = UInt8((value >> 8) & 0xFF)
            result[i * 4 + 2] = UInt8((value >> 16) & 0xFF)
            result[i * 4 + 3] = UInt8((value >> 24) & 0xFF)
        }
        
        return result
    }
    
    // MARK: - Helper functions
    
    private static func f(_ j: Int, _ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        if j < 16 {
            return x ^ y ^ z
        } else if j < 32 {
            return (x & y) | (~x & z)
        } else if j < 48 {
            return (x | ~y) ^ z
        } else if j < 64 {
            return (x & z) | (y & ~z)
        } else {
            return x ^ (y | ~z)
        }
    }
    
    private static func K(_ j: Int) -> UInt32 {
        if j < 16 {
            return 0x00000000
        } else if j < 32 {
            return 0x5A827999
        } else if j < 48 {
            return 0x6ED9EBA1
        } else if j < 64 {
            return 0x8F1BBCDC
        } else {
            return 0xA953FD4E
        }
    }
    
    private static func KPrime(_ j: Int) -> UInt32 {
        if j < 16 {
            return 0x50A28BE6
        } else if j < 32 {
            return 0x5C4DD124
        } else if j < 48 {
            return 0x6D703EF3
        } else if j < 64 {
            return 0x7A6D76E9
        } else {
            return 0x00000000
        }
    }
    
    private static func rotateLeft(_ value: UInt32, _ count: Int) -> UInt32 {
        return (value << count) | (value >> (32 - count))
    }
    
    // Message schedule indices for left line
    private static let r: [Int] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        7, 4, 13, 1, 10, 6, 15, 3, 12, 0, 9, 5, 2, 14, 11, 8,
        3, 10, 14, 4, 9, 15, 8, 1, 2, 7, 0, 6, 13, 11, 5, 12,
        1, 9, 11, 10, 0, 8, 12, 4, 13, 3, 7, 15, 14, 5, 6, 2,
        4, 0, 5, 9, 7, 12, 2, 10, 14, 1, 3, 8, 11, 6, 15, 13
    ]
    
    // Message schedule indices for right line
    private static let rPrime: [Int] = [
        5, 14, 7, 0, 9, 2, 11, 4, 13, 6, 15, 8, 1, 10, 3, 12,
        6, 11, 3, 7, 0, 13, 5, 10, 14, 15, 8, 12, 4, 9, 1, 2,
        15, 5, 1, 3, 7, 14, 6, 9, 11, 8, 12, 2, 10, 0, 4, 13,
        8, 6, 4, 1, 3, 11, 15, 0, 5, 12, 2, 13, 9, 7, 10, 14,
        12, 15, 10, 4, 1, 5, 8, 7, 6, 2, 13, 14, 0, 3, 9, 11
    ]
    
    // Rotation amounts for left line
    private static let s: [Int] = [
        11, 14, 15, 12, 5, 8, 7, 9, 11, 13, 14, 15, 6, 7, 9, 8,
        7, 6, 8, 13, 11, 9, 7, 15, 7, 12, 15, 9, 11, 7, 13, 12,
        11, 13, 6, 7, 14, 9, 13, 15, 14, 8, 13, 6, 5, 12, 7, 5,
        11, 12, 14, 15, 14, 15, 9, 8, 9, 14, 5, 6, 8, 6, 5, 12,
        9, 15, 5, 11, 6, 8, 13, 12, 5, 12, 13, 14, 11, 8, 5, 6
    ]
    
    // Rotation amounts for right line
    private static let sPrime: [Int] = [
        8, 9, 9, 11, 13, 15, 15, 5, 7, 7, 8, 11, 14, 14, 12, 6,
        9, 13, 15, 7, 12, 8, 9, 11, 7, 7, 12, 7, 6, 15, 13, 11,
        9, 7, 15, 11, 8, 6, 6, 14, 12, 13, 5, 14, 13, 13, 7, 5,
        15, 5, 8, 11, 14, 14, 6, 14, 6, 9, 12, 9, 12, 5, 15, 8,
        8, 5, 12, 9, 12, 5, 14, 6, 8, 13, 6, 5, 15, 13, 11, 11
    ]
}
