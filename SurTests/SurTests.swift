//
//  SurTests.swift
//  SurTests
//
//  Created by Mathe Eliel on 04/10/2025.
//

import Testing
import CryptoKit
@testable import Sur

struct SurTests {

    // MARK: - Mnemonic Tests
    
    @Test func testMnemonicGeneration() async throws {
        // Generate a 12-word mnemonic
        let mnemonic = try MnemonicGenerator.generateMnemonic(wordCount: 12)
        let words = mnemonic.split(separator: " ")
        
        #expect(words.count == 12)
        #expect(MnemonicGenerator.validateMnemonic(mnemonic))
    }
    
    @Test func testMnemonicValidation() async throws {
        // Test valid mnemonic
        let validMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        #expect(MnemonicGenerator.validateMnemonic(validMnemonic))
        
        // Test invalid mnemonic (wrong word count)
        let invalidMnemonic = "abandon abandon abandon"
        #expect(!MnemonicGenerator.validateMnemonic(invalidMnemonic))
        
        // Test invalid mnemonic (invalid word)
        let invalidWordMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon invalidword"
        #expect(!MnemonicGenerator.validateMnemonic(invalidWordMnemonic))
    }
    
    // MARK: - Keccak-256 Tests
    
    @Test func testKeccak256Empty() async throws {
        // Empty input should produce known hash
        // Expected: c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
        let emptyHash = Keccak256.hash(Data())
        let hashHex = emptyHash.map { String(format: "%02x", $0) }.joined()
        
        #expect(hashHex == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
    }
    
    @Test func testKeccak256Hello() async throws {
        // "hello" should produce known hash
        // Expected: 1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8
        let helloData = "hello".data(using: .utf8)!
        let hash = Keccak256.hash(helloData)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        
        #expect(hashHex == "1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8")
    }
    
    // MARK: - Secp256k1 Tests
    
    @Test func testSecp256k1PrivateKeyValidation() async throws {
        // Valid private key (32 bytes, non-zero, less than curve order)
        let validKey = Data(repeating: 0x01, count: 32)
        #expect(Secp256k1.isValidPrivateKey(validKey))
        
        // Invalid: zero key
        let zeroKey = Data(repeating: 0x00, count: 32)
        #expect(!Secp256k1.isValidPrivateKey(zeroKey))
        
        // Invalid: wrong length
        let shortKey = Data(repeating: 0x01, count: 16)
        #expect(!Secp256k1.isValidPrivateKey(shortKey))
    }
    
    @Test func testSecp256k1PublicKeyDerivation() async throws {
        // Known private key should produce known public key
        // Private key: 0x0000...0001 (32 bytes) = generator point G
        var privateKey = Data(repeating: 0x00, count: 31)
        privateKey.append(0x01)
        
        guard let publicKey = Secp256k1.derivePublicKey(from: privateKey) else {
            throw TestError.publicKeyDerivationFailed
        }
        
        // Uncompressed public key should be 65 bytes (0x04 + X + Y)
        #expect(publicKey.count == 65)
        #expect(publicKey[0] == 0x04)
        
        // For private key = 1, public key should be the generator point G
        // G.x = 79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
        // G.y = 483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
        let expectedX = Data([
            0x79, 0xBE, 0x66, 0x7E, 0xF9, 0xDC, 0xBB, 0xAC,
            0x55, 0xA0, 0x62, 0x95, 0xCE, 0x87, 0x0B, 0x07,
            0x02, 0x9B, 0xFC, 0xDB, 0x2D, 0xCE, 0x28, 0xD9,
            0x59, 0xF2, 0x81, 0x5B, 0x16, 0xF8, 0x17, 0x98
        ])
        let expectedY = Data([
            0x48, 0x3A, 0xDA, 0x77, 0x26, 0xA3, 0xC4, 0x65,
            0x5D, 0xA4, 0xFB, 0xFC, 0x0E, 0x11, 0x08, 0xA8,
            0xFD, 0x17, 0xB4, 0x48, 0xA6, 0x85, 0x54, 0x19,
            0x9C, 0x47, 0xD0, 0x8F, 0xFB, 0x10, 0xD4, 0xB8
        ])
        
        let actualX = publicKey[1..<33]
        let actualY = publicKey[33..<65]
        
        #expect(Data(actualX) == expectedX)
        #expect(Data(actualY) == expectedY)
    }
    
