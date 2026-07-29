//
//  CapturePreviewView.swift
//  Sur
//
//  Post-capture screen shown over Sur Cam: what was captured, plus a live
//  status readout (pending → submitting → on-chain/failed) for the
//  attestation CaptureAttestationCoordinator already kicked off.
//

import SwiftUI

struct CapturePreviewView: View {
    let image: UIImage?
    let isVideo: Bool
    let attestationId: UUID

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = CapturedMediaAttestationStore.shared

    private var item: CapturedMediaAttestation? {
        store.items.first { $0.id == attestationId }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isVideo {
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
            switch item?.status {
            case .submitted:
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text("Attested on-chain")
            case .failed:
                Image(systemName: "xmark.circle").foregroundColor(.red)
                Text(item?.error ?? "Attestation failed")
                    .lineLimit(1)
            case .submitting, .pending, .none:
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
