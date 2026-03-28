//
//  AppAttestManager.swift
//  Sur
//
//  Implements Apple App Attest (DCAppAttestService) lifecycle for device attestation.
//  Provides cryptographic proof that the device key was generated in genuine Apple hardware.
//
//  The attestation object produced by this manager is included in MsgAddDevice
//  (sent to the Sur Chain project) so the chain can verify:
//  - The device key was generated in Secure Enclave of a genuine Apple device
//  - The build was an unmodified, production-signed build of the Sur app
//  - The specific app bundle ID matches the registered Sur app
//

import Foundation
import DeviceCheck
import CryptoKit

/// Manages Apple App Attest lifecycle for device attestation
public final class AppAttestManager {
    
    // MARK: - Singleton
    
    public static let shared = AppAttestManager()
    
    // MARK: - Constants
    
    /// Keychain service for storing the App Attest key ID
    private static let keychainService = "com.ordo.sure.Sur.appattest"
    
    /// Keychain account for the key ID
    private static let keyIDAccount = "appattest.keyID"
    
    /// Keychain account for the attestation object
    private static let attestationAccount = "appattest.attestation"
    
    // MARK: - Properties
    
    /// The DCAppAttestService instance
    private let attestService: DCAppAttestService
    
    /// Whether App Attest is supported on this device
    public var isSupported: Bool {
        return attestService.isSupported
    }
    
    // MARK: - Error Types
    
    public enum AppAttestError: LocalizedError {
        case notSupported
        case keyGenerationFailed(Error)
        case attestationFailed(Error)
        case assertionFailed(Error)
        case invalidKeyRecoveryNeeded
        case cborDecodingFailed(String)
        case keychainError(OSStatus)
        case noStoredKeyID
        
        public var errorDescription: String? {
            switch self {
            case .notSupported:
                return "App Attest is not supported on this device"
            case .keyGenerationFailed(let error):
                return "Failed to generate App Attest key: \(error.localizedDescription)"
            case .attestationFailed(let error):
                return "App Attest attestation failed: \(error.localizedDescription)"
            case .assertionFailed(let error):
                return "App Attest assertion failed: \(error.localizedDescription)"
            case .invalidKeyRecoveryNeeded:
                return "App Attest key is invalid; re-attestation required"
            case .cborDecodingFailed(let reason):
                return "CBOR decoding failed: \(reason)"
            case .keychainError(let status):
                return "Keychain error: \(status)"
            case .noStoredKeyID:
                return "No stored App Attest key ID"
            }
        }
    }
    
    // MARK: - Initialization
    
    private init() {
        self.attestService = DCAppAttestService.shared
    }
    
    // For testing with a mock service
    init(service: DCAppAttestService) {
        self.attestService = service
    }
    
    // MARK: - Key Generation
    
    /// Generate a new App Attest key in Secure Enclave.
    /// The key ID is stored in Keychain for later use.
    /// - Returns: The generated key ID
    public func generateKey() async throws -> String {
        guard isSupported else {
            throw AppAttestError.notSupported
        }
        
        do {
            let keyID = try await attestService.generateKey()
            try storeKeyID(keyID)
            return keyID
        } catch let error as DCError where error.code == .invalidKey {
            // Key was invalidated (e.g., after OS update) — clear and regenerate
            clearStoredKey()
            throw AppAttestError.invalidKeyRecoveryNeeded
        } catch {
            throw AppAttestError.keyGenerationFailed(error)
        }
    }
    
    // MARK: - Attestation
    
