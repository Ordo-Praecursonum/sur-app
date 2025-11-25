//
//  MultiChainKeyManager.swift
//  Sur
//
//  Manages key derivation for multiple blockchain networks using proper BIP-32/BIP-44 paths
//
//  IMPLEMENTATION NOTES:
//  =====================
//  This implementation uses the web3.swift library for Ethereum-compatible chains:
//  - secp256k1 curve for key generation (Ethereum, BSC, Tron, Bitcoin, Cosmos)
//  - Keccak-256 hashing for Ethereum/BSC address derivation
//
//  The BIP-44 DERIVATION PATHS match industry standards:
//  - Ethereum: m/44'/60'/0'/0/0  (matches MetaMask, Ledger, etc.)
//  - Bitcoin:  m/44'/0'/0'/0/0   (BIP-44 standard)
//  - BSC:      m/44'/60'/0'/0/0  (EVM compatible, same as Ethereum)
//  - Tron:     m/44'/195'/0'/0/0 (Tron standard)
//  - Cosmos:   m/44'/118'/0'/0/0 (Cosmos SDK standard)
//  - Solana:   m/44'/501'/0'/0'  (Phantom, Solflare standard)
//  - OriginTrail: m/44'/60'/0'/0/0 (ERC-20 token on Ethereum)
//
//  NOTE: Solana uses Ed25519 curve (placeholder implementation remains for now).
//  Bitcoin and Cosmos use secp256k1 but have different address encodings.
//

