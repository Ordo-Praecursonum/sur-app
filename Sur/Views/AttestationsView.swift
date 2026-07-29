//
//  AttestationsView.swift
//  Sur
//
//  Was previously its own standalone screen (List + toolbar); superseded by
//  AttestFeedView, which now owns the list and renders these same rows
//  alongside keystroke/camera/file/voice/call attestations in one unified
//  feed. What's left here — AttestationRow and ComposeAttestationView — are
//  reused as-is from AttestFeedView/ComposeMenuView.
//

import SwiftUI

struct AttestationRow: View {
    let item: AttestationItem
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.text).lineLimit(2)
            Text(originLabel)
                .font(.caption2)
                .foregroundColor(.secondary)
            if let cite = item.citation, !cite.isEmpty {
                Text(cite).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            HStack(spacing: 8) {
                statusBadge
                Spacer()
                if let tx = item.txHash {
                    Button { Pasteboard.copy(tx) } label: {
                        Text(shorten(tx))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                if item.status == .pending || item.status == .failed {
                    Button("Submit", action: onSubmit)
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            }
            if let err = item.error, item.status == .failed {
                Text(err).font(.caption2).foregroundColor(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var statusBadge: some View {
        let (label, color, icon): (String, Color, String) = {
            switch item.status {
            case .pending:    return ("Pending", .secondary, "clock")
            case .submitting: return ("Submitting…", .orange, "hourglass")
            case .submitted:  return ("On-chain", .green, "checkmark.seal.fill")
            case .failed:     return ("Failed", .red, "xmark.circle")
            }
        }()
        return Label {
            Text(label).font(.caption)
        } icon: {
            if item.status == .submitting { ProgressView() } else { Image(systemName: icon) }
        }
        .foregroundColor(color)
    }

    private var originLabel: String {
        (AttestationOrigin(rawValue: item.origin) ?? .humanKeyboard).label
    }

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(8))…\(s.suffix(4))"
    }
}

/// Record an attestation for content NOT typed on the Sur Keyboard. This makes a
/// device-signed DECLARATION of a chosen origin — it never claims the content was
/// human-typed (only the Sur Keyboard can prove that). The user picks the origin
/// and, for copied/imported content, a citation.
struct ComposeAttestationView: View {
    @Environment(\.dismiss) private var dismiss
    let onAttest: (_ text: String, _ origin: AttestationOrigin, _ citation: String?) -> Void

    @State private var text = ""
    @State private var origin: AttestationOrigin = .deviceAuthored
    @State private var citation = ""

    /// The compose screen is for declarations only — the human-typed origin comes
    /// solely from the Sur Keyboard.
    private let originOptions: [AttestationOrigin] =
        AttestationOrigin.allCases.filter { $0 != .humanKeyboard }

    private var canAttest: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if origin.needsCitation {
            return !citation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Origin", selection: $origin) {
                        ForEach(originOptions) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Where did this content come from?")
                } footer: {
                    Text(originFooter)
                }

                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                } header: {
                    Text("Content")
                } footer: {
                    Text("\(text.count) characters. The text is hashed — only its hash goes on-chain.")
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
                    Button {
                        onAttest(text, origin, origin.needsCitation ? citation : nil)
                        dismiss()
                    } label: {
                        Text("Sign & submit")
                    }
                    .disabled(!canAttest)
                } footer: {
                    Text("This is a device-signed declaration. It proves your device made this claim — it does NOT certify the text was human-typed. To prove human typing, type it on the Sur Keyboard.")
                }
            }
            .navigationTitle("New Attestation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var originFooter: String {
        switch origin {
        case .deviceAuthored: return "Authored on this device, but typing is not verified (e.g. typed or pasted here, not on the Sur Keyboard)."
        case .aiGenerated:    return "You declare this content was generated by AI."
        case .externalSource: return "Copied or quoted from another source — add a citation below."
        case .imported:       return "Imported from a file or another origin — add a note below."
        case .humanKeyboard:  return ""
        }
    }
}
