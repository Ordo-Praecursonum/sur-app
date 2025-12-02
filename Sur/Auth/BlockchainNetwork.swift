//
//  BlockchainNetwork.swift
//  Sur
//
//  Defines supported blockchain networks and their derivation paths
//

import Foundation
import SwiftUI

/// Supported blockchain networks with their BIP-44 derivation paths
/// Reference: https://support.atomicwallet.io/article/146-list-of-derivation-paths
enum BlockchainNetwork: String, CaseIterable, Identifiable, Codable {
    case ethereum = "ethereum"
    case bitcoin = "bitcoin"
    case bsc = "bsc"
    case tron = "tron"
    case cosmos = "cosmos"
    case solana = "solana"
    case originTrail = "origintrail"
    case base = "base"
    
    var id: String { rawValue }
    
    /// Display name for the network
    var displayName: String {
        switch self {
        case .ethereum:
            return "Ethereum"
        case .bitcoin:
            return "Bitcoin"
        case .bsc:
            return "BNB Smart Chain"
        case .tron:
            return "Tron"
        case .cosmos:
            return "Cosmos"
        case .solana:
            return "Solana"
        case .originTrail:
            return "OriginTrail"
        case .base:
            return "Base"
        }
    }
    
    /// Network symbol/ticker
    var symbol: String {
        switch self {
        case .ethereum:
            return "ETH"
        case .bitcoin:
            return "BTC"
        case .bsc:
            return "BNB"
        case .tron:
            return "TRX"
        case .cosmos:
            return "ATOM"
        case .solana:
            return "SOL"
        case .originTrail:
            return "TRAC"
        case .base:
            return "ETH"
        }
    }
    
    /// BIP-44 coin type (hardened)
    /// Reference: https://github.com/satoshilabs/slips/blob/master/slip-0044.md
    var coinType: UInt32 {
        switch self {
        case .ethereum:
            return 60      // m/44'/60'/...
        case .bitcoin:
            return 0       // m/44'/0'/...
        case .bsc:
            return 60      // BSC uses same as Ethereum (EVM compatible)
        case .tron:
            return 195     // m/44'/195'/...
        case .cosmos:
            return 118     // m/44'/118'/...
        case .solana:
            return 501     // m/44'/501'/...
        case .originTrail:
            return 60      // OriginTrail uses Ethereum derivation path (ERC-20 token)
        case .base:
            return 60      // Base uses same as Ethereum (EVM compatible)
        }
    }
    
    /// Full BIP-44 derivation path
    /// Format: m / purpose' / coin_type' / account' / change / address_index
    var derivationPath: String {
        switch self {
        case .ethereum:
            return "m/44'/60'/0'/0/0"
        case .bitcoin:
            return "m/44'/0'/0'/0/0"
        case .bsc:
            return "m/44'/60'/0'/0/0"  // Same as Ethereum (EVM compatible)
        case .tron:
            return "m/44'/195'/0'/0/0"
        case .cosmos:
            return "m/44'/118'/0'/0/0"
        case .solana:
            return "m/44'/501'/0'/0'"  // Solana uses hardened at all levels
        case .originTrail:
            return "m/44'/60'/0'/0/0"  // Same as Ethereum (ERC-20)
        case .base:
            return "m/44'/60'/0'/0/0"  // Same as Ethereum (EVM compatible)
        }
    }
    
    /// Chain icon (SF Symbol name)
    var iconName: String {
        switch self {
        case .ethereum:
            return "e.circle.fill"
        case .bitcoin:
            return "bitcoinsign.circle.fill"
        case .bsc:
            return "b.circle.fill"
        case .tron:
            return "t.circle.fill"
        case .cosmos:
            return "atom"
        case .solana:
            return "s.circle.fill"
        case .originTrail:
            return "point.3.filled.connected.trianglepath.dotted"
        case .base:
            return "cube.fill"
        }
    }
    
