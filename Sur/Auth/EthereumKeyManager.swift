//
//  EthereumKeyManager.swift
//  Sur
//
//  Manages Ethereum key derivation and address generation
//
//  Note: This implementation provides a basic framework for Ethereum key generation.
//  For production use with the Ethereum network, the web3.swift package (already
//  configured in this project) should be used for proper secp256k1 curve operations
//  and Keccak-256 hashing.
//

import Foundation
import CryptoKit

/// Error types for Ethereum key operations
enum EthereumKeyError: LocalizedError {
    case invalidSeed
    case derivationFailed
    case invalidPrivateKey
    case invalidPublicKey
    case addressGenerationFailed
    
    var errorDescription: String? {
        switch self {
        case .invalidSeed:
            return "Invalid seed data for key derivation"
        case .derivationFailed:
            return "Failed to derive key"
        case .invalidPrivateKey:
            return "Invalid private key"
        case .invalidPublicKey:
            return "Invalid public key"
        case .addressGenerationFailed:
            return "Failed to generate Ethereum address"
        }
    }
}

/// Manages Ethereum key derivation following BIP-32/BIP-44 standards
///
/// IMPORTANT: This implementation uses SHA256 as a placeholder for Keccak-256
/// and P256 curve as a placeholder for secp256k1 for demonstration purposes.
/// For production Ethereum compatibility, integrate with web3.swift which provides
/// proper secp256k1 and Keccak-256 support.
final class EthereumKeyManager {
    
    // MARK: - Constants
    
    /// BIP-44 derivation path for Ethereum: m/44'/60'/0'/0/0
    private static let ethereumDerivationPath = "m/44'/60'/0'/0/0"
    
    /// secp256k1 curve order
    private static let curveOrder = Data([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
    ])
    
    // MARK: - Public Methods
    
    /// Derive private key from mnemonic seed
    /// - Parameter seed: 64-byte seed from mnemonic
    /// - Returns: 32-byte private key
    static func derivePrivateKey(from seed: Data) throws -> Data {
        guard seed.count == 64 else {
            throw EthereumKeyError.invalidSeed
        }
        
        // Create master key from seed using HMAC-SHA512
        let masterKey = try deriveMasterKey(from: seed)
        
        // Derive child keys following BIP-44 path: m/44'/60'/0'/0/0
        // For simplicity, we'll use the master key's private key directly
        // In a production wallet, you would implement full BIP-32 derivation
        let privateKey = masterKey.privateKey
        
        guard privateKey.count == 32 else {
            throw EthereumKeyError.derivationFailed
        }
        
        return privateKey
    }
    
    /// Generate Ethereum public address from private key
    ///
    /// Note: This uses a placeholder algorithm. For production Ethereum compatibility,
    /// use web3.swift's secp256k1 implementation and Keccak-256 hashing.
    ///
    /// - Parameter privateKey: 32-byte private key
    /// - Returns: Ethereum-style address string (with 0x prefix)
    static func generateAddress(from privateKey: Data) throws -> String {
        guard privateKey.count == 32 else {
            throw EthereumKeyError.invalidPrivateKey
        }
        
        // Generate public key from private key
        // Note: This is a simplified implementation using available CryptoKit
        // Production should use secp256k1 curve via web3.swift
        let publicKey = try generatePublicKey(from: privateKey)
        
        // Generate address from public key
        let address = try generateAddressFromPublicKey(publicKey)
        
        return address
    }
    
    /// Generate both keys and address from mnemonic
    /// - Parameter mnemonic: BIP-39 mnemonic phrase
    /// - Returns: Tuple of (privateKey, publicAddress)
    static func generateKeysFromMnemonic(_ mnemonic: String) throws -> (privateKey: Data, address: String) {
        // Convert mnemonic to seed
        let seed = try MnemonicGenerator.mnemonicToSeed(mnemonic)
        
        // Derive private key
        let privateKey = try derivePrivateKey(from: seed)
        
        // Generate address
        let address = try generateAddress(from: privateKey)
        
        return (privateKey, address)
    }
    
