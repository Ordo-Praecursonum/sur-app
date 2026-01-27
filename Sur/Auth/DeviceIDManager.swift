//
//  DeviceIDManager.swift
//  Sur
//
//  Manages device-specific identities derived from user private key and device UUID
//

import Foundation
import CryptoKit
import UIKit

/// Error types for device ID operations
enum DeviceIDError: LocalizedError {
    case invalidPrivateKey
    case derivationFailed
    case storageError
    
    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            return "Invalid user private key"
        case .derivationFailed:
            return "Failed to derive device ID"
        case .storageError:
            return "Failed to store device ID"
        }
    }
}

/// Manages device-specific identities
///
/// Device IDs are deterministically derived from:
/// - User's private key (from mnemonic)
/// - Device UUID (unique per device)
///
/// This allows:
/// - Identifying which device data originates from
/// - Deterministic recreation of device keys
/// - Privacy (public ID can be shared, private ID stays secret)
final class DeviceIDManager {
    
    // MARK: - Constants
    
    /// UserDefaults key for device UUID
    private static let deviceUUIDKey = "device.uuid"
    
    /// UserDefaults key for device public ID
    private static let devicePublicIDKey = "device.publicID"
    
    // MARK: - Singleton
    
    static let shared = DeviceIDManager()
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Get or create device UUID
    /// - Returns: Device UUID string
    func getDeviceUUID() -> String {
        if let existingUUID = UserDefaults.standard.string(forKey: Self.deviceUUIDKey) {
            return existingUUID
        }
        
        // Create new UUID for this device
        let newUUID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        UserDefaults.standard.set(newUUID, forKey: Self.deviceUUIDKey)
        return newUUID
    }
    
    /// Generate device private and public IDs from user private key and device UUID
    ///
    /// Uses HMAC-SHA256 to derive device-specific keys:
    /// - device_private_id = HMAC-SHA256(user_private_key, device_uuid)
    /// - device_public_id = SHA256(device_private_id)
    ///
    /// - Parameter userPrivateKey: User's private key (32 bytes)
    /// - Returns: Tuple of (devicePrivateID, devicePublicID) as hex strings
    func generateDeviceIDs(from userPrivateKey: Data) throws -> (privateID: String, publicID: String) {
        guard userPrivateKey.count == 32 else {
            throw DeviceIDError.invalidPrivateKey
        }
        
        let deviceUUID = getDeviceUUID()
        guard let uuidData = deviceUUID.data(using: .utf8) else {
            throw DeviceIDError.derivationFailed
        }
        
        // Derive device private ID using HMAC-SHA256
        // device_private_id = HMAC-SHA256(key: user_private_key, message: device_uuid)
        let symmetricKey = SymmetricKey(data: userPrivateKey)
        let hmac = HMAC<SHA256>.authenticationCode(for: uuidData, using: symmetricKey)
        let devicePrivateID = Data(hmac)
        
        // Derive device public ID using SHA256
        // device_public_id = SHA256(device_private_id)
        let devicePublicID = Data(SHA256.hash(data: devicePrivateID))
        
        // Convert to hex strings
        let privateIDHex = devicePrivateID.map { String(format: "%02x", $0) }.joined()
        let publicIDHex = devicePublicID.map { String(format: "%02x", $0) }.joined()
        
        return (privateIDHex, publicIDHex)
    }
    
    /// Save device public ID to storage
    /// - Parameter publicID: Device public ID hex string
    func saveDevicePublicID(_ publicID: String) {
        UserDefaults.standard.set(publicID, forKey: Self.devicePublicIDKey)
    }
    
    /// Get stored device public ID
    /// - Returns: Device public ID hex string, if available
    func getStoredDevicePublicID() -> String? {
        return UserDefaults.standard.string(forKey: Self.devicePublicIDKey)
    }
    
    /// Clear device IDs (when wallet is deleted)
    func clearDeviceIDs() {
        UserDefaults.standard.removeObject(forKey: Self.devicePublicIDKey)
        // Note: We keep the device UUID to maintain device identity
    }
    
    /// Format device public ID for display (shortened version)
    /// - Parameter publicID: Full device public ID hex string
    /// - Returns: Shortened ID for display (e.g., "d4f2a1...bc8e3f")
    static func shortenDeviceID(_ publicID: String) -> String {
        guard publicID.count >= 12 else { return publicID }
        let prefix = String(publicID.prefix(6))
        let suffix = String(publicID.suffix(6))
        return "\(prefix)...\(suffix)"
    }
}
