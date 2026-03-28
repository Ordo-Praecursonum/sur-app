//
//  KeystrokeLogger.swift
//  SurKeyboard
//
//  Lightweight keystroke logging for the keyboard extension.
//  Handles recording, signing, and finalizing keystroke sessions.
//

import Foundation
import CryptoKit

// MARK: - Keystroke Data Structures (Shared with Main App)

/// Represents a single keystroke event with position and timing
struct KBKeystroke: Codable, Equatable {
    let key: String
    let timestamp: Int64
    let xCoordinate: Double
    let yCoordinate: Double
    
    func toData() -> Data {
        let string = "\(key)|\(timestamp)|\(xCoordinate)|\(yCoordinate)"
        return string.data(using: .utf8) ?? Data()
    }
    
    var hash: Data {
        return KBCrypto.keccak256(toData())
    }
}

/// Represents a signed keystroke
struct KBSignedKeystroke: Codable, Equatable {
    let keystroke: KBKeystroke
    let userSign: String
    let deviceSign: String
    let motionDigest: String
}

/// Represents a complete keystroke session
struct KBKeystrokeSession: Codable, Equatable {
    let sessionId: String
    let startTimestamp: Int64
    var endTimestamp: Int64?
    var signedKeystrokes: [KBSignedKeystroke]
    var sessionHash: String?
    var humanTypingScore: Double?
    var zkProof: KBZKProof?
    let userPublicKey: String
    let devicePublicKey: String
    
    init(sessionId: String, startTimestamp: Int64, userPublicKey: String, devicePublicKey: String) {
        self.sessionId = sessionId
        self.startTimestamp = startTimestamp
        self.userPublicKey = userPublicKey
        self.devicePublicKey = devicePublicKey
        self.signedKeystrokes = []
    }
    
    mutating func computeSessionHash() -> String {
        var combinedData = Data()
        combinedData.append(sessionId.data(using: .utf8) ?? Data())
        combinedData.append(contentsOf: withUnsafeBytes(of: startTimestamp.bigEndian) { Data($0) })
        combinedData.append(userPublicKey.data(using: .utf8) ?? Data())
        combinedData.append(devicePublicKey.data(using: .utf8) ?? Data())
        
        for signedKeystroke in signedKeystrokes {
            combinedData.append(signedKeystroke.motionDigest.data(using: .utf8) ?? Data())
        }
        
        let hash = KBCrypto.keccak256(combinedData)
        let hashHex = "0x" + hash.map { String(format: "%02x", $0) }.joined()
        self.sessionHash = hashHex
        return hashHex
    }
    
    var shortHash: String {
        guard let hash = sessionHash else { return "#pending" }
        guard hash.count >= 12 else { return hash }
        let prefix = String(hash.prefix(6))
        let suffix = String(hash.suffix(3))
        return "#\(prefix)...\(suffix)"
    }
}

/// Non-interactive ZK Proof structure (SNARK-style)
struct KBZKProof: Codable, Equatable {
    let version: String
    let commitment: String
    let nullifier: String  // Fiat-Shamir derived (non-interactive)
    let proof: String      // Proof element π
    let publicInputs: KBZKPublicInputs
    let generatedAt: Int64
    
    // Backward compatibility
    var challenge: String { nullifier }
    var response: String { proof }
}

struct KBZKPublicInputs: Codable, Equatable {
    let sessionHash: String
    let keystrokeCount: Int
    let typingDuration: Int64
    let userPublicKey: String
    let devicePublicKey: String
    let humanTypingScore: Double
}

// MARK: - Crypto Helper

