//
//  DeviceIDManager.swift
//  Sur
//
//  Manages device-specific cryptographic keys for signing and verification
//  Uses secp256k1 elliptic curve for compatibility with blockchain ecosystems
//

import Foundation
import Security
import CryptoKit
import UIKit

/// Error types for device key operations
enum DeviceIDError: LocalizedError {
    case invalidPrivateKey
    case derivationFailed
    case storageError
    case invalidPublicKey

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            return "Invalid user private key"
        case .derivationFailed:
            return "Failed to derive device key"
        case .storageError:
            return "Failed to store device key in Keychain"
        case .invalidPublicKey:
            return "Failed to generate device public key"
        }
    }
}

/// Manages device-specific cryptographic keys for signing and verification
///
/// Device keys are deterministically derived from:
/// - User's private key (from mnemonic)
/// - Device UUID (unique per device)
///
/// Uses secp256k1 elliptic curve to generate:
/// - Device private key: 32-byte secp256k1 private key (for signing) — stored in Keychain
/// - Device public key: 65-byte uncompressed public key (for verification) — stored in UserDefaults
///
/// This allows:
/// - Signing messages to prove data originated from this device
/// - Verifying signatures to ensure data provenance
/// - Deterministic recreation of device keys
/// - Privacy (public key can be shared, private key stays secret)
final class DeviceIDManager {

    // MARK: - Constants

    /// UserDefaults key for device UUID
    private static let deviceUUIDKey = "device.uuid"

    /// UserDefaults key for device public key (public data, not secret)
    private static let devicePublicKeyKey = "device.publicKey"

    /// UserDefaults key for the old plaintext private key — used only during one-time migration
    private static let legacyDevicePrivateKeyKey = "device.privateKey"

    /// Shared app group identifier for keyboard extension access
    private static let sharedSuiteName = "group.com.ordo.sure.Sur"

    // MARK: - Keychain constants for the device private key

    private static let keychainService = "com.ordo.sur.wallet"
    private static let keychainAccount = "com.ordo.sur.device.privateKey"
    private static let keychainAccessGroup = "group.com.ordo.sure.Sur"

    // MARK: - Singleton

    static let shared = DeviceIDManager()

    private init() {}

    // MARK: - Public Methods

    /// Get or create device UUID
    ///
    /// - Important: This method is used ONLY for the legacy secp256k1 device key
    ///   derivation path (`generateDeviceKeys(from:)`). It is NOT the primary device
    ///   identity for Sur. Primary device identity is now `AppAttestManager.shared.keyID`,
    ///   which is cryptographically bound to the Secure Enclave of a genuine, unmodified
    ///   Apple device. Do not use this UUID to represent the device to the Sur Chain.
    ///
    /// Uses `UIDevice.current.identifierForVendor` which provides a unique ID per app vendor.
    /// Falls back to `UUID().uuidString` if identifierForVendor is nil, which can happen:
    /// - On first launch before iOS has assigned a vendor ID
    /// - When running in simulator without proper configuration
    /// - After app reinstallation in certain edge cases
    ///
    /// - Returns: Device UUID string used as an input to secp256k1 device key derivation
    func getDeviceUUID() -> String {
        if let existingUUID = UserDefaults.standard.string(forKey: Self.deviceUUIDKey) {
            return existingUUID
        }

        // Create new UUID for this device
        // Prefer vendor ID for consistency across app reinstalls, fallback to random UUID
        let newUUID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(newUUID, forKey: Self.deviceUUIDKey)
        return newUUID
    }

