//
//  SurChainNetwork.swift
//  Sur
//
//  Sur Chain (Cosmos) network configuration: which endpoint the app talks to for
//  identity registration, attestation submission, and balance queries.
//
//  The app is operationally tied to ONE chain — the Sur Chain — not the generic
//  multi-chain wallet. This type lets the user pick Local / Devnet / Testnet /
//  Mainnet or enter a custom REST endpoint + chain id. The selection is persisted
//  and applied to `CosmosClient.shared` at runtime (no recompile, no relaunch).
//

import Foundation

/// A selectable Sur Chain environment.
enum SurChainEnvironment: String, CaseIterable, Codable, Identifiable {
    case local
    case devnet
    case testnet
    case mainnet
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:   return "Local"
        case .devnet:  return "Devnet"
        case .testnet: return "Testnet"
        case .mainnet: return "Mainnet"
        case .custom:  return "Custom"
        }
    }
}

/// Resolved Sur Chain connection parameters.
struct SurChainNetwork: Codable, Equatable {
    var environment: SurChainEnvironment
    /// Base REST (gRPC-gateway) endpoint, e.g. https://rest.testnet.surprotocol.xyz
    var restURL: String
    /// Cosmos chain id, e.g. sur-testnet-1
    var chainID: String
    /// Fee/stake denom used for balances and gas (micro-SUR).
    var feeDenom: String
    /// Display denom and the exponent to convert (1 SUR = 10^exponent feeDenom).
    var displayDenom: String
    var displayExponent: Int

    /// Built-in presets. Endpoints follow docs/INTEGRATION.md §3.1.
    static func preset(_ env: SurChainEnvironment) -> SurChainNetwork {
        switch env {
        case .local:
            // `ignite chain serve` derives the chain id from the project name → "surchain".
            return SurChainNetwork(environment: .local,
                                   restURL: "http://localhost:1317",
                                   chainID: "surchain",
                                   feeDenom: "usur", displayDenom: "SUR", displayExponent: 6)
        case .devnet:
            return SurChainNetwork(environment: .devnet,
                                   restURL: "https://rest.devnet.surprotocol.xyz",
                                   chainID: "sur-devnet-1",
                                   feeDenom: "usur", displayDenom: "SUR", displayExponent: 6)
        case .testnet:
            return SurChainNetwork(environment: .testnet,
                                   restURL: "https://rest.testnet.surprotocol.xyz",
                                   chainID: "sur-testnet-1",
                                   feeDenom: "usur", displayDenom: "SUR", displayExponent: 6)
        case .mainnet:
            return SurChainNetwork(environment: .mainnet,
                                   restURL: "https://rest.surprotocol.xyz",
                                   chainID: "sur-1",
                                   feeDenom: "usur", displayDenom: "SUR", displayExponent: 6)
        case .custom:
            // Sensible starting point the user then edits.
            return SurChainNetwork(environment: .custom,
                                   restURL: "http://localhost:1317",
                                   chainID: "surchain",
                                   feeDenom: "usur", displayDenom: "SUR", displayExponent: 6)
        }
    }

    /// Whether this network can support a testnet faucet hint when the balance is zero.
    var isTestLike: Bool { environment == .testnet || environment == .devnet || environment == .local }

    var baseURL: URL? { URL(string: restURL) }
}

/// Observable singleton holding the active Sur Chain network and applying it to
/// `CosmosClient.shared`. Persisted in the shared app-group defaults so the value
/// survives relaunch.
final class SurChainConfig: ObservableObject {

    static let shared = SurChainConfig()

    private static let storageKey = "sur.chain.network.v1"
    private static let appGroup = "group.com.ordo.sure.Sur"

    private let defaults: UserDefaults

    @Published var network: SurChainNetwork {
        didSet {
            persist()
            apply()
        }
    }

    private init() {
        self.defaults = UserDefaults(suiteName: Self.appGroup) ?? .standard
        // Load persisted config, defaulting to Testnet.
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode(SurChainNetwork.self, from: data) {
            self.network = decoded
        } else {
            self.network = .preset(.testnet)
        }
        apply()
    }

    /// Select a built-in environment.
    func select(_ env: SurChainEnvironment) {
        if env == .custom {
            // Keep whatever custom values exist, but flip the environment marker.
            var n = network
            n.environment = .custom
            network = n
        } else {
            network = .preset(env)
        }
    }

    /// Update the custom endpoint. Trims whitespace, auto-prepends an `http://`
    /// scheme when the user omits it (e.g. "127.0.0.1:1317"), and rejects empties.
    /// Returns true if applied.
    @discardableResult
    func setCustom(restURL: String, chainID: String) -> Bool {
        var url = restURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = chainID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !id.isEmpty else { return false }
        let lower = url.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            url = "http://" + url
        }
        guard URL(string: url) != nil else { return false }
        network = SurChainNetwork(environment: .custom,
                                  restURL: url, chainID: id,
                                  feeDenom: network.feeDenom,
                                  displayDenom: network.displayDenom,
                                  displayExponent: network.displayExponent)
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(network) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Point the shared CosmosClient at the active network.
    private func apply() {
        guard let url = network.baseURL else { return }
        CosmosClient.shared.baseURL = url
        CosmosClient.shared.chainID = network.chainID
        CosmosClient.shared.feeDenom = network.feeDenom
    }
}
