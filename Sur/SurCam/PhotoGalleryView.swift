//
//  PhotoGalleryView.swift
//  Sur
//
//  Quick in-app gallery of recent Sur Cam captures, reached via the
//  thumbnail button next to the shutter. Photos are read from
//  CapturedImageCache (this app's own sandboxed copy) rather than the
//  Photos library, matching the add-only privacy model documented in
//  CaptureAttestationCoordinator. Videos don't have a cached frame in v1,
//  so they show a placeholder tile — tapping still surfaces their
//  attestation status.
//

import SwiftUI

struct PhotoGalleryView: View {
    @ObservedObject private var store = CapturedMediaAttestationStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected: CapturedMediaAttestation?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if store.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No captures yet")
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(store.items) { item in
                            tile(for: item)
                                .onTapGesture { selected = item }
                        }
                    }
                }
            }
            .navigationTitle("Captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $selected) { item in
                CaptureDetailView(item: item)
            }
        }
    }

    @ViewBuilder
    private func tile(for item: CapturedMediaAttestation) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if item.kind == .photo, let image = CapturedImageCache.load(id: item.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(Theme.secondaryBackground)
                    .overlay {
                        Image(systemName: item.kind == .video ? "video.fill" : "photo")
                            .foregroundColor(.secondary)
                    }
            }
            statusDot(for: item.status)
                .padding(4)
        }
        .frame(height: 110)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusDot(for status: CapturedMediaAttestation.Status) -> some View {
        let color: Color = {
            switch status {
            case .submitted:  return .green
            case .submitting: return .orange
            case .pending:    return .gray
            case .failed:     return .red
            }
        }()
        return Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
    }
}

private struct CaptureDetailView: View {
    @ObservedObject private var store = CapturedMediaAttestationStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var displayedID: UUID
    @State private var showEdit = false
    @State private var showDetails = false
    private let initialItem: CapturedMediaAttestation

    init(item: CapturedMediaAttestation) {
        self.initialItem = item
        _displayedID = State(initialValue: item.id)
    }

    /// Looked up live from the store (not the frozen `initialItem`) so the
    /// status badge keeps updating as it submits, and so — after an edit —
    /// switching `displayedID` shows the new attestation in place instead of
    /// the caller needing to go find it in the grid themselves.
    private var item: CapturedMediaAttestation {
        store.items.first(where: { $0.id == displayedID }) ?? initialItem
    }

    private var canEdit: Bool {
        item.kind == .photo && item.status == .submitted && CapturedImageCache.exists(id: item.id)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if item.kind == .photo, let image = CapturedImageCache.load(id: item.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.white)
                    Text("Video captured")
                        .foregroundColor(.white)
                }
            }

            VStack {
                Spacer()
                if showDetails {
                    detailsPanel
                        .padding(.bottom, 8)
                }
                actionRow
                    .padding(.bottom, 8)
                statusBar
                    .padding(.bottom, 40)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundColor(.white)
                    .shadow(radius: 4)
            }
            .padding()
        }
        .sheet(isPresented: $showEdit) {
            EditCapturedPhotoView(original: item) { newID in
                displayedID = newID
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            if canEdit {
                pillButton(label: "Edit", icon: "slider.horizontal.3") { showEdit = true }
            }
            pillButton(label: showDetails ? "Hide Details" : "Details", icon: "info.circle") {
                withAnimation { showDetails.toggle() }
            }
        }
    }

    private func pillButton(label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.5))
                .clipShape(Capsule())
        }
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailRow(label: "Content hash", value: hex(item.contentHash), copyValue: hex(item.contentHash, full: true))
            if item.status == .submitted {
                if let tx = item.txHash {
                    detailRow(label: "Transaction", value: shorten(tx), copyValue: tx)
                }
                proofLinkRow
            }
            if let filter = item.filterApplied {
                detailRow(label: "Filter", value: filter.capitalized, copyValue: nil)
            }
            if item.qrApplied {
                detailRow(label: "QR sticker", value: "Applied", copyValue: nil)
            }
        }
        .padding(14)
        .background(.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
    }

    private func detailRow(label: String, value: String, copyValue: String?) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
            if let copyValue {
                Button {
                    Pasteboard.copy(copyValue)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .font(.footnote)
    }

    private var proofLinkRow: some View {
        let link = ProofLink.build(contentHash: item.contentHash)
        return HStack(spacing: 8) {
            Text("Proof link")
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            Link("Open", destination: link)
                .foregroundColor(Theme.brandOrange)
            Button {
                Pasteboard.copy(link.absoluteString)
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .font(.footnote)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            switch item.status {
            case .submitted:
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text("Attested on-chain")
            case .failed:
                Image(systemName: "xmark.circle").foregroundColor(.red)
                Text(item.error ?? "Attestation failed")
                    .lineLimit(1)
            case .submitting, .pending:
                ProgressView().tint(.white)
                Text("Attesting…")
            }
        }
        .font(.subheadline)
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.6))
        .clipShape(Capsule())
    }

    private func hex(_ data: Data, full: Bool = false) -> String {
        let hexString = data.map { String(format: "%02x", $0) }.joined()
        if full || hexString.count <= 16 { return hexString }
        return "\(hexString.prefix(8))…\(hexString.suffix(6))"
    }

    private func shorten(_ s: String) -> String {
        guard s.count > 12 else { return s }
        return "\(s.prefix(8))…\(s.suffix(4))"
    }
}
