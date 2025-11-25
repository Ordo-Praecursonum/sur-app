//
//  MultiChainKeyManager.swift
//  Sur
//
//  Manages key derivation for multiple blockchain networks using proper BIP-32/BIP-44 paths
//
//  IMPORTANT IMPLEMENTATION NOTES:
//  ================================
//  This implementation provides the correct BIP-44 derivation path structure for each
//  supported blockchain network. However, it uses placeholder cryptographic primitives
//  due to Swift/CryptoKit limitations:
//
//  1. CURVE: Uses P256 (NIST P-256) as a placeholder for secp256k1
//     - Bitcoin, Ethereum, Cosmos all require secp256k1
//     - Solana requires Ed25519
//     - For production: Use web3.swift (secp256k1) or TweetNaCl (Ed25519)
//
//  2. HASHING: Uses SHA256 as a placeholder for Keccak-256
//     - Ethereum addresses require Keccak-256 (not SHA3-256)
//     - For production: Use web3.swift's Keccak256 implementation
//
//  3. ADDRESS ENCODING: Uses simplified encoding for demonstration
//     - Bitcoin: Requires proper RIPEMD-160 (uses SHA256 twice as placeholder)
//     - Cosmos: Requires proper Bech32 with CRC checksum (simplified here)
//     - For production: Use dedicated encoding libraries
//
//  The BIP-44 DERIVATION PATHS are correct and match industry standards:
//  - Ethereum: m/44'/60'/0'/0/0  (matches MetaMask, Ledger, etc.)
//  - Bitcoin:  m/44'/0'/0'/0/0   (BIP-44 standard)
//  - Cosmos:   m/44'/118'/0'/0/0 (Cosmos SDK standard)
//  - Solana:   m/44'/501'/0'/0'  (Phantom, Solflare standard)
//  - OriginTrail: m/44'/60'/0'/0/0 (ERC-20 token on Ethereum)
//

import Foundation
import CryptoKit

/// Error types for multi-chain key operations
enum MultiChainKeyError: LocalizedError {
    case invalidSeed
    case derivationFailed
    case invalidPrivateKey
    case invalidPublicKey
    case addressGenerationFailed
    case unsupportedNetwork
    case invalidDerivationPath
    
    var errorDescription: String? {
        switch self {
        case .invalidSeed:
            return "Invalid seed data for key derivation"
        case .derivationFailed:
            return "Failed to derive key at path"
        case .invalidPrivateKey:
            return "Invalid private key"
        case .invalidPublicKey:
            return "Invalid public key"
        case .addressGenerationFailed:
            return "Failed to generate address"
        case .unsupportedNetwork:
            return "Unsupported blockchain network"
        case .invalidDerivationPath:
            return "Invalid derivation path"
        }
    }
}

/// Manages key derivation for multiple blockchain networks
/// Implements BIP-32 (HD Wallets) and BIP-44 (Multi-Account Hierarchy)
final class MultiChainKeyManager {
    
    // MARK: - Constants
    
    /// Hardened key offset (2^31)
    private static let hardenedOffset: UInt32 = 0x80000000
    
    // MARK: - Public Methods
    
    /// Generate keys and address for a specific blockchain network from mnemonic
    /// - Parameters:
    ///   - mnemonic: BIP-39 mnemonic phrase
    ///   - network: Target blockchain network
    /// - Returns: Tuple of (privateKey, publicAddress)
    static func generateKeysForNetwork(_ mnemonic: String, network: BlockchainNetwork) throws -> (privateKey: Data, address: String) {
        // Convert mnemonic to seed
        let seed = try MnemonicGenerator.mnemonicToSeed(mnemonic)
        
        // Derive the master key
        let masterKey = try deriveMasterKey(from: seed)
        
        // Derive child key using BIP-44 path for the network
        let derivedKey = try deriveKeyAtPath(
            masterPrivateKey: masterKey.privateKey,
            masterChainCode: masterKey.chainCode,
            path: network.pathComponents
        )
        
        // Generate address based on the network type
        let address = try generateAddress(from: derivedKey.privateKey, network: network)
        
        return (derivedKey.privateKey, address)
    }
    
    /// Generate addresses for all supported networks from a single mnemonic
    /// - Parameter mnemonic: BIP-39 mnemonic phrase
    /// - Returns: Dictionary mapping network to address
    static func generateAllAddresses(from mnemonic: String) throws -> [BlockchainNetwork: String] {
        var addresses: [BlockchainNetwork: String] = [:]
        
        for network in BlockchainNetwork.allCases {
            let (_, address) = try generateKeysForNetwork(mnemonic, network: network)
            addresses[network] = address
        }
        
        return addresses
    }
    
