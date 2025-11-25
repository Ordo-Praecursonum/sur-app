//
//  SecureEnclaveManager.swift
//  Sur
//
//  Secure storage for private keys using iOS Keychain and Secure Enclave
//

import Foundation
import Security
import LocalAuthentication

/// Error types for secure storage operations
enum SecureStorageError: LocalizedError {
    case keychainError(OSStatus)
    case encodingError
    case decodingError
    case itemNotFound
    case duplicateItem
    case authenticationFailed
    case secureEnclaveNotAvailable
    case accessControlCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .encodingError:
            return "Failed to encode data for storage"
        case .decodingError:
            return "Failed to decode stored data"
        case .itemNotFound:
            return "Item not found in secure storage"
        case .duplicateItem:
            return "Item already exists in secure storage"
        case .authenticationFailed:
            return "Biometric or passcode authentication failed"
        case .secureEnclaveNotAvailable:
            return "Secure Enclave is not available on this device"
        case .accessControlCreationFailed:
            return "Failed to create access control settings"
        }
    }
}

/// Manages secure storage of sensitive data using iOS Keychain with Secure Enclave protection
final class SecureEnclaveManager {
    
    // MARK: - Constants
    
    private enum KeychainKey: String {
        case privateKey = "com.ordo.sur.privateKey"
        case mnemonic = "com.ordo.sur.mnemonic"
        case publicAddress = "com.ordo.sur.publicAddress"
        case biometricEnabled = "com.ordo.sur.biometricEnabled"
        case walletCreated = "com.ordo.sur.walletCreated"
    }
    
    /// Shared instance for singleton access
    static let shared = SecureEnclaveManager()
    
    /// Service name for keychain items
    private let service = "com.ordo.sur.wallet"
    
    /// Access group for sharing keychain items (if needed across app and extension)
    private let accessGroup: String? = "group.com.ordo.sure.Sur"
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Check if Secure Enclave is available on this device
    var isSecureEnclaveAvailable: Bool {
        let context = LAContext()
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }
    