import Foundation
import CryptoKit
import web3

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
    
    /// secp256k1 curve order (n) for modular arithmetic
    private static let curveOrder: [UInt8] = [
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE,
        0xBA, 0xAE, 0xDC, 0xE6, 0xAF, 0x48, 0xA0, 0x3B,
        0xBF, 0xD2, 0x5E, 0x8C, 0xD0, 0x36, 0x41, 0x41
    ]
    
    /// Add two private keys together (mod secp256k1 curve order)
    private static func addPrivateKeys(_ key1: Data, _ key2: Data) throws -> Data {
        guard key1.count == 32 && key2.count == 32 else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        var result = [UInt8](repeating: 0, count: 32)
        var carry: UInt16 = 0
        
        let bytes1 = [UInt8](key1)
        let bytes2 = [UInt8](key2)
        
        for i in (0..<32).reversed() {
            let sum = UInt16(bytes1[i]) + UInt16(bytes2[i]) + carry
            result[i] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        
        // Reduce modulo curve order if needed
        var resultData = Data(result)
        if compareWithCurveOrder(resultData) >= 0 {
            resultData = subtractCurveOrder(from: resultData)
        }
        
        return resultData
    }
    
    /// Compare data with secp256k1 curve order
    private static func compareWithCurveOrder(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        for i in 0..<32 {
            if bytes[i] < curveOrder[i] { return -1 }
            if bytes[i] > curveOrder[i] { return 1 }
        }
        return 0
    }
    
    /// Subtract curve order from data (for modular reduction)
    private static func subtractCurveOrder(from data: Data) -> Data {
        var result = [UInt8](repeating: 0, count: 32)
        var borrow: Int16 = 0
        
        let bytes = [UInt8](data)
        
        for i in (0..<32).reversed() {
            let diff = Int16(bytes[i]) - Int16(curveOrder[i]) - borrow
            if diff < 0 {
                result[i] = UInt8((diff + 256) & 0xFF)
                borrow = 1
            } else {
                result[i] = UInt8(diff & 0xFF)
                borrow = 0
            }
        }
        
        return Data(result)
    }
    
    /// Check if private key is valid
    private static func isValidPrivateKey(_ key: Data) -> Bool {
        guard key.count == 32 else { return false }
        
        // Key must not be zero
        let isZero = key.allSatisfy { $0 == 0 }
        guard !isZero else { return false }
        
        // Key must be less than curve order
        return compareWithCurveOrder(key) < 0
    }
    
    /// Generate compressed secp256k1 public key bytes (33 bytes) using web3.swift
    ///
    /// This method uses proper secp256k1 operations for MetaMask compatibility.
    ///
    /// - Parameter privateKey: 32-byte private key
    /// - Returns: 33-byte compressed public key
    private static func generatePublicKeyBytes(from privateKey: Data) throws -> Data {
        // Use web3.swift for proper secp256k1 public key generation
        guard let hexPrivateKey = privateKey.web3.hexString.web3.noHexPrefix as String?,
              let ethPrivateKey = try? EthereumPrivateKey(hexPrivateKey: hexPrivateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Get the public key bytes (64 bytes: x, y coordinates)
        let publicKeyBytes = ethPrivateKey.publicKey.rawBytes
        
        // Compress: prefix (0x02 or 0x03 based on y parity) + x coordinate
        let xCoord = publicKeyBytes.prefix(32)
        let yCoord = publicKeyBytes.suffix(32)
        let yIsEven = yCoord.last! & 1 == 0
        let prefix: UInt8 = yIsEven ? 0x02 : 0x03
        
        var compressed = Data([prefix])
        compressed.append(contentsOf: xCoord)
        
        return compressed
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
    
    /// Generate Ethereum address from private key using secp256k1 and Keccak-256
    ///
    /// This implementation uses web3.swift for proper MetaMask-compatible address generation:
    /// - secp256k1 curve for public key derivation
    /// - Keccak-256 hashing (not SHA256) for address generation
    ///
    /// - Parameter privateKey: 32-byte private key
    /// - Returns: EIP-55 checksummed Ethereum address
    private static func generateEthereumAddress(from privateKey: Data) throws -> String {
        // Generate secp256k1 public key using web3.swift
        guard let hexPrivateKey = privateKey.web3.hexString.web3.noHexPrefix as String?,
              let ethPrivateKey = try? EthereumPrivateKey(hexPrivateKey: hexPrivateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Get uncompressed public key (64 bytes)
        let publicKey = Data(ethPrivateKey.publicKey.rawBytes)
        
        // Keccak-256 hash of the public key via web3.swift
        let hash = publicKey.web3.keccak256
        
        // Take last 20 bytes
        let addressBytes = hash.suffix(20)
        
        // Convert to hex string
        let addressHex = addressBytes.map { String(format: "%02x", $0) }.joined()
        
        return checksumEthereumAddress(addressHex)
    }
    
    /// Generate Bitcoin address from private key (P2PKH format)
    ///
    /// NOTE: Bitcoin address generation still uses SHA256 twice as a placeholder
    /// for RIPEMD-160. For full Bitcoin compatibility, a RIPEMD-160 library is needed.
    private static func generateBitcoinAddress(from privateKey: Data) throws -> String {
        // Generate compressed secp256k1 public key using web3.swift
        let publicKey = try generatePublicKeyBytes(from: privateKey)
        
        // SHA256 then RIPEMD160 (using SHA256 twice as placeholder for RIPEMD160)
        // NOTE: For proper Bitcoin addresses, use a RIPEMD-160 library
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
    ///
    /// Uses secp256k1 public key via web3.swift.
    /// NOTE: RIPEMD-160 is approximated with SHA256 - for full Cosmos compatibility,
    /// a RIPEMD-160 library should be used.
    private static func generateCosmosAddress(from privateKey: Data) throws -> String {
        // Generate compressed secp256k1 public key using web3.swift
        let publicKey = try generatePublicKeyBytes(from: privateKey)
        
        // SHA256 then RIPEMD160 (using SHA256 twice as placeholder for RIPEMD160)
        // NOTE: For proper Cosmos addresses, use a RIPEMD-160 library
        let sha256Hash = SHA256.hash(data: publicKey)
        let hash160 = Data(SHA256.hash(data: Data(sha256Hash))).prefix(20)
        
        // Bech32 encode with "cosmos" prefix
        return bech32Encode(hrp: "cosmos", data: Data(hash160))
    }
    
    /// Generate Solana address from private key
    ///
    /// NOTE: Solana uses Ed25519, not secp256k1. This is a placeholder implementation.
    /// For proper Solana addresses, an Ed25519 library should be used.
    private static func generateSolanaAddress(from privateKey: Data) throws -> String {
        // Solana uses Ed25519, the public key IS the address
        // This is a placeholder - production should use Ed25519 (e.g., TweetNaCl)
        // Using secp256k1 public key as placeholder
        guard let hexPrivateKey = privateKey.web3.hexString.web3.noHexPrefix as String?,
              let ethPrivateKey = try? EthereumPrivateKey(hexPrivateKey: hexPrivateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Use raw public key bytes (64 bytes) - NOTE: Solana would use 32-byte Ed25519 pubkey
        let publicKey = Data(ethPrivateKey.publicKey.rawBytes.prefix(32))
        
        // Base58 encode (Solana addresses are base58 encoded public keys)
        return base58Encode(publicKey)
    }
    
    /// Generate Tron address from private key using secp256k1 and Keccak-256
    ///
    /// Tron uses the same key derivation as Ethereum (secp256k1 + Keccak-256)
    /// but encodes the address with base58check instead of hex.
    ///
    /// - Parameter privateKey: 32-byte private key
    /// - Returns: Tron address starting with 'T'
    private static func generateTronAddress(from privateKey: Data) throws -> String {
        // Generate secp256k1 public key using web3.swift
        guard let hexPrivateKey = privateKey.web3.hexString.web3.noHexPrefix as String?,
              let ethPrivateKey = try? EthereumPrivateKey(hexPrivateKey: hexPrivateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Get uncompressed public key (64 bytes)
        let publicKey = Data(ethPrivateKey.publicKey.rawBytes)
        
        // Keccak-256 hash of the public key
        let hash = publicKey.web3.keccak256
        
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
    ///
    /// This implementation uses web3.swift's Keccak-256 for proper EIP-55 compliance.
    private static func checksumEthereumAddress(_ address: String) -> String {
        let cleanAddress = address.lowercased()
        
        // Hash the address using Keccak-256 (EIP-55 standard)
        guard let addressData = cleanAddress.data(using: .utf8) else {
            return "0x" + cleanAddress
        }
        let hash = addressData.web3.keccak256
        let hashHex = hash.web3.hexString.dropFirst(2) // Remove 0x prefix
        
        var checksummed = "0x"
        for (index, char) in cleanAddress.enumerated() {
            if char.isLetter {
                let hashIndex = hashHex.index(hashHex.startIndex, offsetBy: index)
                let hashChar = hashHex[hashIndex]
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
