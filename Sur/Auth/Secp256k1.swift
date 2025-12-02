//
//  Secp256k1.swift
//  Sur
//
//  secp256k1 elliptic curve wrapper using the 21-DOT-DEV/swift-secp256k1 library.
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
//  FIXED: Improved compressed public key handling, validation, and addModN operation
//

import Foundation
import P256K

/// secp256k1 elliptic curve wrapper for Ethereum compatibility
/// Uses the 21-DOT-DEV/swift-secp256k1 library (P256K module) for proper cryptographic operations
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
        guard privateKey.count == 32 else {
            #if DEBUG
            print("[Secp256k1] Invalid private key length: \(privateKey.count), expected 32")
            #endif
            return nil
        }

        // Quick validation before attempting to create key
        guard isValidPrivateKey(privateKey) else {
            #if DEBUG
            print("[Secp256k1] Private key validation failed")
            #endif
            return nil
        }

        do {
            // Create a secp256k1 private key from raw 32-byte data
            let privKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)

            // Get the uncompressed public key (65 bytes: 0x04 + X + Y)
            let uncompressedKey = privKey.publicKey.uncompressedRepresentation

            // Verify it's in the expected format
            guard uncompressedKey.count == 65, uncompressedKey[0] == 0x04 else {
                #if DEBUG
                print("[Secp256k1] Unexpected public key format: length=\(uncompressedKey.count), prefix=\(uncompressedKey.first ?? 0)")
                #endif
                return nil
            }

            return uncompressedKey
        } catch {
            #if DEBUG
            print("[Secp256k1] Failed to derive public key: \(error)")
            #endif
            return nil
        }
    }

    /// Derive compressed public key from private key using secp256k1 library
    /// - Parameter privateKey: 32-byte private key data
    /// - Returns: 33-byte compressed public key (0x02/0x03 + X) or nil if invalid
    static func deriveCompressedPublicKey(from privateKey: Data) -> Data? {
        guard privateKey.count == 32 else {
            #if DEBUG
            print("[Secp256k1] Invalid private key length: \(privateKey.count), expected 32")
            #endif
            return nil
        }

        // Quick validation before attempting to create key
        guard isValidPrivateKey(privateKey) else {
            #if DEBUG
            print("[Secp256k1] Private key validation failed for compressed key derivation")
            #endif
            return nil
        }

        do {
            // Create a secp256k1 private key from raw 32-byte data
            let privKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)

            // Get the public key representation
            let publicKeyBytes = privKey.publicKey.dataRepresentation

            // Handle different output formats from the library
            if publicKeyBytes.count == 33 {
                // Already compressed, verify format
                let prefix = publicKeyBytes[0]
                guard prefix == 0x02 || prefix == 0x03 else {
                    #if DEBUG
                    print("[Secp256k1] Invalid compressed public key prefix: 0x\(String(format: "%02x", prefix))")
                    #endif
                    return nil
                }
                return publicKeyBytes
            } else if publicKeyBytes.count == 65 {
                // Uncompressed format (0x04 + X + Y), need to compress
                guard publicKeyBytes[0] == 0x04 else {
                    #if DEBUG
                    print("[Secp256k1] Invalid uncompressed public key prefix: 0x\(String(format: "%02x", publicKeyBytes[0]))")
                    #endif
                    return nil
                }
                
                // Convert uncompressed to compressed
                // Compressed format: prefix (0x02 or 0x03) + X coordinate (32 bytes)
                // Prefix is 0x02 if Y is even, 0x03 if Y is odd
                let yLastByte = publicKeyBytes[64]  // Last byte of Y coordinate
                let prefix: UInt8 = (yLastByte & 1) == 0 ? 0x02 : 0x03
                
                var compressed = Data([prefix])
                compressed.append(publicKeyBytes[1..<33])  // Append X coordinate
                
                return compressed
            } else {
                #if DEBUG
                print("[Secp256k1] Unexpected public key length: \(publicKeyBytes.count)")
                #endif
                return nil
            }
        } catch {
            #if DEBUG
            print("[Secp256k1] Failed to derive compressed public key: \(error)")
            #endif
            return nil
        }
    }

    /// Validate private key is in valid range [1, n-1]
    ///
    /// Note: This validation checks the mathematical constraints for secp256k1:
    /// - Key must be 32 bytes
    /// - Key must not be zero
    /// - Key must be less than the curve order n
    ///
    /// The P256K library performs additional validation when the key is actually used
    /// for signing operations. We removed redundant P256K validation here because
    /// it was causing false rejections for mathematically valid keys.
    ///
    /// - Parameter privateKey: 32-byte private key data
    /// - Returns: true if valid
    static func isValidPrivateKey(_ privateKey: Data) -> Bool {
        guard privateKey.count == 32 else {
            #if DEBUG
            print("[Secp256k1] Invalid key length: \(privateKey.count)")
            #endif
            return false
        }

        let privateKeyBytes = [UInt8](privateKey)

        // Check it's not all zeros
        let isZero = privateKeyBytes.allSatisfy { $0 == 0 }
        if isZero {
            #if DEBUG
            print("[Secp256k1] Private key is zero")
            #endif
            return false
        }

        // Check it's less than the curve order
        // A valid secp256k1 private key must be in range [1, n-1]
        if !isLessThanCurveOrder(privateKeyBytes) {
            #if DEBUG
            print("[Secp256k1] Private key >= curve order")
            #endif
            return false
        }

        return true
    }

    /// Add two 32-byte values modulo the curve order n
    /// This is needed for BIP-32 key derivation: child = (parent + tweak) mod n
    ///
    /// CRITICAL: This function must return a valid private key in range [1, n-1]
    ///
    /// - Parameters:
    ///   - a: First 32-byte value
    ///   - b: Second 32-byte value
    /// - Returns: Sum modulo n as 32-byte Data, or nil if result would be invalid
    static func addModN(_ a: Data, _ b: Data) -> Data? {
        guard a.count == 32, b.count == 32 else {
            #if DEBUG
            print("[Secp256k1] Invalid input lengths for addModN: a=\(a.count), b=\(b.count)")
            #endif
            return nil
        }

        // Convert to byte arrays for arithmetic
        let aBytes = [UInt8](a)
        let bBytes = [UInt8](b)
        
        // Validate inputs are less than curve order
        guard isLessThanCurveOrder(aBytes) && isLessThanCurveOrder(bBytes) else {
            #if DEBUG
            print("[Secp256k1] Input values must be less than curve order")
            #endif
            return nil
        }

        // Perform addition with 33 bytes to catch overflow
        var result = [UInt8](repeating: 0, count: 33)
        var carry: UInt16 = 0
        
        for i in (0..<32).reversed() {
            let sum = UInt16(aBytes[i]) + UInt16(bBytes[i]) + carry
            result[i + 1] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        result[0] = UInt8(carry)

        // Determine if we need to reduce modulo n
        var needsReduction = false
        if result[0] > 0 {
            // Overflow occurred, definitely need reduction
            needsReduction = true
        } else {
            // No overflow, but still might be >= n
            let resultPart = Array(result[1...])
            needsReduction = !isLessThanCurveOrder(resultPart)
        }

        // Get the 32-byte result
        var finalResult = Array(result[1...])

        if needsReduction {
            // Subtract curve order once
            var borrow: Int16 = 0
            for i in (0..<32).reversed() {
                let diff = Int16(finalResult[i]) - Int16(curveOrderBytes[i]) - borrow
                if diff < 0 {
                    finalResult[i] = UInt8((diff + 256) & 0xFF)
                    borrow = 1
                } else {
                    finalResult[i] = UInt8(diff & 0xFF)
                    borrow = 0
                }
            }
        }

        // CRITICAL CHECK: Result must not be zero
        // In BIP-32 derivation, if (parent + tweak) mod n == 0, the derivation fails
        let resultData = Data(finalResult)
        let isZero = finalResult.allSatisfy { $0 == 0 }
        if isZero {
            #if DEBUG
            print("[Secp256k1] addModN resulted in zero, derivation invalid")
            #endif
            return nil  // Return nil instead of modifying to 1
        }

        // Final validation
        guard isValidPrivateKey(resultData) else {
            #if DEBUG
            print("[Secp256k1] addModN result is not a valid private key")
            #endif
            return nil
        }

        return resultData
    }

    // MARK: - Private Helpers

    /// Check if a 32-byte value is less than the curve order
    /// Returns true if value < n, false if value >= n
    private static func isLessThanCurveOrder(_ value: [UInt8]) -> Bool {
        guard value.count == 32 else { return false }

        // Compare byte by byte from most significant to least significant
        for i in 0..<32 {
            if value[i] < curveOrderBytes[i] {
                return true  // Definitively less than
            }
            if value[i] > curveOrderBytes[i] {
                return false  // Definitively greater than
            }
            // If equal, continue to next byte
        }
        
        // All bytes are equal, so value == n
        return false
    }

    // MARK: - Utility Functions (for debugging)
    
    #if DEBUG
    /// Convert Data to hex string for debugging
    static func toHexString(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Print key information for debugging
    static func debugKey(_ privateKey: Data, label: String = "Key") {
        print("[\(label)] Hex: \(toHexString(privateKey))")
        print("[\(label)] Valid: \(isValidPrivateKey(privateKey))")
        print("[\(label)] < n: \(isLessThanCurveOrder([UInt8](privateKey)))")
    }
    #endif
}
