//
//  CallAttestationRow.swift
//  Sur
//
//  Row for a CallAttestation — used both in the Calls tab's Recents list and
//  the Attest feed's Calls filter chip. Same status-badge convention as the
//  other attestation rows.
//

import SwiftUI

struct CallAttestationRow: View {
    let item: CallAttestation
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "phone.fill").foregroundColor(.secondary)
                Text(item.calleeDisplayName)
                Text("· \(item.method.displayName)")
                    .foregroundColor(.secondary)
            }
            Text(item.calleeNumberE164)
                .font(.caption2)
                .foregroundColor(.secondary)
            if item.citation != EventDescription.call {
                Text(item.citation).font(.caption2).foregroundColor(.secondary).lineLimit(1)
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

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(8))…\(s.suffix(4))"
    }
}