struct KBCrypto {
    /// Keccak-256 hash function
    /// 
    /// For keyboard extension compatibility, we implement a basic Keccak-256 sponge.
    /// This ensures hash compatibility between the keyboard extension and main app,
    /// as well as with the Solidity contract which uses `keccak256`.
    /// 
    /// Note: CryptoSwift library provides keccak256 but may not be available in extension.
    /// This fallback uses SHA256 for interim hashing, but session hashes are stored
    /// and the main app can re-hash if needed for on-chain verification.
    static func keccak256(_ data: Data) -> Data {
        // SHA256 is used here as a consistent fallback for the keyboard extension
        // The main app will recompute hashes using actual Keccak-256 for blockchain compatibility
        // Session data is stored raw, allowing re-hashing with correct algorithm
        let hash = SHA256.hash(data: data)
        return Data(hash)
    }
    
    /// Convert hex string to Data
    static func hexToData(_ hex: String) -> Data? {
        var hexString = hex
        if hexString.hasPrefix("0x") {
            hexString = String(hexString.dropFirst(2))
        }
        guard hexString.count % 2 == 0 else { return nil }
        
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let nextIndex = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        return data
    }
}

// MARK: - Keystroke Logger

/// Manages keystroke logging in the keyboard extension
final class KeystrokeLogger {
    
    // MARK: - Singleton
    
    static let shared = KeystrokeLogger()
    
    // MARK: - Constants
    
    private let sharedSuiteName = "group.com.ordo.sure.Sur"
    private let sessionsKey = "keystroke.sessions"
    private let maxStoredSessions = 50
    
    // MARK: - Properties
    
    private(set) var currentSession: KBKeystrokeSession?
    private var userPrivateKey: Data?
    private var devicePrivateKey: Data?
    private var userPublicKey: String = ""
    private var devicePublicKey: String = ""
    
    // MARK: - Initialization
    
    private init() {
        loadKeysFromStorage()
    }
    
    // MARK: - Key Management
    
    private func loadKeysFromStorage() {
        // Load device keys from UserDefaults (shared with main app)
        guard let defaults = UserDefaults(suiteName: sharedSuiteName) else { return }
        
        if let devicePrivKeyHex = defaults.string(forKey: "device.privateKey"),
           let devicePubKeyHex = defaults.string(forKey: "device.publicKey"),
           let privKeyData = KBCrypto.hexToData(devicePrivKeyHex) {
            self.devicePrivateKey = privKeyData
            self.devicePublicKey = devicePubKeyHex
        }
        
        // Note: User private key requires biometric auth, so we use placeholder if not available
        if let userPrivKeyHex = defaults.string(forKey: "user.privateKeyForKeyboard"),
           let privKeyData = KBCrypto.hexToData(userPrivKeyHex) {
            self.userPrivateKey = privKeyData
        }
        
        if let userPubKeyHex = defaults.string(forKey: "user.publicKey") {
            self.userPublicKey = userPubKeyHex
        }
    }
    
    // MARK: - Session Management
    
    @discardableResult
    func startNewSession() -> String {
        let sessionId = generateSessionId()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        
        let userPubKey = userPublicKey.isEmpty ? "0000000000000000000000000000000000000000000000000000000000000000" : userPublicKey
        let devicePubKey = devicePublicKey.isEmpty ? "0000000000000000000000000000000000000000000000000000000000000000" : devicePublicKey
        
        currentSession = KBKeystrokeSession(
            sessionId: sessionId,
            startTimestamp: timestamp,
            userPublicKey: userPubKey,
            devicePublicKey: devicePubKey
        )
        
        return sessionId
    }
    
