//
//  Secp256k1.swift
//  Sur
//
//  secp256k1 elliptic curve wrapper using the GigaBitcoin/secp256k1.swift library.
//  This provides proper, battle-tested cryptographic operations for Ethereum compatibility.
//
//  The secp256k1 curve is used by Ethereum, Bitcoin, and other cryptocurrencies.
//  This wrapper uses libsecp256k1 under the hood for correct and efficient operations.
//
//  Key formats:
//  - Private key: 32 bytes
//  - Uncompressed public key: 65 bytes (0x04 + X + Y)
//  - Compressed public key: 33 bytes (0x02 or 0x03 + X)
//

import Foundation
import secp256k1

/// secp256k1 elliptic curve wrapper for Ethereum compatibility
/// Uses the GigaBitcoin/secp256k1.swift library for proper cryptographic operations
final class Secp256k1 {
    
    // MARK: - Curve Parameters (for reference)
    
    /// Curve order n (order of the generator point G)
    /// This is needed for modular arithmetic in BIP-32 key derivation
    static let curveOrderBytes: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
    ]
    
    // MARK: - Public Interface
    
    /// Derive public key from private key using secp256k1 library
    /// - Parameter privateKey: 32-byte private key data
    /// - Returns: 65-byte uncompressed public key (0x04 + X + Y) or nil if invalid
    static func derivePublicKey(from privateKey: Data) -> Data? {
        guard privateKey.count == 32 else { return nil }
        
        do {
            // Create a secp256k1 private key from raw bytes
            let privKey = try secp256k1.Signing.PrivateKey(
                dataRepresentation: privateKey,
                format: .uncompressed
            )
            
            // Get the public key in uncompressed format
            let publicKeyData = privKey.publicKey.dataRepresentation
            
            // Ensure we have the correct format (65 bytes with 0x04 prefix)
            if publicKeyData.count == 65 && publicKeyData[0] == 0x04 {
                return publicKeyData
            } else if publicKeyData.count == 64 {
                // Add the 0x04 prefix for uncompressed format
                var result = Data([0x04])
                result.append(publicKeyData)
                return result
            }
            
            return publicKeyData
        } catch {
            return nil
        }
    }
    
    /// Derive compressed public key from private key using secp256k1 library
    /// - Parameter privateKey: 32-byte private key data
    /// - Returns: 33-byte compressed public key (0x02/0x03 + X) or nil if invalid
    static func deriveCompressedPublicKey(from privateKey: Data) -> Data? {
        guard privateKey.count == 32 else { return nil }
        
        do {
            // Create a secp256k1 private key
            let privKey = try secp256k1.Signing.PrivateKey(
                dataRepresentation: privateKey,
                format: .compressed
            )
            
            // Get the public key in compressed format (33 bytes)
            return privKey.publicKey.dataRepresentation
        } catch {
            return nil
        }
    }
    
    /// Validate private key is in valid range [1, n-1]
    /// - Parameter privateKey: 32-byte private key data
    /// - Returns: true if valid
    static func isValidPrivateKey(_ privateKey: Data) -> Bool {
        guard privateKey.count == 32 else { return false }
        
        // Check it's not all zeros
        let isZero = privateKey.allSatisfy { $0 == 0 }
        if isZero { return false }
        
        // Check it's less than the curve order
        let privateKeyBytes = [UInt8](privateKey)
        if !isLessThanCurveOrder(privateKeyBytes) {
            return false
        }
        
        // Try to create a private key - the library will validate it
        do {
            _ = try secp256k1.Signing.PrivateKey(dataRepresentation: privateKey)
            return true
        } catch {
            return false
        }
    }
    
    /// Add two 32-byte values modulo the curve order n
    /// This is needed for BIP-32 key derivation: child = (parent + tweak) mod n
    /// - Parameters:
    ///   - a: First 32-byte value
    ///   - b: Second 32-byte value
    /// - Returns: Sum modulo n as 32-byte Data
    static func addModN(_ a: Data, _ b: Data) -> Data {
        guard a.count == 32, b.count == 32 else {
            return Data(repeating: 0, count: 32)
        }
        
        var result = [UInt8](repeating: 0, count: 32)
        let aBytes = [UInt8](a)
        let bBytes = [UInt8](b)
        
        // Add with carry, starting from least significant byte
        var carry: UInt16 = 0
        for i in (0..<32).reversed() {
            let sum = UInt16(aBytes[i]) + UInt16(bBytes[i]) + carry
            result[i] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        
        // Reduce modulo n if result >= n
        while !isLessThanCurveOrder(result) {
            // Subtract curve order
            var borrow: Int16 = 0
            for i in (0..<32).reversed() {
                let diff = Int16(result[i]) - Int16(curveOrderBytes[i]) - borrow
                if diff < 0 {
                    result[i] = UInt8((diff + 256) & 0xFF)
                    borrow = 1
                } else {
                    result[i] = UInt8(diff & 0xFF)
                    borrow = 0
                }
            }
        }
        
        // Handle zero case (unlikely but possible)
        let isZero = result.allSatisfy { $0 == 0 }
        if isZero {
            result[31] = 1  // Return 1 instead of 0
        }
        
        return Data(result)
    }
    
    // MARK: - Private Helpers
    
    /// Check if a 32-byte value is less than the curve order
    private static func isLessThanCurveOrder(_ value: [UInt8]) -> Bool {
        guard value.count == 32 else { return false }
        
        for i in 0..<32 {
            if value[i] < curveOrderBytes[i] { return true }
            if value[i] > curveOrderBytes[i] { return false }
        }
        return false  // Equal to curve order
    }
}
