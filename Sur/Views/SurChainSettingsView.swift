//
//  SurChainSettingsView.swift
//  Sur
//
//  Operational home for the Sur Chain: identity / device registration, fee-token
//  balance, and network (endpoint / RPC) selection. This is the mission-aligned
//  counterpart to the generic wallet screen — everything needed to push provenance
//  attestations to the chain.
//

import SwiftUI
import UIKit

/// Pasteboard writes routed off the main thread. `UIPasteboard.general` can block
/// the caller for several seconds on the iOS Simulator (pasteboard XPC / Universal
/// Clipboard sync), which froze the UI / tripped the watchdog when done on main.
enum Pasteboard {
    static func copy(_ string: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            UIPasteboard.general.string = string
        }
    }
}

struct SurChainSettingsView: View {
    @StateObject private var config = SurChainConfig.shared
    @StateObject private var identity = SurChainIdentityManager.shared

    @State private var balanceText: String = "—"
    @State private var balanceIsZero = false
    @State private var isLoadingBalance = false
    @State private var showRegister = false
    @State private var showSend = false
    @State private var showReceive = false
    @State private var errorMessage: String?

    // Custom endpoint editing
    @State private var customURL: String = ""
    @State private var customChainID: String = ""

    var body: some View {
        List {
            identitySection
            balanceSection
            networkSection
        }
        .navigationTitle("Sur Chain")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRegister) {
            DeviceRegistrationView()
        }
        .sheet(isPresented: $showSend, onDismiss: { Task { await loadBalance() } }) {
            SendSurView(currentBalance: balanceText)
        }
        .sheet(isPresented: $showReceive) {
            if let addr = identity.accountAddress() {
                ReceiveSurView(address: addr)
            }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .task { await loadBalance() }
        .onAppear {
            customURL = config.network.restURL
            customChainID = config.network.chainID
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            Button {
                if let addr = identity.accountAddress() {
                    Pasteboard.copy(addr)
                }
            } label: {
                HStack {
                    Text("Address")
                    Spacer()
                    Text(shorten(identity.accountAddress() ?? "—"))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .foregroundColor(.primary)
            HStack {
                Text("Status")
                Spacer()
                switch identity.state {
                case .registered(let deviceID):
                    Label(identity.deviceAlias ?? shorten(deviceID), systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                case .registering:
                    ProgressView()
                default:
                    Text("Not registered").foregroundColor(.secondary)
                }
            }
            if let deviceID = identity.registeredUsername {
                Button { Pasteboard.copy(deviceID) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Device id").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Image(systemName: "doc.on.doc").font(.caption).foregroundColor(.accentColor)
                        }
                        Text(deviceID)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                }
                .foregroundColor(.primary)
                Button(role: .destructive) {
                    identity.forgetRegistration()
                } label: {
                    Label("Reset registration", systemImage: "arrow.counterclockwise")
                }
            } else {
                Button {
                    showRegister = true
                } label: {
                    Label("Register this device", systemImage: "person.badge.key.fill")
                }
            }
            if let tx = identity.lastTxHash {
                Button {
                    Pasteboard.copy(tx)
                } label: {
                    HStack {
                        Text("Last tx")
                        Spacer()
                        Text(shorten(tx))
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                        Image(systemName: "doc.on.doc").font(.caption).foregroundColor(.accentColor)
                    }
                }
                .foregroundColor(.primary)
                if let h = identity.lastTxHeight {
                    HStack {
                        Text("Block")
                        Spacer()
                        Text("\(h)").foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text("Identity")
        } footer: {
            Text("Registering proves this device to the Sur Chain so your captures can be attributed to you.")
        }
    }

    // MARK: - Balance

    private var balanceSection: some View {
        Section {
            HStack {
                Text("Balance")
                Spacer()
                if isLoadingBalance {
                    ProgressView()
                } else {
                    Text(balanceText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            Button {
                Task { await loadBalance() }
            } label: {
                HStack {
                    if isLoadingBalance {
                        ProgressView().padding(.trailing, 4)
                        Text("Refreshing…")
                    } else {
                        Label("Refresh balance", systemImage: "arrow.clockwise")
                    }
                }
            }
            .disabled(isLoadingBalance)
            Button {
                showSend = true
            } label: {
                Label("Send \(config.network.displayDenom)", systemImage: "paperplane")
            }
            .disabled(balanceIsZero)
            Button {
                showReceive = true
            } label: {
                Label("Receive \(config.network.displayDenom)", systemImage: "qrcode")
            }
            .disabled(identity.accountAddress() == nil)
            if balanceIsZero && config.network.isTestLike {
                Text("Balance is zero. Use the \(config.network.environment.displayName) faucet to fund your address before registering or publishing.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text(config.network.displayDenom + " Balance")
        }
    }

    // MARK: - Network

    private var networkSection: some View {
        Section {
            Picker("Network", selection: Binding(
                get: { config.network.environment },
                set: { config.select($0) }
            )) {
                ForEach(SurChainEnvironment.allCases) { env in
                    Text(env.displayName).tag(env)
                }
            }

            if config.network.environment == .custom {
                TextField("REST URL (https://…:1317)", text: $customURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Chain ID (e.g. sur-testnet-1)", text: $customChainID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Apply custom endpoint") {
                    config.setCustom(restURL: customURL, chainID: customChainID)
                    Task { await loadBalance() }
                }
            }

            HStack {
                Text("Endpoint")
                Spacer()
                Text(config.network.restURL)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text("Chain ID")
                Spacer()
                Text(config.network.chainID).foregroundColor(.secondary)
            }
        } header: {
            Text("Network")
        } footer: {
            Text("Switching networks changes where attestations are submitted and read. Device registration is per-network.")
        }
    }

    // MARK: - Actions

    private func loadBalance() async {
        guard let address = identity.accountAddress() else {
            balanceText = "—"
            return
        }
        isLoadingBalance = true
        defer { isLoadingBalance = false }
        do {
            let balance = try await CosmosClient.shared.getBalance(address: address)
            balanceIsZero = (Decimal(string: balance.amount) ?? 0) == 0
            balanceText = balance.formatted(
                displayDenom: config.network.displayDenom,
                exponent: config.network.displayExponent
            )
        } catch {
            balanceText = "unavailable"
        }
    }

    private func shorten(_ s: String) -> String {
        guard s.count > 16 else { return s }
        return "\(s.prefix(10))…\(s.suffix(4))"
    }
}