    /// Shorten address for display (e.g., "0x1234...5678")
    /// - Parameters:
    ///   - address: Full address
    ///   - network: Blockchain network (affects prefix handling)
    /// - Returns: Shortened address string
    static func shortenAddress(_ address: String, for network: BlockchainNetwork) -> String {
        guard address.count >= 10 else { return address }
        
        switch network {
        case .cosmos:
            // Cosmos addresses: cosmos1abc...xyz
            let prefix = String(address.prefix(10))
            let suffix = String(address.suffix(4))
            return "\(prefix)...\(suffix)"
        default:
            let prefix = String(address.prefix(6))
            let suffix = String(address.suffix(4))
            return "\(prefix)...\(suffix)"
        }
    }
    
    // MARK: - Private Methods - BIP-32 Key Derivation
    
    /// Derive master key from seed using HMAC-SHA512 (BIP-32)
    private static func deriveMasterKey(from seed: Data) throws -> (privateKey: Data, chainCode: Data) {
        guard seed.count == 64 else {
            throw MultiChainKeyError.invalidSeed
        }
        
        // Use "Bitcoin seed" as the key for HMAC (BIP-32 standard)
        let key = "Bitcoin seed".data(using: .utf8)!
        
        // HMAC-SHA512
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: key))
        let hmacData = Data(hmac)
        
        // First 32 bytes are the private key
        let privateKey = Data(hmacData.prefix(32))
        
        // Last 32 bytes are the chain code
        let chainCode = Data(hmacData.suffix(32))
        
        // Validate private key
        guard isValidPrivateKey(privateKey) else {
            throw MultiChainKeyError.derivationFailed
        }
        
        return (privateKey, chainCode)
    }
    
    /// Derive child key at a given BIP-32/BIP-44 path
    /// - Parameters:
    ///   - masterPrivateKey: 32-byte master private key
    ///   - masterChainCode: 32-byte master chain code
    ///   - path: Array of path indices (hardened indices have 0x80000000 added)
    /// - Returns: Derived private key and chain code
    private static func deriveKeyAtPath(
        masterPrivateKey: Data,
        masterChainCode: Data,
        path: [UInt32]
    ) throws -> (privateKey: Data, chainCode: Data) {
        var currentKey = masterPrivateKey
        var currentChainCode = masterChainCode
        
        for index in path {
            let isHardened = index >= hardenedOffset
            
            // Derive child key
            let (childKey, childChainCode) = try deriveChildKey(
                parentPrivateKey: currentKey,
                parentChainCode: currentChainCode,
                index: index,
                hardened: isHardened
            )
            
            currentKey = childKey
            currentChainCode = childChainCode
        }
        
        return (currentKey, currentChainCode)
    }
    
    /// Derive a single child key (BIP-32)
    /// - Parameters:
    ///   - parentPrivateKey: Parent private key
    ///   - parentChainCode: Parent chain code
    ///   - index: Child index
    ///   - hardened: Whether this is a hardened derivation
    /// - Returns: Child private key and chain code
    private static func deriveChildKey(
        parentPrivateKey: Data,
        parentChainCode: Data,
        index: UInt32,
        hardened: Bool
    ) throws -> (privateKey: Data, chainCode: Data) {
        var data = Data()
        
        if hardened {
            // Hardened child: 0x00 || parent_private_key || index
            data.append(0x00)
            data.append(parentPrivateKey)
        } else {
            // Normal child: parent_public_key || index
            // For now, we'll use a simplified approach with the private key
            // In production, this should use the compressed public key
            let publicKey = try generatePublicKeyBytes(from: parentPrivateKey)
            data.append(publicKey)
        }
        
        // Append index as big-endian 4 bytes
        var indexBE = index.bigEndian
        data.append(Data(bytes: &indexBE, count: 4))
        
        // HMAC-SHA512
        let hmac = HMAC<SHA512>.authenticationCode(
            for: data,
            using: SymmetricKey(data: parentChainCode)
        )
        let hmacData = Data(hmac)
        
        // First 32 bytes for key derivation
        let keyData = Data(hmacData.prefix(32))
        
        // Last 32 bytes are the new chain code
        let childChainCode = Data(hmacData.suffix(32))
        
        // Add parent key to derived key (mod n for secp256k1)
        let childKey = try addPrivateKeys(parentPrivateKey, keyData)
        
        guard isValidPrivateKey(childKey) else {
            throw MultiChainKeyError.derivationFailed
        }
        
        return (childKey, childChainCode)
    }
    
    /// Add two private keys together (mod curve order)
    /// This is a simplified implementation
    private static func addPrivateKeys(_ key1: Data, _ key2: Data) throws -> Data {
        guard key1.count == 32 && key2.count == 32 else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Convert to big integers and add
        // For simplicity, we'll use a basic byte-by-byte addition with carry
        // In production, use proper big integer arithmetic with modulo curve order
        var result = [UInt8](repeating: 0, count: 32)
        var carry: UInt16 = 0
        
        let bytes1 = [UInt8](key1)
        let bytes2 = [UInt8](key2)
        
        for i in (0..<32).reversed() {
            let sum = UInt16(bytes1[i]) + UInt16(bytes2[i]) + carry
            result[i] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        
        return Data(result)
    }
    
    /// Check if private key is valid
    private static func isValidPrivateKey(_ key: Data) -> Bool {
        guard key.count == 32 else { return false }
        
        // Key must not be zero
        let isZero = key.allSatisfy { $0 == 0 }
        return !isZero
    }
    
    /// Generate compressed public key bytes (33 bytes)
    /// Simplified implementation - production should use secp256k1
    private static func generatePublicKeyBytes(from privateKey: Data) throws -> Data {
        // This is a placeholder using CryptoKit's P256
        // Production should use secp256k1 from web3.swift
        guard let p256Key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Get compressed public key representation (33 bytes)
        let publicKey = p256Key.publicKey.compressedRepresentation
        return publicKey
    }
    
    // MARK: - Address Generation
    
    /// Generate address from private key for a specific network
    private static func generateAddress(from privateKey: Data, network: BlockchainNetwork) throws -> String {
        switch network {
        case .ethereum, .originTrail, .bsc:
            return try generateEthereumAddress(from: privateKey)
        case .bitcoin:
            return try generateBitcoinAddress(from: privateKey)
        case .tron:
            return try generateTronAddress(from: privateKey)
        case .cosmos:
            return try generateCosmosAddress(from: privateKey)
        case .solana:
            return try generateSolanaAddress(from: privateKey)
        }
    }
    
    /// Generate Ethereum address from private key
    /// Note: Uses SHA256 as placeholder for Keccak-256
    /// Production should use web3.swift for proper Keccak-256 and secp256k1
    private static func generateEthereumAddress(from privateKey: Data) throws -> String {
        // Generate public key
        guard let p256Key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        let publicKey = p256Key.publicKey.rawRepresentation
        
        // Hash public key (SHA256 as placeholder for Keccak-256)
        // Production: Use Keccak-256 from web3.swift
        let hash = SHA256.hash(data: publicKey)
        let hashData = Data(hash)
        
        // Take last 20 bytes
        let addressBytes = hashData.suffix(20)
        
        // Convert to hex with checksum
        let addressHex = addressBytes.map { String(format: "%02x", $0) }.joined()
        
        return checksumEthereumAddress(addressHex)
    }
    
    /// Generate Bitcoin address from private key (P2PKH format)
    /// Simplified implementation
    private static func generateBitcoinAddress(from privateKey: Data) throws -> String {
        // Generate public key
        guard let p256Key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        let publicKey = p256Key.publicKey.compressedRepresentation
        
        // SHA256 then RIPEMD160 (using SHA256 twice as placeholder)
        let sha256Hash = SHA256.hash(data: publicKey)
        let hash160 = SHA256.hash(data: Data(sha256Hash)).prefix(20)
        
        // Add version byte (0x00 for mainnet P2PKH)
        var addressData = Data([0x00])
        addressData.append(contentsOf: hash160)
        
        // Double SHA256 for checksum
        let checksum1 = SHA256.hash(data: addressData)
        let checksum2 = SHA256.hash(data: Data(checksum1))
        addressData.append(contentsOf: checksum2.prefix(4))
        
        // Base58 encode
        return base58Encode(addressData)
    }
    
    /// Generate Cosmos address from private key
    /// Simplified implementation
    private static func generateCosmosAddress(from privateKey: Data) throws -> String {
        // Generate public key
        guard let p256Key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        let publicKey = p256Key.publicKey.compressedRepresentation
        
        // SHA256 then RIPEMD160 (using SHA256 twice as placeholder)
        let sha256Hash = SHA256.hash(data: publicKey)
        let hash160 = Data(SHA256.hash(data: Data(sha256Hash))).prefix(20)
        
        // Bech32 encode with "cosmos" prefix
        return bech32Encode(hrp: "cosmos", data: Data(hash160))
    }
    
    /// Generate Solana address from private key
    /// Solana uses Ed25519, this is a placeholder using the available curves
    private static func generateSolanaAddress(from privateKey: Data) throws -> String {
        // Solana uses Ed25519, the public key IS the address
        // This is a placeholder - production should use Ed25519
        guard let p256Key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        let publicKey = p256Key.publicKey.rawRepresentation
        
        // Base58 encode (Solana addresses are base58 encoded public keys)
        return base58Encode(publicKey)
    }
    
    /// Generate Tron address from private key
    /// Tron uses the same key derivation as Ethereum but with base58check encoding
    private static func generateTronAddress(from privateKey: Data) throws -> String {
        // Generate public key
        guard let p256Key = try? P256.Signing.PrivateKey(rawRepresentation: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        let publicKey = p256Key.publicKey.rawRepresentation
        
        // Hash public key (SHA256 as placeholder for Keccak-256)
        let hash = SHA256.hash(data: publicKey)
        let hashData = Data(hash)
        
        // Take last 20 bytes (same as Ethereum)
        let addressBytes = hashData.suffix(20)
        
        // Add Tron version byte (0x41 for mainnet)
        var addressData = Data([0x41])
        addressData.append(addressBytes)
        
        // Double SHA256 for checksum
        let checksum1 = SHA256.hash(data: addressData)
        let checksum2 = SHA256.hash(data: Data(checksum1))
        addressData.append(contentsOf: checksum2.prefix(4))
        
        // Base58 encode (Tron addresses start with 'T')
        return base58Encode(addressData)
    }
    
    // MARK: - Encoding Helpers
    
    /// Apply EIP-55 checksum to Ethereum address
    private static func checksumEthereumAddress(_ address: String) -> String {
        let cleanAddress = address.lowercased()
        
        // Hash the address (using SHA256 as placeholder for Keccak-256)
        let addressData = cleanAddress.data(using: .utf8)!
        let hash = SHA256.hash(data: addressData)
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()
        
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
    
    /// Base58 encoding (Bitcoin style)
    private static func base58Encode(_ data: Data) -> String {
        let alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
        let alphabetArray = Array(alphabet)
        
        var bytes = [UInt8](data)
        var result = ""
        
        // Count leading zeros
        var leadingZeros = 0
        for byte in bytes {
            if byte == 0 {
                leadingZeros += 1
            } else {
                break
            }
        }
        
        // Convert to base58
        while !bytes.isEmpty && !bytes.allSatisfy({ $0 == 0 }) {
            var carry = 0
            var newBytes = [UInt8]()
            
            for byte in bytes {
                carry = carry * 256 + Int(byte)
                if !newBytes.isEmpty || carry >= 58 {
                    newBytes.append(UInt8(carry / 58))
                }
                carry = carry % 58
            }
            
            result = String(alphabetArray[carry]) + result
            bytes = newBytes
        }
        
        // Add '1' for each leading zero
        result = String(repeating: "1", count: leadingZeros) + result
        
        return result
    }
    
    /// Simplified Bech32 encoding
    private static func bech32Encode(hrp: String, data: Data) -> String {
        // This is a simplified implementation
        // Production should use a proper Bech32 library
        let alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        let alphabetArray = Array(alphabet)
        
        // Convert data to 5-bit groups
        var bits: [UInt8] = []
        var acc: UInt16 = 0
        var accBits: Int = 0
        
        for byte in data {
            acc = (acc << 8) | UInt16(byte)
            accBits += 8
            while accBits >= 5 {
                accBits -= 5
                bits.append(UInt8((acc >> accBits) & 31))
            }
        }
        if accBits > 0 {
            bits.append(UInt8((acc << (5 - accBits)) & 31))
        }
        
        // Encode to bech32 characters
        var result = hrp + "1"
        for bit in bits {
            result.append(alphabetArray[Int(bit)])
        }
        
        // Add checksum (simplified - production should compute proper checksum)
        result += "xxxxxx"
        
        return result
    }
}
