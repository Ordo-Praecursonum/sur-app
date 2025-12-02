//
//  MultiChainKeyManager.swift
//  Sur
//
//  Manages key derivation for multiple blockchain networks using proper BIP-32/BIP-44 paths.
//
//  FIXED: Now properly matches MetaMask address generation
//
//  CRYPTOGRAPHIC IMPLEMENTATION:
//  =============================
//  This implementation uses proper cryptographic primitives for MetaMask compatibility:
//
//  1. CURVE: Uses secp256k1 (via Secp256k1.swift) for Ethereum-compatible chains
//     - Ethereum, BSC, OriginTrail, Bitcoin, Tron, Cosmos all use secp256k1
//     - Solana uses Ed25519 (simplified implementation, requires dedicated library)
//
//  2. HASHING: Uses Keccak-256 (via Keccak256.swift) for Ethereum addresses
//     - Ethereum addresses use Keccak-256 (NOT SHA3-256)
//     - Bitcoin uses SHA256 + RIPEMD-160 (simplified to SHA256 twice here)
//
//  3. BIP-44 DERIVATION PATHS (match industry standards):
//     - Ethereum: m/44'/60'/0'/0/{index}  (matches MetaMask, Ledger, etc.)
//     - Bitcoin:  m/44'/0'/0'/0/{index}   (BIP-44 standard)
//     - Cosmos:   m/44'/118'/0'/0/{index} (Cosmos SDK standard)
//     - Solana:   m/44'/501'/0'/0'        (Phantom, Solflare standard)
//     - OriginTrail: m/44'/60'/0'/0/{index} (ERC-20 token on Ethereum)
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
    
    /// secp256k1 curve order (n)
    /// This is crucial for proper private key addition mod n
    private static let secp256k1Order = Data([
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
    ])
    
    // MARK: - Public Methods
    
    /// Generate keys and address for a specific blockchain network from mnemonic
    /// - Parameters:
    ///   - mnemonic: BIP-39 mnemonic phrase
    ///   - network: Target blockchain network
    ///   - accountIndex: Account index (default 0)
    /// - Returns: Tuple of (privateKey, publicAddress)
    static func generateKeysForNetwork(
        _ mnemonic: String,
        network: BlockchainNetwork,
        accountIndex: UInt32 = 0
    ) throws -> (privateKey: Data, address: String) {
        // Convert mnemonic to seed
        let seed = try MnemonicGenerator.mnemonicToSeed(mnemonic)
        
        // Derive the master key
        let masterKey = try deriveMasterKey(from: seed)
        
        // Get path components for the network with account index
        var pathComponents = network.pathComponents
        // Replace the last component with the account index if it's the address index
        if pathComponents.count >= 5 {
            pathComponents[pathComponents.count - 1] = accountIndex
        }
        
        // Derive child key using BIP-44 path for the network
        let derivedKey = try deriveKeyAtPath(
            masterPrivateKey: masterKey.privateKey,
            masterChainCode: masterKey.chainCode,
            path: pathComponents
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
            // CRITICAL: Must use the actual compressed public key from secp256k1
            guard let publicKey = Secp256k1.deriveCompressedPublicKey(from: parentPrivateKey) else {
                throw MultiChainKeyError.invalidPrivateKey
            }
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
        
        // CRITICAL FIX: Add parent key to derived key (mod n for secp256k1)
        // This must be done with proper big integer arithmetic
        let childKey = try addPrivateKeysMod(parentPrivateKey, keyData)
        
        guard isValidPrivateKey(childKey) else {
            throw MultiChainKeyError.derivationFailed
        }
        
        return (childKey, childChainCode)
    }
    
    /// Add two private keys together (mod curve order n)
    /// CRITICAL: This is the main fix - proper modulo arithmetic with secp256k1 curve order
    private static func addPrivateKeysMod(_ key1: Data, _ key2: Data) throws -> Data {
        guard key1.count == 32 && key2.count == 32 else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Convert to big integers and add with proper carry handling
        var result = [UInt8](repeating: 0, count: 32)
        var carry: UInt16 = 0
        
        let bytes1 = [UInt8](key1)
        let bytes2 = [UInt8](key2)
        
        // Add bytes from right to left (little-endian arithmetic)
        for i in (0..<32).reversed() {
            let sum = UInt16(bytes1[i]) + UInt16(bytes2[i]) + carry
            result[i] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        
        // Now we need to apply modulo n (secp256k1 curve order)
        // If result >= n, subtract n
        let resultData = Data(result)
        if compareBytes(resultData, secp256k1Order) >= 0 {
            return try subtractBytes(resultData, secp256k1Order)
        }
        
        return resultData
    }
    
    /// Compare two byte arrays (returns -1 if a < b, 0 if equal, 1 if a > b)
    private static func compareBytes(_ a: Data, _ b: Data) -> Int {
        let bytes1 = [UInt8](a)
        let bytes2 = [UInt8](b)
        
        for i in 0..<min(bytes1.count, bytes2.count) {
            if bytes1[i] < bytes2[i] {
                return -1
            } else if bytes1[i] > bytes2[i] {
                return 1
            }
        }
        
        if bytes1.count < bytes2.count {
            return -1
        } else if bytes1.count > bytes2.count {
            return 1
        }
        
        return 0
    }
    
    /// Subtract two byte arrays (a - b), assuming a >= b
    private static func subtractBytes(_ a: Data, _ b: Data) throws -> Data {
        guard a.count == b.count else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        var result = [UInt8](repeating: 0, count: a.count)
        var borrow: Int16 = 0
        
        let bytes1 = [UInt8](a)
        let bytes2 = [UInt8](b)
        
        for i in (0..<a.count).reversed() {
            let diff = Int16(bytes1[i]) - Int16(bytes2[i]) - borrow
            if diff < 0 {
                result[i] = UInt8(diff + 256)
                borrow = 1
            } else {
                result[i] = UInt8(diff)
                borrow = 0
            }
        }
        
        return Data(result)
    }
    
    /// Check if private key is valid for secp256k1
    private static func isValidPrivateKey(_ key: Data) -> Bool {
        // Check if key is within valid range: 0 < key < n
        if key.allSatisfy({ $0 == 0 }) {
            return false
        }
        return compareBytes(key, secp256k1Order) < 0
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
    /// Uses secp256k1 for public key derivation and Keccak-256 for address generation
    /// This produces addresses compatible with MetaMask
    private static func generateEthereumAddress(from privateKey: Data) throws -> String {
        // Generate uncompressed public key using secp256k1 (65 bytes: 0x04 + X + Y)
        guard let publicKey = Secp256k1.derivePublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Ensure we have a valid uncompressed public key
        guard publicKey.count == 65 && publicKey[0] == 0x04 else {
            throw MultiChainKeyError.invalidPublicKey
        }
        
        // Hash the public key coordinates (64 bytes, excluding 0x04 prefix) with Keccak-256
        let publicKeyToHash = Data(publicKey.dropFirst())
        let hash = Keccak256.hash(publicKeyToHash)
        
        // Take last 20 bytes as the address
        let addressBytes = hash.suffix(20)
        
        // Convert to hex with EIP-55 checksum
        let addressHex = addressBytes.map { String(format: "%02x", $0) }.joined()
        
        return checksumEthereumAddress(addressHex)
    }
    
    /// Generate Bitcoin address from private key (P2PKH format)
    /// Uses secp256k1 for public key derivation
    /// Note: Uses SHA256 twice as a simplified placeholder for SHA256+RIPEMD160
    private static func generateBitcoinAddress(from privateKey: Data) throws -> String {
        // Generate compressed public key using secp256k1
        guard let compressedPublicKey = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // SHA256 then RIPEMD160 (using SHA256 twice as simplified placeholder)
        // Note: For full Bitcoin compatibility, RIPEMD-160 should be used
        let sha256Hash = SHA256.hash(data: compressedPublicKey)
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
    /// Uses secp256k1 for public key derivation
    /// Note: Uses SHA256 twice as a simplified placeholder for SHA256+RIPEMD160
    private static func generateCosmosAddress(from privateKey: Data) throws -> String {
        // Generate compressed public key using secp256k1
        guard let compressedPublicKey = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // SHA256 then RIPEMD160 (using SHA256 twice as simplified placeholder)
        let sha256Hash = SHA256.hash(data: compressedPublicKey)
        let hash160 = Data(SHA256.hash(data: Data(sha256Hash))).prefix(20)
        
        // Bech32 encode with "cosmos" prefix
        return bech32Encode(hrp: "cosmos", data: Data(hash160))
    }
    
    /// Generate Solana address from private key
    /// Note: Solana uses Ed25519, this is a placeholder implementation
    /// For full Solana compatibility, Ed25519 key derivation should be used
    private static func generateSolanaAddress(from privateKey: Data) throws -> String {
        // Solana uses Ed25519, the public key IS the address
        // This uses secp256k1 as a placeholder - production should use Ed25519
        guard let compressedPublicKey = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Use a hash to generate a 32-byte "public key" for Solana format
        // Note: For full Solana compatibility, use Ed25519
        let hash = SHA256.hash(data: compressedPublicKey)
        
        // Base58 encode (Solana addresses are base58 encoded 32-byte public keys)
        return base58Encode(Data(hash))
    }
    
    /// Generate Tron address from private key
    /// Tron uses secp256k1 and Keccak-256 (same as Ethereum) but with base58check encoding
    private static func generateTronAddress(from privateKey: Data) throws -> String {
        // Generate uncompressed public key using secp256k1
        guard let publicKey = Secp256k1.derivePublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Ensure we have a valid uncompressed public key
        guard publicKey.count == 65 && publicKey[0] == 0x04 else {
            throw MultiChainKeyError.invalidPublicKey
        }
        
        // Hash the public key coordinates (64 bytes, excluding 0x04 prefix) with Keccak-256
        let publicKeyToHash = Data(publicKey.dropFirst())
        let hash = Keccak256.hash(publicKeyToHash)
        
        // Take last 20 bytes (same as Ethereum)
        let addressBytes = hash.suffix(20)
        
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
    
    /// Apply EIP-55 checksum to Ethereum address using Keccak-256
    private static func checksumEthereumAddress(_ address: String) -> String {
        let cleanAddress = address.lowercased()
        
        // Hash the address using Keccak-256 (EIP-55 requirement)
        guard let addressData = cleanAddress.data(using: .utf8) else {
            return "0x" + cleanAddress
        }
        let hash = Keccak256.hash(addressData)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        
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