    /// Attest the generated key with Apple's servers.
    /// The clientDataHash must be SHA256(MsgAddDevice proto bytes) to bind
    /// the attestation to the specific registration message.
    ///
    /// - Parameters:
    ///   - clientDataHash: SHA256 hash of the data to bind the attestation to
    ///   - keyID: Optional key ID to attest (uses stored key ID if nil)
    /// - Returns: The raw attestation object bytes (CBOR-encoded)
    public func attestKey(clientDataHash: Data, keyID: String? = nil) async throws -> Data {
        guard isSupported else {
            throw AppAttestError.notSupported
        }
        
        let resolvedKeyID: String
        if let keyID = keyID {
            resolvedKeyID = keyID
        } else {
            guard let storedKeyID = getStoredKeyID() else {
                throw AppAttestError.noStoredKeyID
            }
            resolvedKeyID = storedKeyID
        }
        
        do {
            let attestation = try await attestService.attestKey(resolvedKeyID, clientDataHash: clientDataHash)
            // Store the attestation object for later reference
            try storeAttestationObject(attestation)
            return attestation
        } catch let error as DCError where error.code == .invalidKey {
            // Key is invalid — clear stored key and offer re-attestation
            clearStoredKey()
            throw AppAttestError.invalidKeyRecoveryNeeded
        } catch {
            throw AppAttestError.attestationFailed(error)
        }
    }
    
    // MARK: - Assertion
    
    /// Generate an assertion for the given client data.
    /// Used for subsequent requests after initial attestation.
    ///
    /// - Parameters:
    ///   - clientDataHash: SHA256 hash of the request data
    ///   - keyID: Optional key ID (uses stored key ID if nil)
    /// - Returns: The assertion bytes
    public func generateAssertion(clientDataHash: Data, keyID: String? = nil) async throws -> Data {
        guard isSupported else {
            throw AppAttestError.notSupported
        }
        
        let resolvedKeyID: String
        if let keyID = keyID {
            resolvedKeyID = keyID
        } else {
            guard let storedKeyID = getStoredKeyID() else {
                throw AppAttestError.noStoredKeyID
            }
            resolvedKeyID = storedKeyID
        }
        
        do {
            return try await attestService.generateAssertion(resolvedKeyID, clientDataHash: clientDataHash)
        } catch let error as DCError where error.code == .invalidKey {
            clearStoredKey()
            throw AppAttestError.invalidKeyRecoveryNeeded
        } catch {
            throw AppAttestError.assertionFailed(error)
        }
    }
    
    // MARK: - Client Data Hash
    
    /// Compute the clientDataHash for MsgAddDevice registration.
    /// Per the spec, this must be SHA256(MsgAddDevice proto bytes).
    ///
    /// - Parameter msgAddDeviceBytes: The serialized MsgAddDevice protobuf bytes
    /// - Returns: SHA256 hash (32 bytes)
    public static func clientDataHash(for msgAddDeviceBytes: Data) -> Data {
        let digest = SHA256.hash(data: msgAddDeviceBytes)
        return Data(digest)
    }
    
    // MARK: - Keychain Storage
    
    /// Store the App Attest key ID in Keychain
    private func storeKeyID(_ keyID: String) throws {
        guard let data = keyID.data(using: .utf8) else { return }
        
        // Delete any existing key ID
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keyIDAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keyIDAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw AppAttestError.keychainError(status)
        }
    }
    
    /// Get the stored App Attest key ID from Keychain
    public func getStoredKeyID() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keyIDAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    /// Store the attestation object in Keychain
    private func storeAttestationObject(_ attestation: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.attestationAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.attestationAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: attestation
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            throw AppAttestError.keychainError(status)
        }
    }
    
    /// Get the stored attestation object from Keychain
    public func getStoredAttestationObject() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.attestationAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
        return data
    }
    
    /// Clear the stored App Attest key ID and attestation
    public func clearStoredKey() {
        let deleteKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keyIDAccount
        ]
        SecItemDelete(deleteKeyQuery as CFDictionary)
        
        let deleteAttestQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.attestationAccount
        ]
        SecItemDelete(deleteAttestQuery as CFDictionary)
    }
    
    /// Check if a valid key ID is stored
    public var hasStoredKey: Bool {
        return getStoredKeyID() != nil
    }
}
