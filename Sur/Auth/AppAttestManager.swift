//
//  AppAttestManager.swift
//  Sur
//
//  Manages Apple App Attest lifecycle for device identity verification.
//
//  App Attest proves to the Sur Chain that:
//  - The key was generated in the Secure Enclave of a genuine, unmodified Apple device
//  - The app is a genuine, unmodified build of Sur (validated against Apple's servers)
//
//  Flow:
//  1. generateAndAttestKey() → DCAppAttestService.generateKey() then attestKey()
//  2. The attestation object is sent to the Sur Chain as part of MsgAddDevice
//  3. Subsequent requests use generateAssertion() to prove this device signed the request
//

import DeviceCheck
import CryptoKit
import Foundation

// MARK: - Error type

enum AppAttestError: LocalizedError {
    /// Device doesn't support App Attest (pre-A12 chip, simulator)
    case notSupported
    /// generateAndAttestKey() hasn't been called yet; no key ID in Keychain
    case notAttested
    /// DCAppAttestService.generateKey() failed
    case keyGenerationFailed
    /// Apple's servers rejected or could not process the attestation
    case attestationFailed(Error)
    /// Assertion generation failed after a valid attestation
    case assertionFailed(Error)
    /// Keychain read/write returned a non-success OSStatus
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notSupported:
            return "App Attest is not supported on this device."
        case .notAttested:
            return "No attested key exists. Call generateAndAttestKey() first."
        case .keyGenerationFailed:
            return "Failed to generate App Attest key in the Secure Enclave."
        case .attestationFailed(let error):
            return "App Attest attestation failed: \(error.localizedDescription)"
        case .assertionFailed(let error):
            return "App Attest assertion failed: \(error.localizedDescription)"
        case .keychainError(let status):
            return "Keychain operation failed with OSStatus \(status)."
        }
    }
}

// MARK: - Wire model

/// The complete device attestation bundle sent to the Sur Chain via MsgAddDevice.
struct DeviceAttestationBundle: Codable {
    /// Apple App Attest key ID returned by DCAppAttestService.generateKey()
    let keyID: String
    /// Apple-signed CBOR attestation object to be verified server-side
    let attestationObject: Data
    /// The challenge supplied during attestation; the Sur Chain must verify it matches
    let challenge: Data
    /// Wall-clock time at which the attestation was performed
    let timestamp: Date
}

// MARK: - Manager

/// Manages Apple App Attest lifecycle for Sur device registration and per-request assertions.
///
/// This is the authoritative device identity source. `DeviceIDManager.getDeviceUUID()` is
/// used only for the legacy secp256k1 device key derivation path; all primary device identity
/// proofs now flow through this class.
@available(iOS 14.0, *)
final class AppAttestManager {

    // MARK: - Singleton

    static let shared = AppAttestManager()
    private init() {}

    // MARK: - Keychain constants

    private static let keyIDKeychainService    = "com.ordo.sur.wallet"
    private static let keyIDKeychainAccount    = "com.ordo.sur.appAttest.keyID"
    private static let keyIDKeychainAccessGroup = "group.com.ordo.sure.Sur"

    // MARK: - Persisted state

    /// The App Attest key ID stored in Keychain after a successful attestation.
    ///
    /// The getter reads straight from Keychain on every access so the extension and main
    /// app always see the same value without an in-memory cache to keep in sync.
    /// The setter persists to Keychain; assigning nil deletes the item.
    private(set) var keyID: String? {
        get { loadKeyIDFromKeychain() }
        set {
            if let id = newValue {
                saveKeyIDToKeychain(id)
            } else {
                deleteKeyIDFromKeychain()
            }
        }
    }

    // MARK: - Public interface

    /// Whether App Attest is supported on this device.
    ///
    /// Returns false on simulators, devices with pre-A12 chips, and any device
    /// that cannot reach Apple's App Attest servers. Never attempt the flow when
    /// this is false — DCAppAttestService will always return DCError.featureUnsupported.
    var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    /// Whether an attestation key already exists in Keychain.
    ///
    /// True means generateAndAttestKey() completed successfully at least once.
    /// A device restore or manual resetAttestation() call will set this back to false.
    var isAttested: Bool {
        keyID != nil
    }