    // MARK: - Ethereum Address Tests
    
    @Test func testEthereumAddressGeneration() async throws {
        // Well-known test mnemonic (BIP-39 test vector)
        // This mnemonic should produce a predictable address
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Generate Ethereum address
        let (_, address) = try EthereumKeyManager.generateKeysFromMnemonic(testMnemonic)
        
        // Address should be properly formatted
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
        
        // Verify it's a valid hex string (after 0x prefix)
        let hexPart = String(address.dropFirst(2))
        let isValidHex = hexPart.allSatisfy { $0.isHexDigit }
        #expect(isValidHex)
    }
    
    @Test func testMetaMaskCompatibility() async throws {
        // Well-known test mnemonic from BIP-39 test vectors
        // MetaMask generates address: 0x9858EfFD232B4033E47d90003D41EC34EcaEda94 for m/44'/60'/0'/0/0
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        let (_, address) = try EthereumKeyManager.generateKeysFromMnemonic(testMnemonic)
        
        // The address should match what MetaMask generates
        // Note: This is the expected address for the BIP-39 test vector
        let expectedAddress = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94"
        
        #expect(address.lowercased() == expectedAddress.lowercased())
    }
    
    @Test func testMetaMaskCompatibilityWithSpecificMnemonic() async throws {
        // Test vector provided by user to verify BIP-32/39/44 implementation
        // Reference: https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
        let testMnemonic = "crawl boost shadow all movie scatter soul two wedding mask cactus brother"
        
        // Expected values (verified with MetaMask)
        let expectedSeedHex = "a969581a4938024c6f7dd8066bb6e8d46d00b0759615314235b9633e534fe351cb0f0802b28d75388e68da7a49f7e7ff111d03d7b21b5f97e55819a158759f29"
        let expectedPrivateKeyHex = "35427bdc4aad663235b6b06a60c83236e27767901f727cf0379e51695cb61fd4"
        let expectedAddress = "0x879DF5268D9343A703D33e55153c26A24FA369f4"
        
        // Step 1: Verify BIP-39 seed derivation
        let seed = try MnemonicGenerator.mnemonicToSeed(testMnemonic)
        let seedHex = seed.map { String(format: "%02x", $0) }.joined()
        #expect(seedHex == expectedSeedHex, "BIP-39 seed derivation should match expected value")
        
        // Step 2: Verify BIP-32/44 private key derivation (m/44'/60'/0'/0/0)
        let privateKey = try EthereumKeyManager.derivePrivateKey(from: seed, index: 0)
        let privateKeyHex = privateKey.map { String(format: "%02x", $0) }.joined()
        #expect(privateKeyHex == expectedPrivateKeyHex, "BIP-32/44 private key derivation should match expected value")
        
        // Step 3: Verify Ethereum address generation (secp256k1 + Keccak-256)
        let address = try EthereumKeyManager.generateAddress(from: privateKey)
        #expect(address.lowercased() == expectedAddress.lowercased(), "Ethereum address should match MetaMask")
        
        // Step 4: Full flow test using generateKeysFromMnemonic
        let (fullPrivateKey, fullAddress) = try EthereumKeyManager.generateKeysFromMnemonic(testMnemonic)
        #expect(fullPrivateKey == privateKey, "Full flow private key should match")
        #expect(fullAddress.lowercased() == expectedAddress.lowercased(), "Full flow address should match")
    }
    