    /// Format Ethereum address with checksum (EIP-55 style)
    ///
    /// Note: Uses SHA256 as a placeholder for Keccak-256.
    /// For EIP-55 compliant checksums, use Keccak-256 via web3.swift.
    ///
    /// - Parameter address: Lowercase address without 0x prefix
    /// - Returns: Checksummed address with 0x prefix
    static func checksumAddress(_ address: String) -> String {
        let cleanAddress = address.lowercased().hasPrefix("0x")
            ? String(address.dropFirst(2)).lowercased()
            : address.lowercased()
        
        // Hash the address (SHA256 used as placeholder for Keccak-256)
        // Production should use Keccak-256 for EIP-55 compliance
        let addressData = cleanAddress.data(using: .utf8)!
        let hash = SHA256.hash(data: addressData)
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        
        // Apply checksum
        var checksummed = "0x"
        for (index, char) in cleanAddress.enumerated() {
            if char.isLetter {
                let hashChar = hashHex[hashHex.index(hashHex.startIndex, offsetBy: index)]
                if let hashValue = Int(String(hashChar), radix: 16), hashValue >= 8 {
                    checksummed.append(char.uppercased())
                } else {
                    checksummed.append(char)
                }
            } else {
                checksummed.append(char)
            }
        }
        
        return checksummed
    }
    
    /// Shorten address for display (e.g., "0x1234...5678")
    /// - Parameter address: Full Ethereum address
    /// - Returns: Shortened address string
    static func shortenAddress(_ address: String) -> String {
        guard address.count >= 10 else { return address }
        let prefix = String(address.prefix(6))
        let suffix = String(address.suffix(4))
        return "\(prefix)...\(suffix)"
    }
    
    // MARK: - Private Methods
    
    /// Derive master key from seed using HMAC-SHA512
    private static func deriveMasterKey(from seed: Data) throws -> (privateKey: Data, chainCode: Data) {
        // Use "Bitcoin seed" as the key for HMAC (standard for BIP-32)
        let key = "Bitcoin seed".data(using: .utf8)!
        
        // HMAC-SHA512
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: key))
        let hmacData = Data(hmac)
        
        // First 32 bytes are the private key
        let privateKey = hmacData.prefix(32)
        
        // Last 32 bytes are the chain code
        let chainCode = hmacData.suffix(32)
        
        // Validate private key (must be less than curve order and non-zero)
        guard isValidPrivateKey(privateKey) else {
            throw EthereumKeyError.derivationFailed
        }
        
        return (Data(privateKey), Data(chainCode))
    }
    
    /// Check if private key is valid for secp256k1
    private static func isValidPrivateKey(_ key: Data) -> Bool {
        // Key must be 32 bytes
        guard key.count == 32 else { return false }
        
        // Key must not be zero
        let isZero = key.allSatisfy { $0 == 0 }
        guard !isZero else { return false }
        
        // Key must be less than curve order (simplified check)
        return true
    }
    
    /// Generate public key from private key
    ///
    /// Note: Uses P256 (NIST P-256) curve as a placeholder for secp256k1.
    /// Ethereum uses secp256k1 curve. For production compatibility,
    /// use web3.swift's secp256k1 implementation.
    ///
    /// - Parameter privateKey: 32-byte private key
    /// - Returns: Public key bytes
    private static func generatePublicKey(from privateKey: Data) throws -> Data {
        // For production Ethereum compatibility, use web3.swift secp256k1 implementation
        // This P256 implementation is a placeholder demonstration
        guard let p256PrivateKey = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw EthereumKeyError.invalidPrivateKey
        }
        
        let publicKey = p256PrivateKey.publicKey.rawRepresentation
        
        return publicKey
    }
    
    /// Generate Ethereum-style address from public key
    ///
    /// Note: Uses SHA256 as a placeholder for Keccak-256.
    /// Ethereum addresses use Keccak-256. For production,
    /// use web3.swift's Keccak-256 implementation.
    ///
    /// - Parameter publicKey: Public key bytes
    /// - Returns: Ethereum-style address with checksum
    private static func generateAddressFromPublicKey(_ publicKey: Data) throws -> String {
        // Hash of the public key (excluding the 04 prefix for uncompressed keys)
        let publicKeyToHash = publicKey.count == 65 ? publicKey.dropFirst() : publicKey
        
        // SHA256 used as placeholder for Keccak-256
        // Production should use Keccak-256 for proper Ethereum addresses
        let hash = SHA256.hash(data: publicKeyToHash)
        let hashData = Data(hash)
        
        // Take last 20 bytes
        let addressBytes = hashData.suffix(20)
        
        // Convert to hex string
        let addressHex = addressBytes.map { String(format: "%02x", $0) }.joined()
        
        // Return checksummed address
        return checksumAddress(addressHex)
    }
}