    /// Generate device cryptographic keys from user private key and device UUID
    ///
    /// Uses HMAC-SHA256 to derive a seed, then generates a valid secp256k1 key pair:
    /// - device_seed = HMAC-SHA256(user_private_key, device_uuid)
    /// - device_private_key = device_seed (validated for secp256k1)
    /// - device_public_key = secp256k1_public_key(device_private_key)
    ///
    /// The device private key can be used to sign messages, and the public key
    /// can be used by others to verify those signatures, proving data provenance.
    ///
    /// - Parameter userPrivateKey: User's private key (32 bytes)
    /// - Returns: Tuple of (devicePrivateKey, devicePublicKey) as Data
    func generateDeviceKeys(from userPrivateKey: Data) throws -> (privateKey: Data, publicKey: Data) {
        guard userPrivateKey.count == 32 else {
            throw DeviceIDError.invalidPrivateKey
        }

        let deviceUUID = getDeviceUUID()
        guard let uuidData = deviceUUID.data(using: .utf8) else {
            throw DeviceIDError.derivationFailed
        }

        // Derive device private key using HMAC-SHA256
        // This provides deterministic generation: same user key + device UUID = same device key
        let symmetricKey = SymmetricKey(data: userPrivateKey)
        let hmac = HMAC<SHA256>.authenticationCode(for: uuidData, using: symmetricKey)
        let devicePrivateKey = Data(hmac)

        // Validate the derived key is valid for secp256k1
        guard Secp256k1.isValidPrivateKey(devicePrivateKey) else {
            throw DeviceIDError.derivationFailed
        }

        // Derive device public key using secp256k1 elliptic curve
        guard let devicePublicKey = Secp256k1.derivePublicKey(from: devicePrivateKey) else {
            throw DeviceIDError.invalidPublicKey
        }

        return (devicePrivateKey, devicePublicKey)
    }

    /// Save device keys to storage
    ///
    /// The private key is stored in the Keychain (shared via App Group so the keyboard
    /// extension can read it). The public key is non-secret and goes to UserDefaults.
    ///
    /// - Parameters:
    ///   - privateKey: Device private key (32 bytes) — stored in Keychain
    ///   - publicKey: Device public key (65 bytes) — stored in UserDefaults as hex string
    func saveDeviceKeys(privateKey: Data, publicKey: Data) {
        // Store private key in Keychain — raw Data, no hex encoding
        savePrivateKeyToKeychain(privateKey)

        // Store public key in UserDefaults (shared) — public data, not secret
        let publicKeyHex = publicKey.map { String(format: "%02x", $0) }.joined()
        if let sharedDefaults = UserDefaults(suiteName: Self.sharedSuiteName) {
            sharedDefaults.set(publicKeyHex, forKey: Self.devicePublicKeyKey)
        }
        UserDefaults.standard.set(publicKeyHex, forKey: Self.devicePublicKeyKey)
    }

    /// Get stored device public key
    /// - Returns: Device public key as Data (65 bytes), if available
    func getStoredDevicePublicKey() -> Data? {
        guard let publicKeyHex = UserDefaults.standard.string(forKey: Self.devicePublicKeyKey) else {
            return nil
        }

        guard let data = hexStringToData(publicKeyHex) else {
            return nil
        }

        // Validate public key format (65 bytes, starts with 0x04)
        guard data.count == 65, data[0] == 0x04 else {
            return nil
        }

        return data
    }

    /// Get stored device private key
    ///
    /// Performs a one-time migration from the legacy UserDefaults store if no Keychain
    /// item exists yet. After migrating, the plaintext value is deleted from UserDefaults.
    ///
    /// - Returns: Device private key as Data (32 bytes), if available
    func getStoredDevicePrivateKey() -> Data? {
        // Try Keychain first
        if let keyData = loadPrivateKeyFromKeychain() {
            return keyData
        }

        // One-time migration: check for legacy plaintext value in UserDefaults
        migratePrivateKeyFromUserDefaultsIfNeeded()

        // Return whatever is now in the Keychain (may still be nil if no legacy value existed)
        return loadPrivateKeyFromKeychain()
    }

    /// Clear device keys (when wallet is deleted)
    func clearDeviceKeys() {
        deletePrivateKeyFromKeychain()
        UserDefaults.standard.removeObject(forKey: Self.devicePublicKeyKey)
        if let sharedDefaults = UserDefaults(suiteName: Self.sharedSuiteName) {
            sharedDefaults.removeObject(forKey: Self.devicePublicKeyKey)
        }
        // Note: We keep the device UUID to maintain device identity
    }

