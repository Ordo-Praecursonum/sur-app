//
//  KeystrokeLogManager.swift
//  Sur
//
//  Manager for keystroke logging sessions with storage capabilities.
//  Handles session creation, storage, and retrieval.
//

import Foundation

/// Manages keystroke logging sessions and their storage
public final class KeystrokeLogManager {
    
    // MARK: - Singleton
    
    public static let shared = KeystrokeLogManager()
    
    // MARK: - Constants
    
    /// UserDefaults suite for sharing data with keyboard extension
    private let sharedSuiteName = "group.com.ordo.sure.Sur"
    
    /// Key for storing sessions in UserDefaults
    private let sessionsKey = "keystroke.sessions"
    
    /// Maximum number of sessions to keep
    private let maxStoredSessions = 50
    
    // MARK: - Properties
    
    /// Current active session (nil if no session is active)
    public private(set) var currentSession: KeystrokeSession?
    
    /// User's private key for signing (must be set before creating sessions)
    private var userPrivateKey: Data?
    
    /// Device's private key for signing (must be set before creating sessions)
    private var devicePrivateKey: Data?
    
    /// User's public key (hex string)
    private var userPublicKey: String?
    
    /// Device's public key (hex string)
    private var devicePublicKey: String?
    
    // MARK: - Initialization
    
    private init() {
        loadKeysFromStorage()
    }
    
    // MARK: - Key Management
    
    /// Set the signing keys for keystroke logging
    /// - Parameters:
    ///   - userPrivateKey: User's private key (32 bytes)
    ///   - userPublicKey: User's public key (65 bytes)
    ///   - devicePrivateKey: Device's private key (32 bytes)
    ///   - devicePublicKey: Device's public key (65 bytes)
    public func setSigningKeys(
        userPrivateKey: Data,
        userPublicKey: Data,
        devicePrivateKey: Data,
        devicePublicKey: Data
    ) {
        self.userPrivateKey = userPrivateKey
        self.devicePrivateKey = devicePrivateKey
        self.userPublicKey = userPublicKey.map { String(format: "%02x", $0) }.joined()
        self.devicePublicKey = devicePublicKey.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Load keys from storage (if available)
    private func loadKeysFromStorage() {
        // Try to load device keys from DeviceIDManager
        if let devicePrivKey = DeviceIDManager.shared.getStoredDevicePrivateKey(),
           let devicePubKey = DeviceIDManager.shared.getStoredDevicePublicKey() {
            self.devicePrivateKey = devicePrivKey
            self.devicePublicKey = devicePubKey.map { String(format: "%02x", $0) }.joined()
        }
        
        // Note: User private key should be loaded from SecureEnclaveManager
        // This requires biometric authentication, so it's done on demand
    }
    
    /// Check if signing keys are available
    public var hasSigningKeys: Bool {
        return userPrivateKey != nil && devicePrivateKey != nil
    }
    
    // MARK: - Session Management
    
    /// Start a new keystroke logging session
    /// - Returns: Session ID or nil if keys are not set
    @discardableResult
    public func startNewSession() -> String? {
        guard let userPubKey = userPublicKey,
              let devicePubKey = devicePublicKey else {
            // Generate placeholder keys if not available
            // This allows the keyboard to work without full wallet setup
            let placeholderUserPubKey = "0000000000000000000000000000000000000000000000000000000000000000"
            let placeholderDevicePubKey = "0000000000000000000000000000000000000000000000000000000000000000"
            
            let sessionId = generateSessionId()
            let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
            
            currentSession = KeystrokeSession(
                sessionId: sessionId,
                startTimestamp: timestamp,
                userPublicKey: placeholderUserPubKey,
                devicePublicKey: placeholderDevicePubKey
            )
            
            return sessionId
        }
        
        let sessionId = generateSessionId()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        
        currentSession = KeystrokeSession(
            sessionId: sessionId,
            startTimestamp: timestamp,
            userPublicKey: userPubKey,
            devicePublicKey: devicePubKey
        )
        
        return sessionId
    }
    
    /// Generate a unique session ID
    private func generateSessionId() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        return "\(uuid.prefix(8))-\(timestamp)"
    }
    