    /// Chain color for UI
    var color: Color {
        switch self {
        case .ethereum:
            return Color(red: 0.39, green: 0.45, blue: 0.95)  // Ethereum blue
        case .bitcoin:
            return Color(red: 0.96, green: 0.62, blue: 0.14)  // Bitcoin orange
        case .bsc:
            return Color(red: 0.95, green: 0.73, blue: 0.13)  // BSC yellow
        case .tron:
            return Color(red: 0.92, green: 0.07, blue: 0.14)  // Tron red
        case .cosmos:
            return Color(red: 0.18, green: 0.18, blue: 0.35)  // Cosmos dark purple
        case .solana:
            return Color(red: 0.60, green: 0.30, blue: 0.90)  // Solana purple
        case .originTrail:
            return Color(red: 0.06, green: 0.51, blue: 0.89)  // OriginTrail blue
        case .base:
            return Color(red: 0.00, green: 0.33, blue: 1.00)  // Base blue
        }
    }
    
    /// Address prefix (for display/validation)
    var addressPrefix: String {
        switch self {
        case .ethereum, .originTrail, .bsc, .base:
            return "0x"
        case .bitcoin:
            return ""  // Bitcoin addresses have various prefixes (1, 3, bc1)
        case .tron:
            return "T"  // Tron addresses start with T
        case .cosmos:
            return "cosmos"
        case .solana:
            return ""  // Solana uses base58 addresses
        }
    }
    
    /// Whether this network uses the secp256k1 curve
    var usesSecp256k1: Bool {
        switch self {
        case .ethereum, .bitcoin, .cosmos, .originTrail, .bsc, .tron, .base:
            return true
        case .solana:
            return false  // Solana uses Ed25519
        }
    }
    
    /// Derivation path components as array of indices
    /// Hardened indices have 0x80000000 added
    var pathComponents: [UInt32] {
        let hardenedOffset: UInt32 = 0x80000000
        
        switch self {
        case .ethereum, .originTrail, .bsc, .base:
            return [
                44 + hardenedOffset,     // purpose (hardened)
                60 + hardenedOffset,     // coin_type (hardened)
                0 + hardenedOffset,      // account (hardened)
                0,                        // change (not hardened)
                0                         // address_index (not hardened)
            ]
        case .bitcoin:
            return [
                44 + hardenedOffset,     // purpose (hardened)
                0 + hardenedOffset,      // coin_type (hardened)
                0 + hardenedOffset,      // account (hardened)
                0,                        // change (not hardened)
                0                         // address_index (not hardened)
            ]
        case .tron:
            return [
                44 + hardenedOffset,     // purpose (hardened)
                195 + hardenedOffset,    // coin_type (hardened)
                0 + hardenedOffset,      // account (hardened)
                0,                        // change (not hardened)
                0                         // address_index (not hardened)
            ]
        case .cosmos:
            return [
                44 + hardenedOffset,     // purpose (hardened)
                118 + hardenedOffset,    // coin_type (hardened)
                0 + hardenedOffset,      // account (hardened)
                0,                        // change (not hardened)
                0                         // address_index (not hardened)
            ]
        case .solana:
            return [
                44 + hardenedOffset,     // purpose (hardened)
                501 + hardenedOffset,    // coin_type (hardened)
                0 + hardenedOffset,      // account (hardened)
                0 + hardenedOffset       // Solana uses hardened at this level too
            ]
        }
    }
}

/// Storage key for selected network
extension BlockchainNetwork {
    static let selectedNetworkKey = "selectedBlockchainNetwork"
    
    /// Save selected network to UserDefaults
    static func saveSelected(_ network: BlockchainNetwork) {
        UserDefaults.standard.set(network.rawValue, forKey: selectedNetworkKey)
    }
    
    /// Load selected network from UserDefaults (defaults to Ethereum)
    static func loadSelected() -> BlockchainNetwork {
        guard let rawValue = UserDefaults.standard.string(forKey: selectedNetworkKey),
              let network = BlockchainNetwork(rawValue: rawValue) else {
            return .ethereum
        }
        return network
    }
}
