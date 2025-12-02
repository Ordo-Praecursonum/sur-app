//
//  Keccak256.swift
//  Sur
//
//  Keccak-256 hash function wrapper using CryptoSwift library.
//  This is the hash function used by Ethereum for address generation.
//
//  IMPORTANT: Ethereum uses Keccak-256, NOT SHA3-256. While both are based on the
//  Keccak sponge construction, they use different padding:
//  - Keccak-256 uses 0x01 padding
//  - SHA3-256 uses 0x06 padding (FIPS 202)
//
//  MetaMask and all Ethereum wallets use Keccak-256 for address derivation.
//  This implementation uses the well-tested CryptoSwift library.
//

import Foundation
import CryptoSwift

/// Keccak-256 hash wrapper using CryptoSwift for Ethereum compatibility
/// This produces the same output as MetaMask's Keccak-256 implementation
final class Keccak256 {
    
    // MARK: - Public Interface
    
    /// Compute Keccak-256 hash of data
    /// - Parameter data: Input data to hash
    /// - Returns: 32-byte Keccak-256 hash
    static func hash(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let digest = bytes.sha3(.keccak256)
        return Data(digest)
    }
    
    /// Compute Keccak-256 hash and return as hex string
    /// - Parameter data: Input data to hash
    /// - Returns: Hex-encoded hash string
    static func hashToHex(_ data: Data) -> String {
        let hashData = hash(data)
        return hashData.map { String(format: "%02x", $0) }.joined()
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
