//
//  AuthenticationManager.swift
//  Sur
//
//  Orchestrates the authentication flow for the wallet
//

import Foundation
import SwiftUI
import Combine

/// Represents the current authentication state
enum AuthenticationState: Equatable {
    case unknown
    case unauthenticated
    case authenticating
    case authenticated
    case locked
    case error(String)
    
    static func == (lhs: AuthenticationState, rhs: AuthenticationState) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown),
             (.unauthenticated, .unauthenticated),
             (.authenticating, .authenticating),
             (.authenticated, .authenticated),
             (.locked, .locked):
            return true
        case (.error(let lhsMessage), .error(let rhsMessage)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }
}

/// Main authentication manager that orchestrates wallet authentication
@MainActor
final class AuthenticationManager: ObservableObject {
    
    // MARK: - Published Properties
    
    /// Current authentication state
    @Published private(set) var state: AuthenticationState = .unknown
    
    /// Whether the user has an existing wallet
    @Published private(set) var hasWallet: Bool = false
    
    /// Current user's Ethereum address (if authenticated)
    @Published private(set) var publicAddress: String?
    
    /// Short version of the public address for display
    @Published private(set) var shortAddress: String?
    
    /// Whether biometric authentication is enabled
    @Published private(set) var isBiometricEnabled: Bool = false
    
    /// Error message if authentication failed
    @Published private(set) var errorMessage: String?
    
    /// Loading state for async operations
    @Published private(set) var isLoading: Bool = false
    
    // MARK: - Dependencies
    
    private let secureStorage = SecureEnclaveManager.shared
    private let biometricAuth = BiometricAuthManager.shared
    
    // MARK: - Singleton
    
    /// Shared instance
    static let shared = AuthenticationManager()
    
    // MARK: - Initialization
    
    private init() {
        checkInitialState()
    }
    
    // MARK: - Public Methods
    
    /// Check initial authentication state
    func checkInitialState() {
        hasWallet = secureStorage.isWalletCreated()
        isBiometricEnabled = secureStorage.isBiometricEnabled()
        
        if hasWallet {
            // Load public address (non-sensitive data)
            if let address = try? secureStorage.getPublicAddress() {
                publicAddress = address
                shortAddress = EthereumKeyManager.shortenAddress(address)
            }
            state = .locked
        } else {
            state = .unauthenticated
        }
    }
    
