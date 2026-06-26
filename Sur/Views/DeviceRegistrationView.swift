//
//  DeviceRegistrationView.swift
//  Sur
//
//  One-time device registration on the Sur Chain (MsgRegisterUsername). Identity
//  is the device id (surdev1…) — a pseudonym derived from your key + this device,
//  NOT a public username. A human display name is optional and stays on-device.
//  Requires a funded Sur Chain account and a real device (App Attest / Secure Enclave).
//

import SwiftUI

struct DeviceRegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var identity = SurChainIdentityManager.shared

    @State private var alias: String = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var successTxHash: String?
    @State private var successHeight: Int64?

    // The alias is optional; if provided it must be a reasonable label.
    private var aliasValid: Bool {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.range(of: "^[a-zA-Z0-9 _-]{1,32}$", options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            if let tx = successTxHash {
                successView(txHash: tx)
            } else {
                formView
            }
        }
    }

    // MARK: - Form

    private var formView: some View {
        Form {
            Section {
                Label(
                    "This device registers under a private device id (surdev1…). Your name is never put on-chain.",
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundColor(.secondary)
            }

            Section {
                TextField("Display name (optional)", text: $alias)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Display name (optional)")
            } footer: {
                Text("A label shown only to you, on this device. It is not your on-chain identity and is never shared. Leave blank to stay fully pseudonymous.")
            }

            if let address = identity.accountAddress() {
                Section("Fee account") {
                    Text(address)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Button {
                    Task { await register() }
                } label: {
                    HStack {
                        if isWorking { ProgressView().padding(.trailing, 6) }
                        Text(isWorking ? "Registering…" : "Register this device")
                    }
                }
                .disabled(!aliasValid || isWorking)
            } footer: {
                Text("Your fee account must hold a small balance to cover the registration fee.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundColor(.red).font(.footnote)
                }
            }
        }
        .navigationTitle("Register Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(isWorking)
            }
        }
    }

    // MARK: - Success

    private func successView(txHash: String) -> some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text("Device registered").fontWeight(.semibold)
                }
            }
            if let deviceID = identity.registeredUsername {
                Section {
                    Button { Pasteboard.copy(deviceID) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Your device id").font(.caption).foregroundColor(.secondary)
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
                    if let alias = identity.deviceAlias {
                        HStack {
                            Text("Display name")
                            Spacer()
                            Text(alias).foregroundColor(.secondary)
                        }
                    }
                } footer: {
                    Text("Share this device id with anyone you want to be able to verify content you create. It reveals nothing about your identity until you choose to link it.")
                }
            }
            Section {
                Button { Pasteboard.copy(txHash) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Transaction").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Image(systemName: "doc.on.doc").font(.caption).foregroundColor(.accentColor)
                        }
                        Text(txHash)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                }
                .foregroundColor(.primary)
                if let h = successHeight {
                    HStack {
                        Text("Block height")
                        Spacer()
                        Text("\(h)").foregroundColor(.secondary)
                    }
                }
            } footer: {
                Text("Look this hash up in the explorer to view it on-chain.")
            }
        }
        .navigationTitle("Registered")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func register() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await identity.register(alias: alias.isEmpty ? nil : alias)
            // Show the tx hash instead of dismissing, so the user sees the on-chain result.
            successTxHash = identity.lastTxHash ?? "(submitted)"
            successHeight = identity.lastTxHeight
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