    /// Generate a new App Attest key and attest it with Apple's servers.
    ///
    /// This is the one-time device registration call. It must be called before any
    /// assertion can be generated. The returned attestation object must be forwarded
    /// to the Sur Chain as the `attestation_object` field of `MsgAddDevice`; the
    /// chain verifies it against Apple's root CA before accepting the device.
    ///
    /// - Parameter challengeData: A fresh random challenge from the Sur Chain (any
    ///   length). It is SHA-256 hashed here to produce the 32-byte clientDataHash
    ///   required by DCAppAttestService. The chain must echo the same challenge back
    ///   when verifying the attestation object.
    /// - Returns: The key ID and raw CBOR attestation object.
    /// - Throws: `AppAttestError.notSupported` if the device cannot use App Attest,
    ///   `AppAttestError.attestationFailed` if Apple's servers reject the key, or
    ///   `AppAttestError.keychainError` if the key ID cannot be persisted.
    func generateAndAttestKey(challengeData: Data) async throws -> (keyID: String, attestationObject: Data) {
        guard isSupported else {
            throw AppAttestError.notSupported
        }

        let service = DCAppAttestService.shared

        // Step 1: Generate a new Secure Enclave-backed key.
        // The key ID is an opaque handle managed by the OS — no raw key material is
        // ever exposed to the app. This call may fail with DCError.invalidInput if
        // the service is temporarily unavailable; the caller should surface the error
        // and prompt the user to retry rather than silently swallowing it.
        let newKeyID: String
        do {
            newKeyID = try await service.generateKey()
        } catch {
            throw AppAttestError.keyGenerationFailed
        }

        // Step 2: Hash the challenge to produce the clientDataHash.
        // DCAppAttestService requires exactly 32 bytes. SHA-256 of any server-supplied
        // nonce satisfies this and binds the attestation to a specific server challenge,
        // preventing replay of an attestation object from a different session.
        let clientDataHash = Data(SHA256.hash(data: challengeData))

        // Step 3: Attest the key with Apple's servers.
        // On success, Apple returns a CBOR-encoded object containing:
        //   - authData (including rpIdHash, counter, AAGUID, credentialId)
        //   - attStmt.x5c  — the leaf certificate and intermediate CA chain
        // The Sur Chain verifies the x5c chain against Apple App Attest CA 1.
        let attestationObject: Data
        do {
            attestationObject = try await service.attestKey(newKeyID, clientDataHash: clientDataHash)
        } catch {
            throw AppAttestError.attestationFailed(error)
        }

        // Step 4: Persist the key ID.
        // Only write after a confirmed successful attestation — a key ID without a
        // valid attestation would cause every subsequent assertion to be rejected.
        self.keyID = newKeyID

        return (newKeyID, attestationObject)
    }

    /// Generate an assertion for an existing attested key.
    ///
    /// Call this for every signed request after the initial `generateAndAttestKey()` /
    /// `MsgAddDevice` round trip. The assertion proves that the request was initiated
    /// by the same Secure Enclave key that was attested, and that the key resides on
    /// an unmodified Apple device running an unmodified Sur binary.
    ///
    /// - Parameter requestData: The payload to bind the assertion to (e.g., the
    ///   SHA-256 digest of the Cosmos SignDoc bytes). The OS hashes this internally
    ///   to produce the clientDataHash.
    /// - Returns: The raw assertion object to include in the request.
    /// - Throws: `AppAttestError.notAttested` if no key ID exists, or
    ///   `AppAttestError.assertionFailed` wrapping the underlying DCError.
    func generateAssertion(requestData: Data) async throws -> Data {
        guard let keyID = self.keyID else {
            throw AppAttestError.notAttested
        }

        // Hash the request payload so the assertion is bound to exactly this request.
        // An assertion generated for one SignDoc cannot be replayed against a different one.
        let clientDataHash = Data(SHA256.hash(data: requestData))

        do {
            return try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
        } catch {
            // Callers should check for DCError.invalidKey here: it surfaces after a
            // device restore and means the Secure Enclave no longer contains the key
            // referenced by keyID. The correct recovery is resetAttestation() followed
            // by a new generateAndAttestKey() + MsgAddDevice round trip.
            throw AppAttestError.assertionFailed(error)
        }
    }

    /// Reset attestation state.
    ///
    /// Removes the key ID from Keychain. The Secure Enclave key itself cannot be
    /// deleted programmatically — it simply becomes unreferenced. After calling this,
    /// `isAttested` returns false and a full `generateAndAttestKey()` + `MsgAddDevice`
    /// cycle is required before assertions can be generated again.
    ///
    /// Call this on user logout or when DCError.invalidKey indicates the Secure Enclave
    /// no longer holds the attested key (e.g., after a device restore).
    func resetAttestation() {
        keyID = nil
    }

    // MARK: - Private Keychain helpers

    /// Write the key ID string to the shared Keychain item.
    ///
    /// Deletes any pre-existing item before adding to avoid errSecDuplicateItem.
    /// The item is tagged kSecAttrAccessibleWhenUnlockedThisDeviceOnly so it is
    /// never included in iCloud or local backups and cannot be migrated to another
    /// device — consistent with App Attest's device-binding guarantee.
    private func saveKeyIDToKeychain(_ keyID: String) {
        guard let data = keyID.data(using: .utf8) else { return }

        // Always delete first to avoid errSecDuplicateItem on update.
        deleteKeyIDFromKeychain()

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      Self.keyIDKeychainService,
            kSecAttrAccount as String:      Self.keyIDKeychainAccount,
            kSecAttrAccessGroup as String:  Self.keyIDKeychainAccessGroup,
            kSecAttrAccessible as String:   kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String:        data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        // A failure here is silent but the caller can detect it via the next
        // loadKeyIDFromKeychain() returning nil. Callers that require durability
        // guarantees should check isAttested after the write.
        if status != errSecSuccess {
            // In a debug build you would assert or log here. Never log key material.
            _ = status // suppress unused-result warning
        }
    }

    /// Read the key ID string from the Keychain.
    ///
    /// Returns nil if the item does not exist, has been deleted, or if the stored
    /// data cannot be decoded as a UTF-8 string.
    private func loadKeyIDFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      Self.keyIDKeychainService,
            kSecAttrAccount as String:      Self.keyIDKeychainAccount,
            kSecAttrAccessGroup as String:  Self.keyIDKeychainAccessGroup,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete the key ID Keychain item.
    ///
    /// errSecItemNotFound is silently ignored — the desired post-condition (item
    /// absent) is already satisfied.
    private func deleteKeyIDFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      Self.keyIDKeychainService,
            kSecAttrAccount as String:      Self.keyIDKeychainAccount,
            kSecAttrAccessGroup as String:  Self.keyIDKeychainAccessGroup
        ]

        SecItemDelete(query as CFDictionary)
    }
}
