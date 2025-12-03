//
//  MultiChainKeyManager.swift
//  Sur
//
//  Manages key derivation for multiple blockchain networks using proper BIP-32/BIP-44 paths.
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
    
    // MARK: - Public Methods
    
    /// Generate keys and address for a specific blockchain network from mnemonic
    /// - Parameters:
    ///   - mnemonic: BIP-39 mnemonic phrase
    ///   - network: Target blockchain network
    /// - Returns: Tuple of (privateKey, publicAddress)
    static func generateKeysForNetwork(_ mnemonic: String, network: BlockchainNetwork) throws -> (privateKey: Data, address: String) {
        // Convert mnemonic to seed
        let seed = try MnemonicGenerator.mnemonicToSeed(mnemonic)
        
        // Derive the master key (use SLIP-10 for Ed25519 curves like Solana)
        let useSlip10 = !network.usesSecp256k1
        let masterKey = try deriveMasterKey(from: seed, useSlip10: useSlip10)
        
        // Derive child key using BIP-44 path for the network
        let derivedKey = try deriveKeyAtPath(
            masterPrivateKey: masterKey.privateKey,
            masterChainCode: masterKey.chainCode,
            path: network.pathComponents,
            useSlip10: useSlip10
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
    
    /// Derive master key from seed using HMAC-SHA512 (BIP-32 or SLIP-10)
    /// - Parameters:
    ///   - seed: 64-byte BIP-39 seed
    ///   - useSlip10: Use SLIP-10 for Ed25519 curves (e.g., Solana)
    /// - Returns: Master private key and chain code
    private static func deriveMasterKey(from seed: Data, useSlip10: Bool) throws -> (privateKey: Data, chainCode: Data) {
        guard seed.count == 64 else {
            throw MultiChainKeyError.invalidSeed
        }
        
        // Use appropriate HMAC key based on curve type
        // SLIP-10: "ed25519 seed" for Ed25519 curves
        // BIP-32: "Bitcoin seed" for secp256k1 curves
        let hmacKey = useSlip10 ? "ed25519 seed" : "Bitcoin seed"
        let key = hmacKey.data(using: .utf8)!
        
        // HMAC-SHA512
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: key))
        let hmacData = Data(hmac)
        
        // First 32 bytes are the private key
        let privateKey = Data(hmacData.prefix(32))
        
        // Last 32 bytes are the chain code
        let chainCode = Data(hmacData.suffix(32))
        
        // Validate private key
        if useSlip10 {
            // For Ed25519 (SLIP-10): basic validation - must be 32 bytes and not all zeros
            guard privateKey.count == 32 && !privateKey.allSatisfy({ $0 == 0 }) else {
                throw MultiChainKeyError.derivationFailed
            }
        } else {
            // For secp256k1 (BIP-32): validate against curve order
            guard isValidPrivateKey(privateKey) else {
                throw MultiChainKeyError.derivationFailed
            }
        }
        
        return (privateKey, chainCode)
    }
    
    /// Derive child key at a given BIP-32/BIP-44 path
    /// - Parameters:
    ///   - masterPrivateKey: 32-byte master private key
    ///   - masterChainCode: 32-byte master chain code
    ///   - path: Array of path indices (hardened indices have 0x80000000 added)
    ///   - useSlip10: Use SLIP-10 for Ed25519 curves
    /// - Returns: Derived private key and chain code
    private static func deriveKeyAtPath(
        masterPrivateKey: Data,
        masterChainCode: Data,
        path: [UInt32],
        useSlip10: Bool
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
                hardened: isHardened,
                useSlip10: useSlip10
            )
            
            currentKey = childKey
            currentChainCode = childChainCode
        }
        
        return (currentKey, currentChainCode)
    }
    
    /// Derive a single child key (BIP-32 or SLIP-10)
    /// - Parameters:
    ///   - parentPrivateKey: Parent private key
    ///   - parentChainCode: Parent chain code
    ///   - index: Child index
    ///   - hardened: Whether this is a hardened derivation
    ///   - useSlip10: Use SLIP-10 for Ed25519 curves
    /// - Returns: Child private key and chain code
    private static func deriveChildKey(
        parentPrivateKey: Data,
        parentChainCode: Data,
        index: UInt32,
        hardened: Bool,
        useSlip10: Bool
    ) throws -> (privateKey: Data, chainCode: Data) {
        var data = Data()
        
        if hardened {
            // Hardened child: 0x00 || parent_private_key || index
            data.append(0x00)
            data.append(parentPrivateKey)
        } else {
            // Normal (non-hardened) child: parent_public_key || index (BIP-32 only)
            // SLIP-10 for Ed25519 only supports hardened derivation
            if useSlip10 {
                throw MultiChainKeyError.invalidDerivationPath
            }
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
        
        // Key derivation differs between SLIP-10 and BIP-32:
        // SLIP-10 (Ed25519): child_key = IL (first 32 bytes of HMAC output)
        // BIP-32 (secp256k1): child_key = (IL + parent_key) mod n
        let childKey: Data
        if useSlip10 {
            // SLIP-10 for Ed25519: Use HMAC output directly as private key
            // No addition of parent key (unlike BIP-32)
            childKey = keyData
        } else {
            // BIP-32 for secp256k1: Add parent key to HMAC output (mod curve order n)
            childKey = try addPrivateKeys(parentPrivateKey, keyData)
            
            guard isValidPrivateKey(childKey) else {
                throw MultiChainKeyError.derivationFailed
            }
        }
        
        return (childKey, childChainCode)
    }
    
    /// Add two private keys together (mod curve order)
    /// Uses proper secp256k1 modular arithmetic for BIP-32 child key derivation
    /// child_key = (parent_key + tweak) mod n
    private static func addPrivateKeys(_ key1: Data, _ key2: Data) throws -> Data {
        guard key1.count == 32 && key2.count == 32 else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Use proper modular arithmetic from Secp256k1 implementation
        // This correctly handles overflow and reduction by curve order n
        return Secp256k1.addModN(key1, key2)
    }
    
    /// Check if private key is valid for secp256k1
    private static func isValidPrivateKey(_ key: Data) -> Bool {
        return Secp256k1.isValidPrivateKey(key)
    }
    
    /// Generate compressed public key bytes (33 bytes) using secp256k1
    private static func generatePublicKeyBytes(from privateKey: Data) throws -> Data {
        guard let compressedKey = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        return compressedKey
    }
    
    // MARK: - Address Generation
    
    /// Generate address from private key for a specific network
    private static func generateAddress(from privateKey: Data, network: BlockchainNetwork) throws -> String {
        switch network {
        case .ethereum, .originTrail, .bsc, .world:
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
    
    /// Generate Bitcoin address from private key (P2WPKH format - native SegWit)
    /// Uses secp256k1 for public key derivation and Bech32 encoding
    private static func generateBitcoinAddress(from privateKey: Data) throws -> String {
        // Generate compressed public key using secp256k1
        guard let compressedPublicKey = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // SHA256 then RIPEMD-160 (proper Bitcoin hash160)
        let sha256Hash = SHA256.hash(data: compressedPublicKey)
        let hash160 = RIPEMD160.hash(Data(sha256Hash))
        
        // P2WPKH: witness version 0 with 20-byte hash as witness program
        // Encode using Bech32 with "bc" HRP (Human Readable Part) for Bitcoin mainnet
        guard let address = Bech32.encodeSegWit(hrp: "bc", witnessVersion: 0, witnessProgram: hash160) else {
            throw MultiChainKeyError.addressGenerationFailed
        }
        
        return address
    }
    
    /// Generate Cosmos address from private key
    /// Uses secp256k1 for public key derivation and proper Bech32 encoding
    private static func generateCosmosAddress(from privateKey: Data) throws -> String {
        // Generate compressed public key using secp256k1
        guard let compressedPublicKey = Secp256k1.deriveCompressedPublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // SHA256 then RIPEMD-160 (proper Cosmos hash160)
        let sha256Hash = SHA256.hash(data: compressedPublicKey)
        let hash160 = RIPEMD160.hash(Data(sha256Hash))
        
        // Bech32 encode with "cosmos" prefix
        guard let address = Bech32.encode(hrp: "cosmos", data: hash160) else {
            throw MultiChainKeyError.addressGenerationFailed
        }
        
        return address
    }
    
    /// Generate Solana address from private key
    /// Solana uses Ed25519, where the public key IS the address
    private static func generateSolanaAddress(from privateKey: Data) throws -> String {
        // For Solana, use Ed25519 key derivation
        // The private key from BIP-32 is used as the seed for Ed25519
        guard let publicKey = Ed25519.derivePublicKey(from: privateKey) else {
            throw MultiChainKeyError.invalidPrivateKey
        }
        
        // Base58 encode the 32-byte public key (Solana addresses are base58 encoded Ed25519 public keys)
        return base58Encode(publicKey)
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
    

}