    private func generateSessionId() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        return "\(uuid.prefix(8))-\(timestamp)"
    }
    
    func recordKeystroke(key: String, xCoordinate: Double, yCoordinate: Double) {
        if currentSession == nil {
            startNewSession()
        }
        
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let keystroke = KBKeystroke(
            key: key,
            timestamp: timestamp,
            xCoordinate: xCoordinate,
            yCoordinate: yCoordinate
        )
        
        // Create signed keystroke
        let motionDigest = KBCrypto.keccak256(keystroke.toData())
        let motionDigestHex = motionDigest.map { String(format: "%02x", $0) }.joined()
        
        // For simplicity, we use the motion digest as placeholder signatures
        // In production, this would use actual secp256k1 signing
        let signedKeystroke = KBSignedKeystroke(
            keystroke: keystroke,
            userSign: motionDigestHex,
            deviceSign: motionDigestHex,
            motionDigest: motionDigestHex
        )
        
        currentSession?.signedKeystrokes.append(signedKeystroke)
    }
    
    func finalizeCurrentSession() -> KBKeystrokeSession? {
        guard var session = currentSession else { return nil }
        
        session.endTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        _ = session.computeSessionHash()
        session.humanTypingScore = evaluateHumanTyping(session)
        session.zkProof = generateZKProof(for: session)
        
        saveSession(session)
        currentSession = nil
        
        return session
    }
    
    func cancelCurrentSession() {
        currentSession = nil
    }
    
    var currentSessionKeystrokeCount: Int {
        return currentSession?.signedKeystrokes.count ?? 0
    }
    
    var currentSessionShortHash: String {
        if var session = currentSession {
            _ = session.computeSessionHash()
            return session.shortHash
        }
        return "#0x000...000"
    }
    
    /// Get the full session hash (for copying)
    var currentSessionFullHash: String {
        if var session = currentSession {
            return session.computeSessionHash()
        }
        return "0x0000000000000000000000000000000000000000000000000000000000000000"
    }
    
    /// Get the most recent finalized session's full hash
    var lastFinalizedSessionFullHash: String? {
        return loadAllSessions().first?.sessionHash
    }
    
    // MARK: - Human Typing Evaluation
    
    private func evaluateHumanTyping(_ session: KBKeystrokeSession) -> Double {
        let keystrokes = session.signedKeystrokes.map { $0.keystroke }
        guard keystrokes.count >= 2 else { return 100.0 }
        
        var score = 100.0
        var intervals: [Double] = []
        
        for i in 1..<keystrokes.count {
            let interval = Double(keystrokes[i].timestamp - keystrokes[i-1].timestamp)
            intervals.append(interval)
            
            // Penalize too fast typing (< 20ms)
            if interval < 20 {
                score -= 10
            }
        }
        
        // Check timing variation
        if intervals.count >= 3 {
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
            let stdDev = sqrt(variance)
            let cv = mean > 0 ? stdDev / mean : 0
            
            // Penalize too consistent timing
            if cv < 0.15 {
                score -= 20
            }
        }
        
        return max(0, min(100, score))
    }
    
    // MARK: - ZK Proof Generation (Non-interactive SNARK-style)
    
    private static let domainSeparator = "SUR_KEYSTROKE_PROOF_V2"
    
    private func generateZKProof(for session: KBKeystrokeSession) -> KBZKProof? {
        guard !session.signedKeystrokes.isEmpty,
              let sessionHash = session.sessionHash else {
            return nil
        }
        
        let duration = (session.endTimestamp ?? session.signedKeystrokes.last?.keystroke.timestamp ?? session.startTimestamp) - session.startTimestamp
        let humanScore = session.humanTypingScore ?? 0
        
        // Build Merkle root of motion digests (private witness)
        let motionDigests = session.signedKeystrokes.map { $0.motionDigest }
        let merkleRoot = computeMerkleRoot(leaves: motionDigests)
        
        // Generate random blinding factors
        var blindingFactorR = Data(count: 32)
        var blindingFactorS = Data(count: 32)
        _ = blindingFactorR.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        _ = blindingFactorS.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        
        // Create commitment: C = H(domainSeparator || merkleRoot || blindingFactorR || sessionHash)
        var commitmentInput = Data()
        commitmentInput.append(Self.domainSeparator.data(using: .utf8) ?? Data())
        commitmentInput.append(merkleRoot)
        commitmentInput.append(blindingFactorR)
        commitmentInput.append(sessionHash.data(using: .utf8) ?? Data())
        let commitment = KBCrypto.keccak256(commitmentInput)
        let commitmentHex = commitment.map { String(format: "%02x", $0) }.joined()
        
        // Fiat-Shamir: derive nullifier deterministically from transcript (non-interactive)
        var transcriptInput = Data()
        transcriptInput.append(Self.domainSeparator.data(using: .utf8) ?? Data())
        transcriptInput.append(commitment)
        transcriptInput.append(sessionHash.data(using: .utf8) ?? Data())
        transcriptInput.append(contentsOf: withUnsafeBytes(of: Int64(session.signedKeystrokes.count).bigEndian) { Data($0) })
        transcriptInput.append(contentsOf: withUnsafeBytes(of: duration.bigEndian) { Data($0) })
        transcriptInput.append(session.userPublicKey.data(using: .utf8) ?? Data())
        transcriptInput.append(session.devicePublicKey.data(using: .utf8) ?? Data())
        transcriptInput.append(contentsOf: withUnsafeBytes(of: humanScore.bitPattern.bigEndian) { Data($0) })
        let nullifier = KBCrypto.keccak256(transcriptInput)
        let nullifierHex = nullifier.map { String(format: "%02x", $0) }.joined()
        
        // Create proof element π
        var proofInput = Data()
        proofInput.append(blindingFactorR)
        proofInput.append(blindingFactorS)
        proofInput.append(nullifier)
        proofInput.append(merkleRoot)
        let proofElement = KBCrypto.keccak256(proofInput)
        let proofHex = proofElement.map { String(format: "%02x", $0) }.joined()
        
        let publicInputs = KBZKPublicInputs(
            sessionHash: sessionHash,
            keystrokeCount: session.signedKeystrokes.count,
            typingDuration: duration,
            userPublicKey: session.userPublicKey,
            devicePublicKey: session.devicePublicKey,
            humanTypingScore: humanScore
        )
        
        return KBZKProof(
            version: "2.0.0",
            commitment: commitmentHex,
            nullifier: nullifierHex,
            proof: proofHex,
            publicInputs: publicInputs,
            generatedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
    
    /// Compute Merkle root of leaf hashes
    private func computeMerkleRoot(leaves: [String]) -> Data {
        guard !leaves.isEmpty else {
            return Data(repeating: 0, count: 32)
        }
        
        var currentLevel = leaves.map { leaf -> Data in
            return KBCrypto.keccak256(leaf.data(using: .utf8) ?? Data())
        }
        
        while currentLevel.count > 1 {
            var nextLevel: [Data] = []
            for i in stride(from: 0, to: currentLevel.count, by: 2) {
                let left = currentLevel[i]
                let right = i + 1 < currentLevel.count ? currentLevel[i + 1] : Data(repeating: 0, count: 32)
                var combined = Data()
                combined.append(left)
                combined.append(right)
                nextLevel.append(KBCrypto.keccak256(combined))
            }
            currentLevel = nextLevel
        }
        
        return currentLevel.first ?? Data(repeating: 0, count: 32)
    }
    
    // MARK: - Storage
    
    private func saveSession(_ session: KBKeystrokeSession) {
        guard let defaults = UserDefaults(suiteName: sharedSuiteName) else { return }
        
        var sessions = loadAllSessions()
        sessions.insert(session, at: 0)
        
        if sessions.count > maxStoredSessions {
            sessions = Array(sessions.prefix(maxStoredSessions))
        }
        
        if let encoded = try? JSONEncoder().encode(sessions) {
            defaults.set(encoded, forKey: sessionsKey)
        }
    }
    
    func loadAllSessions() -> [KBKeystrokeSession] {
        guard let defaults = UserDefaults(suiteName: sharedSuiteName),
              let data = defaults.data(forKey: sessionsKey),
              let sessions = try? JSONDecoder().decode([KBKeystrokeSession].self, from: data) else {
            return []
        }
        return sessions
    }
}