    /// Format device public key for display (shortened version)
    /// - Parameter publicKey: Full device public key (65 bytes)
    /// - Returns: Shortened hex string for display (e.g., "04a3f2...bc8e3f")
    static func shortenDevicePublicKey(_ publicKey: Data) -> String {
        let publicKeyHex = publicKey.map { String(format: "%02x", $0) }.joined()
        guard publicKeyHex.count >= 12 else { return publicKeyHex }
        let prefix = String(publicKeyHex.prefix(6))
        let suffix = String(publicKeyHex.suffix(6))
        return "\(prefix)...\(suffix)"
    }

    /// Generate Ethereum-compatible address from device public key
    ///
    /// This demonstrates that device keys are fully compatible with Ethereum.
    /// Device keys use the same secp256k1 curve as Ethereum, so the device public key
    /// can be converted to an Ethereum address using the standard Keccak-256 hashing.
    ///
    /// **Note**: This is provided for compatibility verification. In practice, the device
    /// keys are used for signing messages to prove device identity, not for holding funds.
    ///
    /// - Parameter devicePublicKey: 65-byte uncompressed device public key (0x04 + X + Y)
    /// - Returns: Ethereum address with 0x prefix (EIP-55 checksummed)
    static func deriveEthereumAddress(from devicePublicKey: Data) -> String? {
        // Validate public key format
        guard devicePublicKey.count == 65, devicePublicKey[0] == 0x04 else {
            return nil
        }

        // Use the same Ethereum address derivation as EthereumKeyManager
        // This proves device keys are fully compatible with Ethereum

        // Hash the public key coordinates (excluding 0x04 prefix) with Keccak-256
        let publicKeyToHash = Data(devicePublicKey.dropFirst())
        let hash = Keccak256.hash(publicKeyToHash)

        // Take last 20 bytes as the address
        let addressBytes = hash.suffix(20)
        let addressHex = addressBytes.map { String(format: "%02x", $0) }.joined()

        // Apply EIP-55 checksum
        return EthereumKeyManager.checksumAddress(addressHex)
    }

    // MARK: - Sur Device Identity (surdev1…)

    /// Bech32 human-readable prefix for a Sur device identifier.
    static let deviceIDHRP = "surdev"

    /// The pseudonymous protocol identity for this device: a bech32 `surdev1…`
    /// address of the device public key. This REPLACES the username as the
    /// identifier under which content is attested — it is derived from the
    /// user key + device UUID (see generateDeviceKeys), so it is recoverable yet
    /// device-scoped, and opaque until the user chooses to share it. Anyone given
    /// this id can verify the device's signatures (see signContentHash).
    func currentDeviceID() -> String? {
        guard let pub = getStoredDevicePublicKey() else { return nil }
        return Self.deviceID(fromPublicKey: pub)
    }

    /// Derive a `surdev1…` device id from a secp256k1 device public key
    /// (accepts 33-byte compressed or 65-byte uncompressed). Standard Cosmos-style
    /// address: bech32(hrp, ripemd160(sha256(compressedPubKey))).
    static func deviceID(fromPublicKey publicKey: Data) -> String? {
        let compressed: Data
        if publicKey.count == 33 {
            compressed = publicKey
        } else if let c = compressPublicKey(publicKey) {
            compressed = c
        } else {
            return nil
        }
        let sha = Data(SHA256.hash(data: compressed))
        let hash160 = RIPEMD160.hash(sha)
        return Bech32.encode(hrp: deviceIDHRP, data: hash160)
    }

    /// Sign a 32-byte content hash with this device's private key, producing a
    /// portable 64-byte low-S secp256k1 signature. Anyone holding the device
    /// public key can verify authorship offline (no chain required):
    ///   Secp256k1.verify(signature, for: SHA256(contentHash), publicKey)
    /// (signMessage hashes its input once with SHA-256, so the signed digest is
    /// SHA256(contentHash) — verifiers must match this convention.)
    func signContentHash(_ contentHash: Data) -> Data? {
        guard let priv = getStoredDevicePrivateKey() else { return nil }
        return Secp256k1.signMessage(contentHash, with: priv)
    }

