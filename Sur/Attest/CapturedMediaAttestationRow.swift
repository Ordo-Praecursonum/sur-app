//
//  CapturedMediaAttestationRow.swift
//  Sur
//
//  Feed row for a CapturedMediaAttestation (Sur Cam photo/video) — same
//  layout/status-badge convention as the other attestation rows.
//

import SwiftUI

struct CapturedMediaAttestationRow: View {
    let item: CapturedMediaAttestation
    let onSubmit: () -> Void
    var onEdit: (() -> Void)?

    private var canEdit: Bool {
        item.kind == .photo && item.status == .submitted && item.localAssetIdentifier != nil && onEdit != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: item.kind == .photo ? "photo.fill" : "video.fill")
                    .foregroundColor(.secondary)
                Text(item.kind == .photo ? "Sur Cam photo" : "Sur Cam video")
                if let filter = item.filterApplied {
                    Text("· \(filter.capitalized)")
                        .foregroundColor(.secondary)
                }
                if item.qrApplied {
                    Image(systemName: "qrcode")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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
                if canEdit, let onEdit {
                    Button("Edit", action: onEdit)
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
