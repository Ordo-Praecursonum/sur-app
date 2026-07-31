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
    let item: CapturedMediaAttestation
    @Environment(\.dismiss) private var dismiss

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
}
