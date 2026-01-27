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
    
    /// Current user's address for the selected network
    @Published private(set) var publicAddress: String?
    
    /// Short version of the public address for display
    @Published private(set) var shortAddress: String?
    
    /// Currently selected blockchain network
    @Published var selectedNetwork: BlockchainNetwork = .ethereum {
        didSet {
            BlockchainNetwork.saveSelected(selectedNetwork)
            updateAddressForNetwork()
        }
    }
    
    /// Addresses for all supported networks (cached)
    @Published private(set) var networkAddresses: [BlockchainNetwork: String] = [:]
    
    /// Whether biometric authentication is enabled
    @Published private(set) var isBiometricEnabled: Bool = false
    
    /// Error message if authentication failed
    @Published private(set) var errorMessage: String?
    
    /// Loading state for async operations
    @Published private(set) var isLoading: Bool = false
    
    /// Device public ID for display
    @Published private(set) var devicePublicID: String?
    
    /// Short version of device public ID for display
    @Published private(set) var shortDeviceID: String?
    
    // MARK: - Dependencies
    
    private let secureStorage = SecureEnclaveManager.shared
    private let biometricAuth = BiometricAuthManager.shared
    private let deviceIDManager = DeviceIDManager.shared
    
    // MARK: - Singleton
    
    /// Shared instance
    static let shared = AuthenticationManager()
    
    // MARK: - Initialization
    
    private init() {
        selectedNetwork = BlockchainNetwork.loadSelected()
        checkInitialState()
    }
    
    // MARK: - Public Methods
    
    /// Check initial authentication state
    func checkInitialState() {
        hasWallet = secureStorage.isWalletCreated()
        isBiometricEnabled = secureStorage.isBiometricEnabled()
        
        if hasWallet {
            // Load cached addresses if available
            loadCachedAddresses()
            // Load device public ID if available
            loadDevicePublicID()
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
            
            // Generate addresses for all networks
            let addresses = try MultiChainKeyManager.generateAllAddresses(from: mnemonic)
            networkAddresses = addresses
            
            // Get the private key for the default network (Ethereum)
            let (privateKey, _) = try MultiChainKeyManager.generateKeysForNetwork(mnemonic, network: .ethereum)
            
            // Generate device IDs from user private key
            let (_, devicePublicID) = try deviceIDManager.generateDeviceIDs(from: privateKey)
            deviceIDManager.saveDevicePublicID(devicePublicID)
            
            // Store securely
            try secureStorage.saveMnemonic(mnemonic, requireBiometric: useBiometric)
            try secureStorage.savePrivateKey(privateKey, requireBiometric: useBiometric)
            
            // Save addresses for all networks
            for (network, address) in addresses {
                try saveAddressForNetwork(address, network: network)
            }
            
            try secureStorage.saveBiometricEnabled(useBiometric)
            try secureStorage.saveWalletCreated(true)
            
            // Update state
            hasWallet = true
            updateAddressForNetwork()
            loadDevicePublicID()
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
            
            // Generate addresses for all networks
            let addresses = try MultiChainKeyManager.generateAllAddresses(from: mnemonic)
            networkAddresses = addresses
            
            // Get the private key for the default network (Ethereum)
            let (privateKey, _) = try MultiChainKeyManager.generateKeysForNetwork(mnemonic, network: .ethereum)
            
            // Generate device IDs from user private key
            let (_, devicePublicID) = try deviceIDManager.generateDeviceIDs(from: privateKey)
            deviceIDManager.saveDevicePublicID(devicePublicID)
            
            // Store securely
            try secureStorage.saveMnemonic(mnemonic, requireBiometric: useBiometric)
            try secureStorage.savePrivateKey(privateKey, requireBiometric: useBiometric)
            
            // Save addresses for all networks
            for (network, address) in addresses {
                try saveAddressForNetwork(address, network: network)
            }
            
            try secureStorage.saveBiometricEnabled(useBiometric)
            try secureStorage.saveWalletCreated(true)
            
            // Update state
            hasWallet = true
            updateAddressForNetwork()
            loadDevicePublicID()
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
                    // Load addresses
                    loadCachedAddresses()
                    updateAddressForNetwork()
                    loadDevicePublicID()
                    state = .authenticated
                } else {
                    state = .locked
                    throw BiometricError.failed
                }
            } else {
                // No biometric required, just unlock
                loadCachedAddresses()
                updateAddressForNetwork()
                loadDevicePublicID()
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
            // Clear cached addresses
            for network in BlockchainNetwork.allCases {
                UserDefaults.standard.removeObject(forKey: addressKey(for: network))
            }
            // Clear device IDs
            deviceIDManager.clearDeviceIDs()
            hasWallet = false
            publicAddress = nil
            shortAddress = nil
            networkAddresses = [:]
            devicePublicID = nil
            shortDeviceID = nil
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
    
    /// Get the private key for a specific network (requires authentication)
    /// - Parameter network: Target blockchain network
    /// - Returns: The derived private key data
    func getPrivateKey(for network: BlockchainNetwork) async throws -> Data {
        guard state == .authenticated else {
            throw BiometricError.cancelled
        }
        
        let mnemonic: String
        if isBiometricEnabled {
            let context = try await biometricAuth.createAuthenticatedContext(
                reason: "Access private key"
            )
            mnemonic = try secureStorage.getMnemonic(context: context)
        } else {
            mnemonic = try secureStorage.getMnemonic()
        }
        
        let (privateKey, _) = try MultiChainKeyManager.generateKeysForNetwork(mnemonic, network: network)
        return privateKey
    }
    
    /// Get the private key for the currently selected network
    func getPrivateKey() async throws -> Data {
        return try await getPrivateKey(for: selectedNetwork)
    }
    
    /// Get address for a specific network
    func getAddress(for network: BlockchainNetwork) -> String? {
        return networkAddresses[network]
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
        if case .error = state {
            state = hasWallet ? .locked : .unauthenticated
        }
    }
    
    // MARK: - Private Methods
    
    /// Update the displayed address for the selected network
    private func updateAddressForNetwork() {
        if let address = networkAddresses[selectedNetwork] {
            publicAddress = address
            shortAddress = MultiChainKeyManager.shortenAddress(address, for: selectedNetwork)
        } else if let address = loadAddressForNetwork(selectedNetwork) {
            publicAddress = address
            shortAddress = MultiChainKeyManager.shortenAddress(address, for: selectedNetwork)
            networkAddresses[selectedNetwork] = address
        }
    }
    
    /// Load cached addresses from storage
    private func loadCachedAddresses() {
        for network in BlockchainNetwork.allCases {
            if let address = loadAddressForNetwork(network) {
                networkAddresses[network] = address
            }
        }
    }
    
    /// Storage key for network address
    private func addressKey(for network: BlockchainNetwork) -> String {
        return "wallet.address.\(network.rawValue)"
    }
    
    /// Save address for a network
    private func saveAddressForNetwork(_ address: String, network: BlockchainNetwork) throws {
        UserDefaults.standard.set(address, forKey: addressKey(for: network))
    }
    
    /// Load address for a network
    private func loadAddressForNetwork(_ network: BlockchainNetwork) -> String? {
        return UserDefaults.standard.string(forKey: addressKey(for: network))
    }
    
    /// Load device public ID from storage
    private func loadDevicePublicID() {
        if let publicID = deviceIDManager.getStoredDevicePublicID() {
            devicePublicID = publicID
            shortDeviceID = DeviceIDManager.shortenDeviceID(publicID)
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
