//
//  FileAttestationRow.swift
//  Sur
//
//  Feed row for a FileAttestation — same layout/status-badge convention as
//  AttestationRow (Views/AttestationsView.swift), just file-shaped.
//

import SwiftUI

struct FileAttestationRow: View {
    let item: FileAttestation
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.fill").foregroundColor(.secondary)
                Text(item.fileName).lineLimit(1)
            }
            Text(ByteCountFormatter.string(fromByteCount: Int64(item.fileSize), countStyle: .file))
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

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(8))…\(s.suffix(4))"
    }
}
