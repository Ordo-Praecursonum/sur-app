//
//  BiometricAuthManager.swift
//  Sur
//
//  Manages biometric authentication (Face ID / Touch ID)
//

import Foundation
import LocalAuthentication

/// Error types for biometric authentication
enum BiometricError: LocalizedError {
    case notAvailable
    case notEnrolled
    case lockout
    case cancelled
    case failed
    case passcodeNotSet
    case invalidContext
    
    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Biometric authentication is not available on this device."
        case .notEnrolled:
            return "No biometric data is enrolled. Please set up Face ID or Touch ID in Settings."
        case .lockout:
            return "Biometric authentication is locked. Please use your device passcode."
        case .cancelled:
            return "Authentication was cancelled."
        case .failed:
            return "Biometric authentication failed."
        case .passcodeNotSet:
            return "Device passcode is not set. Please set a passcode in Settings."
        case .invalidContext:
            return "Invalid authentication context."
        }
    }
}

/// Manages biometric authentication for the wallet
final class BiometricAuthManager {
    
    // MARK: - Types
    
    /// Represents the type of biometric available on the device
    enum BiometricType {
        case none
        case touchID
        case faceID
        
        var displayName: String {
            switch self {
            case .none: return "None"
            case .touchID: return "Touch ID"
            case .faceID: return "Face ID"
            }
        }
        
        var iconName: String {
            switch self {
            case .none: return "lock"
            case .touchID: return "touchid"
            case .faceID: return "faceid"
            }
        }
    }
    
    // MARK: - Properties
    
    /// Shared instance
    static let shared = BiometricAuthManager()
    
    /// The current authentication context
    private var context: LAContext?
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Get the type of biometric authentication available on this device
    var availableBiometricType: BiometricType {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        
        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .opticID:
            return .faceID // Treat Optic ID as Face ID for display purposes
        case .none:
            return .none
        @unknown default:
            return .none
        }
    }
    
    /// Check if biometric authentication is available and configured
    var isBiometricAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
    
    /// Check if device passcode is set
    var isPasscodeSet: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }
    
    /// Authenticate user with biometrics
    /// - Parameter reason: The reason for authentication displayed to the user
    /// - Returns: Boolean indicating success
    func authenticate(reason: String = "Authenticate to access your wallet") async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Passcode"
        
        var error: NSError?
        
        // Check if biometric authentication is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw mapLAError(error)
        }
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            
            if success {
                self.context = context
            }
            
            return success
        } catch let laError as LAError {
            throw mapLAError(laError)
        }
    }
    
    /// Authenticate user with device passcode or biometrics
    /// - Parameter reason: The reason for authentication displayed to the user
    /// - Returns: Boolean indicating success
    func authenticateWithPasscode(reason: String = "Authenticate to access your wallet") async throws -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        
        var error: NSError?
        
        // Check if device authentication is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw mapLAError(error)
        }
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            
            if success {
                self.context = context
            }
            
            return success
        } catch let laError as LAError {
            throw mapLAError(laError)
        }
    }
    
    /// Get authenticated context for keychain operations
    /// - Returns: The authenticated LAContext
    func getAuthenticatedContext() -> LAContext? {
        return context
    }
    
    /// Create a new authentication context for keychain operations
    /// - Parameter reason: The reason for authentication
    /// - Returns: An authenticated LAContext if successful
    func createAuthenticatedContext(reason: String = "Authenticate to access your wallet") async throws -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Passcode"
        
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            // Fall back to passcode if biometrics not available
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                throw mapLAError(error)
            }
            
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            
            if success {
                self.context = context
                return context
            } else {
                throw BiometricError.failed
            }
        }
        
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
            
            if success {
                self.context = context
                return context
            } else {
                throw BiometricError.failed
            }
        } catch let laError as LAError {
            throw mapLAError(laError)
        }
    }
    
    /// Invalidate the current authentication context
    func invalidateContext() {
        context?.invalidate()
        context = nil
    }
    
    // MARK: - Private Methods
    
    /// Map LAError to BiometricError
    private func mapLAError(_ error: NSError?) -> BiometricError {
        guard let error = error else {
            return .failed
        }
        
        if let laError = error as? LAError {
            return mapLAError(laError)
        }
        
        switch error.code {
        case LAError.biometryNotAvailable.rawValue:
            return .notAvailable
        case LAError.biometryNotEnrolled.rawValue:
            return .notEnrolled
        case LAError.biometryLockout.rawValue:
            return .lockout
        case LAError.userCancel.rawValue:
            return .cancelled
        case LAError.passcodeNotSet.rawValue:
            return .passcodeNotSet
        default:
            return .failed
        }
    }
    
    /// Map LAError to BiometricError
    private func mapLAError(_ error: LAError) -> BiometricError {
        switch error.code {
        case .biometryNotAvailable:
            return .notAvailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .biometryLockout:
            return .lockout
        case .userCancel, .systemCancel, .appCancel:
            return .cancelled
        case .passcodeNotSet:
            return .passcodeNotSet
        case .invalidContext:
            return .invalidContext
        default:
            return .failed
        }
    }
}
