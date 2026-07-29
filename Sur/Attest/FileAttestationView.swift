//
//  FileAttestationView.swift
//  Sur
//
//  File attestation flow: pick a file, hash it, declare its origin (defaults
//  to "Imported / other", matching AttestationOrigin.imported's needsCitation
//  requirement), and submit via FileAttestationStore. Mirrors
//  ComposeAttestationView's origin/citation UI for consistency.
//

import SwiftUI
import CryptoKit

struct FileAttestationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = FileAttestationStore.shared

    @State private var showPicker = true
    @State private var pickedFileName: String?
    @State private var pickedFileSize: Int?
    @State private var contentHash: Data?
    @State private var origin: AttestationOrigin = .imported
    @State private var citation = ""

    private let originOptions: [AttestationOrigin] =
        AttestationOrigin.allCases.filter { $0 != .humanKeyboard }

    private var canAttest: Bool {
        guard contentHash != nil else { return false }
        if origin.needsCitation {
            return !citation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Group {
                if let name = pickedFileName, let size = pickedFileSize, let hash = contentHash {
                    Form {
                        Section {
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundColor(Theme.brandOrange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            HStack {
                                Text("Fingerprint")
                                Spacer()
                                Text(shortenHex(hash))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        } header: {
                            Text("File")
                        }

                        Section {
                            Picker("Origin", selection: $origin) {
                                ForEach(originOptions) { Text($0.label).tag($0) }
                            }
                        } header: {
                            Text("Where did this file come from?")
                        }

                        if origin.needsCitation {
                            Section {
                                TextField(origin == .externalSource ? "URL, book, author…" : "Source / note",
                                          text: $citation)
                                    .textInputAutocapitalization(.never)
                            } header: {
                                Text("Citation")
                            }
                        }

                        Section {
                            Button("Sign & submit") {
                                store.enqueue(
                                    fileName: name, fileSize: size, contentHash: hash,
                                    origin: origin, citation: origin.needsCitation ? citation : nil
                                )
                                dismiss()
                            }
                            .disabled(!canAttest)
                        } footer: {
                            Text("This is a device-signed declaration of the file's fingerprint — only its hash goes on-chain, never the file itself.")
                        }
                    }
                } else {
                    Color.clear
                }
            }
            .navigationTitle("New File Attestation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker, onDismiss: {
                if pickedFileName == nil { dismiss() }
            }) {
                DocumentPicker { picked in
                    guard let (name, data) = picked else { return }
                    pickedFileName = name
                    pickedFileSize = data.count
                    contentHash = Data(SHA256.hash(data: data))
                }
            }
        }
    }

    private func shortenHex(_ data: Data) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard hex.count > 16 else { return hex }
        return "\(hex.prefix(10))…\(hex.suffix(6))"
    }
}
