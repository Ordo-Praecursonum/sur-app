//
//  KeystrokeLogger+Signing.swift
//  SurKeyboard
//
//  Signing support for the keyboard extension.
//

import Foundation
import Security
import CryptoKit

/// Signing support for the keyboard extension.
///
/// The keyboard extension signs the session bundle using the device's Secure Enclave key.
/// This creates an unforgeable link between the session data and this specific device.
///
/// Key hierarchy:
/// - The device Secure Enclave key is a P-256 key created by the main app (AppAttestManager / SecureEnclaveManager)
/// - It is accessible from the keyboard extension via the shared Keychain access group
/// - Signatures use ECDSA with SHA-256 (.ecdsaSignatureMessageX962SHA256)
extension KeystrokeLogger {

    // MARK: - Signing Constants
    private static let seKeyService = "com.ordo.sur.wallet"
    private static let seKeyAccount = "com.ordo.sur.device.seKey"     // Secure Enclave P-256 key reference
    private static let seKeyAccessGroup = "group.com.ordo.sure.Sur"

    // MARK: - Session Bundle Signing

    /// Sign a finalized session bundle with the device Secure Enclave key.
    ///
    /// - Parameter sessionData: The serialized session bundle to sign (e.g., JSON-encoded)
    /// - Returns: DER-encoded ECDSA signature (P-256, SHA-256), or nil if key unavailable
    func signSessionBundle(_ sessionData: Data) -> Data? {
        guard let privateKey = loadSecureEnclaveKeyRef() else {
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            sessionData as CFData,
            &error
        ) as Data? else {
            return nil
        }

        return signature
    }

    /// Retrieve the Secure Enclave key reference from the shared Keychain.
    private func loadSecureEnclaveKeyRef() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationLabel as String: Self.seKeyAccount,
            kSecAttrAccessGroup as String: Self.seKeyAccessGroup,
            kSecReturnRef as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return (result as! SecKey)
    }
}
