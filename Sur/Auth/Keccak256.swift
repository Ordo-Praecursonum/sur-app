//
//  Keccak256.swift
//  Sur
//
//  Pure Swift implementation of Keccak-256 hash function.
//  This is the hash function used by Ethereum for address generation.
//
//  IMPORTANT: Ethereum uses Keccak-256, NOT SHA3-256. While both are based on the
//  Keccak sponge construction, they use different padding:
//  - Keccak-256 uses 0x01 padding
//  - SHA3-256 uses 0x06 padding (FIPS 202)
//
//  MetaMask and all Ethereum wallets use Keccak-256 for address derivation.
//

import Foundation

/// Keccak-256 hash implementation for Ethereum compatibility
/// This produces the same output as MetaMask's Keccak-256 implementation
final class Keccak256 {
    
    // MARK: - Constants
    
    /// State size in 64-bit words (5x5 = 25)
    private static let stateSize = 25
    
    /// Rate in bytes for Keccak-256 (1600 - 512 = 1088 bits = 136 bytes)
    private static let rate = 136
    
    /// Output length in bytes for Keccak-256 (256 bits = 32 bytes)
    private static let outputLength = 32
    
    /// Round constants for Keccak-f[1600]
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
        0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
        0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
    ]
    
    /// Rotation offsets for rho step (linearized 5x5 array)
    private static let rotationOffsets: [Int] = [
        0,  1, 62, 28, 27,
        36, 44,  6, 55, 20,
        3, 10, 43, 25, 39,
        41, 45, 15, 21,  8,
        18,  2, 61, 56, 14
    ]
    
    // MARK: - Public Interface
    
    /// Compute Keccak-256 hash of data
    /// - Parameter data: Input data to hash
    /// - Returns: 32-byte Keccak-256 hash
    static func hash(_ data: Data) -> Data {
        var state = [UInt64](repeating: 0, count: stateSize)
        var input = [UInt8](data)
        
        // Keccak padding: append domain separator 0x01, then pad with zeros, XOR 0x80 at end
        // Note: Keccak uses 0x01, SHA3 uses 0x06
        input.append(0x01)
        while (input.count % rate) != 0 {
            input.append(0x00)
        }
        // XOR 0x80 into the last byte to complete padding
        if input.count > 0 {
            input[input.count - 1] ^= 0x80
        }
        
        // Absorb phase - process each block
        for blockStart in stride(from: 0, to: input.count, by: rate) {
            // XOR block into state (little-endian conversion)
            for i in 0..<(rate / 8) {
                let offset = blockStart + i * 8
                if offset + 8 <= input.count {
                    var word: UInt64 = 0
                    for j in 0..<8 {
                        word |= UInt64(input[offset + j]) << (j * 8)
                    }
                    state[i] ^= word
                }
            }
            
            // Apply Keccak-f[1600] permutation
            keccakF1600(&state)
        }
        
        // Squeeze phase - extract output (little-endian conversion)
        var output = Data()
        for i in 0..<(outputLength / 8) {
            var word = state[i]
            for _ in 0..<8 {
                output.append(UInt8(word & 0xFF))
                word >>= 8
            }
        }
        
        return output
    }
    
    /// Compute Keccak-256 hash and return as hex string
    /// - Parameter data: Input data to hash
    /// - Returns: Hex-encoded hash string
    static func hashToHex(_ data: Data) -> String {
        let hashData = hash(data)
        return hashData.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Private Methods
    
    /// Apply Keccak-f[1600] permutation (24 rounds)
    private static func keccakF1600(_ state: inout [UInt64]) {
        for round in 0..<24 {
            // θ (theta) step
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ rotateLeft(c[(x + 1) % 5], by: 1)
            }
            
            for i in 0..<25 {
                state[i] ^= d[i % 5]
            }
            
            // ρ (rho) and π (pi) steps combined
            var b = [UInt64](repeating: 0, count: 25)
            for x in 0..<5 {
                for y in 0..<5 {
                    let index = x + 5 * y
                    let newIndex = y + 5 * ((2 * x + 3 * y) % 5)
                    b[newIndex] = rotateLeft(state[index], by: rotationOffsets[index])
                }
            }
            
            // χ (chi) step
            for x in 0..<5 {
                for y in 0..<5 {
                    let index = x + 5 * y
                    state[index] = b[index] ^ ((~b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y])
                }
            }
            
            // ι (iota) step
            state[0] ^= roundConstants[round]
        }
    }
    
    /// Rotate a 64-bit value left by the specified number of bits
    private static func rotateLeft(_ value: UInt64, by bits: Int) -> UInt64 {
        return (value << bits) | (value >> (64 - bits))
    }
}

// MARK: - Data Extension for Keccak-256

extension Data {
    /// Compute Keccak-256 hash of this data
    /// - Returns: 32-byte Keccak-256 hash
    var keccak256: Data {
        return Keccak256.hash(self)
    }
    
    /// Compute Keccak-256 hash and return as hex string
    var keccak256Hex: String {
        return Keccak256.hashToHex(self)
    }
}