    /// Record a keystroke in the current session
    /// - Parameters:
    ///   - key: The key pressed
    ///   - xCoordinate: X position of the key press
    ///   - yCoordinate: Y position of the key press
    public func recordKeystroke(key: String, xCoordinate: Double, yCoordinate: Double) {
        guard currentSession != nil else {
            // Start a new session automatically if none exists
            startNewSession()
            recordKeystroke(key: key, xCoordinate: xCoordinate, yCoordinate: yCoordinate)
            return
        }
        
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        let keystroke = Keystroke(
            key: key,
            timestamp: timestamp,
            xCoordinate: xCoordinate,
            yCoordinate: yCoordinate
        )
        
        // Sign the keystroke if keys are available
        if let userPrivKey = userPrivateKey,
           let devicePrivKey = devicePrivateKey,
           let signedKeystroke = KeystrokeSigner.sign(
               keystroke: keystroke,
               userPrivateKey: userPrivKey,
               devicePrivateKey: devicePrivKey
           ) {
            currentSession?.signedKeystrokes.append(signedKeystroke)
        } else {
            // Create an unsigned placeholder
            let placeholderSigned = SignedKeystroke(
                keystroke: keystroke,
                userSign: "unsigned",
                deviceSign: "unsigned",
                motionDigest: Keccak256.hashToHex(keystroke.toData())
            )
            currentSession?.signedKeystrokes.append(placeholderSigned)
        }
    }
    
    /// Finalize the current session
    /// - Returns: The finalized session with hash and evaluation, or nil if no session
    public func finalizeCurrentSession() -> KeystrokeSession? {
        guard var session = currentSession else { return nil }
        
        // Set end timestamp
        session.endTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        
        // Compute session hash
        _ = session.computeSessionHash()
        
        // Evaluate human typing
        session.humanTypingScore = HumanTypingEvaluator.evaluate(session: session)
        
        // Generate ZK proof
        session.zkProof = ZKProofGenerator.generateProof(for: session)
        
        // Save the session
        saveSession(session)
        
        // Clear current session
        currentSession = nil
        
        return session
    }
    
    /// Cancel the current session without saving
    public func cancelCurrentSession() {
        currentSession = nil
    }
    
    /// Get the number of keystrokes in current session
    public var currentSessionKeystrokeCount: Int {
        return currentSession?.signedKeystrokes.count ?? 0
    }
    
    /// Get the current session's short hash (for display)
    public var currentSessionShortHash: String {
        if var session = currentSession {
            _ = session.computeSessionHash()
            return session.shortHash
        }
        return "#0x000...000"
    }
    
    // MARK: - Storage
    
    /// Save a session to storage
    private func saveSession(_ session: KeystrokeSession) {
        guard let defaults = UserDefaults(suiteName: sharedSuiteName) else { return }
        
        var sessions = loadAllSessions()
        sessions.insert(session, at: 0)
        
        // Trim to max stored sessions
        if sessions.count > maxStoredSessions {
            sessions = Array(sessions.prefix(maxStoredSessions))
        }
        
        // Encode and save
        if let encoded = try? JSONEncoder().encode(sessions) {
            defaults.set(encoded, forKey: sessionsKey)
        }
    }
    
    /// Load all stored sessions
    public func loadAllSessions() -> [KeystrokeSession] {
        guard let defaults = UserDefaults(suiteName: sharedSuiteName),
              let data = defaults.data(forKey: sessionsKey),
              let sessions = try? JSONDecoder().decode([KeystrokeSession].self, from: data) else {
            return []
        }
        return sessions
    }
    
    /// Get a specific session by ID
    public func getSession(byId sessionId: String) -> KeystrokeSession? {
        return loadAllSessions().first { $0.sessionId == sessionId }
    }
    
    /// Delete a session by ID
    public func deleteSession(byId sessionId: String) {
        guard let defaults = UserDefaults(suiteName: sharedSuiteName) else { return }
        
        var sessions = loadAllSessions()
        sessions.removeAll { $0.sessionId == sessionId }
        
        if let encoded = try? JSONEncoder().encode(sessions) {
            defaults.set(encoded, forKey: sessionsKey)
        }
    }
    
    /// Delete all sessions
    public func deleteAllSessions() {
        guard let defaults = UserDefaults(suiteName: sharedSuiteName) else { return }
        defaults.removeObject(forKey: sessionsKey)
    }
    
    /// Get the most recent session
    public var mostRecentSession: KeystrokeSession? {
        return loadAllSessions().first
    }
    
    /// Export session as JSON string
    public func exportSessionAsJSON(_ session: KeystrokeSession) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        guard let data = try? encoder.encode(session),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return json
    }
}