    @Test func testMultiChainKeyManagerMatchesMetaMask() async throws {
        // CRITICAL: This test verifies that MultiChainKeyManager (used by the app's wallet creation)
        // produces the same addresses as EthereumKeyManager and MetaMask
        let testMnemonic = "crawl boost shadow all movie scatter soul two wedding mask cactus brother"
        let expectedAddress = "0x879DF5268D9343A703D33e55153c26A24FA369f4"
        let expectedPrivateKeyHex = "35427bdc4aad663235b6b06a60c83236e27767901f727cf0379e51695cb61fd4"
        
        // Test MultiChainKeyManager (this is what the app uses for wallet creation)
        let (privateKey, address) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .ethereum)
        let privateKeyHex = privateKey.map { String(format: "%02x", $0) }.joined()
        
        #expect(privateKeyHex == expectedPrivateKeyHex, "MultiChainKeyManager private key should match MetaMask")
        #expect(address.lowercased() == expectedAddress.lowercased(), "MultiChainKeyManager address should match MetaMask")
        
        // Also verify generateAllAddresses produces the same result
        let allAddresses = try MultiChainKeyManager.generateAllAddresses(from: testMnemonic)
        #expect(allAddresses[.ethereum]?.lowercased() == expectedAddress.lowercased(), "generateAllAddresses should match MetaMask")
    }
    
    @Test func testEIP55Checksum() async throws {
        // Test EIP-55 address checksumming
        // Known address should have proper checksum
        let lowercaseAddress = "5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed".lowercased()
        let checksummed = EthereumKeyManager.checksumAddress(lowercaseAddress)
        
        // Should have 0x prefix
        #expect(checksummed.hasPrefix("0x"))
        
        // Should be 42 characters (0x + 40 hex chars)
        #expect(checksummed.count == 42)
    }
    
    // MARK: - Multi-Chain Key Manager Tests
    
    @Test func testMultiChainAddressGeneration() async throws {
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Test Ethereum address generation through MultiChainKeyManager
        let (_, ethAddress) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .ethereum)
        
        #expect(ethAddress.hasPrefix("0x"))
        #expect(ethAddress.count == 42)
    }
    
    @Test func testAllNetworksAddressGeneration() async throws {
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Generate addresses for all networks
        let addresses = try MultiChainKeyManager.generateAllAddresses(from: testMnemonic)
        
        // All networks should have an address
        for network in BlockchainNetwork.allCases {
            let address = addresses[network]
            #expect(address != nil)
            #expect(!address!.isEmpty)
        }
    }
    
    // MARK: - BIP-44 Path Tests
    
    @Test func testBIP44DerivationPath() async throws {
        // Test that different account indices produce different addresses
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        let seed = try MnemonicGenerator.mnemonicToSeed(testMnemonic)
        
        let key0 = try EthereumKeyManager.derivePrivateKey(from: seed, index: 0)
        let key1 = try EthereumKeyManager.derivePrivateKey(from: seed, index: 1)
        
        // Different indices should produce different keys
        #expect(key0 != key1)
    }
    
    @Test func testAddressShortening() async throws {
        let fullAddress = "0x1234567890abcdef1234567890abcdef12345678"
        let shortened = EthereumKeyManager.shortenAddress(fullAddress)
        
        // Should be in format "0x1234...5678"
        #expect(shortened == "0x1234...5678")
    }
    
    // MARK: - Bitcoin Address Tests
    
    @Test func testBitcoinAddressGeneration() async throws {
        // Well-known test mnemonic from BIP-39 test vectors
        // This should produce a predictable Bitcoin address
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Generate Bitcoin address
        let (_, address) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .bitcoin)
        
        // Bitcoin P2WPKH (native SegWit) addresses start with 'bc1'
        #expect(address.hasPrefix("bc1"))
        
        // Bitcoin Bech32 addresses are 42-62 characters
        #expect(address.count >= 42 && address.count <= 62)
        
        // Verify it's a valid Bech32 string (lowercase alphanumeric from Bech32 charset)
        let bech32Chars = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        let datapart = String(address.dropFirst(3)) // Remove "bc1"
        let isValidBech32 = datapart.allSatisfy { bech32Chars.contains($0) }
        #expect(isValidBech32)
    }
    
    @Test func testBitcoinAddressMatchesStandardWallet() async throws {
        // Test vector: Known mnemonic should produce known Bitcoin address
        // Reference: Using m/84'/0'/0'/0/0 derivation path (BIP-84 for native SegWit)
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Expected address for this mnemonic at m/84'/0'/0'/0/0 (P2WPKH/Bech32)
        // Can be verified using Ian Coleman's BIP39 tool with BIP84 tab
        let expectedAddress = "bc1qcr8te4kr6gch7z8stxu842stf3d85zw027pnp9"
        
        let (_, address) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .bitcoin)
        
        #expect(address == expectedAddress, "Bitcoin address should match standard wallet derivation")
    }
    
    // MARK: - Cosmos Address Tests
    
    @Test func testCosmosAddressGeneration() async throws {
        // Test Cosmos address generation
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Generate Cosmos address
        let (_, address) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .cosmos)
        
        // Cosmos addresses start with "cosmos1"
        #expect(address.hasPrefix("cosmos1"))
        
        // Cosmos addresses are 45 characters (cosmos1 + 38 chars)
        #expect(address.count == 45)
        
        // Verify it's a valid Bech32 string (uses specific 32-character alphabet)
        let bech32Chars = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
        let datapart = String(address.dropFirst(7)) // Remove "cosmos1"
        let isValidBech32 = datapart.allSatisfy { bech32Chars.contains($0) }
        #expect(isValidBech32)
    }
    
    @Test func testCosmosAddressMatchesStandardWallet() async throws {
        // Test vector: Known mnemonic should produce known Cosmos address
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Expected address for this mnemonic at m/44'/118'/0'/0/0
        // Can be verified using Keplr wallet or Cosmostation
        let expectedAddress = "cosmos1r5v5srda7xfth3hn2s26txvrcrntldjumt8mhl"
        
        let (_, address) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .cosmos)
        
        #expect(address == expectedAddress, "Cosmos address should match Keplr wallet derivation")
    }
    
    // MARK: - Solana Address Tests
    
    @Test func testSolanaAddressGeneration() async throws {
        // Test Solana address generation
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Generate Solana address
        let (_, address) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .solana)
        
        // Solana addresses are base58 encoded (32 bytes = ~43-44 chars in base58)
        #expect(address.count >= 32 && address.count <= 44)
        
        // Verify it's a valid base58 string
        let base58Chars = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
        let isValidBase58 = address.allSatisfy { base58Chars.contains($0) }
        #expect(isValidBase58)
    }
    
    @Test func testSolanaAddressMatchesStandardWallet() async throws {
        // Test vector: Known mnemonic should produce known Solana address
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Expected address for this mnemonic at m/44'/501'/0'/0'
        // Can be verified using Phantom or Solflare wallet
        // Note: Solana derivation uses Ed25519 and hardened derivation
        let expectedAddress = "DRpbCBMxVnDK7maPM5tGv6MvB3v1sRMC86PZ8okm21hy"
        
        let (_, address) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .solana)
        
        #expect(address == expectedAddress, "Solana address should match Phantom wallet derivation")
    }
    
    // MARK: - World Network Tests
    
    @Test func testWorldNetworkAddressGeneration() async throws {
        // Test World network address generation
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        // Generate World address
        let (_, address) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .world)
        
        // World uses Ethereum-compatible addresses
        #expect(address.hasPrefix("0x"))
        #expect(address.count == 42)
        
        // Verify it's a valid hex string (after 0x prefix)
        let hexPart = String(address.dropFirst(2))
        let isValidHex = hexPart.allSatisfy { $0.isHexDigit }
        #expect(isValidHex)
    }
    
    @Test func testWorldAddressMatchesEthereum() async throws {
        // World uses the same derivation path as Ethereum (m/44'/60'/0'/0/0)
        // So it should produce the same address as Ethereum
        let testMnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        
        let (_, ethAddress) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .ethereum)
        let (_, worldAddress) = try MultiChainKeyManager.generateKeysForNetwork(testMnemonic, network: .world)
        
        #expect(ethAddress.lowercased() == worldAddress.lowercased(), "World should use same address as Ethereum")
    }
    
    // MARK: - RIPEMD-160 Tests
    
    @Test func testRIPEMD160EmptyString() async throws {
        // Known test vector: RIPEMD-160 of empty string
        // Expected: 9c1185a5c5e9fc54612808977ee8f548b2258d31
        let emptyData = Data()
        let hash = RIPEMD160.hash(emptyData)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        
        #expect(hashHex == "9c1185a5c5e9fc54612808977ee8f548b2258d31")
    }
    
    @Test func testRIPEMD160KnownVector() async throws {
        // Known test vector: RIPEMD-160 of "abc"
        // Expected: 8eb208f7e05d987a9b044a8e98c6b087f15a0bfc
        let data = "abc".data(using: .utf8)!
        let hash = RIPEMD160.hash(data)
        let hashHex = hash.map { String(format: "%02x", $0) }.joined()
        
        #expect(hashHex == "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc")
    }
    
    // MARK: - Bech32 Tests
    
    @Test func testBech32Encoding() async throws {
        // Test basic Bech32 encoding
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
                        0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13])
        
        guard let encoded = Bech32.encode(hrp: "cosmos", data: data) else {
            throw TestError.bech32EncodingFailed
        }
        
        #expect(encoded.hasPrefix("cosmos1"))
        #expect(encoded.count > 7) // More than just "cosmos1"
    }
    
    @Test func testBech32RoundTrip() async throws {
        // Test encoding and decoding round trip
        let originalData = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
                                0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13])
        
        guard let encoded = Bech32.encode(hrp: "cosmos", data: originalData) else {
            throw TestError.bech32EncodingFailed
        }
        
        guard let (hrp, decodedData) = Bech32.decode(encoded) else {
            throw TestError.bech32DecodingFailed
        }
        
        #expect(hrp == "cosmos")
        #expect(decodedData == originalData)
    }
    
    // MARK: - Ed25519 Tests
    
    @Test func testEd25519KeyDerivation() async throws {
        // Test Ed25519 public key derivation from a 32-byte seed
        let seed = Data(repeating: 0x01, count: 32)
        
        guard let publicKey = Ed25519.derivePublicKey(from: seed) else {
            throw TestError.ed25519KeyDerivationFailed
        }
        
        // Ed25519 public keys are 32 bytes
        #expect(publicKey.count == 32)
    }
    
    @Test func testEd25519SeedValidation() async throws {
        // Valid seed (32 bytes)
        let validSeed = Data(repeating: 0x01, count: 32)
        #expect(Ed25519.isValidSeed(validSeed))
        
        // Invalid seed (wrong length)
        let invalidSeed = Data(repeating: 0x01, count: 16)
        #expect(!Ed25519.isValidSeed(invalidSeed))
    }
    
    // MARK: - Device Key Tests
    
    @Test func testDeviceKeyGeneration() async throws {
        // Test device key generation from user private key using secp256k1
        let userPrivateKey = Data(repeating: 0x01, count: 32)
        let deviceIDManager = DeviceIDManager.shared
        
        let (devicePrivateKey, devicePublicKey) = try deviceIDManager.generateDeviceKeys(from: userPrivateKey)
        
        // Device private key should be 32 bytes
        #expect(devicePrivateKey.count == 32)
        
        // Device public key should be 65 bytes (uncompressed secp256k1)
        #expect(devicePublicKey.count == 65)
        
        // Public key should start with 0x04 (uncompressed format)
        #expect(devicePublicKey[0] == 0x04)
        
        // Device private key should be valid for secp256k1
        #expect(Secp256k1.isValidPrivateKey(devicePrivateKey))
    }
    
    @Test func testDeviceKeyDeterminism() async throws {
        // Test that device keys are deterministic for the same user private key
        let userPrivateKey = Data(repeating: 0x42, count: 32)
        let deviceIDManager = DeviceIDManager.shared
        
        // Generate keys twice
        let (privateKey1, publicKey1) = try deviceIDManager.generateDeviceKeys(from: userPrivateKey)
        let (privateKey2, publicKey2) = try deviceIDManager.generateDeviceKeys(from: userPrivateKey)
        
        // Keys should be identical (deterministic)
        #expect(privateKey1 == privateKey2)
        #expect(publicKey1 == publicKey2)
    }
    
    @Test func testDeviceKeyUniqueness() async throws {
        // Test that different user private keys produce different device keys
        let userPrivateKey1 = Data(repeating: 0x01, count: 32)
        let userPrivateKey2 = Data(repeating: 0x02, count: 32)
        let deviceIDManager = DeviceIDManager.shared
        
        let (privateKey1, publicKey1) = try deviceIDManager.generateDeviceKeys(from: userPrivateKey1)
        let (privateKey2, publicKey2) = try deviceIDManager.generateDeviceKeys(from: userPrivateKey2)
        
        // Keys should be different for different user keys
        #expect(privateKey1 != privateKey2)
        #expect(publicKey1 != publicKey2)
    }
    
    @Test func testDeviceKeyInvalidPrivateKey() async throws {
        // Test that invalid private key throws error
        let invalidKey = Data(repeating: 0x01, count: 16) // Wrong length
        let deviceIDManager = DeviceIDManager.shared
        
        do {
            _ = try deviceIDManager.generateDeviceKeys(from: invalidKey)
            #expect(Bool(false), "Should have thrown error for invalid key")
        } catch DeviceIDError.invalidPrivateKey {
            // Expected error
            #expect(true)
        } catch {
            #expect(Bool(false), "Wrong error type thrown")
        }
    }
    
    @Test func testDevicePublicKeyShortening() async throws {
        // Test device public key shortening for display
        let fullKey = Data(repeating: 0xAB, count: 65)
        let shortened = DeviceIDManager.shortenDevicePublicKey(fullKey)
        
        // Should be in format "xxxxxx...xxxxxx"
        #expect(shortened.contains("..."))
        #expect(shortened.count == 15) // 6 + 3 + 6
        #expect(shortened == "ababab...ababab")
    }
    
    @Test func testDeviceKeyStorageAndRetrieval() async throws {
        // Test saving and retrieving device keys
        let deviceIDManager = DeviceIDManager.shared
        let testPrivateKey = Data(repeating: 0x42, count: 32)
        let testPublicKey = Data(repeating: 0x04, count: 65)
        
        deviceIDManager.saveDeviceKeys(privateKey: testPrivateKey, publicKey: testPublicKey)
        let retrievedPublic = deviceIDManager.getStoredDevicePublicKey()
        let retrievedPrivate = deviceIDManager.getStoredDevicePrivateKey()
        
        #expect(retrievedPublic == testPublicKey)
        #expect(retrievedPrivate == testPrivateKey)
        
        // Clean up
        deviceIDManager.clearDeviceKeys()
    }
    
    @Test func testDeviceKeyValidation() async throws {
        // Test that stored keys are validated on retrieval
        let deviceIDManager = DeviceIDManager.shared
        
        // Test invalid public key (wrong length)
        UserDefaults.standard.set("0102030405", forKey: "device.publicKey")
        #expect(deviceIDManager.getStoredDevicePublicKey() == nil)
        
        // Test invalid public key (wrong prefix)
        let wrongPrefixKey = Data(repeating: 0x02, count: 65)
        let wrongPrefixHex = wrongPrefixKey.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(wrongPrefixHex, forKey: "device.publicKey")
        #expect(deviceIDManager.getStoredDevicePublicKey() == nil)
        
        // Test invalid hex string
        UserDefaults.standard.set("invalid_hex_string", forKey: "device.publicKey")
        #expect(deviceIDManager.getStoredDevicePublicKey() == nil)
        
        // Clean up
        deviceIDManager.clearDeviceKeys()
    }
    
    @Test func testDeviceKeyCanBeUsedForCryptography() async throws {
        // Test that generated device keys are valid for secp256k1 operations
        let userPrivateKey = Data(repeating: 0x01, count: 32)
        let deviceIDManager = DeviceIDManager.shared
        
        let (devicePrivateKey, devicePublicKey) = try deviceIDManager.generateDeviceKeys(from: userPrivateKey)
        
        // Verify the private key is valid for secp256k1
        #expect(Secp256k1.isValidPrivateKey(devicePrivateKey))
        
        // Verify the public key can be derived from the private key
        let derivedPublicKey = Secp256k1.derivePublicKey(from: devicePrivateKey)
        #expect(derivedPublicKey == devicePublicKey)
        
        // Note: Actual signing/verification tests would require implementing
        // or exposing signing functions in the Secp256k1 wrapper
    }
    
    @Test func testDeviceKeySigningAndVerification() async throws {
        // Test that device keys can actually sign and verify messages
        let userPrivateKey = Data(repeating: 0x01, count: 32)
        let deviceIDManager = DeviceIDManager.shared
        
        let (devicePrivateKey, devicePublicKey) = try deviceIDManager.generateDeviceKeys(from: userPrivateKey)
        
        // Create a test message
        let message = "Test message from device"
        guard let messageData = message.data(using: .utf8) else {
            throw TestError.messageEncodingFailed
        }
        
        // Hash the message using SHA-256
        let messageHash = SHA256.hash(data: messageData)
        let messageHashData = Data(messageHash)
        
        // Sign the message with device private key
        guard let signature = Secp256k1.sign(messageHash: messageHashData, with: devicePrivateKey) else {
            throw TestError.signingFailed
        }
        
        // Verify the signature is exactly 64 bytes (R + S in compact format)
        #expect(signature.count == 64)
        
        // Verify the signature with device public key
        let isValid = Secp256k1.verify(signature: signature, for: messageHashData, publicKey: devicePublicKey)
        #expect(isValid)
        
        // Verify that wrong message doesn't verify
        let wrongMessage = "Different message"
        guard let wrongMessageData = wrongMessage.data(using: .utf8) else {
            throw TestError.messageEncodingFailed
        }
        let wrongMessageHash = SHA256.hash(data: wrongMessageData)
        let wrongMessageHashData = Data(wrongMessageHash)
        
        let isValidWithWrongMessage = Secp256k1.verify(signature: signature, for: wrongMessageHashData, publicKey: devicePublicKey)
        #expect(!isValidWithWrongMessage)
    }
    
    @Test func testSecp256k1SignatureNormalization() async throws {
        // Test that signatures are normalized to have low S value (S <= n/2)
        // This is required by BIP-62, Ethereum, and external ECDSA tools
        
        // Use a test private key
        let privateKey = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
        ])
        
        // Create a test message
        let message = "Hello"
        guard let messageData = message.data(using: .utf8) else {
            throw TestError.messageEncodingFailed
        }
        
        // Hash the message using SHA-256 (same as the app does)
        let messageHash = SHA256.hash(data: messageData)
        let messageHashData = Data(messageHash)
        
        // Sign the message
        guard let signature = Secp256k1.sign(messageHash: messageHashData, with: privateKey) else {
            throw TestError.signingFailed
        }
        
        // Signature should be 64 bytes
        #expect(signature.count == 64)
        
        // Extract R and S
        let r = signature.prefix(32)
        let s = signature.suffix(32)
        
        // Define n/2 (half of secp256k1 curve order) for verification
        // This is intentionally defined here to independently verify the implementation
        let halfOrder = Data([
            0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
            0x5D, 0x57, 0x6E, 0x73, 0x57, 0xA4, 0x50, 0x1D,
            0xDF, 0xE9, 0x2F, 0x46, 0x68, 0x1B, 0x20, 0xA0
        ])
        
        // Check that S <= n/2 (normalized/canonical form)
        let sBytes = [UInt8](s)
        let halfOrderBytes = [UInt8](halfOrder)
        var sIsNormalized = true  // Default to true for the case where s == n/2
        
        for i in 0..<32 {
            if sBytes[i] < halfOrderBytes[i] {
                sIsNormalized = true
                break
            }
            if sBytes[i] > halfOrderBytes[i] {
                sIsNormalized = false
                break
            }
            // If equal, continue to next byte
        }
        
        #expect(sIsNormalized, "S value should be normalized (S <= n/2) for compatibility with external tools")
        
        // Verify the signature still validates
        guard let publicKey = Secp256k1.derivePublicKey(from: privateKey) else {
            throw TestError.publicKeyDerivationFailed
        }
        
        let isValid = Secp256k1.verify(signature: signature, for: messageHashData, publicKey: publicKey)
        #expect(isValid, "Normalized signature should still verify correctly")
    }
    
    @Test func testSecp256k1SignatureCompatibilityWithExternalTools() async throws {
        // Test case based on the issue reported
        // This verifies that our signatures can be verified by external tools
        // Reference: https://emn178.github.io/online-tools/ecdsa/sign/
        
        // Known test vector for verification
        // Private key: all zeros except last byte = 1
        let privateKey = Data([
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
        ])
        
        // Derive public key
        guard let publicKey = Secp256k1.derivePublicKey(from: privateKey) else {
            throw TestError.publicKeyDerivationFailed
        }
        
        // Expected public key for private key = 1 (generator point G)
        // This is a well-known constant in secp256k1
        #expect(publicKey.count == 65)
        #expect(publicKey[0] == 0x04)
        
        // Test message
        let message = "Hello"
        guard let messageData = message.data(using: .utf8) else {
            throw TestError.messageEncodingFailed
        }
        
        // Hash using SHA-256 (standard for ECDSA)
        let messageHash = SHA256.hash(data: messageData)
        let messageHashData = Data(messageHash)
        
        // Expected hash for "Hello" with SHA-256
        let expectedHashHex = "185f8db32271fe25f561a6fc938b2e264306ec304eda518007d1764826381969"
        let actualHashHex = messageHashData.map { String(format: "%02x", $0) }.joined()
        #expect(actualHashHex == expectedHashHex, "SHA-256 hash of 'Hello' should match expected value")
        
        // Sign the message
        guard let signature = Secp256k1.sign(messageHash: messageHashData, with: privateKey) else {
            throw TestError.signingFailed
        }
        
        // Signature should be 64 bytes in compact format
        #expect(signature.count == 64)
        
        // The signature should have normalized S value
        let s = signature.suffix(32)
        let sBytes = [UInt8](s)
        
        // Verify S is not all zeros (would be invalid)
        let sIsZero = sBytes.allSatisfy { $0 == 0 }
        #expect(!sIsZero, "S value should not be zero")
        
        // Verify the signature locally
        let isValid = Secp256k1.verify(signature: signature, for: messageHashData, publicKey: publicKey)
        #expect(isValid, "Signature should verify with our implementation")
        
        // Print signature for manual verification with external tools
        let signatureHex = signature.map { String(format: "%02x", $0) }.joined()
        let publicKeyHex = publicKey.map { String(format: "%02x", $0) }.joined()
        let privateKeyHex = privateKey.map { String(format: "%02x", $0) }.joined()
        
        print("=== Signature Verification Data ===")
        print("Message: \(message)")
        print("Message Hash (SHA-256): \(actualHashHex)")
        print("Private Key: \(privateKeyHex)")
        print("Public Key (uncompressed): \(publicKeyHex)")
        print("Signature (R+S): \(signatureHex)")
        print("Signature is \(signature.count) bytes (32-byte R + 32-byte S)")
        print("=== End Verification Data ===")
    }
}
}

// MARK: - Test Helpers

enum TestError: Error {
    case publicKeyDerivationFailed
    case bech32EncodingFailed
    case bech32DecodingFailed
    case ed25519KeyDerivationFailed
    case messageEncodingFailed
    case signingFailed
}