    /// The device's 33-byte compressed secp256k1 public key (for chain-side
    /// signature verification and device-id derivation).
    func compressedDevicePublicKey() -> Data? {
        guard let pub = getStoredDevicePublicKey() else { return nil }
        return Self.compressPublicKey(pub)
    }

    /// Sign an arbitrary declaration payload with the device key. Returns a
    /// 64-byte low-S secp256k1 signature over SHA-256(payload), matching the
    /// chain's `secp256k1.PubKey.VerifySignature`.
    func signDeclaration(_ payload: Data) -> Data? {
        guard let priv = getStoredDevicePrivateKey() else { return nil }
        return Secp256k1.signMessage(payload, with: priv)
    }

    /// Compress an uncompressed (0x04‖X‖Y) secp256k1 public key to 33 bytes.
    private static func compressPublicKey(_ uncompressed: Data) -> Data? {
        let b = [UInt8](uncompressed)
        guard b.count == 65, b[0] == 0x04 else { return nil }
        let x = Array(b[1..<33])
        let prefix: UInt8 = (b[64] & 1) == 0 ? 0x02 : 0x03
        return Data([prefix] + x)
    }

    // MARK: - Private Keychain Helpers

    /// Write the device private key to the shared Keychain item.
    /// Deletes any pre-existing item first to avoid errSecDuplicateItem.
    private func savePrivateKeyToKeychain(_ privateKey: Data) {
        // Remove any existing item before adding the new one
        deletePrivateKeyFromKeychain()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: privateKey
        ]

        SecItemAdd(query as CFDictionary, nil)
    }

    /// Read the device private key from the Keychain.
    /// Returns nil if the item does not exist or the read fails.
    private func loadPrivateKeyFromKeychain() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        // Validate: must be exactly 32 bytes and a valid secp256k1 private key
        guard data.count == 32, Secp256k1.isValidPrivateKey(data) else {
            return nil
        }

        return data
    }

    /// Delete the device private key Keychain item.
    private func deletePrivateKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecAttrAccessGroup as String: Self.keychainAccessGroup
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// One-time migration: if a plaintext private key exists in UserDefaults from a
    /// previous install, move it to the Keychain and erase the UserDefaults copy.
    private func migratePrivateKeyFromUserDefaultsIfNeeded() {
        // Check both the standard store and the shared app group store
        let legacyHex = UserDefaults.standard.string(forKey: Self.legacyDevicePrivateKeyKey)
            ?? UserDefaults(suiteName: Self.sharedSuiteName)?.string(forKey: Self.legacyDevicePrivateKeyKey)

        guard let hex = legacyHex,
              let keyData = hexStringToData(hex),
              keyData.count == 32,
              Secp256k1.isValidPrivateKey(keyData) else {
            return
        }

        // Persist in Keychain
        savePrivateKeyToKeychain(keyData)

        // Remove plaintext copies from both UserDefaults stores
        UserDefaults.standard.removeObject(forKey: Self.legacyDevicePrivateKeyKey)
        UserDefaults(suiteName: Self.sharedSuiteName)?.removeObject(forKey: Self.legacyDevicePrivateKeyKey)
    }

    // MARK: - Private Utilities

    /// Convert hex string to Data
    /// - Parameter hex: Hex string (with or without 0x prefix)
    /// - Returns: Data representation, or nil if invalid hex
    private func hexStringToData(_ hex: String) -> Data? {
        var hexString = hex

        // Remove 0x prefix if present
        if hexString.hasPrefix("0x") {
            hexString = String(hexString.dropFirst(2))
        }

        // Hex string must have even length
        guard hexString.count % 2 == 0 else {
            return nil
        }

        var data = Data()
        var temp = hexString

        while temp.count >= 2 {
            let subString = temp.prefix(2)
            temp = String(temp.dropFirst(2))

            guard let byte = UInt8(subString, radix: 16) else {
                return nil // Invalid hex character
            }

            data.append(byte)
        }

        return data.count > 0 ? data : nil
    }
}
