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

        do {
            // Create a secp256k1 private key from raw 32-byte data
            let privKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)

            // Get the uncompressed public key (65 bytes: 0x04 + X + Y)
            // The P256K library provides uncompressedRepresentation property
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
        guard privateKey.count == 32 else { return nil }

        do {
            // Create a secp256k1 private key from raw 32-byte data
            let privKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)

            // Get the public key in compressed format (33 bytes: 0x02/0x03 + X)
            let publicKeyBytes = privKey.publicKey.dataRepresentation

            // Handle different output formats
            if publicKeyBytes.count == 33 {
                return publicKeyBytes
            } else if publicKeyBytes.count == 65 {
                // Convert uncompressed to compressed
                // First byte of uncompressed is 0x04
                // Compressed prefix is 0x02 if Y is even, 0x03 if Y is odd
                let yLastByte = publicKeyBytes[64]
                let prefix: UInt8 = (yLastByte & 1) == 0 ? 0x02 : 0x03
                var compressed = Data([prefix])
                compressed.append(publicKeyBytes[1..<33])
                return compressed
            }

            return publicKeyBytes
        } catch {
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
        guard privateKey.count == 32 else { return false }

        // Check it's not all zeros
        let isZero = privateKey.allSatisfy { $0 == 0 }
        if isZero { return false }

        // Check it's less than the curve order
        // A valid secp256k1 private key must be in range [1, n-1]
        let privateKeyBytes = [UInt8](privateKey)
        if !isLessThanCurveOrder(privateKeyBytes) {
            return false
        }

        return true
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

        var result = [UInt8](repeating: 0, count: 33)  // Extra byte for overflow
        let aBytes = [UInt8](a)
        let bBytes = [UInt8](b)

        // Add with carry, starting from least significant byte
        var carry: UInt16 = 0
        for i in (0..<32).reversed() {
            let sum = UInt16(aBytes[i]) + UInt16(bBytes[i]) + carry
            result[i + 1] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        result[0] = UInt8(carry)

        // If result >= n, subtract n once (at most once since a,b < n implies a+b < 2n)
        // Check if we need to reduce by comparing with n (preceded by 0x00)
        var needsReduction = false
        if result[0] > 0 {
            needsReduction = true
        } else {
            // Compare the 32-byte portion with curve order
            let resultPart = Array(result[1...])
            needsReduction = !isLessThanCurveOrder(resultPart)
        }

        var finalResult = Array(result[1...])  // Get the 32-byte portion

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

        // Handle zero case (extremely unlikely but possible)
        let isZero = finalResult.allSatisfy { $0 == 0 }
        if isZero {
            finalResult[31] = 1  // Return 1 instead of 0
        }

        return Data(finalResult)
    }

    /// Sign a message hash using secp256k1 ECDSA
    /// 
    /// This produces an ECDSA signature in compact format (64 bytes: R + S).
    /// The signature can be verified using the corresponding public key.
    /// Compatible with Ethereum and Bitcoin ECDSA signing.
    ///
    /// - Parameters:
    ///   - messageHash: 32-byte hash of the message to sign (e.g., SHA-256 or Keccak-256 of message)
    ///   - privateKey: 32-byte private key data
    /// - Returns: Signature data (64 bytes: R + S in compact format) or nil if signing fails
    static func sign(messageHash: Data, with privateKey: Data) -> Data? {
        guard messageHash.count == 32 else {
            #if DEBUG
            print("[Secp256k1] Invalid message hash length: \(messageHash.count), expected 32")
            #endif
            return nil
        }
        
        guard privateKey.count == 32 else {
            #if DEBUG
            print("[Secp256k1] Invalid private key length: \(privateKey.count), expected 32")
            #endif
            return nil
        }
        
        do {
            // Create a secp256k1 private key from raw 32-byte data
            let privKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)
            
            // Sign the message hash
            let signature = try privKey.signature(for: messageHash)
            
            // P256K returns DER-encoded signature via dataRepresentation
            // We need to convert it to raw R,S format (64 bytes: 32R + 32S)
            let derSig = signature.dataRepresentation
            
            #if DEBUG
            print("[Secp256k1] DER signature length: \(derSig.count)")
            print("[Secp256k1] DER signature: \(derSig.map { String(format: "%02x", $0) }.joined())")
            #endif
            
            // Extract R and S from DER encoding
            guard let rawSig = extractRSFromDERToRaw(derSig) else {
                #if DEBUG
                print("[Secp256k1] Failed to extract R,S from DER signature")
                #endif
                return nil
            }
            
            #if DEBUG
            print("[Secp256k1] Raw R,S signature length: \(rawSig.count)")
            print("[Secp256k1] Raw R,S signature: \(rawSig.map { String(format: "%02x", $0) }.joined())")
            #endif
            
            return rawSig
        } catch {
            #if DEBUG
            print("[Secp256k1] Failed to sign message: \(error)")
            #endif
            return nil
        }
    }
    
    /// Verify an ECDSA signature for a message hash
    ///
    /// - Parameters:
    ///   - signature: Signature data (64 bytes in compact format: R + S)
    ///   - messageHash: 32-byte hash of the message
    ///   - publicKey: 65-byte uncompressed public key (0x04 + X + Y)
    /// - Returns: true if signature is valid, false otherwise
    static func verify(signature: Data, for messageHash: Data, publicKey: Data) -> Bool {
        guard messageHash.count == 32 else {
            #if DEBUG
            print("[Secp256k1] Invalid message hash length: \(messageHash.count), expected 32")
            #endif
            return false
        }
        
        guard publicKey.count == 65, publicKey[0] == 0x04 else {
            #if DEBUG
            print("[Secp256k1] Invalid public key format")
            #endif
            return false
        }
        
        // Signature should be 64 bytes in compact format (R + S)
        guard signature.count == 64 else {
            #if DEBUG
            print("[Secp256k1] Invalid signature length: \(signature.count), expected 64")
            #endif
            return false
        }
        
        do {
            // Create P256K public key from uncompressed representation
            let pubKey = try P256K.Signing.PublicKey(x963Representation: publicKey)
            
            // Convert raw R,S signature (64 bytes) to DER format for P256K
            guard let derSig = createDERSignature(from: signature) else {
                #if DEBUG
                print("[Secp256k1] Failed to convert raw R,S to DER format")
                #endif
                return false
            }
            
            // Create P256K signature from DER representation
            let sig = try P256K.Signing.ECDSASignature(dataRepresentation: derSig)
            
            // Verify the signature
            return pubKey.isValidSignature(sig, for: messageHash)
        } catch {
            #if DEBUG
            print("[Secp256k1] Failed to verify signature: \(error)")
            #endif
            return false
        }
    }

    // MARK: - Private Helpers
    
    /// Extract R and S values from DER-encoded signature (returns as tuple)
    /// - Parameter der: DER-encoded signature
    /// - Returns: Tuple of (R, S) as 32-byte Data each, or nil if parsing fails
    private static func extractRSFromDERTuple(_ der: Data) -> (Data, Data)? {
        guard der.count >= 8 else { return nil }
        guard der[0] == 0x30 else { return nil } // DER sequence tag
        
        var index = 2 // Skip sequence tag and length
        
        // Extract R
        guard index < der.count, der[index] == 0x02 else { return nil } // Integer tag
        index += 1
        
        guard index < der.count else { return nil }
        var rLength = Int(der[index])
        index += 1
        
        // Handle leading zero byte for positive integers
        if rLength > 32 {
            guard index < der.count, der[index] == 0x00 else { return nil }
            index += 1
            rLength -= 1
        }
        
        guard index + rLength <= der.count else { return nil }
        var rData = Data(der[index..<(index + rLength)])
        index += rLength
        
        // Pad R to 32 bytes if needed
        while rData.count < 32 {
            rData.insert(0x00, at: 0)
        }
        
        // Extract S
        guard index < der.count, der[index] == 0x02 else { return nil } // Integer tag
        index += 1
        
        guard index < der.count else { return nil }
        var sLength = Int(der[index])
        index += 1
        
        // Handle leading zero byte for positive integers
        if sLength > 32 {
            guard index < der.count, der[index] == 0x00 else { return nil }
            index += 1
            sLength -= 1
        }
        
        guard index + sLength <= der.count else { return nil }
        var sData = Data(der[index..<(index + sLength)])
        
        // Pad S to 32 bytes if needed
        while sData.count < 32 {
            sData.insert(0x00, at: 0)
        }
        
        return (rData, sData)
    }
    
    /// Create DER-encoded signature from R and S values
    /// - Parameters:
    ///   - r: R value (32 bytes)
    ///   - s: S value (32 bytes)
    /// - Returns: DER-encoded signature or nil if creation fails
    private static func createDERSignatureFromRS(r: Data, s: Data) -> Data? {
        guard r.count == 32, s.count == 32 else { return nil }
        
        // Remove leading zeros from R and S, but keep at least one byte
        var rTrimmed = r
        while rTrimmed.count > 1 && rTrimmed[0] == 0x00 {
            rTrimmed = rTrimmed.dropFirst()
        }
        
        var sTrimmed = s
        while sTrimmed.count > 1 && sTrimmed[0] == 0x00 {
            sTrimmed = sTrimmed.dropFirst()
        }
        
        // Add leading zero if high bit is set (to keep it positive)
        if rTrimmed[0] & 0x80 != 0 {
            rTrimmed.insert(0x00, at: 0)
        }
        if sTrimmed[0] & 0x80 != 0 {
            sTrimmed.insert(0x00, at: 0)
        }
        
        // Build DER structure
        var der = Data()
        
        // R integer
        der.append(0x02) // Integer tag
        der.append(UInt8(rTrimmed.count))
        der.append(rTrimmed)
        
        // S integer
        der.append(0x02) // Integer tag
        der.append(UInt8(sTrimmed.count))
        der.append(sTrimmed)
        
        // Sequence wrapper
        var result = Data()
        result.append(0x30) // Sequence tag
        result.append(UInt8(der.count))
        result.append(der)
        
        return result
    }

    /// Extract R and S from DER-encoded signature and return as concatenated 64-byte Data
    /// - Parameter der: DER-encoded signature
    /// - Returns: 64-byte Data (32-byte R + 32-byte S) or nil if parsing fails
    private static func extractRSFromDERToRaw(_ der: Data) -> Data? {
        guard let (r, s) = extractRSFromDERTuple(der) else { return nil }
        var result = Data()
        result.append(r)
        result.append(s)
        return result
    }
    
    /// Create DER-encoded signature from 64-byte raw R,S format
    /// - Parameter rawSignature: 64-byte Data (32-byte R + 32-byte S)
    /// - Returns: DER-encoded signature or nil if creation fails
    private static func createDERSignature(from rawSignature: Data) -> Data? {
        guard rawSignature.count == 64 else { return nil }
        let r = rawSignature.prefix(32)
        let s = rawSignature.suffix(32)
        return createDERSignatureFromRS(r: r, s: s)
    }
    
    /// Extract R and S values from DER-encoded signature (returns as tuple)
    /// - Parameter der: DER-encoded signature
    /// - Returns: Tuple of (R, S) as 32-byte Data each, or nil if parsing fails
    private static func extractRSFromDERTuple(_ der: Data) -> (Data, Data)? {

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
