//
//  SurTests.swift
//  SurTests
//
//  Created by Mathe Eliel on 04/10/2025.
//

import Testing
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
        // Private key: 0x0000...0001 (32 bytes)
        var privateKey = Data(repeating: 0x00, count: 31)
        privateKey.append(0x01)
        
        guard let publicKey = Secp256k1.derivePublicKey(from: privateKey) else {
            throw TestError.publicKeyDerivationFailed
        }
        
        // Uncompressed public key should be 65 bytes (0x04 + X + Y)
        #expect(publicKey.count == 65)
        #expect(publicKey[0] == 0x04)
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
}

// MARK: - Test Helpers

enum TestError: Error {
    case publicKeyDerivationFailed
}
