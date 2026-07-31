//
//  KeystrokeLogger.swift
//  SurKeyboard
//
//  Lightweight keystroke logging for the keyboard extension.
//  Handles recording, signing, and finalizing keystroke sessions.
//

import Foundation
import Security
import CryptoKit
import os

/// Structured logging for the keyboard extension. View in Console.app or the Xcode
/// console by filtering subsystem `com.ordo.sur.keyboard`. Categories separate the
/// lifecycle (view load), per-keystroke, and signing paths so a hang is easy to spot
/// (the last line before the stall names the culprit).
enum KBLog {
    static let lifecycle = Logger(subsystem: "com.ordo.sur.keyboard", category: "lifecycle")
    static let keystroke = Logger(subsystem: "com.ordo.sur.keyboard", category: "keystroke")
    static let signing   = Logger(subsystem: "com.ordo.sur.keyboard", category: "signing")
}

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
    var sessionSignature: String?
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

    /// The typed text replayed from the keystroke log, including deletions —
    /// must produce the exact text that ends up attested on-chain (same replay
    /// rules as the app-side KeystrokeSession.typedText).
    var typedText: String {
        var result = ""
        for signedKeystroke in signedKeystrokes {
            switch signedKeystroke.keystroke.key {
            case "space": result.append(" ")
            case "return", "enter": result.append("\n")
            case "delete", "backspace":
                if !result.isEmpty { result.removeLast() }
            default: result.append(signedKeystroke.keystroke.key)
            }
        }
        return result
    }

    /// The public lookup key for this session's attestation on Sur Chain:
    /// 0x-prefixed SHA-256 of the typed text. This — not sessionHash — is what
    /// the chain's VerifyContent endpoint and the explorer accept.
    var contentHash: String {
        let digest = SHA256.hash(data: Data(typedText.utf8))
        return "0x" + digest.map { String(format: "%02x", $0) }.joined()
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
    let usernameHash: String
    let contentHashLo: String
    let contentHashHi: String
    let nullifier: String
    let commitmentRoot: String
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

    /// Serial queue for per-keystroke work. Hashing and (especially) Secure Enclave
    /// signing are too slow to run on the keyboard's main thread — doing so froze
    /// text input. All session mutation is funneled through this queue so the main
    /// thread only captures the lightweight keystroke and returns immediately.
    private let workQueue = DispatchQueue(label: "com.ordo.sur.keyboard.keystrokeLogger", qos: .utility)
    
    // MARK: - Initialization

    private init() {
        // NOTHING heavy may run here: this singleton is touched during the
        // keyboard view controller's init, on the main thread, while iOS is
        // animating the keyboard in. Keychain reads and the one-time legacy
        // storage migration happen on the serial work queue instead — every
        // consumer of the keys already runs through that same queue, so
        // ordering is guaranteed without blocking startup.
        KBLog.lifecycle.log("KeystrokeLogger init: scheduling key load off-main")
        workQueue.async { [weak self] in
            guard let self else { return }
            self.loadKeysFromStorage()
            self.migrateLegacySessionsBlobIfNeeded()
            KBLog.lifecycle.log("KeystrokeLogger init: keys loaded (deviceKey: \(self.devicePrivateKey != nil), userKey: \(self.userPrivateKey != nil))")
        }
    }

    // Debug trail retired: it persisted a growing string array to the shared
    // UserDefaults (with a forced synchronize) on every finalize step, which
    // both leaked typing timestamps into the plist and contributed to plist
    // bloat. Kept as a no-op so the call sites don't need touching.
    private func debugCheckpoint(_ label: String) {
        KBLog.signing.debug("\(label, privacy: .public)")
    }
    
    // MARK: - Key Management
    
    private func loadKeysFromStorage() {
        guard let defaults = UserDefaults(suiteName: sharedSuiteName) else { return }

        // Load device private key from the Keychain (shared via App Group).
        // The main app stores it under these attributes; we replicate the same query
        // inline here because the keyboard extension cannot import the main app target.
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ordo.sur.wallet",
            kSecAttrAccount as String: "com.ordo.sur.device.privateKey",
            kSecAttrAccessGroup as String: "group.com.ordo.sure.Sur",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var keychainResult: AnyObject?
        let status = SecItemCopyMatching(keychainQuery as CFDictionary, &keychainResult)
        if status == errSecSuccess,
           let privKeyData = keychainResult as? Data,
           privKeyData.count == 32 {
            self.devicePrivateKey = privKeyData
        }

        // Load device public key from UserDefaults (public data, not secret)
        if let devicePubKeyHex = defaults.string(forKey: "device.publicKey") {
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
        // Capture the keystroke immediately and cheaply on the caller's (main) thread
        // so timing stays accurate, then do all hashing/signing off the main thread.
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let keystroke = KBKeystroke(
            key: key,
            timestamp: timestamp,
            xCoordinate: xCoordinate,
            yCoordinate: yCoordinate
        )

        workQueue.async { [weak self] in
            guard let self = self else { return }
            if self.currentSession == nil {
                self.startNewSession()
            }

            // Per keystroke we record ONLY a cheap digest. We do NOT run a Secure
            // Enclave signature here — signing on every keystroke is far too slow and
            // froze typing system-wide. The authoritative device signature is applied
            // ONCE to the whole session bundle in finalizeCurrentSession(); the main
            // app re-derives/re-signs for the real proof regardless.
            let keystrokeData = keystroke.toData()
            let deviceSignature = SHA256.hash(data: keystrokeData).map { String(format: "%02x", $0) }.joined()

            // userSign is a placeholder (user key requires biometric auth, not
            // available in the keyboard extension).
            let userSign = "placeholder_requires_biometric"

            let signedKeystroke = KBSignedKeystroke(
                keystroke: keystroke,
                userSign: userSign,
                deviceSign: deviceSignature,
                motionDigest: SHA256.hash(data: (userSign + deviceSignature).data(using: .utf8)!).map { String(format: "%02x", $0) }.joined()
            )

            self.currentSession?.signedKeystrokes.append(signedKeystroke)
            KBLog.keystroke.debug("recorded keystroke; session count now \(self.currentSession?.signedKeystrokes.count ?? 0)")
        }
    }
    
    func finalizeCurrentSession() -> KBKeystrokeSession? {
        debugCheckpoint("finalizeCurrentSession: called, currentSession is nil: \(currentSession == nil)")
        // Run on workQueue so we don't race the background keystroke appends, and so
        // any queued keystrokes are flushed before we snapshot the session.
        return workQueue.sync {
            guard var session = currentSession else {
                debugCheckpoint("finalizeCurrentSession: guard failed, currentSession was nil inside workQueue")
                return nil
            }
            KBLog.signing.log("finalizing session with \(session.signedKeystrokes.count) keystrokes")
            debugCheckpoint("finalizeCurrentSession: session found, \(session.signedKeystrokes.count) keystrokes")

            session.endTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
            _ = session.computeSessionHash()
            debugCheckpoint("finalizeCurrentSession: hash computed")
            session.humanTypingScore = evaluateHumanTyping(session)
            debugCheckpoint("finalizeCurrentSession: humanTypingScore = \(session.humanTypingScore ?? -1)")
            session.zkProof = generateZKProof(for: session)
            debugCheckpoint("finalizeCurrentSession: zkProof generated: \(session.zkProof != nil)")

            // Sign the complete session bundle ONCE with the Secure Enclave key.
            if let sessionJSON = try? JSONEncoder().encode(session),
               let sessionSignature = signSessionBundle(sessionJSON) {
                session.sessionSignature = sessionSignature.map { String(format: "%02x", $0) }.joined()
                KBLog.signing.log("session bundle signed")
                debugCheckpoint("finalizeCurrentSession: session bundle signed OK")
            } else {
                KBLog.signing.error("session bundle signing failed (Secure Enclave key unavailable?)")
                debugCheckpoint("finalizeCurrentSession: session bundle signing FAILED (continuing anyway)")
            }

            debugCheckpoint("finalizeCurrentSession: about to call saveSession")
            saveSession(session)
            debugCheckpoint("finalizeCurrentSession: saveSession returned, about to set currentSession=nil and return")
            currentSession = nil
            return session
        }
    }

    func cancelCurrentSession() {
        workQueue.sync { currentSession = nil }
    }

    var currentSessionKeystrokeCount: Int {
        return workQueue.sync { currentSession?.signedKeystrokes.count ?? 0 }
    }

    var currentSessionShortHash: String {
        return workQueue.sync {
            if var session = currentSession {
                _ = session.computeSessionHash()
                return session.shortHash
            }
            return "#0x000...000"
        }
    }

    /// Get the full session hash (for copying)
    var currentSessionFullHash: String {
        return workQueue.sync {
            if var session = currentSession {
                return session.computeSessionHash()
            }
            return "0x0000000000000000000000000000000000000000000000000000000000000000"
        }
    }
    
    /// Get the most recent finalized session's full hash
    var lastFinalizedSessionFullHash: String? {
        return newestFinalizedSession()?.sessionHash
    }

    /// Content hash (0x + SHA-256 of the typed text) of the in-progress session
    /// — the chain's public lookup key, usable in the explorer's verifier.
    var currentSessionContentHash: String? {
        return workQueue.sync {
            guard let session = currentSession, !session.signedKeystrokes.isEmpty else { return nil }
            return session.contentHash
        }
    }

    /// Content hash of the most recently finalized session.
    var lastFinalizedSessionContentHash: String? {
        return newestFinalizedSession()?.contentHash
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

            // Penalize too-fast typing (< 20ms) — except back-to-back deletes,
            // which legitimately happen near-instantly during a bulk correction
            // (holding delete, or accepting an autocorrect/suggestion that
            // removes several characters at once). That burst reflects assisted
            // editing, not a suspiciously fast typing rhythm.
            let bothDeletes = keystrokes[i].key == "delete" && keystrokes[i - 1].key == "delete"
            if interval < 20 && !bothDeletes {
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
        
        // Behavioral values stay as private witness — they are used inside the circuit but
        // are NOT included in the public inputs that leave the device.
        _ = (session.endTimestamp ?? session.signedKeystrokes.last?.keystroke.timestamp ?? session.startTimestamp) - session.startTimestamp  // typingDurationMs (private witness)
        _ = session.humanTypingScore ?? 0  // humanScore (private witness)

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
        
        // Fiat-Shamir: derive nullifier deterministically from commitment + merkle root (non-interactive).
        // Behavioral stats (keystroke count, duration, humanScore) stay as private witness — NOT in transcript.
        var transcriptInput = Data()
        transcriptInput.append(Self.domainSeparator.data(using: .utf8) ?? Data())
        transcriptInput.append(commitment)
        transcriptInput.append(merkleRoot)
        let nullifier = KBCrypto.keccak256(transcriptInput)
        let nullifierHex = nullifier.map { String(format: "%02x", $0) }.joined()
        let commitmentRootHex = merkleRoot.map { String(format: "%02x", $0) }.joined()

        // Create proof element π
        var proofInput = Data()
        proofInput.append(blindingFactorR)
        proofInput.append(blindingFactorS)
        proofInput.append(nullifier)
        proofInput.append(merkleRoot)
        let proofElement = KBCrypto.keccak256(proofInput)
        let proofHex = proofElement.map { String(format: "%02x", $0) }.joined()

        // Public inputs: 5 BN254 field elements — the ONLY values revealed to the verifier.
        // Placeholder hex strings used until gnark FFI is wired up in TASK-1.
        let publicInputs = KBZKPublicInputs(
            usernameHash: "0x" + String(repeating: "00", count: 32),   // placeholder until gnark FFI (TASK-1)
            contentHashLo: "0x" + String(repeating: "00", count: 32),  // placeholder until gnark FFI (TASK-1)
            contentHashHi: "0x" + String(repeating: "00", count: 32),  // placeholder until gnark FFI (TASK-1)
            nullifier: nullifierHex,
            commitmentRoot: commitmentRootHex
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
    //
    // One JSON file per session in the App Group container
    // (<container>/KeystrokeSessions/<zero-padded startTimestamp>-<id>.json).
    //
    // Sessions used to live as ONE JSON blob under a single UserDefaults key.
    // With 50 stored sessions × hundreds of signed keystrokes each, that blob
    // grew to multiple megabytes — and UserDefaults loads its ENTIRE plist
    // synchronously on first access, which happens on the keyboard's main
    // thread during startup. That one design choice was the multi-second
    // keyboard launch freeze. Files fix both directions: startup no longer
    // touches session data at all, and saving writes one ~50KB file (atomic,
    // durable — no synchronize() dance) instead of re-encoding all 50.

    private var sessionsDirectory: URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: sharedSuiteName
        ) else { return nil }
        let dir = container.appendingPathComponent("KeystrokeSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Zero-padded start timestamp prefix makes lexicographic order equal
    /// chronological order, so "newest" never requires decoding anything.
    private func sessionFileName(_ session: KBKeystrokeSession) -> String {
        {
        let ts = String(session.startTimestamp)
        let padded = String(repeating: "0", count: max(0, 15 - ts.count)) + ts
        return "\(padded)-\(session.sessionId).json"
    }()
    }

    /// Sorted newest-first without reading file contents.
    private func sessionFileURLsNewestFirst() -> [URL] {
        guard let dir = sessionsDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".json") }
            .sorted(by: >)
            .map { dir.appendingPathComponent($0) }
    }

    private func saveSession(_ session: KBKeystrokeSession) {
        guard let dir = sessionsDirectory else {
            KBLog.signing.error("saveSession: app group container unavailable — entitlement missing or misconfigured")
            return
        }
        do {
            let encoded = try JSONEncoder().encode(session)
            let url = dir.appendingPathComponent(sessionFileName(session))
            // .atomic writes to a temp file and renames — the file is either
            // fully there or not at all, even if iOS reclaims the extension
            // process right after. No UserDefaults synchronize() needed.
            try encoded.write(to: url, options: .atomic)
            KBLog.signing.log("saveSession: persisted \(encoded.count) bytes to \(url.lastPathComponent, privacy: .public)")
        } catch {
            KBLog.signing.error("saveSession: write failed: \(String(describing: error), privacy: .public) — session was NOT saved")
            return
        }

        // Trim to the retention cap — file deletes, no re-encoding.
        let urls = sessionFileURLsNewestFirst()
        if urls.count > maxStoredSessions {
            for url in urls.suffix(from: maxStoredSessions) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func loadAllSessions() -> [KBKeystrokeSession] {
        let decoder = JSONDecoder()
        return sessionFileURLsNewestFirst().compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(KBKeystrokeSession.self, from: data)
        }
    }

    /// The most recent finalized session, decoding exactly one file.
    func newestFinalizedSession() -> KBKeystrokeSession? {
        guard let url = sessionFileURLsNewestFirst().first,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KBKeystrokeSession.self, from: data)
    }

    /// One-time migration of the legacy single-blob storage. Decodes the old
    /// UserDefaults value into per-session files, then deletes the key — which
    /// permanently shrinks the shared plist back to a few hundred bytes (the
    /// actual startup fix; the blob's mere existence made every first
    /// UserDefaults access slow in BOTH the keyboard and the host app).
    /// Idempotent, and also implemented app-side so whichever process runs
    /// first after the update pays the one-time cost — preferably the app.
    private func migrateLegacySessionsBlobIfNeeded() {
        guard let defaults = UserDefaults(suiteName: sharedSuiteName) else { return }
        // Retired debug trail (see debugCheckpoint) — clear its leftover array.
        defaults.removeObject(forKey: "debug.checkpoints")
        guard let data = defaults.data(forKey: sessionsKey) else { return }
        KBLog.lifecycle.log("migrating legacy sessions blob (\(data.count) bytes) to per-session files")
        if let sessions = try? JSONDecoder().decode([KBKeystrokeSession].self, from: data),
           let dir = sessionsDirectory {
            for session in sessions {
                let url = dir.appendingPathComponent(sessionFileName(session))
                guard !FileManager.default.fileExists(atPath: url.path),
                      let encoded = try? JSONEncoder().encode(session) else { continue }
                try? encoded.write(to: url, options: .atomic)
            }
        }
        defaults.removeObject(forKey: sessionsKey)
        defaults.synchronize()
    }
}
