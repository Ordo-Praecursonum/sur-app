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
    
    /// Hash of combined signatures: Keccak-256(userSign || deviceSign)
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

    /// Human typing evaluation percentage (0-100) — computed locally, not sent on-chain
    public var humanTypingScore: Double?

    /// Zero-knowledge proof of typing
    public var zkProof: ZKTypingProof?

    /// User's public key used for signing (hex)
    public let userPublicKey: String

    /// Device's public key used for signing (hex)
    public let devicePublicKey: String

    // MARK: - Identity Layer Fields (ZK circuit private inputs)
    // Populated by AuthenticationManager once the user has a registered Cosmos identity.
    // Stored locally so the prover can reconstruct inputs across app launches.
    // These are private witnesses — never sent as public on-chain data.

    /// Poseidon(username_bytes) over BN254 — fed into the gnark circuit as a public input.
    public var usernameHash: String?

    /// P-256 Secure Enclave device public key X coordinate (hex, reduced mod BN254 r).
    public var devicePubkeyX: String?

    /// P-256 Secure Enclave device public key Y coordinate (hex, reduced mod BN254 r).
    public var devicePubkeyY: String?

    /// Monotonically increasing per-device session counter (prevents nullifier reuse).
    public var sessionCounter: UInt64?

    /// Root of the device commitment Merkle tree (fetched from Cosmos x/identity).
    public var commitmentRoot: String?

    /// Merkle inclusion proof — sibling hashes at each level (8 elements for depth-8 tree).
    public var merklePath: [String]?

    /// Merkle path direction bits (0 = leaf is left child, 1 = right child).
    public var merkleDirections: [Int]?

    /// Secure Enclave ECDSA signature R over the session bundle (used as circuit witness).
    public var seSignatureR: String?

    /// Secure Enclave ECDSA signature S over the session bundle.
    public var seSignatureS: String?

    /// Private behavioral witness — populated when ZK proof is generated, NOT serialized on-chain.
    /// Excluded from Codable so it is never persisted or transmitted as public data.
    public var behavioralWitness: ZKBehavioralWitness?

    // Exclude behavioralWitness from Codable (it is always recomputed, never stored)
    private enum CodingKeys: String, CodingKey {
        case sessionId, startTimestamp, endTimestamp, signedKeystrokes
        case sessionHash, humanTypingScore, zkProof, userPublicKey, devicePublicKey
        case usernameHash, devicePubkeyX, devicePubkeyY, sessionCounter
        case commitmentRoot, merklePath, merkleDirections, seSignatureR, seSignatureS
    }

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
        self.behavioralWitness = nil
        self.usernameHash = nil
        self.devicePubkeyX = nil
        self.devicePubkeyY = nil
        self.sessionCounter = nil
        self.commitmentRoot = nil
        self.merklePath = nil
        self.merkleDirections = nil
        self.seSignatureR = nil
        self.seSignatureS = nil
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
    
    /// Get the typed text from the keystrokes.
    /// Replays deletes as removing the previous character rather than a no-op —
    /// this is the exact text that gets attested on-chain, so it must match what
    /// actually ended up on screen, including corrections.
    public var typedText: String {
        var result = ""
        for signedKeystroke in signedKeystrokes {
            let key = signedKeystroke.keystroke.key
            switch key {
            case "space": result.append(" ")
            case "return", "enter": result.append("\n")
            case "delete", "backspace":
                if !result.isEmpty { result.removeLast() }
            default: result.append(key)
            }
        }
        return result
    }
}

// MARK: - KeystrokeSession Equatable

// behavioralWitness is excluded from equality — it is a transient value
// recomputed during proof generation and excluded from Codable.
// Two sessions are equal when all their persisted (Codable) fields match.
extension KeystrokeSession {
    public static func == (lhs: KeystrokeSession, rhs: KeystrokeSession) -> Bool {
        lhs.sessionId          == rhs.sessionId          &&
        lhs.startTimestamp     == rhs.startTimestamp     &&
        lhs.endTimestamp       == rhs.endTimestamp       &&
        lhs.signedKeystrokes   == rhs.signedKeystrokes   &&
        lhs.sessionHash        == rhs.sessionHash        &&
        lhs.humanTypingScore   == rhs.humanTypingScore   &&
        lhs.zkProof            == rhs.zkProof            &&
        lhs.userPublicKey      == rhs.userPublicKey      &&
        lhs.devicePublicKey    == rhs.devicePublicKey    &&
        lhs.usernameHash       == rhs.usernameHash       &&
        lhs.devicePubkeyX      == rhs.devicePubkeyX     &&
        lhs.devicePubkeyY      == rhs.devicePubkeyY     &&
        lhs.sessionCounter     == rhs.sessionCounter     &&
        lhs.commitmentRoot     == rhs.commitmentRoot     &&
        lhs.merklePath         == rhs.merklePath         &&
        lhs.merkleDirections   == rhs.merkleDirections   &&
        lhs.seSignatureR       == rhs.seSignatureR       &&
        lhs.seSignatureS       == rhs.seSignatureS
    }
}