    /// Create a new wallet with a generated mnemonic
    /// - Parameter useBiometric: Whether to enable biometric protection
    /// - Returns: The generated mnemonic phrase (user must back this up)
    func createNewWallet(useBiometric: Bool) async throws -> String {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        do {
            // Generate new mnemonic
            let mnemonic = try MnemonicGenerator.generateMnemonic(wordCount: 12)
            
            // Derive keys from mnemonic
            let (privateKey, address) = try EthereumKeyManager.generateKeysFromMnemonic(mnemonic)
            
            // Store securely
            try secureStorage.saveMnemonic(mnemonic, requireBiometric: useBiometric)
            try secureStorage.savePrivateKey(privateKey, requireBiometric: useBiometric)
            try secureStorage.savePublicAddress(address)
            try secureStorage.saveBiometricEnabled(useBiometric)
            try secureStorage.saveWalletCreated(true)
            
            // Update state
            hasWallet = true
            publicAddress = address
            shortAddress = EthereumKeyManager.shortenAddress(address)
            isBiometricEnabled = useBiometric
            state = .authenticated
            
            return mnemonic
        } catch {
            errorMessage = error.localizedDescription
            state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Import an existing wallet using a mnemonic phrase
    /// - Parameters:
    ///   - mnemonic: The mnemonic phrase to import
    ///   - useBiometric: Whether to enable biometric protection
    func importWallet(mnemonic: String, useBiometric: Bool) async throws {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        do {
            // Validate mnemonic
            guard MnemonicGenerator.validateMnemonic(mnemonic) else {
                throw MnemonicError.invalidMnemonic
            }
            
            // Derive keys from mnemonic
            let (privateKey, address) = try EthereumKeyManager.generateKeysFromMnemonic(mnemonic)
            
            // Store securely
            try secureStorage.saveMnemonic(mnemonic, requireBiometric: useBiometric)
            try secureStorage.savePrivateKey(privateKey, requireBiometric: useBiometric)
            try secureStorage.savePublicAddress(address)
            try secureStorage.saveBiometricEnabled(useBiometric)
            try secureStorage.saveWalletCreated(true)
            
            // Update state
            hasWallet = true
            publicAddress = address
            shortAddress = EthereumKeyManager.shortenAddress(address)
            isBiometricEnabled = useBiometric
            state = .authenticated
        } catch {
            errorMessage = error.localizedDescription
            state = .error(error.localizedDescription)
            throw error
        }
    }
    
    /// Authenticate user to unlock wallet
    func authenticate() async throws {
        guard hasWallet else {
            state = .unauthenticated
            return
        }
        
        isLoading = true
        errorMessage = nil
        state = .authenticating
        
        defer { isLoading = false }
        
        do {
            if isBiometricEnabled && biometricAuth.isBiometricAvailable {
                // Authenticate with biometrics
                let success = try await biometricAuth.authenticate(
                    reason: "Unlock your Sur wallet"
                )
                
                if success {
                    // Load public address
                    if let address = try? secureStorage.getPublicAddress() {
                        publicAddress = address
                        shortAddress = EthereumKeyManager.shortenAddress(address)
                    }
                    state = .authenticated
                } else {
                    state = .locked
                    throw BiometricError.failed
                }
            } else {
                // No biometric required, just unlock
                if let address = try? secureStorage.getPublicAddress() {
                    publicAddress = address
                    shortAddress = EthereumKeyManager.shortenAddress(address)
                }
                state = .authenticated
            }
        } catch {
            errorMessage = error.localizedDescription
            state = .locked
            throw error
        }
    }
    
    /// Lock the wallet
    func lock() {
        state = .locked
        biometricAuth.invalidateContext()
    }
    
    /// Sign out and optionally delete wallet data
    /// - Parameter deleteWallet: Whether to delete all wallet data
    func signOut(deleteWallet: Bool = false) {
        if deleteWallet {
            secureStorage.deleteAllWalletData()
            hasWallet = false
            publicAddress = nil
            shortAddress = nil
        }
        
        isBiometricEnabled = false
        state = .unauthenticated
        errorMessage = nil
        biometricAuth.invalidateContext()
    }
    
    /// Get the mnemonic phrase (requires authentication)
    /// - Returns: The stored mnemonic phrase
    func getMnemonic() async throws -> String {
        guard state == .authenticated else {
            throw BiometricError.cancelled
        }
        
        if isBiometricEnabled {
            let context = try await biometricAuth.createAuthenticatedContext(
                reason: "View recovery phrase"
            )
            return try secureStorage.getMnemonic(context: context)
        } else {
            return try secureStorage.getMnemonic()
        }
    }
    
    /// Get the private key (requires authentication)
    /// - Returns: The stored private key data
    func getPrivateKey() async throws -> Data {
        guard state == .authenticated else {
            throw BiometricError.cancelled
        }
        
        if isBiometricEnabled {
            let context = try await biometricAuth.createAuthenticatedContext(
                reason: "Access private key"
            )
            return try secureStorage.getPrivateKey(context: context)
        } else {
            return try secureStorage.getPrivateKey()
        }
    }
    
    /// Check if biometric authentication is available
    var isBiometricAvailable: Bool {
        biometricAuth.isBiometricAvailable
    }
    
    /// Get the type of biometric available
    var biometricType: BiometricAuthManager.BiometricType {
        biometricAuth.availableBiometricType
    }
    
    /// Clear any error state
    func clearError() {
        errorMessage = nil
        if state == .error {
            state = hasWallet ? .locked : .unauthenticated
        }
    }
}

// MARK: - State Extension

extension AuthenticationState {
    /// Check if user is authenticated
    var isAuthenticated: Bool {
        self == .authenticated
    }
    
    /// Check if user needs to authenticate
    var needsAuthentication: Bool {
        switch self {
        case .locked, .error:
            return true
        default:
            return false
        }
    }
}
