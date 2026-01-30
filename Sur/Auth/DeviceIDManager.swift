//
//  DeviceIDManager.swift
//  Sur
//
//  Manages device-specific cryptographic keys for signing and verification
//  Uses secp256k1 elliptic curve for compatibility with blockchain ecosystems
//

import Foundation
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
            return "Failed to store device key in UserDefaults"
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
/// - Device private key: 32-byte secp256k1 private key (for signing)
/// - Device public key: 65-byte uncompressed public key (for verification)
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
    
    /// UserDefaults key for device private key (stored securely)
    private static let devicePrivateKeyKey = "device.privateKey"
    
    /// UserDefaults key for device public key
    private static let devicePublicKeyKey = "device.publicKey"
    
    // MARK: - Singleton
    
    static let shared = DeviceIDManager()
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Get or create device UUID
    ///
    /// Uses `UIDevice.current.identifierForVendor` which provides a unique ID per app vendor.
    /// Falls back to `UUID().uuidString` if identifierForVendor is nil, which can happen:
    /// - On first launch before iOS has assigned a vendor ID
    /// - When running in simulator without proper configuration
    /// - After app reinstallation in certain edge cases
    ///
    /// - Returns: Device UUID string
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
    /// - Parameters:
    ///   - privateKey: Device private key (32 bytes) - stored as hex string
    ///   - publicKey: Device public key (65 bytes) - stored as hex string
    func saveDeviceKeys(privateKey: Data, publicKey: Data) {
        let privateKeyHex = privateKey.map { String(format: "%02x", $0) }.joined()
        let publicKeyHex = publicKey.map { String(format: "%02x", $0) }.joined()
        
        // Note: In production, device private key should be stored in Keychain
        // For now, storing in UserDefaults as hex string
        UserDefaults.standard.set(privateKeyHex, forKey: Self.devicePrivateKeyKey)
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
    /// - Returns: Device private key as Data (32 bytes), if available
    func getStoredDevicePrivateKey() -> Data? {
        guard let privateKeyHex = UserDefaults.standard.string(forKey: Self.devicePrivateKeyKey) else {
            return nil
        }
        
        guard let data = hexStringToData(privateKeyHex) else {
            return nil
        }
        
        // Validate private key format (32 bytes, valid for secp256k1)
        guard data.count == 32, Secp256k1.isValidPrivateKey(data) else {
            return nil
        }
        
        return data
    }
    
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
    
    /// Clear device keys (when wallet is deleted)
    func clearDeviceKeys() {
        UserDefaults.standard.removeObject(forKey: Self.devicePrivateKeyKey)
        UserDefaults.standard.removeObject(forKey: Self.devicePublicKeyKey)
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
}
