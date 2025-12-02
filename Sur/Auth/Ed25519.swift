//
//  Ed25519.swift
//  Sur
//
//  Ed25519 curve implementation for Solana key derivation
//  Uses CryptoKit's Curve25519 for signing operations
//

import Foundation
import CryptoKit

/// Ed25519 key operations for Solana
struct Ed25519 {
    
    /// Derive Ed25519 public key from seed (32 bytes)
    /// For Solana, the seed comes from BIP-32 derivation
    /// - Parameter seed: 32-byte seed from BIP-32 derivation
    /// - Returns: 32-byte Ed25519 public key or nil if invalid
    static func derivePublicKey(from seed: Data) -> Data? {
        guard seed.count == 32 else {
            return nil
        }
        
        do {
            // Create Ed25519 signing key from seed
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            
            // Get the public key (32 bytes)
            let publicKey = signingKey.publicKey.rawRepresentation
            
            return publicKey
        } catch {
            return nil
        }
    }
    
    /// Derive Ed25519 keypair from a 32-byte seed
    /// - Parameter seed: 32-byte seed from BIP-32 derivation
    /// - Returns: Tuple of (privateKey, publicKey) or nil if invalid
    static func deriveKeypair(from seed: Data) -> (privateKey: Data, publicKey: Data)? {
        guard seed.count == 32 else {
            return nil
        }
        
        do {
            // Create Ed25519 signing key from seed
            let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            
            // Get both keys
            let privateKey = signingKey.rawRepresentation
            let publicKey = signingKey.publicKey.rawRepresentation
            
            return (privateKey, publicKey)
        } catch {
            return nil
        }
    }
    
    /// Check if a seed is valid for Ed25519 key generation
    /// - Parameter seed: Seed data to validate
    /// - Returns: true if valid
    static func isValidSeed(_ seed: Data) -> Bool {
        guard seed.count == 32 else {
            return false
        }
        
        // Try to create a key from it
        do {
            _ = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return true
        } catch {
            return false
        }
    }
}