// MARK: - Zero Knowledge Proof Structure

/// Non-interactive zero-knowledge proof of human typing (SNARK-style)
/// Uses Fiat-Shamir heuristic for non-interactivity
public struct ZKTypingProof: Codable, Equatable {
    /// Version of the proof protocol (2.0.0 = non-interactive SNARK-style)
    public let version: String
    
    /// Commitment to the keystroke data (Pedersen-style commitment)
    public let commitment: String
    
    /// Nullifier derived via Fiat-Shamir transform (deterministic, non-interactive)
    /// This replaces the interactive "challenge" - derived from transcript hash
    public let nullifier: String
    
    /// Proof element π (proves knowledge of witness without revealing it)
    /// This replaces the interactive "response"
    public let proof: String
    
    /// Public inputs for verification
    public let publicInputs: ZKPublicInputs
    
    /// Timestamp when proof was generated
    public let generatedAt: Int64
    
    public init(
        version: String,
        commitment: String,
        nullifier: String,
        proof: String,
        publicInputs: ZKPublicInputs,
        generatedAt: Int64
    ) {
        self.version = version
        self.commitment = commitment
        self.nullifier = nullifier
        self.proof = proof
        self.publicInputs = publicInputs
        self.generatedAt = generatedAt
    }
    
    // MARK: - Backward Compatibility

    /// Backward compatibility: challenge maps to nullifier
    public var challenge: String { nullifier }

    /// Backward compatibility: response maps to proof
    public var response: String { proof }

    // MARK: - gnark Verifier Format

    /// Returns the 5 public inputs as hex strings in the order the gnark verifier expects:
    /// [usernameHash, contentHashLo, contentHashHi, nullifier, commitmentRoot]
    public func publicInputsArray() -> [String] {
        return [
            publicInputs.usernameHash,
            publicInputs.contentHashLo,
            publicInputs.contentHashHi,
            publicInputs.nullifier,
            publicInputs.commitmentRoot
        ]
    }
}

/// Public inputs for gnark Groth16 proof verification.
/// These are the ONLY values revealed to the verifier.
/// All behavioral statistics (WPM, IKI, typing score) remain private witnesses.
public struct ZKPublicInputs: Codable, Equatable {
    /// Poseidon(username_utf8_bytes) over BN254 — identifies the user account
    public let usernameHash: String

    /// Low 128 bits of Poseidon(content) — content binding
    public let contentHashLo: String

    /// High 128 bits of Poseidon(content) — content binding
    public let contentHashHi: String

    /// Poseidon(usernameHash, sessionCounter, blindingFactor) — prevents double-use
    public let nullifier: String

    /// Root of the device commitment Merkle tree
    public let commitmentRoot: String

    public init(
        usernameHash: String,
        contentHashLo: String,
        contentHashHi: String,
        nullifier: String,
        commitmentRoot: String
    ) {
        self.usernameHash = usernameHash
        self.contentHashLo = contentHashLo
        self.contentHashHi = contentHashHi
        self.nullifier = nullifier
        self.commitmentRoot = commitmentRoot
    }
}

/// Private witness data for ZK circuit — never leaves the device as public data.
/// The circuit proves these constraints are satisfied without revealing the values.
public struct ZKBehavioralWitness {
    /// Human typing score 0–100 (circuit enforces >= 50)
    public let humanScore: Int
    /// IKI values in milliseconds (circuit enforces 20ms–2000ms range)
    public let ikiValuesMs: [Int]
    /// Number of keystrokes (circuit enforces >= 10)
    public let keystrokeCount: Int
    /// Typing duration in ms (derived from IKI values — not separately constrained)
    public let typingDurationMs: Int64

    public init(
        humanScore: Int,
        ikiValuesMs: [Int],
        keystrokeCount: Int,
        typingDurationMs: Int64
    ) {
        self.humanScore = humanScore
        self.ikiValuesMs = ikiValuesMs
        self.keystrokeCount = keystrokeCount
        self.typingDurationMs = typingDurationMs
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
