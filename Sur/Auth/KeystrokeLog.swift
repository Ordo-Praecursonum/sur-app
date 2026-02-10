//
//  KeystrokeLog.swift
//  Sur
//
//  Data structures for keystroke logging with cryptographic signing
//  for proving human-generated content provenance.
//

import Foundation
import CryptoKit

// MARK: - Keystroke Data Structures

/// Represents a single keystroke event with position and timing
public struct Keystroke: Codable, Equatable {
    /// The key that was pressed (character or key identifier)
    public let key: String
    
    /// Unix timestamp in milliseconds when the key was pressed
    public let timestamp: Int64
    
    /// X coordinate of the key press on the keyboard
    public let xCoordinate: Double
    
    /// Y coordinate of the key press on the keyboard
    public let yCoordinate: Double
    
    public init(key: String, timestamp: Int64, xCoordinate: Double, yCoordinate: Double) {
        self.key = key
        self.timestamp = timestamp
        self.xCoordinate = xCoordinate
        self.yCoordinate = yCoordinate
    }
    
    /// Serialize keystroke to Data for signing
    public func toData() -> Data {
        let string = "\(key)|\(timestamp)|\(xCoordinate)|\(yCoordinate)"
        return string.data(using: .utf8) ?? Data()
    }
    
    /// Hash of the keystroke data using Keccak-256
    public var hash: Data {
        return Keccak256.hash(toData())
    }
}

/// Represents a signed keystroke with user and device signatures
public struct SignedKeystroke: Codable, Equatable {
    /// The original keystroke data
    public let keystroke: Keystroke
    
    /// Signature from user's private key (64 bytes in hex)
    public let userSign: String
    
    /// Signature from device's private key (64 bytes in hex)
    public let deviceSign: String
    
    /// Hash of combined signatures: hash256(userSign || deviceSign)
    public let motionDigest: String
    
    public init(keystroke: Keystroke, userSign: String, deviceSign: String, motionDigest: String) {
        self.keystroke = keystroke
        self.userSign = userSign
        self.deviceSign = deviceSign
        self.motionDigest = motionDigest
    }
}

/// Represents a complete keystroke logging session
public struct KeystrokeSession: Codable, Equatable {
    /// Unique identifier for this session
    public let sessionId: String
    
    /// Start timestamp of the session
    public let startTimestamp: Int64
    
    /// End timestamp of the session (set when finalized)
    public var endTimestamp: Int64?
    
    /// All signed keystrokes in this session
    public var signedKeystrokes: [SignedKeystroke]
    
    /// Hash of the entire session log
    public var sessionHash: String?
    
    /// Human typing evaluation percentage (0-100)
    public var humanTypingScore: Double?
    
    /// Zero-knowledge proof of typing
    public var zkProof: ZKTypingProof?
    
    /// User's public key used for signing (hex)
    public let userPublicKey: String
    
    /// Device's public key used for signing (hex)
    public let devicePublicKey: String
    
    public init(
        sessionId: String,
        startTimestamp: Int64,
        userPublicKey: String,
        devicePublicKey: String
    ) {
        self.sessionId = sessionId
        self.startTimestamp = startTimestamp
        self.userPublicKey = userPublicKey
        self.devicePublicKey = devicePublicKey
        self.signedKeystrokes = []
        self.endTimestamp = nil
        self.sessionHash = nil
        self.humanTypingScore = nil
        self.zkProof = nil
    }
    
    /// Compute the hash of all signed keystrokes in this session
    public mutating func computeSessionHash() -> String {
        var combinedData = Data()
        
        // Add session metadata
        combinedData.append(sessionId.data(using: .utf8) ?? Data())
        combinedData.append(contentsOf: withUnsafeBytes(of: startTimestamp.bigEndian) { Data($0) })
        combinedData.append(userPublicKey.data(using: .utf8) ?? Data())
        combinedData.append(devicePublicKey.data(using: .utf8) ?? Data())
        
        // Add each signed keystroke's motion digest
        for signedKeystroke in signedKeystrokes {
            combinedData.append(signedKeystroke.motionDigest.data(using: .utf8) ?? Data())
        }
        
        let hash = Keccak256.hash(combinedData)
        let hashHex = "0x" + hash.map { String(format: "%02x", $0) }.joined()
        self.sessionHash = hashHex
        return hashHex
    }
    
    /// Get a shortened version of the session hash for display
    public var shortHash: String {
        guard let hash = sessionHash else { return "#pending" }
        guard hash.count >= 12 else { return hash }
        let prefix = String(hash.prefix(6))
        let suffix = String(hash.suffix(3))
        return "#\(prefix)...\(suffix)"
    }
    
    /// Get the typed text from the keystrokes
    public var typedText: String {
        return signedKeystrokes.map { signedKeystroke -> String in
            let key = signedKeystroke.keystroke.key
            // Handle special keys
            switch key {
            case "space": return " "
            case "return", "enter": return "\n"
            case "delete", "backspace": return ""
            default: return key
            }
        }.joined()
    }
}

// MARK: - Zero Knowledge Proof Structure

/// Zero-knowledge proof of human typing
public struct ZKTypingProof: Codable, Equatable {
    /// Version of the proof protocol
    public let version: String
    
    /// Commitment to the keystroke data (blinded hash)
    public let commitment: String
    
