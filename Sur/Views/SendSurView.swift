//
//  SendSurView.swift
//  Sur
//
//  Send the chain's native token (SUR) to another sur1… account. Builds a
//  cosmos bank MsgSend, signs with the wallet account, and broadcasts.
//

import SwiftUI

struct SendSurView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var identity = SurChainIdentityManager.shared
    @StateObject private var config = SurChainConfig.shared

    /// Display balance string shown for context (passed from the settings screen).
    let currentBalance: String

    @State private var recipient = ""
    @State private var amount = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var successTxHash: String?
    @State private var successHeight: Int64?

    private var denom: String { config.network.displayDenom }

    private var isValid: Bool {
        let r = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let amountOK = SurChainIdentityManager.toMicroAmount(amount, exponent: config.network.displayExponent) != nil
        return r.hasPrefix("sur1") && r.count >= 39 && amountOK && !isSending
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

    private var formView: some View {
        Form {
            Section {
                TextField("sur1…", text: $recipient)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.footnote, design: .monospaced))
            } header: {
                Text("Recipient address")
            }

            Section {
                HStack {
                    TextField("0.0", text: $amount)
                        .keyboardType(.decimalPad)
                    Text(denom).foregroundColor(.secondary)
                }
            } header: {
                Text("Amount")
            } footer: {
                Text("Available: \(currentBalance). A small network fee is added.")
            }

            Section {
                Button {
                    Task { await send() }
                } label: {
                    HStack {
                        if isSending { ProgressView().padding(.trailing, 6) }
                        Text(isSending ? "Sending…" : "Send \(denom)")
                    }
                }
                .disabled(!isValid)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundColor(.red).font(.footnote)
                }
            }
        }
        .navigationTitle("Send \(denom)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(isSending)
            }
        }
    }

    private func successView(txHash: String) -> some View {
        Form {
            Section {
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text("Sent \(amount) \(denom)").fontWeight(.semibold)
                }
                Text("to \(recipient)")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
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
            }
        }
        .navigationTitle("Sent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func send() async {
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            let result = try await identity.sendSur(toAddress: recipient, displayAmount: amount)
            successTxHash = result.txHash
            successHeight = result.height
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