    /// Check if biometric authentication is available
    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return canEvaluate && error == nil
    }
    
    /// Get the type of biometric authentication available (Face ID or Touch ID)
    var biometricType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }
    
    // MARK: - Private Key Storage
    
    /// Save private key to Keychain with optional biometric protection
    /// - Parameters:
    ///   - privateKey: The private key data to store
    ///   - requireBiometric: Whether to require biometric authentication for access
    func savePrivateKey(_ privateKey: Data, requireBiometric: Bool) throws {
        let accessControl = try createAccessControl(requireBiometric: requireBiometric)
        try saveToKeychain(data: privateKey, key: .privateKey, accessControl: accessControl)
    }
    
    /// Retrieve private key from Keychain
    /// - Parameter context: Optional LAContext for authentication (reuse for multiple operations)
    /// - Returns: The stored private key data
    func getPrivateKey(context: LAContext? = nil) throws -> Data {
        return try loadFromKeychain(key: .privateKey, context: context)
    }
    
    /// Delete private key from Keychain
    func deletePrivateKey() throws {
        try deleteFromKeychain(key: .privateKey)
    }
    
    // MARK: - Mnemonic Storage
    
    /// Save encrypted mnemonic to Keychain with optional biometric protection
    /// - Parameters:
    ///   - mnemonic: The mnemonic phrase to store
    ///   - requireBiometric: Whether to require biometric authentication for access
    func saveMnemonic(_ mnemonic: String, requireBiometric: Bool) throws {
        guard let data = mnemonic.data(using: .utf8) else {
            throw SecureStorageError.encodingError
        }
        let accessControl = try createAccessControl(requireBiometric: requireBiometric)
        try saveToKeychain(data: data, key: .mnemonic, accessControl: accessControl)
    }
    
    /// Retrieve mnemonic from Keychain
    /// - Parameter context: Optional LAContext for authentication
    /// - Returns: The stored mnemonic phrase
    func getMnemonic(context: LAContext? = nil) throws -> String {
        let data = try loadFromKeychain(key: .mnemonic, context: context)
        guard let mnemonic = String(data: data, encoding: .utf8) else {
            throw SecureStorageError.decodingError
        }
        return mnemonic
    }
    
    /// Delete mnemonic from Keychain
    func deleteMnemonic() throws {
        try deleteFromKeychain(key: .mnemonic)
    }
    
    // MARK: - Public Address Storage (Non-sensitive)
    
    /// Save public Ethereum address to Keychain (no biometric required)
    /// - Parameter address: The public Ethereum address
    func savePublicAddress(_ address: String) throws {
        guard let data = address.data(using: .utf8) else {
            throw SecureStorageError.encodingError
        }
        try saveToKeychain(data: data, key: .publicAddress, accessControl: nil)
    }
    
    /// Retrieve public Ethereum address from Keychain
    /// - Returns: The stored public address
    func getPublicAddress() throws -> String {
        let data = try loadFromKeychain(key: .publicAddress, context: nil)
        guard let address = String(data: data, encoding: .utf8) else {
            throw SecureStorageError.decodingError
        }
        return address
    }
    
    /// Delete public address from Keychain
    func deletePublicAddress() throws {
        try deleteFromKeychain(key: .publicAddress)
    }
    
    // MARK: - Settings Storage
    
    /// Save biometric enabled setting
    func saveBiometricEnabled(_ enabled: Bool) throws {
        let data = Data([enabled ? 1 : 0])
        try saveToKeychain(data: data, key: .biometricEnabled, accessControl: nil)
    }
    
    /// Get biometric enabled setting
    func isBiometricEnabled() -> Bool {
        do {
            let data = try loadFromKeychain(key: .biometricEnabled, context: nil)
            return data.first == 1
        } catch {
            return false
        }
    }
    
    /// Save wallet created flag
    func saveWalletCreated(_ created: Bool) throws {
        let data = Data([created ? 1 : 0])
        try saveToKeychain(data: data, key: .walletCreated, accessControl: nil)
    }
    
    /// Check if wallet has been created
    func isWalletCreated() -> Bool {
        do {
            let data = try loadFromKeychain(key: .walletCreated, context: nil)
            return data.first == 1
        } catch {
            return false
        }
    }
    
    // MARK: - Wallet Deletion
    
    /// Delete all wallet-related data from Keychain
    func deleteAllWalletData() {
        try? deleteFromKeychain(key: .privateKey)
        try? deleteFromKeychain(key: .mnemonic)
        try? deleteFromKeychain(key: .publicAddress)
        try? deleteFromKeychain(key: .biometricEnabled)
        try? deleteFromKeychain(key: .walletCreated)
    }
    
    // MARK: - Private Methods
    
    /// Create access control settings for Keychain items
    private func createAccessControl(requireBiometric: Bool) throws -> SecAccessControl? {
        guard requireBiometric else { return nil }
        
        var flags: SecAccessControlCreateFlags = .privateKeyUsage
        
        // Use biometry if available, otherwise fall back to device passcode
        if isBiometricAvailable {
            flags = [.userPresence, .privateKeyUsage]
        } else {
            flags = [.devicePasscode, .privateKeyUsage]
        }
        
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &error
        ) else {
            throw SecureStorageError.accessControlCreationFailed
        }
        
        return accessControl
    }
    
    /// Save data to Keychain
    private func saveToKeychain(data: Data, key: KeychainKey, accessControl: SecAccessControl?) throws {
        // First, try to delete any existing item
        try? deleteFromKeychain(key: key)
        
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        if let accessControl = accessControl {
            query[kSecAttrAccessControl as String] = accessControl
            // Remove kSecAttrAccessible when using access control
            query.removeValue(forKey: kSecAttrAccessible as String)
        }
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        guard status == errSecSuccess else {
            if status == errSecDuplicateItem {
                throw SecureStorageError.duplicateItem
            }
            throw SecureStorageError.keychainError(status)
        }
    }
    
    /// Load data from Keychain
    private func loadFromKeychain(key: KeychainKey, context: LAContext?) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        if let context = context {
            query[kSecUseAuthenticationContext as String] = context
        }
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw SecureStorageError.itemNotFound
            }
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw SecureStorageError.authenticationFailed
            }
            throw SecureStorageError.keychainError(status)
        }
        
        guard let data = result as? Data else {
            throw SecureStorageError.decodingError
        }
        
        return data
    }
    
    /// Delete data from Keychain
    private func deleteFromKeychain(key: KeychainKey) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        
        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        
        let status = SecItemDelete(query as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureStorageError.keychainError(status)
        }
    }
}