    /// Challenge derived from commitment and public parameters
    public let challenge: String
    
    /// Response to the challenge (proves knowledge without revealing data)
    public let response: String
    
    /// Public inputs for verification
    public let publicInputs: ZKPublicInputs
    
    /// Timestamp when proof was generated
    public let generatedAt: Int64
    
    public init(
        version: String,
        commitment: String,
        challenge: String,
        response: String,
        publicInputs: ZKPublicInputs,
        generatedAt: Int64
    ) {
        self.version = version
        self.commitment = commitment
        self.challenge = challenge
        self.response = response
        self.publicInputs = publicInputs
        self.generatedAt = generatedAt
    }
}

/// Public inputs for ZK proof verification
public struct ZKPublicInputs: Codable, Equatable {
    /// Hash of the session log
    public let sessionHash: String
    
    /// Number of keystrokes in the session
    public let keystrokeCount: Int
    
    /// Duration of typing session in milliseconds
    public let typingDuration: Int64
    
    /// User's public key (for signature verification)
    public let userPublicKey: String
    
    /// Device's public key (for signature verification)
    public let devicePublicKey: String
    
    /// Human typing score (0-100)
    public let humanTypingScore: Double
    
    public init(
        sessionHash: String,
        keystrokeCount: Int,
        typingDuration: Int64,
        userPublicKey: String,
        devicePublicKey: String,
        humanTypingScore: Double
    ) {
        self.sessionHash = sessionHash
        self.keystrokeCount = keystrokeCount
        self.typingDuration = typingDuration
        self.userPublicKey = userPublicKey
        self.devicePublicKey = devicePublicKey
        self.humanTypingScore = humanTypingScore
    }
}

// MARK: - Keystroke Signer

/// Utility for signing keystrokes with user and device keys
public struct KeystrokeSigner {
    
    /// Sign a keystroke using user and device private keys
    /// - Parameters:
    ///   - keystroke: The keystroke to sign
    ///   - userPrivateKey: User's private key (32 bytes)
    ///   - devicePrivateKey: Device's private key (32 bytes)
    /// - Returns: SignedKeystroke with both signatures and motion digest
    public static func sign(
        keystroke: Keystroke,
        userPrivateKey: Data,
        devicePrivateKey: Data
    ) -> SignedKeystroke? {
        // Get the hash of the keystroke
        let keystrokeHash = keystroke.hash
        
        // Sign with user's private key
        guard let userSignature = Secp256k1.sign(messageHash: keystrokeHash, with: userPrivateKey) else {
            return nil
        }
        let userSignHex = userSignature.map { String(format: "%02x", $0) }.joined()
        
        // Sign with device's private key
        guard let deviceSignature = Secp256k1.sign(messageHash: keystrokeHash, with: devicePrivateKey) else {
            return nil
        }
        let deviceSignHex = deviceSignature.map { String(format: "%02x", $0) }.joined()
        
        // Compute motion digest: hash256(userSign || deviceSign)
        var combinedSigs = Data()
        combinedSigs.append(userSignature)
        combinedSigs.append(deviceSignature)
        let motionDigest = Keccak256.hash(combinedSigs)
        let motionDigestHex = motionDigest.map { String(format: "%02x", $0) }.joined()
        
        return SignedKeystroke(
            keystroke: keystroke,
            userSign: userSignHex,
            deviceSign: deviceSignHex,
            motionDigest: motionDigestHex
        )
    }
    
    /// Verify a signed keystroke
    /// - Parameters:
    ///   - signedKeystroke: The signed keystroke to verify
    ///   - userPublicKey: User's public key (65 bytes)
    ///   - devicePublicKey: Device's public key (65 bytes)
    /// - Returns: true if both signatures are valid
    public static func verify(
        signedKeystroke: SignedKeystroke,
        userPublicKey: Data,
        devicePublicKey: Data
    ) -> Bool {
        let keystrokeHash = signedKeystroke.keystroke.hash
        
        // Convert hex signatures to Data
        guard let userSignature = hexStringToData(signedKeystroke.userSign),
              let deviceSignature = hexStringToData(signedKeystroke.deviceSign) else {
            return false
        }
        
        // Verify user signature
        let userValid = Secp256k1.verify(
            signature: userSignature,
            for: keystrokeHash,
            publicKey: userPublicKey
        )
        
        // Verify device signature
        let deviceValid = Secp256k1.verify(
            signature: deviceSignature,
            for: keystrokeHash,
            publicKey: devicePublicKey
        )
        
        // Verify motion digest
        var combinedSigs = Data()
        combinedSigs.append(userSignature)
        combinedSigs.append(deviceSignature)
        let expectedDigest = Keccak256.hash(combinedSigs)
        let expectedDigestHex = expectedDigest.map { String(format: "%02x", $0) }.joined()
        let digestValid = expectedDigestHex == signedKeystroke.motionDigest
        
        return userValid && deviceValid && digestValid
    }
    
    /// Convert hex string to Data
    private static func hexStringToData(_ hex: String) -> Data? {
        var hexString = hex
        if hexString.hasPrefix("0x") {
            hexString = String(hexString.dropFirst(2))
        }
        
        guard hexString.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = hexString.startIndex
        
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            let byteString = hexString[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        
        return data
    }
}
